package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/yangy003/ios-debug-system/cli/internal/config"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ios-debug-system/cli/internal/doctor"
	"github.com/yangy003/ios-debug-system/cli/internal/transport"
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

func NewRoot(deps Dependencies) *cobra.Command {
	cmd := &cobra.Command{
		Use:           "ios-debug",
		Short:         "Debug an opted-in iOS App through a stable local protocol",
		Version:       deps.Version,
		SilenceErrors: true,
		SilenceUsage:  true,
	}
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
		_, _ = fmt.Fprintf(stderr, "ios-debug: %s %s\n", stable.Message, stable.Hint)
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
