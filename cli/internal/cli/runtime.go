package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"github.com/yangy003/ios-debug-system/cli/internal/config"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ios-debug-system/cli/internal/device"
	"github.com/yangy003/ios-debug-system/cli/internal/protocol"
	"github.com/yangy003/ios-debug-system/cli/internal/transport"
)

type DeviceDiscoverer interface {
	List(context.Context) ([]device.Device, error)
	Resolve(context.Context, device.Selector) (device.Device, error)
	CheckReady(context.Context, device.Device) error
}

type Runtime struct {
	root       *cobra.Command
	load       func(context.Context, config.LoadOptions) (config.Config, error)
	devices    DeviceDiscoverer
	newUSB     func() transport.DeviceTransport
	newTCP     func(string) (transport.DeviceTransport, error)
	emitter    *contract.Emitter
	stdout     io.Writer
	now        func() time.Time
	started    time.Time
	workingDir string
	userHome   string

	loadOnce sync.Once
	loaded   config.Config
	loadErr  error
}

func newRuntime(root *cobra.Command, deps Dependencies) *Runtime {
	stdout := deps.Stdout
	if stdout == nil {
		stdout = io.Discard
	}
	loader := deps.LoadConfig
	if loader == nil {
		loader = config.Load
	}
	discoverer := deps.Devices
	if discoverer == nil {
		discoverer = device.NewDiscoverer(commandRunner{}, "")
	}
	newUSB := deps.NewUSB
	if newUSB == nil {
		newUSB = transport.NewUSB
	}
	newTCP := deps.NewTCP
	if newTCP == nil {
		newTCP = transport.NewTCP
	}
	now := deps.Now
	if now == nil {
		now = time.Now
	}
	return &Runtime{
		root: root, load: loader, devices: discoverer, newUSB: newUSB, newTCP: newTCP,
		emitter: contract.NewEmitter(stdout), now: now, started: now(),
		stdout:     stdout,
		workingDir: deps.WorkingDir, userHome: deps.UserHome,
	}
}

func (r *Runtime) Resolve(ctx context.Context, requireDevice bool) (config.Config, *device.Device, *protocol.Client, error) {
	cfg, err := r.loadConfig(ctx)
	if err != nil {
		return cfg, nil, nil, err
	}
	if cfg.Transport == "tcp" {
		tr, err := r.newTCP(cfg.TCPHost)
		if err != nil {
			return cfg, nil, nil, err
		}
		return cfg, nil, protocol.NewClient(tr, protocol.Target{Port: cfg.Port}, cfg.Token), nil
	}
	if !requireDevice {
		return cfg, nil, nil, nil
	}
	selected, err := r.devices.Resolve(ctx, device.Selector{UDID: cfg.DeviceID, AllowSingle: cfg.DeviceID == ""})
	if err != nil {
		return cfg, nil, nil, err
	}
	if err := r.devices.CheckReady(ctx, selected); err != nil {
		return cfg, nil, nil, err
	}
	client := protocol.NewClient(r.newUSB(), protocol.Target{DeviceID: selected.UDID, Port: cfg.Port}, cfg.Token)
	return cfg, &selected, client, nil
}

func (r *Runtime) loadConfig(ctx context.Context) (config.Config, error) {
	r.loadOnce.Do(func() {
		options, err := r.loadOptions()
		if err != nil {
			r.loadErr = err
			return
		}
		r.loaded, r.loadErr = r.load(ctx, options)
	})
	return r.loaded, r.loadErr
}

func (r *Runtime) loadOptions() (config.LoadOptions, error) {
	values := config.CLIValues{}
	var err error
	if values.DeviceID, err = optionalString(r.root, "device"); err != nil {
		return config.LoadOptions{}, err
	}
	if values.Port, err = optionalUint16(r.root, "port"); err != nil {
		return config.LoadOptions{}, err
	}
	if values.OutputDir, err = optionalString(r.root, "output-dir"); err != nil {
		return config.LoadOptions{}, err
	}
	if values.Transport, err = optionalString(r.root, "transport"); err != nil {
		return config.LoadOptions{}, err
	}
	if values.TCPHost, err = optionalString(r.root, "tcp-host"); err != nil {
		return config.LoadOptions{}, err
	}
	return config.LoadOptions{CLI: values, WorkingDir: r.workingDir, UserHome: r.userHome}, nil
}

func optionalString(root *cobra.Command, name string) (*string, error) {
	if !root.PersistentFlags().Changed(name) {
		return nil, nil
	}
	value, err := root.PersistentFlags().GetString(name)
	if err != nil {
		return nil, contract.New(contract.ConfigInvalid, err)
	}
	return &value, nil
}

func optionalUint16(root *cobra.Command, name string) (*uint16, error) {
	if !root.PersistentFlags().Changed(name) {
		return nil, nil
	}
	value, err := root.PersistentFlags().GetUint16(name)
	if err != nil {
		return nil, contract.New(contract.ConfigInvalid, err)
	}
	return &value, nil
}

func (r *Runtime) Success(data any, meta contract.Meta, humanText ...string) error {
	jsonMode, err := r.root.PersistentFlags().GetBool("json")
	if err != nil {
		return contract.New(contract.ConfigInvalid, err)
	}
	if jsonMode {
		return r.emitter.Success(data, meta)
	}
	text := "Success.\n"
	if len(humanText) != 0 {
		text = humanText[0]
	}
	if _, err := fmt.Fprint(r.stdout, text); err != nil {
		return contract.New(contract.IOFailure, err)
	}
	return nil
}

func (r *Runtime) Elapsed() time.Duration {
	elapsed := r.now().Sub(r.started)
	if elapsed < 0 {
		return 0
	}
	return elapsed
}

func metaFor(selected *device.Device, elapsed time.Duration) contract.Meta {
	meta := contract.Meta{ProtocolVersion: 1, DurationMS: elapsed.Milliseconds()}
	if selected != nil {
		meta.DeviceID = selected.UDID
	}
	return meta
}

type commandRunner struct{}

func (commandRunner) Run(ctx context.Context, executable string, args ...string) error {
	err := exec.CommandContext(ctx, executable, args...).Run()
	var missing *exec.Error
	if errors.As(err, &missing) {
		return contract.New(contract.ToolMissing, err)
	}
	return err
}
