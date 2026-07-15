package doctor_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/internal/config"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/device"
	"github.com/yangy003/ap-ios-debug-system/internal/doctor"
)

type discoverer struct {
	devices []device.Device
	err     error
	ready   error
	listN   *int
	readyN  *int
}

func (d discoverer) List(context.Context) ([]device.Device, error) {
	if d.listN != nil {
		(*d.listN)++
	}
	return d.devices, d.err
}

func (d discoverer) CheckReady(context.Context, device.Device) error {
	if d.readyN != nil {
		(*d.readyN)++
	}
	return d.ready
}

type locator struct {
	path string
	err  error
}

func (l locator) Locate() (string, error) { return l.path, l.err }

type countingLocator struct {
	path  string
	count *int
}

func (l countingLocator) Locate() (string, error) {
	(*l.count)++
	return l.path, nil
}

func healthyDependencies(t *testing.T) doctor.Dependencies {
	t.Helper()
	executable := filepath.Join(t.TempDir(), "ap-ios-debug")
	return doctor.Dependencies{
		Version: "1.2.3",
		LookPath: func(name string) (string, error) {
			switch name {
			case "xcode-select":
				return "/usr/bin/xcode-select", nil
			case "xcrun":
				return "/usr/bin/xcrun", nil
			case "ap-ios-debug":
				return executable, nil
			default:
				return "", os.ErrNotExist
			}
		},
		Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			if name == "/usr/bin/xcrun" && strings.Join(args, " ") == "devicectl --version" {
				return []byte("devicectl 1.0\n"), nil
			}
			return []byte("/Applications/Xcode.app\n"), nil
		},
		ConfigLoader: func(context.Context, config.LoadOptions) (config.Config, error) {
			return config.Config{Token: "configured-secret", Transport: "usb"}, nil
		},
		DeviceDiscoverer: discoverer{devices: []device.Device{{UDID: "one", Available: true}}},
		USBProbe:         func(context.Context) (int, error) { return 1, nil },
		TCPProbe:         func(context.Context, config.Config) error { return nil },
		AppProbe:         func(context.Context, config.Config, *device.Device) error { return nil },
		ProtocolVersionProbe: func(context.Context, config.Config, *device.Device) (int, error) {
			return 1, nil
		},
		CapabilitiesProbe: func(context.Context, config.Config, *device.Device) error { return nil },
		TemplateLocator:   locator{path: "/installed/ap-ios-debug-kit"},
		ExecutablePath:    executable,
	}
}

func TestRunReturnsStableOrderedChecks(t *testing.T) {
	report, err := doctor.Run(context.Background(), healthyDependencies(t))
	require.NoError(t, err)
	require.True(t, report.Healthy)
	require.Equal(t, "1.2.3", report.Version)
	require.Equal(t, []string{"xcode-select", "devicectl", "usbmuxd", "config", "template", "path"}, checkNames(report.Checks))
	for _, check := range report.Checks {
		require.Equal(t, "pass", check.Status)
	}
}

func TestNoDeviceIsWarningButMissingDevicectlFails(t *testing.T) {
	deps := healthyDependencies(t)
	var probeN int
	deps.DeviceDiscoverer = discoverer{}
	deps.USBProbe = func(context.Context) (int, error) { probeN++; return 0, nil }
	report, err := doctor.Run(context.Background(), deps)
	require.NoError(t, err)
	require.True(t, report.Healthy)
	require.Equal(t, "warning", statusForCheck(report, "usbmuxd"))
	require.Equal(t, 1, probeN)

	deps = healthyDependencies(t)
	original := deps.LookPath
	deps.LookPath = func(name string) (string, error) {
		if name == "xcrun" {
			return "", os.ErrNotExist
		}
		return original(name)
	}
	report, err = doctor.Run(context.Background(), deps)
	require.Equal(t, contract.ToolMissing, contract.CodeOf(err))
	require.False(t, report.Healthy)
	require.Len(t, report.Checks, 6)
	require.Equal(t, "fail", statusForCheck(report, "devicectl"))
}

func TestRunZeroDevicesStillFailsWhenUSBServiceProbeFails(t *testing.T) {
	deps := healthyDependencies(t)
	var probeN, listN int
	deps.DeviceDiscoverer = discoverer{listN: &listN}
	deps.USBProbe = func(context.Context) (int, error) {
		probeN++
		return 0, errors.New("service unavailable")
	}
	report, err := doctor.Run(context.Background(), deps)
	require.Equal(t, 1, probeN)
	require.Zero(t, listN)
	require.Equal(t, contract.TransportFailure, contract.CodeOf(err))
	require.Equal(t, 4, contract.ExitCode(err))
	require.False(t, report.Healthy)
	require.Equal(t, "fail", statusForCheck(report, "usbmuxd"))
	require.Len(t, report.Checks, 6)
}

func TestRunUSBUsesDeterministicDeviceResolution(t *testing.T) {
	devices := []device.Device{
		{Identifier: "core-1", UDID: "udid-1", Available: true},
		{Identifier: "core-2", UDID: "udid-2", Available: true},
	}
	t.Run("unconfigured multiple devices", func(t *testing.T) {
		deps := healthyDependencies(t)
		var probeN, readyN, appN int
		deps.DeviceDiscoverer = discoverer{devices: devices, readyN: &readyN}
		deps.USBProbe = func(context.Context) (int, error) { probeN++; return 2, nil }
		deps.AppProbe = func(context.Context, config.Config, *device.Device) error { appN++; return nil }
		report, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.MultipleDevices, contract.CodeOf(err))
		require.False(t, report.Healthy)
		require.Equal(t, []int{1, 0, 0}, []int{probeN, readyN, appN})
		require.Len(t, report.Checks, 6)
	})

	t.Run("configured missing device", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
			return config.Config{Transport: "usb", DeviceID: "core-2"}, nil
		}
		var probeN, readyN, appN int
		deps.DeviceDiscoverer = discoverer{devices: devices, readyN: &readyN}
		deps.USBProbe = func(context.Context) (int, error) { probeN++; return 2, nil }
		deps.AppProbe = func(context.Context, config.Config, *device.Device) error { appN++; return nil }
		report, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.NoDevice, contract.CodeOf(err))
		require.False(t, report.Healthy)
		require.Equal(t, []int{1, 0, 0}, []int{probeN, readyN, appN})
	})

	t.Run("configured exact device", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
			return config.Config{Transport: "usb", DeviceID: "udid-2"}, nil
		}
		var selected string
		var readyN int
		deps.DeviceDiscoverer = discoverer{devices: devices, readyN: &readyN}
		deps.AppProbe = func(_ context.Context, _ config.Config, target *device.Device) error {
			selected = target.UDID
			return nil
		}
		report, err := doctor.Run(context.Background(), deps)
		require.NoError(t, err)
		require.True(t, report.Healthy)
		require.Equal(t, "udid-2", selected)
		require.Equal(t, 1, readyN)
	})
}

func TestRunContinuesAfterRequiredFailureAndCallsApplicableDependenciesOnce(t *testing.T) {
	deps := healthyDependencies(t)
	var configN, listN, readyN, usbN, appN, versionN, capabilitiesN, templateN, pathN int
	deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
		configN++
		return config.Config{Token: "token", Transport: "usb"}, nil
	}
	deps.DeviceDiscoverer = discoverer{
		devices: []device.Device{{UDID: "one", Available: true}}, listN: &listN, readyN: &readyN,
	}
	deps.USBProbe = func(context.Context) (int, error) { usbN++; return 1, nil }
	deps.AppProbe = func(context.Context, config.Config, *device.Device) error { appN++; return nil }
	deps.ProtocolVersionProbe = func(context.Context, config.Config, *device.Device) (int, error) {
		versionN++
		return 1, nil
	}
	deps.CapabilitiesProbe = func(context.Context, config.Config, *device.Device) error { capabilitiesN++; return nil }
	deps.TemplateLocator = countingLocator{path: "/installed/ap-ios-debug-kit", count: &templateN}
	original := deps.LookPath
	deps.LookPath = func(name string) (string, error) {
		if name == "xcode-select" {
			return "", os.ErrNotExist
		}
		if name == "ap-ios-debug" {
			pathN++
		}
		return original(name)
	}

	report, err := doctor.Run(context.Background(), deps)
	require.Equal(t, contract.ToolMissing, contract.CodeOf(err))
	require.Equal(t, []string{"xcode-select", "devicectl", "usbmuxd", "config", "template", "path"}, checkNames(report.Checks))
	require.Equal(t, []int{1, 1, 1, 1, 1, 1, 1, 1, 1}, []int{configN, listN, readyN, usbN, appN, versionN, capabilitiesN, templateN, pathN})
}

func TestRunTCPTransportSkipsUSBAndChecksAppProtocolCapabilitiesOnce(t *testing.T) {
	deps := healthyDependencies(t)
	var listN, readyN, usbN, tcpN, appN, versionN, capabilitiesN int
	deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Token: "tcp-token", Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876}, nil
	}
	deps.DeviceDiscoverer = discoverer{listN: &listN, readyN: &readyN}
	deps.USBProbe = func(context.Context) (int, error) { usbN++; return 1, nil }
	deps.TCPProbe = func(context.Context, config.Config) error { tcpN++; return nil }
	deps.AppProbe = func(_ context.Context, cfg config.Config, selected *device.Device) error {
		appN++
		require.Equal(t, "tcp-token", cfg.Token)
		require.Nil(t, selected)
		return nil
	}
	deps.ProtocolVersionProbe = func(context.Context, config.Config, *device.Device) (int, error) {
		versionN++
		return 1, nil
	}
	deps.CapabilitiesProbe = func(context.Context, config.Config, *device.Device) error { capabilitiesN++; return nil }

	report, err := doctor.Run(context.Background(), deps)
	require.NoError(t, err)
	require.True(t, report.Healthy)
	require.Equal(t, []int{0, 0, 0, 1, 1, 1, 1}, []int{listN, readyN, usbN, tcpN, appN, versionN, capabilitiesN})
}

func TestRunSkipsTransportDependenciesWhenPrerequisiteFails(t *testing.T) {
	setups := []func(*doctor.Dependencies){
		func(deps *doctor.Dependencies) {
			deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
				return config.Config{}, contract.New(contract.ConfigInvalid, errors.New("bad"))
			}
		},
		func(deps *doctor.Dependencies) {
			original := deps.LookPath
			deps.LookPath = func(name string) (string, error) {
				if name == "xcrun" {
					return "", os.ErrNotExist
				}
				return original(name)
			}
		},
	}
	for _, setup := range setups {
		deps := healthyDependencies(t)
		var listN, readyN, usbN, tcpN, appN, versionN, capabilitiesN int
		deps.DeviceDiscoverer = discoverer{listN: &listN, readyN: &readyN}
		deps.USBProbe = func(context.Context) (int, error) { usbN++; return 0, nil }
		deps.TCPProbe = func(context.Context, config.Config) error { tcpN++; return nil }
		deps.AppProbe = func(context.Context, config.Config, *device.Device) error { appN++; return nil }
		deps.ProtocolVersionProbe = func(context.Context, config.Config, *device.Device) (int, error) { versionN++; return 1, nil }
		deps.CapabilitiesProbe = func(context.Context, config.Config, *device.Device) error { capabilitiesN++; return nil }
		setup(&deps)
		report, err := doctor.Run(context.Background(), deps)
		require.Error(t, err)
		require.Len(t, report.Checks, 6)
		require.Equal(t, []int{0, 0, 0, 0, 0, 0, 0}, []int{listN, readyN, usbN, tcpN, appN, versionN, capabilitiesN})
	}
}

func TestRunUsesPerCheckDeadlineAndPreservesKnownErrors(t *testing.T) {
	deps := healthyDependencies(t)
	deps.Timeout = time.Millisecond
	deps.Run = func(ctx context.Context, _ string, args ...string) ([]byte, error) {
		if strings.Join(args, " ") == "-p" {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return []byte("1"), nil
	}
	report, err := doctor.Run(context.Background(), deps)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
	require.Equal(t, "fail", statusForCheck(report, "xcode-select"))
	require.Len(t, report.Checks, 6)
	require.Equal(t, contract.New(contract.RequestTimeout, nil).Hint, report.Checks[0].Hint)
	var stable *contract.Error
	require.ErrorAs(t, err, &stable)
	require.Equal(t, report.Checks[0].Hint, stable.Hint)

	deps = healthyDependencies(t)
	deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp"}, nil
	}
	deps.TCPProbe = func(context.Context, config.Config) error {
		return contract.New(contract.IOFailure, errors.New("disk"))
	}
	_, err = doctor.Run(context.Background(), deps)
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
}

func TestRunRejectsSuccessReturnedAfterCheckDeadline(t *testing.T) {
	deps := healthyDependencies(t)
	deps.Timeout = time.Millisecond
	deps.Run = func(ctx context.Context, _ string, args ...string) ([]byte, error) {
		if strings.Join(args, " ") == "-p" {
			<-ctx.Done()
			return []byte("late success"), nil
		}
		return []byte("1"), nil
	}
	report, err := doctor.Run(context.Background(), deps)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
	require.False(t, report.Healthy)
	require.Equal(t, "fail", report.Checks[0].Status)
	require.Equal(t, contract.New(contract.RequestTimeout, nil).Hint, report.Checks[0].Hint)
	require.Len(t, report.Checks, 6)
}

func TestRunRejectsLateSuccessFromNonContextDependencies(t *testing.T) {
	t.Run("look path", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.Timeout = time.Millisecond
		original := deps.LookPath
		deps.LookPath = func(name string) (string, error) {
			if name == "ap-ios-debug" {
				time.Sleep(3 * time.Millisecond)
			}
			return original(name)
		}
		report, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
		require.False(t, report.Healthy)
		require.Equal(t, "fail", report.Checks[5].Status)
	})

	t.Run("template locator", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.Timeout = time.Millisecond
		deps.TemplateLocator = delayedLocator{delay: 3 * time.Millisecond, path: "/installed/ap-ios-debug-kit"}
		report, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
		require.False(t, report.Healthy)
		require.Equal(t, "fail", report.Checks[4].Status)
		require.Equal(t, "pass", report.Checks[5].Status)
	})
}

func TestRunMapsRequiredFailuresPrecisely(t *testing.T) {
	t.Run("configuration", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.ConfigLoader = func(context.Context, config.LoadOptions) (config.Config, error) {
			return config.Config{}, contract.New(contract.ConfigInvalid, errors.New("AP_IOS_DEBUG_TOKEN bearer-secret"))
		}
		_, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
		require.NotContains(t, err.Error(), "bearer-secret")
	})

	t.Run("template outside repository", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.TemplateLocator = locator{err: contract.New(contract.IOFailure, errors.New("missing /private/repo"))}
		_, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.IOFailure, contract.CodeOf(err))
		require.NotContains(t, err.Error(), "/private/repo")
	})

	t.Run("usbmux service", func(t *testing.T) {
		deps := healthyDependencies(t)
		deps.DeviceDiscoverer = discoverer{err: errors.New("Authorization: Bearer transport-secret")}
		deps.USBProbe = func(context.Context) (int, error) { return 0, errors.New("socket unavailable") }
		_, err := doctor.Run(context.Background(), deps)
		require.Equal(t, contract.TransportFailure, contract.CodeOf(err))
		require.NotContains(t, err.Error(), "transport-secret")
	})
}

func TestRunWarnsWhenExecutableIsNotDiscoverableThroughPath(t *testing.T) {
	deps := healthyDependencies(t)
	original := deps.LookPath
	deps.LookPath = func(name string) (string, error) {
		if name == "ap-ios-debug" {
			return "/another/ap-ios-debug", nil
		}
		return original(name)
	}
	report, err := doctor.Run(context.Background(), deps)
	require.NoError(t, err)
	require.True(t, report.Healthy)
	require.Equal(t, "warning", statusForCheck(report, "path"))
}

func TestRunSanitizesCommandOutputAndNeverLeaksSecrets(t *testing.T) {
	deps := healthyDependencies(t)
	deps.Run = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("devicectl\x00 1.0\nAuthorization: Bearer bearer-secret\nAP_IOS_DEBUG_TOKEN=configured-secret"), nil
	}
	report, err := doctor.Run(context.Background(), deps)
	require.NoError(t, err)
	encoded := report.Version
	for _, check := range report.Checks {
		encoded += check.Name + check.Status + check.Message + check.Hint
		require.LessOrEqual(t, len(check.Message), 256)
	}
	for _, secret := range []string{"AP_IOS_DEBUG_TOKEN", "Authorization", "bearer-secret", "configured-secret"} {
		require.NotContains(t, encoded, secret)
	}
}

func checkNames(checks []doctor.Check) []string {
	result := make([]string, len(checks))
	for i, check := range checks {
		result[i] = check.Name
	}
	return result
}

func statusForCheck(report doctor.Report, name string) string {
	for _, check := range report.Checks {
		if check.Name == name {
			return check.Status
		}
	}
	return ""
}

type delayedLocator struct {
	delay time.Duration
	path  string
}

func (l delayedLocator) Locate() (string, error) {
	time.Sleep(l.delay)
	return l.path, nil
}
