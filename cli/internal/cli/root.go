package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/internal/config"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/device"
	"github.com/yangy003/ap-ios-debug-system/internal/doctor"
	"github.com/yangy003/ap-ios-debug-system/internal/protocol"
	"github.com/yangy003/ap-ios-debug-system/internal/scaffold"
	"github.com/yangy003/ap-ios-debug-system/internal/transport"
)

type Dependencies struct {
	Version        string
	Stdout         io.Writer
	Stderr         io.Writer
	LoadConfig     func(context.Context, config.LoadOptions) (config.Config, error)
	Devices        DeviceDiscoverer
	NewUSB         func() transport.DeviceTransport
	NewTCP         func(string) (transport.DeviceTransport, error)
	Now            func() time.Time
	WorkingDir     string
	UserHome       string
	ExecutablePath string
	Doctor         doctor.Dependencies
}

var usbProbeSlot = make(chan struct{}, 1)

func productionUSBProbe(ctx context.Context) (int, error) {
	return boundedUSBProbe(ctx, ios.ListDevices)
}

func boundedUSBProbe(ctx context.Context, list func() (ios.DeviceList, error)) (int, error) {
	select {
	case usbProbeSlot <- struct{}{}:
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	type result struct {
		count int
		err   error
	}
	completed := make(chan result, 1)
	go func() {
		devices, err := list()
		<-usbProbeSlot
		completed <- result{count: len(devices.DeviceList), err: err}
	}()
	select {
	case result := <-completed:
		return result.count, result.err
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

func NewProductionDependencies(stdout, stderr io.Writer) Dependencies {
	workingDir, _ := os.Getwd()
	userHome, _ := os.UserHomeDir()
	executablePath, _ := os.Executable()
	discoverer := device.NewDiscoverer(commandRunner{}, "")

	deps := Dependencies{
		Stdout: stdout, Stderr: stderr, LoadConfig: config.Load, Devices: discoverer,
		NewUSB: transport.NewUSB, NewTCP: transport.NewTCP, Now: time.Now,
		WorkingDir: workingDir, UserHome: userHome, ExecutablePath: executablePath,
	}
	clientFor := func(cfg config.Config, selected *device.Device) (*protocol.Client, error) {
		var tr transport.DeviceTransport
		var err error
		target := protocol.Target{Port: cfg.Port}
		if cfg.Transport == "tcp" {
			tr, err = transport.NewTCP(cfg.TCPHost)
		} else {
			tr = transport.NewUSB()
			if selected != nil {
				target.DeviceID = selected.UDID
			}
		}
		if err != nil {
			return nil, err
		}
		return protocol.NewClient(tr, target, cfg.Token), nil
	}
	deps.Doctor = doctor.Dependencies{
		LookPath: exec.LookPath,
		Run: func(ctx context.Context, executable string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, executable, args...).Output()
		},
		DeviceDiscoverer: discoverer,
		USBProbe:         productionUSBProbe,
		TCPProbe: func(ctx context.Context, cfg config.Config) error {
			tr, err := transport.NewTCP(cfg.TCPHost)
			if err != nil {
				return err
			}
			conn, err := tr.Dial(ctx, "", cfg.Port)
			if err != nil {
				return err
			}
			return conn.Close()
		},
		AppProbe: func(ctx context.Context, cfg config.Config, selected *device.Device) error {
			client, err := clientFor(cfg, selected)
			if err != nil {
				return err
			}
			var value json.RawMessage
			_, err = client.DoJSON(ctx, http.MethodGet, "/v1/health", nil, 1<<20, &value)
			return err
		},
		ProtocolVersionProbe: func(ctx context.Context, cfg config.Config, selected *device.Device) (int, error) {
			client, err := clientFor(cfg, selected)
			if err != nil {
				return 0, err
			}
			var health struct {
				ProtocolVersion int `json:"protocol_version"`
			}
			_, err = client.DoJSON(ctx, http.MethodGet, "/v1/health", nil, 1<<20, &health)
			return health.ProtocolVersion, err
		},
		CapabilitiesProbe: func(ctx context.Context, cfg config.Config, selected *device.Device) error {
			client, err := clientFor(cfg, selected)
			if err != nil {
				return err
			}
			var value json.RawMessage
			_, err = client.DoJSON(ctx, http.MethodGet, "/v1/capabilities", nil, 1<<20, &value)
			return err
		},
		TemplateLocator: scaffold.NewLocator(executablePath, userHome),
		ExecutablePath:  executablePath,
	}
	return deps
}

func NewRoot(deps Dependencies) *cobra.Command {
	cmd := &cobra.Command{
		Use:           "ap-ios-debug",
		Short:         "AppPilot iOS Debug CLI",
		Version:       deps.Version,
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	cmd.SetVersionTemplate("AppPilot {{.Name}} version {{.Version}}\n")
	cmd.SetOut(deps.Stdout)
	cmd.SetErr(deps.Stderr)
	cmd.PersistentFlags().Bool("json", false, "emit exactly one JSON document on stdout")
	cmd.PersistentFlags().String("device", "", "target device UDID")
	cmd.PersistentFlags().Uint16("port", 0, "App debug port (default 9876)")
	cmd.PersistentFlags().String("output-dir", "", "default artifact directory")
	cmd.PersistentFlags().String("transport", "", "device transport: usb or tcp")
	cmd.PersistentFlags().String("tcp-host", "", "loopback host for the tcp transport")
	runtime := newRuntime(cmd, deps)
	cmd.AddCommand(
		newDevicesCommand(runtime),
		newAppCommand(runtime),
		newRequestCommand(runtime),
		newActionsCommand(runtime),
		newStateCommand(runtime),
		newScreenshotCommand(runtime),
		newRecordingCommand(runtime),
		newInitCommand(runtime),
		newDoctorCommand(runtime, deps.Doctor, deps.Version),
	)
	return cmd
}

func Execute(args []string, stdout, stderr io.Writer, deps Dependencies) int {
	deps.Stdout = stdout
	deps.Stderr = stderr
	emitter := contract.NewEmitter(stdout)

	var err error
	if portErr := validatePortArgument(args); portErr != nil {
		err = portErr
	} else {
		root := NewRoot(deps)
		jsonMode := hasJSONFlag(args)
		var cobraOutput bytes.Buffer
		if jsonMode {
			root.SetOut(&cobraOutput)
		}
		root.SetArgs(args)
		executed, executeErr := root.ExecuteC()
		err = executeErr
		if err == nil && jsonMode && executed == root {
			if version, versionErr := root.Flags().GetBool("version"); versionErr == nil && version {
				return emitJSONSuccess(emitter, map[string]string{"version": deps.Version})
			}
			return emitJSONSuccess(emitter, map[string]string{"help": cobraOutput.String()})
		}
	}
	if err == nil {
		return 0
	}

	stable := stableCommandError(err)
	if isPortError(err) {
		stable = contract.NewWithHint(contract.ConfigInvalid, err, "Use a port from 1 through 65535.")
	}
	var reported *reportedCommandError
	if errors.As(err, &reported) {
		return contract.ExitCode(stable)
	}
	if hasJSONFlag(args) {
		_ = emitter.Failure(stable)
	} else {
		_, _ = fmt.Fprintf(stderr, "ap-ios-debug: %s %s\n", stable.Message, stable.Hint)
	}
	return contract.ExitCode(stable)
}

type reportedCommandError struct{ err error }

func (e *reportedCommandError) Error() string { return e.err.Error() }
func (e *reportedCommandError) Unwrap() error { return e.err }

func stableCommandError(err error) *contract.Error {
	var stable *contract.Error
	if errors.As(err, &stable) {
		return stable
	}
	return contract.New(contract.ConfigInvalid, err)
}

func emitJSONSuccess(emitter *contract.Emitter, data any) int {
	if err := emitter.Success(data, contract.Meta{ProtocolVersion: 1}); err != nil {
		return contract.ExitCode(err)
	}
	return 0
}

type portArgumentError struct{ cause error }

func (e *portArgumentError) Error() string { return "invalid port" }
func (e *portArgumentError) Unwrap() error { return e.cause }

func validatePortArgument(args []string) error {
	for i, arg := range args {
		var value string
		switch {
		case arg == "--port" && i+1 < len(args):
			value = args[i+1]
		case strings.HasPrefix(arg, "--port="):
			value = strings.TrimPrefix(arg, "--port=")
		default:
			continue
		}
		port, err := strconv.ParseUint(value, 10, 16)
		if err != nil || port == 0 {
			return &portArgumentError{cause: err}
		}
	}
	return nil
}

func isPortError(err error) bool {
	_, ok := err.(*portArgumentError)
	return ok
}

func hasJSONFlag(args []string) bool {
	enabled := false
	for _, arg := range args {
		if arg == "--json" {
			enabled = true
			continue
		}
		if strings.HasPrefix(arg, "--json=") {
			value, err := strconv.ParseBool(strings.TrimPrefix(arg, "--json="))
			if err != nil {
				return true
			}
			enabled = value
		}
	}
	return enabled
}
