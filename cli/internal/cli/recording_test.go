package cli

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ggyy0515/AppPilot/internal/artifact"
	"github.com/ggyy0515/AppPilot/internal/config"
	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/stretchr/testify/require"
)

type recordingStep struct {
	method   string
	path     string
	response string
}

type recordingTransport struct {
	t        *testing.T
	mu       sync.Mutex
	steps    []recordingStep
	requests []string
}

func (r *recordingTransport) Name() string { return "recording-test" }

func (r *recordingTransport) Dial(ctx context.Context, _ string, _ uint16) (net.Conn, error) {
	r.mu.Lock()
	index := len(r.requests)
	if index >= len(r.steps) {
		r.mu.Unlock()
		return nil, fmt.Errorf("unexpected recording request %d", index+1)
	}
	r.mu.Unlock()

	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			r.t.Error(err)
			return
		}
		_, _ = io.Copy(io.Discard, request.Body)
		line := request.Method + " " + request.URL.RequestURI()
		r.mu.Lock()
		step := r.steps[len(r.requests)]
		r.requests = append(r.requests, line)
		r.mu.Unlock()
		if request.Method != step.method || request.URL.RequestURI() != step.path {
			r.t.Errorf("unexpected request %s, want %s %s", line, step.method, step.path)
			return
		}
		_, _ = io.WriteString(server, step.response)
	}()
	return client, nil
}

func (r *recordingTransport) requestLines() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.requests...)
}

func TestRecordingStatusAndStartUseBoundedContexts(t *testing.T) {
	originalContext := recordingContext
	var observedTimeout time.Duration
	recordingContext = func(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
		observedTimeout = timeout
		return context.WithCancel(parent)
	}
	defer func() { recordingContext = originalContext }()

	status := recordingJSON(`{"state":"idle","elapsed_ms":0,"recording_id":null}`, "status-1")
	statusFake := &recordingTransport{t: t, steps: []recordingStep{{http.MethodGet, "/v1/recording/status", status}}}
	stdout, stderr, code := executeReadCommand(t, recordingDependencies(t, statusFake, t.TempDir()), "--json", "recording", "status")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, `"state":"idle"`)
	require.Zero(t, observedTimeout)

	started := recordingJSON(`{"state":"recording","elapsed_ms":0,"recording_id":"rec-1"}`, "start-1")
	startFake := &recordingTransport{t: t, steps: []recordingStep{{http.MethodPost, "/v1/recording/start", started}}}
	stdout, stderr, code = executeReadCommand(t, recordingDependencies(t, startFake, t.TempDir()), "--json", "recording", "start")
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, `"state":"recording"`)
	require.Equal(t, 60*time.Second, observedTimeout)
}

func TestRecordingStopDownloadsVerifiesThenDeletes(t *testing.T) {
	originalContext := recordingContext
	var observedTimeout time.Duration
	recordingContext = func(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
		observedTimeout = timeout
		return context.WithCancel(parent)
	}
	defer func() { recordingContext = originalContext }()

	mp4 := validMinimalMP4()
	sha := sha256Hex(mp4)
	fake := &recordingTransport{t: t, steps: []recordingStep{
		{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)), sha)},
		{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(mp4, int64(len(mp4)), sha)},
		{http.MethodDelete, "/v1/recordings/rec-1", recordingJSON(`{"recording_id":"rec-1","deleted":true}`, "delete-1")},
	}}
	destination := filepath.Join(t.TempDir(), "recording.mp4")
	stdout, stderr, code := executeReadCommand(t, recordingDependencies(t, fake, filepath.Dir(destination)), "--json", "--transport", "tcp", "recording", "stop", "--out", destination)
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Equal(t, []string{"POST /v1/recording/stop", "GET /v1/recordings/rec-1", "DELETE /v1/recordings/rec-1"}, fake.requestLines())
	require.FileExists(t, destination)
	require.Contains(t, stdout, `"device_file_deleted":true`)
	absolute, err := filepath.Abs(destination)
	require.NoError(t, err)
	require.Contains(t, stdout, `"next_commands":["open `+absolute+`"]`)
	stat, err := os.Stat(destination)
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0o600), stat.Mode().Perm())
	require.Equal(t, 90*time.Second, observedTimeout)
}

func TestRecordingStopFailuresKeepDeviceFileAndRemoveLocalTemp(t *testing.T) {
	mp4 := validMinimalMP4()
	validSHA := sha256Hex(mp4)
	tests := []struct {
		name  string
		steps []recordingStep
		code  contract.Code
	}{
		{name: "response length", code: contract.ArtifactChecksumMismatch, steps: []recordingStep{
			{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)+1), validSHA)},
			{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(mp4, int64(len(mp4)), validSHA)},
		}},
		{name: "header checksum", code: contract.ArtifactChecksumMismatch, steps: []recordingStep{
			{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)), validSHA)},
			{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(mp4, int64(len(mp4)), strings.Repeat("a", 64))},
		}},
		{name: "download checksum", code: contract.ArtifactChecksumMismatch, steps: func() []recordingStep {
			corrupt := append([]byte(nil), mp4...)
			corrupt[len(corrupt)-1] ^= 0xff
			return []recordingStep{{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)), validSHA)}, {http.MethodGet, "/v1/recordings/rec-1", recordingBinary(corrupt, int64(len(corrupt)), validSHA)}}
		}()},
		{name: "invalid MP4", code: contract.RecordingNotAvailable, steps: func() []recordingStep {
			bad := []byte("not-an-mp4")
			sha := sha256Hex(bad)
			return []recordingStep{{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(bad)), sha)}, {http.MethodGet, "/v1/recordings/rec-1", recordingBinary(bad, int64(len(bad)), sha)}}
		}()},
		{name: "truncated download", code: contract.ProtocolMismatch, steps: []recordingStep{
			{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)), validSHA)},
			{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(mp4[:len(mp4)-1], int64(len(mp4)), validSHA)},
		}},
		{name: "too large", code: contract.ArtifactTooLarge, steps: []recordingStep{
			{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", (500<<20)+1, validSHA)},
			{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(nil, (500<<20)+1, validSHA)},
		}},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			destination := filepath.Join(directory, "recording.mp4")
			fake := &recordingTransport{t: t, steps: testCase.steps}
			stdout, stderr, code := executeReadCommand(t, recordingDependencies(t, fake, directory), "--json", "recording", "stop", "--out", destination)
			require.Equal(t, contract.ExitCode(contract.New(testCase.code, nil)), code)
			require.Empty(t, stderr)
			require.Contains(t, stdout, `"code":"`+string(testCase.code)+`"`)
			require.Len(t, fake.requestLines(), 2)
			require.NoFileExists(t, destination)
			temps, err := filepath.Glob(filepath.Join(directory, ".ap-ios-debug-*"))
			require.NoError(t, err)
			require.Empty(t, temps)
		})
	}
}

func TestRecordingDeleteFailurePreservesVerifiedArtifactAndWarns(t *testing.T) {
	mp4 := validMinimalMP4()
	sha := sha256Hex(mp4)
	fake := &recordingTransport{t: t, steps: []recordingStep{
		{http.MethodPost, "/v1/recording/stop", recordingStopJSON("rec-1", int64(len(mp4)), sha)},
		{http.MethodGet, "/v1/recordings/rec-1", recordingBinary(mp4, int64(len(mp4)), sha)},
		{http.MethodDelete, "/v1/recordings/rec-1", recordingFailureJSON("recording_not_available")},
	}}
	destination := filepath.Join(t.TempDir(), "recording.mp4")
	stdout, stderr, code := executeReadCommand(t, recordingDependencies(t, fake, filepath.Dir(destination)), "--json", "recording", "stop", "--out", destination)
	require.Equal(t, 0, code)
	require.FileExists(t, destination)
	require.Contains(t, stdout, `"device_file_deleted":false`)
	require.Equal(t, "ap-ios-debug: warning: verified recording saved locally; device cleanup will retry through the App retention policy.\n", stderr)
	require.NotContains(t, stderr, "rec-1")
}

func TestRecordingValidateMP4RejectsMalformedBoxes(t *testing.T) {
	tests := map[string][]byte{
		"missing ftyp":      makeBox("moov", nil),
		"missing moov":      makeBox("ftyp", []byte("isom\x00\x00\x00\x00isom")),
		"unsupported brand": append(makeBox("ftyp", []byte("avc1\x00\x00\x00\x00avc1")), makeBox("moov", nil)...),
		"truncated":         []byte{0, 0, 0, 20, 'f', 't', 'y', 'p', 'i'},
		"overflowing large": []byte{0, 0, 0, 1, 'f', 't', 'y', 'p', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
	}
	for name, payload := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "recording.mp4")
			require.NoError(t, os.WriteFile(path, payload, 0o600))
			err := artifact.ValidateMP4(path)
			require.Error(t, err)
			require.Equal(t, contract.RecordingNotAvailable, contract.CodeOf(err))
		})
	}
}

func recordingDependencies(t *testing.T, tr *recordingTransport, outputDir string) Dependencies {
	t.Helper()
	deps := commandDependencies(t, &fakeDeviceDiscoverer{}, tr)
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876, OutputDir: outputDir}, nil
	}
	return deps
}

func recordingJSON(data, requestID string) string {
	body := `{"ok":true,"data":` + data + `,"meta":{"protocol_version":1,"request_id":"` + requestID + `"}}`
	return fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
}

func recordingStopJSON(id string, size int64, sha string) string {
	return recordingJSON(fmt.Sprintf(`{"recording_id":%q,"byte_count":%d,"duration_ms":900,"sha256":%q,"mime":"video/mp4"}`, id, size, sha), "stop-1")
}

func recordingFailureJSON(code string) string {
	body := fmt.Sprintf(`{"ok":false,"error":{"code":%q,"message":"private","hint":"private"},"meta":{"protocol_version":1,"request_id":"delete-fail"}}`, code)
	return fmt.Sprintf("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
}

func recordingBinary(payload []byte, declared int64, sha string) string {
	return fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: %d\r\nConnection: close\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: binary-1\r\nX-IOS-Debug-SHA256: %s\r\n\r\n%s", declared, sha, payload)
}

func validMinimalMP4() []byte {
	return append(makeBox("ftyp", []byte("isom\x00\x00\x00\x00isom")), makeBox("moov", nil)...)
}

func makeBox(kind string, payload []byte) []byte {
	box := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(box[:4], uint32(len(box)))
	copy(box[4:8], kind)
	copy(box[8:], payload)
	return box
}

func sha256Hex(payload []byte) string {
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}
