package cli_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/cli"
	"github.com/yangy003/ios-debug-system/cli/internal/config"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ios-debug-system/cli/internal/protocol"
	"github.com/yangy003/ios-debug-system/cli/internal/testutil/fakeapp"
	"github.com/yangy003/ios-debug-system/cli/internal/transport"
)

func TestAllCommandsAgainstFakeApp(t *testing.T) {
	app := fakeapp.Start(t)
	common := []string{"--json", "--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port))}
	shot := filepath.Join(t.TempDir(), "shot.png")
	recording := filepath.Join(t.TempDir(), "screen.mp4")
	assertSuccess(t, append(common, "app", "probe")...)
	assertSuccess(t, append(common, "actions", "list")...)
	assertSuccess(t, append(common, "actions", "activate", "counter.increment", "--dry-run")...)
	assertSuccess(t, append(common, "actions", "activate", "counter.increment")...)
	state := assertSuccess(t, append(common, "state", "get")...)
	require.Equal(t, float64(1), state["data"].(map[string]any)["counter"])
	screenshot := assertSuccess(t, append(common, "screenshot", "capture", "--out", shot)...)
	assertArtifact(t, shot, app.ScreenshotBytes(), screenshot)
	status := assertSuccess(t, append(common, "recording", "status")...)
	require.Equal(t, "idle", status["data"].(map[string]any)["state"])
	assertSuccess(t, append(common, "recording", "start")...)
	status = assertSuccess(t, append(common, "recording", "status")...)
	require.Equal(t, "recording", status["data"].(map[string]any)["state"])
	recorded := assertSuccess(t, append(common, "recording", "stop", "--out", recording)...)
	assertArtifact(t, recording, app.RecordingBytes(), recorded)
	status = assertSuccess(t, append(common, "recording", "status")...)
	require.Equal(t, "idle", status["data"].(map[string]any)["state"])
	assertSuccess(t, append(common, "request", "get", "/v1/capabilities")...)
	head := assertSuccess(t, append(common, "request", "head", "/v1/capabilities")...)
	headData := head["data"].(map[string]any)
	require.Equal(t, float64(http.StatusOK), headData["status_code"])
	headHeaders := headData["headers"].(map[string]any)
	require.NotEmpty(t, headHeaders["Content-Length"])
	require.NotEmpty(t, headHeaders["Content-Type"])
	headerNames := make([]string, 0, len(headHeaders))
	for name := range headHeaders {
		headerNames = append(headerNames, name)
	}
	require.ElementsMatch(t, []string{
		"Content-Length", "Content-Type", "X-Ios-Debug-Protocol-Version", "X-Ios-Debug-Request-Id",
	}, headerNames)

	want := []fakeapp.RecordedRequest{
		{Method: "GET", Path: "/v1/health"},
		{Method: "GET", Path: "/v1/actions"},
		{Method: "GET", Path: "/v1/actions"},
		{Method: "GET", Path: "/v1/actions"},
		{Method: "POST", Path: "/v1/actions/activate", Body: []byte(`{"identifier":"counter.increment"}`)},
		{Method: "GET", Path: "/v1/state"},
		{Method: "GET", Path: "/v1/screenshot"},
		{Method: "GET", Path: "/v1/recording/status"},
		{Method: "POST", Path: "/v1/recording/start", Body: []byte(`{}`)},
		{Method: "GET", Path: "/v1/recording/status"},
		{Method: "POST", Path: "/v1/recording/stop", Body: []byte(`{}`)},
		{Method: "GET", Path: "/v1/recordings/recording-1"},
		{Method: "DELETE", Path: "/v1/recordings/recording-1"},
		{Method: "GET", Path: "/v1/recording/status"},
		{Method: "GET", Path: "/v1/capabilities"},
		{Method: "HEAD", Path: "/v1/capabilities"},
	}
	require.Equal(t, want, app.Requests())
}

func TestProductionDoctorUsesCommandTCPFlagsInEitherOrder(t *testing.T) {
	app := fakeapp.Start(t)
	tests := []struct {
		name  string
		args  []string
		setup func(*testing.T, *cli.Dependencies)
	}{
		{name: "flags before command", args: []string{"--json", "--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port)), "doctor"}},
		{name: "flags after command", args: []string{"doctor", "--port", strconv.Itoa(int(app.Port)), "--tcp-host", app.Host, "--transport", "tcp", "--json"}},
		{name: "environment", args: []string{"--json", "doctor"}, setup: func(t *testing.T, deps *cli.Dependencies) {
			working := t.TempDir()
			contents := fmt.Sprintf("transport = \"tcp\"\ntcp_host = %q\nport = 1\n", app.Host)
			require.NoError(t, os.WriteFile(filepath.Join(working, ".ios-debug.toml"), []byte(contents), 0o600))
			deps.WorkingDir = working
			t.Setenv("IOS_DEBUG_PORT", strconv.Itoa(int(app.Port)))
		}},
		{name: "project TOML", args: []string{"--json", "doctor"}, setup: func(t *testing.T, deps *cli.Dependencies) {
			working := t.TempDir()
			contents := fmt.Sprintf("transport = \"tcp\"\ntcp_host = %q\nport = %d\n", app.Host, app.Port)
			require.NoError(t, os.WriteFile(filepath.Join(working, ".ios-debug.toml"), []byte(contents), 0o600))
			deps.WorkingDir = working
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			deps := cli.NewProductionDependencies(&stdout, &stderr)
			if test.setup != nil {
				test.setup(t, &deps)
			}
			var tcpConfig config.Config
			productionTCPProbe := deps.Doctor.TCPProbe
			deps.Doctor.LookPath = func(name string) (string, error) { return "/usr/bin/" + name, nil }
			deps.Doctor.Run = func(context.Context, string, ...string) ([]byte, error) { return []byte("version 1\n"), nil }
			deps.Doctor.TemplateLocator = staticLocator{path: t.TempDir()}
			usbCalls := 0
			deps.Doctor.USBProbe = func(context.Context) (int, error) { usbCalls++; return 0, nil }
			deps.Doctor.TCPProbe = func(ctx context.Context, cfg config.Config) error {
				tcpConfig = cfg
				return productionTCPProbe(ctx, cfg)
			}
			code := cli.Execute(test.args, &stdout, &stderr, deps)
			require.Equal(t, 0, code, "stdout=%s stderr=%s", stdout.String(), stderr.String())
			require.Equal(t, "tcp", tcpConfig.Transport)
			require.Equal(t, app.Host, tcpConfig.TCPHost)
			require.Equal(t, app.Port, tcpConfig.Port)
			require.Zero(t, usbCalls)
		})
	}
}

type staticLocator struct{ path string }

func (l staticLocator) Locate() (string, error) { return l.path, nil }

func TestTextTCPCommandsAreHumanReadable(t *testing.T) {
	app := fakeapp.Start(t)
	common := []string{"--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port))}
	for _, command := range [][]string{{"app", "probe"}, {"actions", "list"}, {"state", "get"}, {"request", "head", "/v1/capabilities"}} {
		stdout, stderr, code := executeProduction(append(common, command...))
		require.Equal(t, 0, code, stderr)
		require.NotEmpty(t, stdout)
		require.False(t, json.Valid([]byte(stdout)), stdout)
		for _, r := range stdout {
			require.False(t, r < 0x20 && r != '\n' && r != '\t', "control character %U in %q", r, stdout)
		}
	}
}

func TestTokenIsNotWrittenToEitherStream(t *testing.T) {
	app := fakeapp.Start(t)
	binary := buildCLI(t)
	secret := "secret-token-123"
	args := []string{"--json", "--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port)), "app", "probe"}
	command := exec.Command(binary, args...)
	command.Dir = "/tmp"
	command.Env = append(os.Environ(), "HOME="+t.TempDir(), "IOS_DEBUG_TOKEN="+secret)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	require.NoError(t, command.Run(), stderr.String())
	require.NotContains(t, stdout.String(), secret)
	require.NotContains(t, stderr.String(), secret)
}

func TestCanceledRequestClosesSocket(t *testing.T) {
	app := fakeapp.Start(t)
	tr, err := transport.NewTCP(app.Host)
	require.NoError(t, err)
	client := protocol.NewClient(tr, protocol.Target{Port: app.Port}, "")
	app.BlockNextRequest()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		var data json.RawMessage
		_, err := client.DoJSON(ctx, "GET", "/v1/health", nil, 1<<20, &data)
		done <- err
	}()
	require.Eventually(t, func() bool { return len(app.Requests()) == 1 }, time.Second, 10*time.Millisecond)
	cancel()
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(<-done))
	require.Eventually(t, func() bool { return app.CloseCount() == app.DialCount() }, time.Second, 10*time.Millisecond)
}

func TestSequentialCommandsCloseEveryConnection(t *testing.T) {
	app := fakeapp.Start(t)
	args := []string{"--json", "--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port)), "app", "probe"}
	for range 50 {
		_, _, code := executeProduction(args)
		require.Equal(t, 0, code)
	}
	require.Equal(t, int64(50), app.DialCount())
	require.Eventually(t, func() bool { return app.CloseCount() == 50 }, time.Second, 10*time.Millisecond)
}

func TestInstalledBinaryFindsTemplateFromTemporaryHome(t *testing.T) {
	binary := buildCLI(t)
	home := t.TempDir()
	template := filepath.Join(home, ".local", "share", "ios-debug", "IOSDebugKit")
	require.NoError(t, os.MkdirAll(filepath.Join(template, "Templates"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Package.swift"), []byte("// fixture\n"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Templates", "IOSDebugBootstrap.swift"), []byte("// fixture\n"), 0o644))
	project := t.TempDir()
	command := exec.Command(binary, "--json", "app", "scaffold", "--into", project, "--dry-run")
	command.Dir = "/tmp"
	command.Env = append(os.Environ(), "HOME="+home)
	result, err := command.CombinedOutput()
	require.NoError(t, err, string(result))
	require.Contains(t, string(result), "IOSDebugBootstrap.swift")
}

func buildCLI(t *testing.T) string {
	t.Helper()
	repository, err := filepath.Abs(filepath.Join("..", ".."))
	require.NoError(t, err)
	binary := filepath.Join(t.TempDir(), "ios-debug")
	build := exec.Command("go", "build", "-trimpath", "-o", binary, "./cmd/ios-debug")
	build.Dir = repository
	output, err := build.CombinedOutput()
	require.NoError(t, err, string(output))
	return binary
}

func TestInvalidArityReturnsConfigInvalidWithoutDial(t *testing.T) {
	app := fakeapp.Start(t)
	stdout, _, code := executeProduction([]string{"--json", "--transport", "tcp", "--tcp-host", app.Host, "--port", strconv.Itoa(int(app.Port)), "state", "get", "extra"})
	require.Equal(t, 2, code)
	require.Contains(t, stdout, `"code":"config_invalid"`)
	require.Zero(t, app.DialCount())
}

func assertSuccess(t *testing.T, args ...string) map[string]any {
	t.Helper()
	stdout, stderr, code := executeProduction(args)
	require.Equal(t, 0, code, "stdout=%s stderr=%s", stdout, stderr)
	decoder := json.NewDecoder(strings.NewReader(stdout))
	var envelope map[string]any
	require.NoError(t, decoder.Decode(&envelope), stdout)
	var extra any
	require.ErrorIs(t, decoder.Decode(&extra), io.EOF)
	require.Equal(t, true, envelope["ok"], stdout)
	require.Empty(t, stderr)
	return envelope
}

func assertArtifact(t *testing.T, path string, want []byte, envelope map[string]any) {
	t.Helper()
	contents, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, want, contents)
	info, err := os.Stat(path)
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	digest := fmt.Sprintf("%x", sha256.Sum256(want))
	data := envelope["data"].(map[string]any)
	require.Equal(t, digest, data["sha256"])
	require.Equal(t, float64(len(want)), data["byte_count"])
}

func executeProduction(args []string) (string, string, int) {
	var stdout, stderr bytes.Buffer
	deps := cli.NewProductionDependencies(&stdout, &stderr)
	code := cli.Execute(args, &stdout, &stderr, deps)
	return strings.TrimSpace(stdout.String()), stderr.String(), code
}
