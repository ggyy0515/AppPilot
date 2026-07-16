package cli

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/ggyy0515/AppPilot/internal/config"
	"github.com/ggyy0515/AppPilot/internal/device"
	"github.com/ggyy0515/AppPilot/internal/doctor"
	"github.com/stretchr/testify/require"
)

func TestBoundedUSBProbeReturnsWhenContextIsCanceled(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := boundedUSBProbe(ctx, func() (ios.DeviceList, error) {
			close(entered)
			<-release
			return ios.DeviceList{}, nil
		})
		result <- err
	}()
	<-entered
	cancel()
	require.ErrorIs(t, <-result, context.Canceled)
	close(release)
	require.Eventually(t, func() bool { return len(usbProbeSlot) == 0 }, time.Second, time.Millisecond)
}

type doctorLocator struct{ path string }

func (l doctorLocator) Locate() (string, error) { return l.path, nil }

type failingDoctorLocator struct{}

func (failingDoctorLocator) Locate() (string, error) { return "", errors.New("missing") }

type doctorDiscoverer struct{ devices []device.Device }

func (d doctorDiscoverer) List(context.Context) ([]device.Device, error) { return d.devices, nil }

func (d doctorDiscoverer) CheckReady(context.Context, device.Device) error { return nil }

func TestDoctorCommandEmitsStableJSONAndNoSecrets(t *testing.T) {
	deps := doctorCommandDependencies(t)
	stdout, stderr, code := executeReadCommand(t, deps, "--json", "doctor")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	var envelope struct {
		OK   bool          `json:"ok"`
		Data doctor.Report `json:"data"`
	}
	require.NoError(t, json.Unmarshal([]byte(stdout), &envelope))
	require.True(t, envelope.OK)
	require.True(t, envelope.Data.Healthy)
	require.Equal(t, "9.8.7", envelope.Data.Version)
	require.Len(t, envelope.Data.Checks, 6)
	for _, secret := range []string{"AP_IOS_DEBUG_TOKEN", "Authorization", "configured-secret"} {
		require.NotContains(t, stdout, secret)
		require.NotContains(t, stderr, secret)
	}
}

func TestDoctorCommandUsesStableFailureEnvelopeAndExit(t *testing.T) {
	deps := doctorCommandDependencies(t)
	deps.Doctor.LookPath = func(name string) (string, error) {
		if name == "xcrun" {
			return "", errors.New("Authorization: configured-secret")
		}
		return "/usr/bin/" + name, nil
	}
	stdout, stderr, code := executeReadCommand(t, deps, "doctor", "--json")
	require.Equal(t, 2, code)
	require.Empty(t, stderr)
	var envelope struct {
		OK   bool          `json:"ok"`
		Data doctor.Report `json:"data"`
	}
	require.NoError(t, json.Unmarshal([]byte(stdout), &envelope))
	require.True(t, envelope.OK)
	require.False(t, envelope.Data.Healthy)
	require.Len(t, envelope.Data.Checks, 6)
	require.Equal(t, "fail", envelope.Data.Checks[1].Status)
	require.Equal(t, "Install Xcode command line tools.", envelope.Data.Checks[1].Hint)
	require.NotContains(t, stdout, "configured-secret")
}

func TestDoctorTextFailureEmitsCompleteReportAndUsesCheckHint(t *testing.T) {
	deps := doctorCommandDependencies(t)
	deps.Doctor.TemplateLocator = failingDoctorLocator{}
	stdout, stderr, code := executeReadCommand(t, deps, "doctor")
	require.Equal(t, 6, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, "Doctor: unhealthy")
	require.Contains(t, stdout, "template: fail")
	require.Contains(t, stdout, "Run make install-local from the repository.")
	require.Contains(t, stdout, "path: pass")
}

func TestDoctorUSBServiceFailureWithNoDevicesEmitsFullReportAndTransportExit(t *testing.T) {
	deps := doctorCommandDependencies(t)
	deps.Doctor.DeviceDiscoverer = doctorDiscoverer{}
	var probeN int
	deps.Doctor.USBProbe = func(context.Context) (int, error) {
		probeN++
		return 0, errors.New("usbmuxd unavailable")
	}
	stdout, stderr, code := executeReadCommand(t, deps, "--json", "doctor")
	require.Equal(t, 4, code)
	require.Empty(t, stderr)
	require.Equal(t, 1, probeN)
	var envelope struct {
		OK   bool          `json:"ok"`
		Data doctor.Report `json:"data"`
	}
	require.NoError(t, json.Unmarshal([]byte(stdout), &envelope))
	require.True(t, envelope.OK)
	require.False(t, envelope.Data.Healthy)
	require.Len(t, envelope.Data.Checks, 6)
	require.Equal(t, "fail", envelope.Data.Checks[2].Status)
}

func TestDoctorTextOutputIsConcise(t *testing.T) {
	stdout, stderr, code := executeReadCommand(t, doctorCommandDependencies(t), "doctor")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, "Doctor: healthy")
	require.Contains(t, stdout, "xcode-select: pass")
	require.NotContains(t, stdout, "configured-secret")
}

func doctorCommandDependencies(t *testing.T) Dependencies {
	t.Helper()
	executable := filepath.Join(t.TempDir(), "ap-ios-debug")
	return Dependencies{
		Version: "9.8.7",
		Doctor: doctor.Dependencies{
			LookPath: func(name string) (string, error) {
				if name == "ap-ios-debug" {
					return executable, nil
				}
				return "/usr/bin/" + name, nil
			},
			Run: func(context.Context, string, ...string) ([]byte, error) { return []byte("version 1\n"), nil },
			ConfigLoader: func(context.Context, config.LoadOptions) (config.Config, error) {
				return config.Config{Token: "configured-secret"}, nil
			},
			DeviceDiscoverer: doctorDiscoverer{devices: []device.Device{{UDID: "one", Available: true}}},
			USBProbe:         func(context.Context) (int, error) { return 1, nil },
			TCPProbe:         func(context.Context, config.Config) error { return nil },
			AppProbe:         func(context.Context, config.Config, *device.Device) error { return nil },
			ProtocolVersionProbe: func(context.Context, config.Config, *device.Device) (int, error) {
				return 1, nil
			},
			CapabilitiesProbe: func(context.Context, config.Config, *device.Device) error { return nil },
			TemplateLocator:   doctorLocator{path: "/installed/ap-ios-debug-kit"},
			ExecutablePath:    executable,
		},
		LoadConfig: func(context.Context, config.LoadOptions) (config.Config, error) { return config.Config{}, nil },
		Devices:    &fakeDeviceDiscoverer{},
		Now:        nil,
		Stdout:     nil,
		Stderr:     nil,
		WorkingDir: os.TempDir(),
		UserHome:   os.TempDir(),
	}
}
