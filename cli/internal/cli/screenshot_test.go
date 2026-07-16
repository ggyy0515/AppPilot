package cli

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ggyy0515/AppPilot/internal/config"
	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/ggyy0515/AppPilot/internal/device"
	"github.com/stretchr/testify/require"
)

type screenshotTransport struct {
	t            *testing.T
	payload      []byte
	declaredSize int
	sha          string
	mime         string
	method       string
	width        string
	height       string
	scale        string
}

func (s *screenshotTransport) Name() string { return "screenshot-test" }

func (s *screenshotTransport) Dial(context.Context, string, uint16) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			s.t.Error(err)
			return
		}
		if request.Method != http.MethodGet || request.URL.RequestURI() != "/v1/screenshot" {
			s.t.Errorf("unexpected request: %s %s", request.Method, request.URL.RequestURI())
			return
		}
		declaredSize := s.declaredSize
		if declaredSize == 0 {
			declaredSize = len(s.payload)
		}
		mime := defaultString(s.mime, "image/png")
		sha := defaultString(s.sha, screenshotSHA(s.payload))
		method := defaultString(s.method, "drawHierarchy")
		width := defaultString(s.width, "1")
		height := defaultString(s.height, "1")
		scale := defaultString(s.scale, "2")
		_, _ = fmt.Fprintf(server, "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: screenshot-1\r\nX-IOS-Debug-SHA256: %s\r\nX-IOS-Debug-Capture-Method: %s\r\nX-IOS-Debug-Pixel-Width: %s\r\nX-IOS-Debug-Pixel-Height: %s\r\nX-IOS-Debug-Scale: %s\r\n\r\n", mime, declaredSize, sha, method, width, height, scale)
		_, _ = server.Write(s.payload)
	}()
	return client, nil
}

func TestScreenshotCaptureWritesVerifiedPrivateArtifactAndUSBJSON(t *testing.T) {
	payload := screenshotPNG(t)
	transport := &screenshotTransport{t: t, payload: payload}
	output := filepath.Join(t.TempDir(), "shot.png")
	deps := commandDependencies(t, &fakeDeviceDiscoverer{devices: []device.Device{{UDID: "usb-1", Available: true}}}, transport)
	deps.Now = func() time.Time { return time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC) }

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "--device", "usb-1", "screenshot", "capture", "--out", output)
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	absolute, err := filepath.Abs(output)
	require.NoError(t, err)
	requireScreenshotJSON(t, stdout, absolute, len(payload), screenshotSHA(payload), "drawHierarchy", 1, 1, 2, []string{"ap-ios-debug --json state get --device usb-1"})
	stat, err := os.Stat(output)
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0o600), stat.Mode().Perm())
}

func TestScreenshotCaptureUsesDefaultUTCPathAndTCPNextCommand(t *testing.T) {
	payload := screenshotPNG(t)
	transport := &screenshotTransport{t: t, payload: payload}
	outputDir := t.TempDir()
	deps := commandDependencies(t, &fakeDeviceDiscoverer{}, transport)
	deps.Now = func() time.Time { return time.Date(2026, 7, 14, 8, 9, 10, 123000000, time.FixedZone("CST", 8*60*60)) }
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876, OutputDir: outputDir}, nil
	}

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "--transport", "tcp", "--tcp-host", "127.0.0.1", "screenshot", "capture")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	expected := filepath.Join(outputDir, "20260714T000910.123000000Z", "screenshot.png")
	requireScreenshotJSON(t, stdout, expected, len(payload), screenshotSHA(payload), "drawHierarchy", 1, 1, 2, []string{"ap-ios-debug --json state get --transport tcp --tcp-host 127.0.0.1"})
}

func TestScreenshotCaptureRemovesOutputForShortBody(t *testing.T) {
	payload := screenshotPNG(t)
	output := filepath.Join(t.TempDir(), "short.png")
	transport := &screenshotTransport{t: t, payload: payload[:len(payload)-1], declaredSize: len(payload), sha: screenshotSHA(payload)}
	deps := screenshotTCPDependencies(t, transport, filepath.Dir(output))

	stdout, stderr, code := executeReadCommand(t, deps, "--json", "screenshot", "capture", "--out", output)
	require.Equal(t, 5, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, `"code":"protocol_mismatch"`)
	require.NoFileExists(t, output)
	require.Empty(t, screenshotTemps(t, filepath.Dir(output)))
}

func TestScreenshotCaptureRejectsInvalidMetadataAndPNG(t *testing.T) {
	tests := []struct {
		name      string
		transport func(*testing.T) *screenshotTransport
		code      contract.Code
	}{
		{name: "empty method", transport: func(t *testing.T) *screenshotTransport {
			return &screenshotTransport{t: t, payload: screenshotPNG(t), method: " "}
		}, code: contract.ProtocolMismatch},
		{name: "zero width", transport: func(t *testing.T) *screenshotTransport {
			return &screenshotTransport{t: t, payload: screenshotPNG(t), width: "0"}
		}, code: contract.ProtocolMismatch},
		{name: "invalid scale", transport: func(t *testing.T) *screenshotTransport {
			return &screenshotTransport{t: t, payload: screenshotPNG(t), scale: "NaN"}
		}, code: contract.ProtocolMismatch},
		{name: "invalid png", transport: func(t *testing.T) *screenshotTransport { return &screenshotTransport{t: t, payload: []byte("not png")} }, code: contract.ScreenshotFailed},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			outputDir := t.TempDir()
			output := filepath.Join(outputDir, "shot.png")
			deps := screenshotTCPDependencies(t, testCase.transport(t), outputDir)
			stdout, stderr, code := executeReadCommand(t, deps, "--json", "screenshot", "capture", "--out", output)
			require.Equal(t, contract.ExitCode(contract.New(testCase.code, nil)), code)
			require.Empty(t, stderr)
			require.Contains(t, stdout, `"code":"`+string(testCase.code)+`"`)
			require.NoFileExists(t, output)
			require.Empty(t, screenshotTemps(t, outputDir))
		})
	}
}

func screenshotTCPDependencies(t *testing.T, tr *screenshotTransport, outputDir string) Dependencies {
	t.Helper()
	deps := commandDependencies(t, &fakeDeviceDiscoverer{}, tr)
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876, OutputDir: outputDir}, nil
	}
	return deps
}

func screenshotPNG(t *testing.T) []byte {
	t.Helper()
	var output bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, color.RGBA{R: 20, G: 40, B: 60, A: 255})
	require.NoError(t, png.Encode(&output, img))
	return output.Bytes()
}

func screenshotSHA(payload []byte) string {
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func requireScreenshotJSON(t *testing.T, raw, path string, bytes int, sha, method string, width, height int, scale float64, next []string) {
	t.Helper()
	var envelope struct {
		OK   bool `json:"ok"`
		Data struct {
			Path          string   `json:"path"`
			ByteCount     int64    `json:"byte_count"`
			MIME          string   `json:"mime"`
			SHA256        string   `json:"sha256"`
			CaptureMethod string   `json:"capture_method"`
			PixelWidth    int      `json:"pixel_width"`
			PixelHeight   int      `json:"pixel_height"`
			Scale         float64  `json:"scale"`
			NextCommands  []string `json:"next_commands"`
		} `json:"data"`
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	require.NoError(t, decoder.Decode(&envelope))
	require.True(t, envelope.OK)
	require.Equal(t, path, envelope.Data.Path)
	require.Equal(t, int64(bytes), envelope.Data.ByteCount)
	require.Equal(t, "image/png", envelope.Data.MIME)
	require.Equal(t, sha, envelope.Data.SHA256)
	require.Equal(t, method, envelope.Data.CaptureMethod)
	require.Equal(t, width, envelope.Data.PixelWidth)
	require.Equal(t, height, envelope.Data.PixelHeight)
	require.Equal(t, scale, envelope.Data.Scale)
	require.Equal(t, next, envelope.Data.NextCommands)
}

func screenshotTemps(t *testing.T, directory string) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(directory, ".ap-ios-debug-*"))
	require.NoError(t, err)
	return matches
}
