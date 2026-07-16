package doctor

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/ggyy0515/AppPilot/internal/buildinfo"
	"github.com/ggyy0515/AppPilot/internal/config"
	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/ggyy0515/AppPilot/internal/device"
	"github.com/ggyy0515/AppPilot/internal/scaffold"
)

const (
	maxVersionBytes = 256
	defaultTimeout  = 5 * time.Second
)

type Check struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Message string `json:"message"`
	Hint    string `json:"hint"`
}

type Report struct {
	Healthy bool    `json:"healthy"`
	Version string  `json:"version"`
	Checks  []Check `json:"checks"`
}

type DeviceDiscoverer interface {
	List(context.Context) ([]device.Device, error)
	CheckReady(context.Context, device.Device) error
}

type Dependencies struct {
	Version              string
	LookPath             func(string) (string, error)
	Run                  func(context.Context, string, ...string) ([]byte, error)
	ConfigLoader         func(context.Context, config.LoadOptions) (config.Config, error)
	DeviceDiscoverer     DeviceDiscoverer
	USBProbe             func(context.Context) (int, error)
	TCPProbe             func(context.Context, config.Config) error
	AppProbe             func(context.Context, config.Config, *device.Device) error
	ProtocolVersionProbe func(context.Context, config.Config, *device.Device) (int, error)
	CapabilitiesProbe    func(context.Context, config.Config, *device.Device) error
	TemplateLocator      scaffold.Locator
	ExecutablePath       string
	Secrets              []string
	Timeout              time.Duration
}

type runState struct {
	config       config.Config
	configErr    error
	devicectlErr error
	secrets      []string
}

type namedCheck struct {
	name string
	run  func(context.Context, Dependencies, *runState) (Check, error)
}

func Run(ctx context.Context, deps Dependencies) (Report, error) {
	deps = defaults(deps)
	state := &runState{secrets: append([]string(nil), deps.Secrets...)}
	configCtx, cancelConfig := context.WithTimeout(ctx, deps.Timeout)
	state.config, state.configErr = deps.ConfigLoader(configCtx, config.LoadOptions{})
	configDeadlineErr := contextDeadlineError(configCtx)
	cancelConfig()
	if state.config.Token != "" {
		state.secrets = append(state.secrets, state.config.Token)
	}
	if configDeadlineErr != nil {
		state.configErr = contract.New(contract.RequestTimeout, configDeadlineErr)
	} else if state.configErr != nil {
		state.configErr = classify(state.configErr, configDeadlineErr, contract.ConfigInvalid)
	}

	report := Report{Version: deps.Version, Healthy: true, Checks: make([]Check, 0, 6)}
	checks := []namedCheck{
		{"xcode-select", checkXcodeSelect},
		{"devicectl", checkDeviceCtl},
		{"usbmuxd", checkTransport},
		{"config", checkConfig},
		{"template", checkTemplate},
		{"path", checkPath},
	}
	var firstErr error
	for _, item := range checks {
		checkCtx, cancel := context.WithTimeout(ctx, deps.Timeout)
		result, err := item.run(checkCtx, deps, state)
		deadlineErr := contextDeadlineError(checkCtx)
		cancel()
		if deadlineErr != nil {
			result = failed(item.name+" check timed out", hintForCode(contract.RequestTimeout))
			err = contract.New(contract.RequestTimeout, deadlineErr)
		} else if err != nil {
			err = classify(err, deadlineErr, contract.IOFailure)
		}
		result.Name = item.name
		report.Checks = append(report.Checks, result)
		if result.Status == "fail" {
			report.Healthy = false
		}
		if firstErr == nil && err != nil {
			firstErr = contract.NewWithHint(contract.CodeOf(err), err, result.Hint)
		}
	}
	return report, firstErr
}

func contextDeadlineError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if deadline, ok := ctx.Deadline(); ok && !time.Now().Before(deadline) {
		return context.DeadlineExceeded
	}
	return nil
}

func defaults(deps Dependencies) Dependencies {
	if deps.Version == "" {
		deps.Version = buildinfo.Version
	}
	if deps.LookPath == nil {
		deps.LookPath = exec.LookPath
	}
	if deps.Run == nil {
		deps.Run = func(ctx context.Context, executable string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, executable, args...).Output()
		}
	}
	if deps.ConfigLoader == nil {
		deps.ConfigLoader = config.Load
	}
	if deps.ExecutablePath == "" {
		deps.ExecutablePath, _ = os.Executable()
	}
	if deps.Timeout <= 0 {
		deps.Timeout = defaultTimeout
	}
	return deps
}

func checkXcodeSelect(ctx context.Context, deps Dependencies, _ *runState) (Check, error) {
	executable, err := deps.LookPath("xcode-select")
	if err != nil {
		return failure(contract.ToolMissing, "xcode-select is unavailable", "Install Xcode command line tools.", err)
	}
	if _, err := deps.Run(ctx, executable, "-p"); err != nil {
		return failure(classifyCode(err, ctx.Err(), contract.ToolMissing), "Xcode developer directory is unavailable", "Select an active Xcode with xcode-select.", err)
	}
	return passed("Xcode developer directory is selected"), nil
}

func checkDeviceCtl(ctx context.Context, deps Dependencies, state *runState) (Check, error) {
	xcrun, err := deps.LookPath("xcrun")
	if err != nil {
		state.devicectlErr = contract.New(contract.ToolMissing, err)
		return failure(contract.ToolMissing, "xcrun is unavailable", "Install Xcode command line tools.", err)
	}
	if _, err := deps.Run(ctx, xcrun, "--find", "devicectl"); err != nil {
		state.devicectlErr = contract.New(classifyCode(err, ctx.Err(), contract.ToolMissing), err)
		return failure(contract.CodeOf(state.devicectlErr), "devicectl is unavailable", "Install a current Xcode release.", err)
	}
	output, err := deps.Run(ctx, xcrun, "devicectl", "--version")
	if err != nil {
		state.devicectlErr = contract.New(classifyCode(err, ctx.Err(), contract.ToolMissing), err)
		return failure(contract.CodeOf(state.devicectlErr), "devicectl cannot run", "Select a current Xcode release.", err)
	}
	version := safeOneLine(output, state.secrets...)
	if version == "" {
		return passed("devicectl is available"), nil
	}
	return passed("devicectl is available: " + version), nil
}

func checkTransport(ctx context.Context, deps Dependencies, state *runState) (Check, error) {
	if state.configErr != nil {
		return warning("Transport diagnostics skipped because configuration is invalid", "Fix the configuration check, then rerun doctor."), nil
	}
	if state.config.Transport == "tcp" {
		if deps.TCPProbe == nil {
			return failure(contract.TransportFailure, "TCP transport diagnostics are unavailable", "Use a loopback TCP host and retry.", errors.New("TCP probe is unavailable"))
		}
		if err := deps.TCPProbe(ctx, state.config); err != nil {
			return failure(classifyCode(err, ctx.Err(), contract.TransportFailure), "TCP transport is unavailable", "Start the loopback debug server and retry.", err)
		}
		return checkApp(ctx, deps, state, nil, "TCP transport and App protocol are available")
	}
	if state.devicectlErr != nil {
		return warning("USB diagnostics skipped because devicectl is unavailable", "Fix the devicectl check, then rerun doctor."), nil
	}
	if deps.DeviceDiscoverer == nil || deps.USBProbe == nil {
		return failure(contract.IOFailure, "USB device service is unavailable", "Reconnect the device and restart usbmuxd.", errors.New("USB diagnostics are unavailable"))
	}
	count, probeErr := deps.USBProbe(ctx)
	if probeErr != nil || count < 0 {
		if probeErr == nil {
			probeErr = errors.New("invalid usbmuxd probe result")
		}
		return failure(classifyCode(probeErr, ctx.Err(), contract.TransportFailure), "USB device service is unavailable", "Reconnect the device and restart usbmuxd.", probeErr)
	}
	devices, listErr := deps.DeviceDiscoverer.List(ctx)
	if listErr != nil {
		return failure(classifyCode(listErr, ctx.Err(), contract.TransportFailure), "USB device discovery failed", "Reconnect the device and retry discovery.", listErr)
	}
	selected, noDevice, err := resolveUSBDevice(devices, state.config.DeviceID)
	if err != nil {
		return failure(contract.CodeOf(err), "A deterministic iOS device could not be selected", hintFor(err), err)
	}
	if noDevice {
		return warning("USB device service is available, but no iOS device is connected", "Connect and unlock a physical iOS device."), nil
	}
	if err := deps.DeviceDiscoverer.CheckReady(ctx, selected); err != nil {
		return failure(classifyCode(err, ctx.Err(), contract.TransportFailure), "The selected iOS device is not ready", hintFor(err), err)
	}
	return checkApp(ctx, deps, state, &selected, "USB transport and App protocol are available")
}

func checkApp(ctx context.Context, deps Dependencies, state *runState, selected *device.Device, message string) (Check, error) {
	if deps.AppProbe == nil || deps.ProtocolVersionProbe == nil || deps.CapabilitiesProbe == nil {
		return failure(contract.AppNotReachable, "App protocol diagnostics are unavailable", "Launch a Debug build with APIOSDebugKit enabled.", errors.New("App probes are unavailable"))
	}
	if err := deps.AppProbe(ctx, state.config, selected); err != nil {
		return failure(classifyCode(err, ctx.Err(), contract.AppNotReachable), "The App debug server is not reachable", hintForCode(contract.AppNotReachable), err)
	}
	version, err := deps.ProtocolVersionProbe(ctx, state.config, selected)
	if err != nil {
		return failure(classifyCode(err, ctx.Err(), contract.ProtocolMismatch), "The App protocol version is unavailable", hintForCode(contract.ProtocolMismatch), err)
	}
	if version != 1 {
		return failure(contract.ProtocolMismatch, "The App debug protocol is incompatible", hintForCode(contract.ProtocolMismatch), errors.New("unsupported protocol version"))
	}
	if err := deps.CapabilitiesProbe(ctx, state.config, selected); err != nil {
		return failure(classifyCode(err, ctx.Err(), contract.ProtocolMismatch), "App capabilities are unavailable", hintForCode(contract.ProtocolMismatch), err)
	}
	return passed(message), nil
}

func checkConfig(_ context.Context, _ Dependencies, state *runState) (Check, error) {
	if state.configErr != nil {
		return failure(contract.CodeOf(state.configErr), "Configuration is invalid", "Fix the named configuration source.", state.configErr)
	}
	return passed("Configuration sources are valid"), nil
}

func checkTemplate(_ context.Context, deps Dependencies, _ *runState) (Check, error) {
	if deps.TemplateLocator == nil {
		return failure(contract.IOFailure, "APIOSDebugKit template is unavailable", "Run make install-local from the repository.", errors.New("template locator is unavailable"))
	}
	path, err := deps.TemplateLocator.Locate()
	if err != nil || path == "" {
		if err == nil {
			err = errors.New("template path is empty")
		}
		return failure(classifyCode(err, nil, contract.IOFailure), "APIOSDebugKit template is unavailable", "Run make install-local from the repository.", err)
	}
	return passed("APIOSDebugKit template is available"), nil
}

func checkPath(_ context.Context, deps Dependencies, _ *runState) (Check, error) {
	found, err := deps.LookPath("ap-ios-debug")
	if err != nil || !samePath(found, deps.ExecutablePath) {
		return warning("The running ap-ios-debug is not the executable resolved through PATH", "Add the installed ap-ios-debug directory to PATH."), nil
	}
	return passed("ap-ios-debug resolves through PATH"), nil
}

func resolveUSBDevice(devices []device.Device, identifier string) (device.Device, bool, error) {
	matches := make([]device.Device, 0, len(devices))
	for _, candidate := range devices {
		if !candidate.Available {
			continue
		}
		if identifier == "" || candidate.UDID == identifier {
			matches = append(matches, candidate)
		}
	}
	if len(matches) == 1 {
		return matches[0], false, nil
	}
	if len(matches) > 1 {
		return device.Device{}, false, contract.New(contract.MultipleDevices, nil)
	}
	if identifier == "" {
		return device.Device{}, true, nil
	}
	return device.Device{}, false, contract.New(contract.NoDevice, nil)
}

func classify(err, deadlineErr error, fallback contract.Code) error {
	return contract.New(classifyCode(err, deadlineErr, fallback), err)
}

func classifyCode(err, deadlineErr error, fallback contract.Code) contract.Code {
	if errors.Is(deadlineErr, context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return contract.RequestTimeout
	}
	code := contract.CodeOf(err)
	if code != contract.ProtocolMismatch || isExplicitProtocolMismatch(err) {
		return code
	}
	return fallback
}

func isExplicitProtocolMismatch(err error) bool {
	var stable *contract.Error
	return errors.As(err, &stable) && contract.CodeOf(err) == contract.ProtocolMismatch
}

func failure(code contract.Code, message, hint string, cause error) (Check, error) {
	if code == contract.RequestTimeout {
		hint = hintForCode(code)
	}
	check := failed(message, hint)
	return check, contract.NewWithHint(code, cause, hint)
}

func hintFor(err error) string { return hintForCode(contract.CodeOf(err)) }

func hintForCode(code contract.Code) string { return contract.New(code, nil).Hint }

func samePath(left, right string) bool {
	if left == "" || right == "" {
		return false
	}
	left, leftErr := filepath.Abs(left)
	right, rightErr := filepath.Abs(right)
	return leftErr == nil && rightErr == nil && filepath.Clean(left) == filepath.Clean(right)
}

func passed(message string) Check { return Check{Status: "pass", Message: message} }

func warning(message, hint string) Check {
	return Check{Status: "warning", Message: message, Hint: hint}
}

func failed(message, hint string) Check {
	return Check{Status: "fail", Message: message, Hint: hint}
}

func safeOneLine(output []byte, secrets ...string) string {
	value := string(output)
	for _, secret := range secrets {
		if secret != "" {
			value = strings.ReplaceAll(value, secret, "[redacted]")
		}
	}
	if index := strings.IndexAny(value, "\r\n"); index >= 0 {
		value = value[:index]
	}
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, value)
	value = strings.TrimSpace(value)
	lower := strings.ToLower(value)
	if strings.Contains(lower, "authorization") || strings.Contains(lower, "bearer") || strings.Contains(lower, "ios_debug_token") {
		return "version available"
	}
	bytes := []byte(value)
	if len(bytes) > maxVersionBytes {
		bytes = bytes[:maxVersionBytes]
		for !utf8.Valid(bytes) {
			bytes = bytes[:len(bytes)-1]
		}
	}
	return string(bytes)
}
