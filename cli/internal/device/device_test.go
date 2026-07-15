package device_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/device"
)

type fixtureRunner struct {
	t        *testing.T
	fixtures []string
	calls    [][]string
	err      error
}

type runnerFunc func(context.Context, string, ...string) error

func (f runnerFunc) Run(ctx context.Context, executable string, args ...string) error {
	return f(ctx, executable, args...)
}

func jsonOutputPath(args []string) string {
	for i, arg := range args {
		if arg == "--json-output" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func requireEmptyDirectory(t *testing.T, directory string) {
	t.Helper()
	entries, err := os.ReadDir(directory)
	require.NoError(t, err)
	require.Empty(t, entries)
}

func (r *fixtureRunner) Run(_ context.Context, executable string, args ...string) error {
	r.t.Helper()
	r.calls = append(r.calls, append([]string{executable}, args...))
	if r.err != nil {
		return r.err
	}
	require.NotEmpty(r.t, r.fixtures)
	fixture := r.fixtures[0]
	r.fixtures = r.fixtures[1:]
	index := -1
	for i, arg := range args {
		if arg == "--json-output" && i+1 < len(args) {
			index = i + 1
			break
		}
	}
	require.NotEqual(r.t, -1, index)
	fixturePath := fixture
	if !filepath.IsAbs(fixturePath) {
		fixturePath = filepath.Join("testdata", fixturePath)
	}
	data, err := os.ReadFile(fixturePath)
	require.NoError(r.t, err)
	require.NoError(r.t, os.WriteFile(args[index], data, 0o600))
	return nil
}

func newDiscoverer(t *testing.T, fixtures ...string) (*device.Discoverer, *fixtureRunner, string) {
	t.Helper()
	tempDir := t.TempDir()
	runner := &fixtureRunner{t: t, fixtures: fixtures}
	return device.NewDiscoverer(runner, tempDir), runner, tempDir
}

func TestListParsesPhysicalIOSV3Record(t *testing.T) {
	d, runner, tempDir := newDiscoverer(t, "devicectl-list-v3.json")
	devices, err := d.List(context.Background())
	require.NoError(t, err)
	require.Equal(t, []device.Device{{
		Identifier: "TEST-COREDEVICE-0001", UDID: "TEST-UDID-0001", Name: "Test iPhone",
		Platform: "iOS", DeviceType: "iPhone", OSVersion: "26.5", PairingState: "paired",
		TransportType: "wired", Available: true,
	}}, devices)
	require.Len(t, runner.calls, 1)
	require.Equal(t, []string{"xcrun", "devicectl", "list", "devices", "--quiet", "--json-output"}, runner.calls[0][:6])
	entries, err := os.ReadDir(tempDir)
	require.NoError(t, err)
	require.Empty(t, entries)
}

func TestListKeepsUnavailablePhysicalDevicesAndFiltersOthers(t *testing.T) {
	d, _, _ := newDiscoverer(t, "devicectl-list-multiple-v3.json")
	devices, err := d.List(context.Background())
	require.NoError(t, err)
	require.Len(t, devices, 3)
	require.False(t, devices[2].Available)
	require.Equal(t, "TEST-UDID-OFFLINE", devices[2].UDID)
}

func TestResolveNeverGuessesBetweenTwoAvailableDevices(t *testing.T) {
	d, _, _ := newDiscoverer(t, "devicectl-list-multiple-v3.json")
	_, err := d.Resolve(context.Background(), device.Selector{AllowSingle: true})
	require.Equal(t, contract.MultipleDevices, contract.CodeOf(err))
}

func TestResolveUsesExactUDIDAndExactUniqueName(t *testing.T) {
	d, _, _ := newDiscoverer(t, "devicectl-list-multiple-v3.json", "devicectl-list-v3.json")
	selected, err := d.Resolve(context.Background(), device.Selector{UDID: "TEST-UDID-0002"})
	require.NoError(t, err)
	require.Equal(t, "TEST-COREDEVICE-0002", selected.Identifier)
	selected, err = d.Resolve(context.Background(), device.Selector{Name: "Test iPhone"})
	require.NoError(t, err)
	require.Equal(t, "TEST-UDID-0001", selected.UDID)
}

func TestResolveRejectsDuplicateAndPartialNamesAndUnavailableRecords(t *testing.T) {
	for _, selector := range []device.Selector{{Name: "Shared Name"}, {Name: "Shared"}, {UDID: "TEST-UDID-OFFLINE"}} {
		d, _, _ := newDiscoverer(t, "devicectl-list-multiple-v3.json")
		_, err := d.Resolve(context.Background(), selector)
		expected := contract.NoDevice
		if selector.Name == "Shared Name" {
			expected = contract.MultipleDevices
		}
		require.Equal(t, expected, contract.CodeOf(err))
	}
}

func TestCheckReadyMapsLockState(t *testing.T) {
	d, runner, _ := newDiscoverer(t, "devicectl-list-v3.json", "devicectl-lock-locked-v3.json")
	selected, err := d.Resolve(context.Background(), device.Selector{UDID: "TEST-UDID-0001"})
	require.NoError(t, err)
	require.Equal(t, contract.DeviceLocked, contract.CodeOf(d.CheckReady(context.Background(), selected)))
	require.Contains(t, strings.Join(runner.calls[1], " "), "device info lockState --device TEST-COREDEVICE-0001")
}

func TestCheckReadyReturnsUnlockedDevice(t *testing.T) {
	d, _, _ := newDiscoverer(t, "devicectl-list-v3.json", "devicectl-lock-unlocked-v3.json")
	selected, err := d.Resolve(context.Background(), device.Selector{AllowSingle: true})
	require.NoError(t, err)
	require.NoError(t, d.CheckReady(context.Background(), selected))
}

func TestCheckReadyRejectsMissingPasscodeRequired(t *testing.T) {
	tempDir := t.TempDir()
	runner := runnerFunc(func(_ context.Context, _ string, args ...string) error {
		path := jsonOutputPath(args)
		require.NotEmpty(t, path)
		return os.WriteFile(path, []byte(`{"info":{"commandType":"devicectl.device.info.lockState","jsonVersion":3,"outcome":"success"},"result":{"deviceIdentifier":"TEST-COREDEVICE-0001"}}`), 0o600)
	})
	d := device.NewDiscoverer(runner, tempDir)
	err := d.CheckReady(context.Background(), device.Device{Identifier: "TEST-COREDEVICE-0001", PairingState: "paired"})
	require.Error(t, err)
	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
	requireEmptyDirectory(t, tempDir)
}

func TestListRejectsAvailablePhysicalRecordsWithoutIdentifiers(t *testing.T) {
	for _, record := range []string{
		`{"connectionProperties":{"pairingState":"paired","transportType":"wired"},"deviceProperties":{"name":"Missing identifier"},"hardwareProperties":{"platform":"iOS","reality":"physical","udid":"TEST-UDID"}}`,
		`{"connectionProperties":{"pairingState":"paired","transportType":"wired"},"deviceProperties":{"name":"Missing UDID"},"hardwareProperties":{"platform":"iOS","reality":"physical"},"identifier":"TEST-COREDEVICE"}`,
	} {
		tempDir := t.TempDir()
		body := `{"info":{"commandType":"devicectl.list.devices","jsonVersion":3,"outcome":"success"},"result":{"devices":[` + record + `]}}`
		runner := runnerFunc(func(_ context.Context, _ string, args ...string) error {
			return os.WriteFile(jsonOutputPath(args), []byte(body), 0o600)
		})
		d := device.NewDiscoverer(runner, tempDir)
		devices, err := d.List(context.Background())
		require.Nil(t, devices)
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
		requireEmptyDirectory(t, tempDir)
	}
}

func TestContextCancellationAndDeadlineMapToStableTransportFailure(t *testing.T) {
	for _, want := range []error{context.Canceled, context.DeadlineExceeded} {
		tempDir := t.TempDir()
		ctx := context.WithValue(context.Background(), struct{}{}, "same context")
		runner := runnerFunc(func(got context.Context, _ string, _ ...string) error {
			require.True(t, got == ctx, "caller context must be passed unchanged")
			return want
		})
		d := device.NewDiscoverer(runner, tempDir)
		_, got := d.List(ctx)
		require.Equal(t, contract.TransportFailure, contract.CodeOf(got))
		require.Equal(t, "The device transport failed.", got.Error())
		require.ErrorIs(t, got, want)
		require.NotContains(t, got.Error(), want.Error())
		require.NotContains(t, got.Error(), tempDir)
		requireEmptyDirectory(t, tempDir)
	}
}

func TestTemporaryJSONFileIsRemovedOnEveryFailurePath(t *testing.T) {
	tests := []struct {
		name   string
		runner func(*testing.T) device.Runner
		call   func(*device.Discoverer) error
	}{
		{
			name: "command failure",
			runner: func(t *testing.T) device.Runner {
				return runnerFunc(func(context.Context, string, ...string) error {
					return errors.New("secret command output")
				})
			},
			call: func(d *device.Discoverer) error { _, err := d.List(context.Background()); return err },
		},
		{
			name: "JSON parse failure",
			runner: func(t *testing.T) device.Runner {
				return runnerFunc(func(_ context.Context, _ string, args ...string) error {
					return os.WriteFile(jsonOutputPath(args), []byte(`{"secret":"payload"`), 0o600)
				})
			},
			call: func(d *device.Discoverer) error { _, err := d.List(context.Background()); return err },
		},
		{
			name: "lock read failure",
			runner: func(t *testing.T) device.Runner {
				return runnerFunc(func(_ context.Context, _ string, args ...string) error {
					path := jsonOutputPath(args)
					require.NoError(t, os.Remove(path))
					return os.Mkdir(path, 0o700)
				})
			},
			call: func(d *device.Discoverer) error {
				return d.CheckReady(context.Background(), device.Device{Identifier: "TEST-COREDEVICE", PairingState: "paired"})
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			tempDir := t.TempDir()
			d := device.NewDiscoverer(test.runner(t), tempDir)
			err := test.call(d)
			require.Error(t, err)
			require.NotContains(t, err.Error(), "secret")
			require.NotContains(t, err.Error(), tempDir)
			requireEmptyDirectory(t, tempDir)
		})
	}
}

func TestCheckReadyRejectsUntrustedBeforeLockCommand(t *testing.T) {
	d, runner, _ := newDiscoverer(t, "devicectl-list-untrusted-v3.json")
	selected, err := d.Resolve(context.Background(), device.Selector{AllowSingle: true})
	require.NoError(t, err)
	require.Equal(t, contract.DeviceUntrusted, contract.CodeOf(d.CheckReady(context.Background(), selected)))
	require.Len(t, runner.calls, 1)
}

func TestCommandErrorsMapWithoutParsingHumanOutput(t *testing.T) {
	tests := []struct {
		message string
		code    contract.Code
	}{
		{"device must be paired and trusted: {\"result\":[]}", contract.DeviceUntrusted},
		{"passcode lock prevents access", contract.DeviceLocked},
		{"connection reset; {\"info\":{\"outcome\":\"success\"}}", contract.TransportFailure},
	}
	for _, test := range tests {
		runner := &fixtureRunner{t: t, err: errors.New(test.message)}
		d := device.NewDiscoverer(runner, t.TempDir())
		_, err := d.List(context.Background())
		require.Equal(t, test.code, contract.CodeOf(err))
	}
}

func TestListRejectsUnexpectedV3Envelope(t *testing.T) {
	for _, body := range []string{
		`{"info":{"commandType":"wrong","jsonVersion":3,"outcome":"success"},"result":{"devices":[]}}`,
		`{"info":{"commandType":"devicectl.list.devices","jsonVersion":4,"outcome":"success"},"result":{"devices":[]}}`,
		`{"info":{"commandType":"devicectl.list.devices","jsonVersion":3,"outcome":"failure"},"result":{"devices":[]}}`,
	} {
		path := filepath.Join(t.TempDir(), "invalid.json")
		require.NoError(t, os.WriteFile(path, []byte(body), 0o600))
		runner := &fixtureRunner{t: t, fixtures: []string{path}}
		d := device.NewDiscoverer(runner, t.TempDir())
		_, err := d.List(context.Background())
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
	}
}
