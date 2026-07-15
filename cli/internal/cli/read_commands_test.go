package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/config"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/device"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/protocol"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/transport"
)

type fakeDeviceDiscoverer struct {
	devices      []device.Device
	resolveErr   error
	readyErr     error
	listCalls    int
	resolveCalls int
	readyCalls   int
	selector     device.Selector
}

func (f *fakeDeviceDiscoverer) List(context.Context) ([]device.Device, error) {
	f.listCalls++
	return append([]device.Device(nil), f.devices...), nil
}

func (f *fakeDeviceDiscoverer) Resolve(_ context.Context, selector device.Selector) (device.Device, error) {
	f.resolveCalls++
	f.selector = selector
	if f.resolveErr != nil {
		return device.Device{}, f.resolveErr
	}
	matches := make([]device.Device, 0, len(f.devices))
	for _, candidate := range f.devices {
		if !candidate.Available {
			continue
		}
		if selector.UDID != "" && candidate.UDID == selector.UDID ||
			selector.UDID == "" && selector.Name != "" && candidate.Name == selector.Name ||
			selector.UDID == "" && selector.Name == "" && selector.AllowSingle {
			matches = append(matches, candidate)
		}
	}
	if len(matches) == 0 {
		return device.Device{}, contract.New(contract.NoDevice, nil)
	}
	if len(matches) != 1 {
		return device.Device{}, contract.New(contract.MultipleDevices, nil)
	}
	return matches[0], nil
}

func (f *fakeDeviceDiscoverer) CheckReady(_ context.Context, _ device.Device) error {
	f.readyCalls++
	return f.readyErr
}

type scriptedCLITransport struct {
	t        *testing.T
	response string
	mu       sync.Mutex
	dials    int
	deviceID string
	method   string
	path     string
}

func (s *scriptedCLITransport) Name() string { return "scripted" }

func (s *scriptedCLITransport) Dial(_ context.Context, deviceID string, _ uint16) (net.Conn, error) {
	s.mu.Lock()
	s.dials++
	s.deviceID = deviceID
	s.mu.Unlock()
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			s.t.Error(err)
			return
		}
		s.mu.Lock()
		s.method = request.Method
		s.path = request.URL.RequestURI()
		s.mu.Unlock()
		_, _ = io.WriteString(server, s.response)
	}()
	return client, nil
}

func (s *scriptedCLITransport) snapshot() (int, string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dials, s.deviceID, s.method, s.path
}

type panicDialTransport struct{}

func (panicDialTransport) Name() string { return "panic" }
func (panicDialTransport) Dial(context.Context, string, uint16) (net.Conn, error) {
	panic("invalid request reached transport")
}

func TestReadCommandsEmitStableTextWithoutJSONFlag(t *testing.T) {
	t.Run("devices list", func(t *testing.T) {
		devices := &fakeDeviceDiscoverer{devices: []device.Device{
			{UDID: "udid-2", Name: "Offline", OSVersion: "18.4", Available: false},
			{UDID: "udid-1", Name: "Phone", OSVersion: "18.5", Available: true},
		}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, panicDialTransport{}), "devices", "list")

		require.Equal(t, 0, code)
		require.Equal(t, "UDID\tNAME\tOS VERSION\tSTATUS\nudid-2\tOffline\t18.4\tunavailable\nudid-1\tPhone\t18.5\tavailable\n", stdout)
		require.Empty(t, stderr)
		require.NotContains(t, stdout, `{"ok":`)
	})

	t.Run("devices resolve", func(t *testing.T) {
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Name: "Phone", OSVersion: "18.5", Available: true}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, panicDialTransport{}), "devices", "resolve", "--name", "Phone")

		require.Equal(t, 0, code)
		require.Equal(t, "Device: Phone (udid-1), iOS 18.5, available.\n", stdout)
		require.Empty(t, stderr)
		require.NotContains(t, stdout, `{"ok":`)
	})

	t.Run("app probe", func(t *testing.T) {
		response := cliJSONResponse(`{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"request_id":"health-text"}}`)
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Name: "Phone", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "--device", "udid-1", "app", "probe")

		require.Equal(t, 0, code)
		require.Equal(t, "App reachable on udid-1 (protocol 1, authentication not required).\n", stdout)
		require.Empty(t, stderr)
		require.NotContains(t, stdout, `{"ok":`)
	})

	t.Run("request get", func(t *testing.T) {
		response := cliJSONResponse(`{"ok":true,"data":{"z":2,"screen":"home"},"meta":{"protocol_version":1,"request_id":"get-text"}}`)
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "--device", "udid-1", "request", "get", "/v1/state")

		require.Equal(t, 0, code)
		require.Equal(t, "GET /v1/state succeeded.\nscreen: \"home\"\nz: 2\n", stdout)
		require.Empty(t, stderr)
		require.NotContains(t, stdout, `{"screen":`)
	})

	t.Run("request head", func(t *testing.T) {
		response := "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 123\r\nContent-Type: application/json\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: head-text\r\n\r\n"
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "--device", "udid-1", "request", "head", "/v1/state")

		require.Equal(t, 0, code)
		require.Equal(t, "HEAD /v1/state: 200\nContent-Length: 123\nContent-Type: application/json\nX-Ios-Debug-Protocol-Version: 1\nX-Ios-Debug-Request-Id: head-text\n", stdout)
		require.Empty(t, stderr)
		require.NotContains(t, stdout, `{"ok":`)
	})
}

func TestHumanOutputCollapsesControlRunsAndPreservesUnicode(t *testing.T) {
	t.Run("device name and UDID", func(t *testing.T) {
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{
			UDID:      "udid\x1b\x07\x00\u0085一号",
			Name:      "手机\x00\x07\x1b\u0085📱",
			OSVersion: "18.5",
			Available: true,
		}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, panicDialTransport{}), "devices", "list")

		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		require.Equal(t, "UDID\tNAME\tOS VERSION\tSTATUS\nudid 一号\t手机 📱\t18.5\tavailable\n", stdout)
		require.NotContains(t, stdout, "\x1b")
		require.NotContains(t, stdout, "\x07")
		require.NotContains(t, stdout, "\x00")
		require.NotContains(t, stdout, "\u0085")
	})

	t.Run("GET key", func(t *testing.T) {
		response := cliJSONResponse(`{"ok":true,"data":{"状态\u001b\u0007\u0000\u0085键":"正常📱"},"meta":{"protocol_version":1,"request_id":"controls"}}`)
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "--device", "udid-1", "request", "get", "/v1/state")

		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		require.Equal(t, "GET /v1/state succeeded.\n状态 键: \"正常📱\"\n", stdout)
		require.NotContains(t, stdout, "\x1b")
		require.NotContains(t, stdout, "\x07")
		require.NotContains(t, stdout, "\x00")
		require.NotContains(t, stdout, "\u0085")
	})

	t.Run("HEAD value", func(t *testing.T) {
		metadata := protocol.ResponseMetadata{StatusCode: http.StatusOK, Headers: http.Header{
			"X-Ios-Debug-Request-Id": {"请求\x1b\x07\x00\u0085一号📱"},
		}}

		output := formatHEAD("/v1/state", metadata)
		require.Equal(t, "HEAD /v1/state: 200\nX-Ios-Debug-Request-Id: 请求 一号📱\n", output)
		require.NotContains(t, output, "\x1b")
		require.NotContains(t, output, "\x07")
		require.NotContains(t, output, "\x00")
		require.NotContains(t, output, "\u0085")
	})
}

func TestReadCommandsEmitOneJSONEnvelopeWithJSONFlag(t *testing.T) {
	t.Run("devices list", func(t *testing.T) {
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Name: "Phone", Available: true}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, panicDialTransport{}), "devices", "list", "--json")
		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		assertSuccessfulJSONDocument(t, stdout)
		require.JSONEq(t, `{"ok":true,"data":{"devices":[{"identifier":"","udid":"udid-1","name":"Phone","platform":"","device_type":"","os_version":"","pairing_state":"","transport_type":"","available":true}]},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
	})

	t.Run("devices resolve", func(t *testing.T) {
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Name: "Phone", Available: true}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, panicDialTransport{}), "devices", "resolve", "--name", "Phone", "--json")
		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		assertSuccessfulJSONDocument(t, stdout)
		require.JSONEq(t, `{"ok":true,"data":{"device":{"identifier":"","udid":"udid-1","name":"Phone","platform":"","device_type":"","os_version":"","pairing_state":"","transport_type":"","available":true}},"meta":{"protocol_version":1,"device_id":"udid-1","duration_ms":0}}`, stdout)
	})

	t.Run("app probe", func(t *testing.T) {
		response := cliJSONResponse(`{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"request_id":"health-json"}}`)
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "app", "probe", "--json", "--device", "udid-1")
		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		assertSuccessfulJSONDocument(t, stdout)
		require.JSONEq(t, `{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"device_id":"udid-1","duration_ms":0}}`, stdout)
	})

	t.Run("request get", func(t *testing.T) {
		response := cliJSONResponse(`{"ok":true,"data":{"screen":"home"},"meta":{"protocol_version":1,"request_id":"get-json"}}`)
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "request", "get", "/v1/state", "--json", "--device", "udid-1")
		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		assertSuccessfulJSONDocument(t, stdout)
		require.JSONEq(t, `{"ok":true,"data":{"screen":"home"},"meta":{"protocol_version":1,"device_id":"udid-1","duration_ms":0}}`, stdout)
	})

	t.Run("request head", func(t *testing.T) {
		response := "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: head-json\r\n\r\n"
		tr := &scriptedCLITransport{t: t, response: response}
		devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
		stdout, stderr, code := executeReadCommand(t, commandDependencies(t, devices, tr), "request", "head", "/v1/state", "--json", "--device", "udid-1")
		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		assertSuccessfulJSONDocument(t, stdout)
		require.JSONEq(t, `{"ok":true,"data":{"status_code":200,"headers":{"Content-Length":["0"],"X-Ios-Debug-Protocol-Version":["1"],"X-Ios-Debug-Request-Id":["head-json"]}},"meta":{"protocol_version":1,"device_id":"udid-1","duration_ms":0}}`, stdout)
	})
}

func TestRuntimeResolveInvokesEachDependencyOnce(t *testing.T) {
	devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
	loadCalls := 0
	usbCalls := 0
	deps := commandDependencies(t, devices, panicDialTransport{})
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		loadCalls++
		return config.Config{Transport: "usb", Port: 9876, DeviceID: "udid-1"}, nil
	}
	deps.NewUSB = func() transport.DeviceTransport {
		usbCalls++
		return panicDialTransport{}
	}
	root := NewRoot(deps)
	runtime := newRuntime(root, deps)

	_, selected, client, err := runtime.Resolve(context.Background(), true)
	require.NoError(t, err)
	require.Equal(t, "udid-1", selected.UDID)
	require.NotNil(t, client)
	require.Equal(t, 1, loadCalls)
	require.Equal(t, 1, devices.resolveCalls)
	require.Equal(t, 1, devices.readyCalls)
	require.Equal(t, 1, usbCalls)
}

func TestAppProbeLoadsAndResolvesDependenciesExactlyOnce(t *testing.T) {
	response := cliJSONResponse(`{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"request_id":"once"}}`)
	tr := &scriptedCLITransport{t: t, response: response}
	devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
	deps := commandDependencies(t, devices, tr)
	loadCalls := 0
	usbCalls := 0
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		loadCalls++
		return config.Config{Transport: "usb", Port: 9876, DeviceID: "udid-1"}, nil
	}
	deps.NewUSB = func() transport.DeviceTransport {
		usbCalls++
		return tr
	}

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "app", "probe")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	assertSuccessfulJSONDocument(t, stdout)
	require.Equal(t, 1, loadCalls)
	require.Equal(t, 1, devices.resolveCalls)
	require.Equal(t, 1, devices.readyCalls)
	require.Equal(t, 1, usbCalls)
	dials, _, _, _ := tr.snapshot()
	require.Equal(t, 1, dials)
}

func TestAppProbeEmitsHealthWithCLIEnvelope(t *testing.T) {
	response := cliJSONResponse(`{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"request_id":"health-1"}}`)
	tr := &scriptedCLITransport{t: t, response: response}
	devices := &fakeDeviceDiscoverer{devices: []device.Device{{Identifier: "core-1", UDID: "udid-1", Name: "Phone", Available: true, PairingState: "paired"}}}
	deps := commandDependencies(t, devices, tr)

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "--device", "udid-1", "app", "probe")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":true,"data":{"protocol_version":1,"auth_required":false,"reachable":true},"meta":{"protocol_version":1,"device_id":"udid-1","duration_ms":0}}`, stdout)
	require.Equal(t, 1, devices.readyCalls)
	require.Equal(t, device.Selector{UDID: "udid-1", AllowSingle: false}, devices.selector)
	dials, selectedID, method, path := tr.snapshot()
	require.Equal(t, 1, dials)
	require.Equal(t, "udid-1", selectedID, "the usbmux UDID must not be the CoreDevice identifier")
	require.Equal(t, http.MethodGet, method)
	require.Equal(t, "/v1/health", path)
}

func TestDevicesListKeepsUnavailableAndResolveRejectsDuplicateExactNames(t *testing.T) {
	devices := &fakeDeviceDiscoverer{devices: []device.Device{
		{Identifier: "core-1", UDID: "udid-1", Name: "Same", Available: true},
		{Identifier: "core-2", UDID: "udid-2", Name: "Same", Available: true},
		{Identifier: "core-3", UDID: "udid-3", Name: "Offline", Available: false},
	}}
	deps := commandDependencies(t, devices, panicDialTransport{})

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "devices", "list")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	var document struct {
		Data struct {
			Devices []device.Device `json:"devices"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal([]byte(stdout), &document))
	require.Len(t, document.Data.Devices, 3)
	require.False(t, document.Data.Devices[2].Available)
	require.Zero(t, devices.resolveCalls, "list must never auto-select")

	stdout, stderr, code = executeReadCommand(t, deps, "--json", "devices", "resolve", "--name", "Same")
	require.Equal(t, 3, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":false,"error":{"code":"multiple_devices","message":"More than one available iOS device matches.","hint":"Pass --device with a UDID or use devices resolve --name with a unique name."}}`, stdout)
	require.Zero(t, devices.readyCalls)
}

func TestDevicesResolveRequiresNonEmptyName(t *testing.T) {
	devices := &fakeDeviceDiscoverer{}
	deps := commandDependencies(t, devices, panicDialTransport{})

	for _, args := range [][]string{{"--json", "devices", "resolve"}, {"--json", "devices", "resolve", "--name", ""}} {
		stdout, stderr, code := executeReadCommand(t, deps, args...)
		require.Equal(t, 2, code)
		require.Empty(t, stderr)
		assertOneJSONDocument(t, stdout)
	}
	require.Zero(t, devices.resolveCalls)
}

func TestRequestRejectsUnsupportedMethodAndDirectoryPathBeforeDial(t *testing.T) {
	devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true}}}
	deps := commandDependencies(t, devices, panicDialTransport{})

	for _, args := range [][]string{
		{"--json", "request", "get", "/v1/"},
		{"--json", "request", "post", "/v1/state"},
	} {
		stdout, stderr, code := executeReadCommand(t, deps, args...)
		require.Equal(t, 2, code)
		require.Empty(t, stderr)
		assertOneJSONDocument(t, stdout)
	}
	require.Zero(t, devices.resolveCalls)
	require.Zero(t, devices.readyCalls)
}

func TestTCPRequestGetDoesNotDiscoverDeviceAndReturnsAppData(t *testing.T) {
	response := cliJSONResponse(`{"ok":true,"data":{"screen":"home"},"meta":{"protocol_version":1,"request_id":"state-1"}}`)
	tr := &scriptedCLITransport{t: t, response: response}
	devices := &fakeDeviceDiscoverer{resolveErr: fmt.Errorf("must not resolve a device")}
	deps := commandDependencies(t, devices, tr)
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876}, nil
	}
	deps.NewTCP = func(host string) (transport.DeviceTransport, error) {
		require.Equal(t, "127.0.0.1", host)
		return tr, nil
	}

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "request", "get", "/v1/state")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":true,"data":{"screen":"home"},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
	require.Zero(t, devices.listCalls)
	require.Zero(t, devices.resolveCalls)
	require.Zero(t, devices.readyCalls)
	_, selectedID, method, path := tr.snapshot()
	require.Empty(t, selectedID)
	require.Equal(t, http.MethodGet, method)
	require.Equal(t, "/v1/state", path)
}

func TestRequestHeadReturnsOnlySafeMetadataWithNullData(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\n" +
		"Connection: close\r\n" +
		"Content-Length: 123\r\n" +
		"Content-Type: application/json\r\n" +
		"Authorization: private\r\n" +
		"Set-Cookie: session=private\r\n" +
		"Server: private\r\n" +
		"X-IOS-Debug-Protocol-Version: 1\r\n" +
		"X-IOS-Debug-Request-ID: head-1\r\n\r\n"
	tr := &scriptedCLITransport{t: t, response: response}
	devices := &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "udid-1", Available: true, PairingState: "paired"}}}
	deps := commandDependencies(t, devices, tr)

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "--device", "udid-1", "request", "head", "/v1/state")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	var document struct {
		OK   bool `json:"ok"`
		Data struct {
			StatusCode int         `json:"status_code"`
			Headers    http.Header `json:"headers"`
		} `json:"data"`
		Meta contract.Meta `json:"meta"`
	}
	require.NoError(t, json.Unmarshal([]byte(stdout), &document))
	require.True(t, document.OK)
	require.Equal(t, http.StatusOK, document.Data.StatusCode)
	require.Equal(t, "123", document.Data.Headers.Get("Content-Length"))
	require.Equal(t, "head-1", document.Data.Headers.Get("X-IOS-Debug-Request-ID"))
	require.Empty(t, document.Data.Headers.Get("Authorization"))
	require.Empty(t, document.Data.Headers.Get("Set-Cookie"))
	require.Empty(t, document.Data.Headers.Get("Server"))
	require.Equal(t, "udid-1", document.Meta.DeviceID)
	require.NotContains(t, stdout, "private")
	require.NotContains(t, stdout, "Authorization")
	require.NotContains(t, stdout, "Set-Cookie")
	require.NotContains(t, stdout, "Server")
	require.Contains(t, stdout, "Content-Length")
	require.Contains(t, stdout, "X-Ios-Debug-Request-Id")
	_, _, method, path := tr.snapshot()
	require.Equal(t, http.MethodHead, method)
	require.Equal(t, "/v1/state", path)
}

func commandDependencies(t *testing.T, devices DeviceDiscoverer, tr transport.DeviceTransport) Dependencies {
	t.Helper()
	return Dependencies{
		Devices: devices,
		LoadConfig: func(_ context.Context, options config.LoadOptions) (config.Config, error) {
			cfg := config.Config{Transport: "usb", Port: 9876}
			if options.CLI.DeviceID != nil {
				cfg.DeviceID = *options.CLI.DeviceID
			}
			return cfg, nil
		},
		NewUSB: func() transport.DeviceTransport { return tr },
		NewTCP: func(string) (transport.DeviceTransport, error) { return tr, nil },
		Now:    func() time.Time { return time.Time{} },
	}
}

func executeReadCommand(t *testing.T, deps Dependencies, args ...string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := Execute(args, &stdout, &stderr, deps)
	return stdout.String(), stderr.String(), code
}

func cliJSONResponse(body string) string {
	return fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
}

func assertOneJSONDocument(t *testing.T, output string) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewBufferString(output))
	var value any
	require.NoError(t, decoder.Decode(&value))
	require.ErrorIs(t, decoder.Decode(&value), io.EOF)
}

func assertSuccessfulJSONDocument(t *testing.T, output string) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewBufferString(output))
	var value struct {
		OK bool `json:"ok"`
	}
	require.NoError(t, decoder.Decode(&value))
	require.True(t, value.OK)
	require.ErrorIs(t, decoder.Decode(&value), io.EOF)
}
