package protocol

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/stretchr/testify/require"
)

type scriptedDeviceTransport struct {
	t        *testing.T
	response string
	dialErr  error
	mu       sync.Mutex
	dials    int
	request  string
	host     string
}

func (s *scriptedDeviceTransport) Name() string { return "scripted" }

func (s *scriptedDeviceTransport) Dial(context.Context, string, uint16) (net.Conn, error) {
	s.mu.Lock()
	s.dials++
	s.mu.Unlock()
	if s.dialErr != nil {
		return nil, s.dialErr
	}
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			s.t.Error(err)
			return
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			s.t.Error(err)
			return
		}
		var raw strings.Builder
		fmt.Fprintf(&raw, "%s %s %s\r\n", request.Method, request.URL.RequestURI(), request.Proto)
		for key, values := range request.Header {
			for _, value := range values {
				fmt.Fprintf(&raw, "%s: %s\r\n", key, value)
			}
		}
		raw.WriteString("\r\n")
		raw.Write(body)
		s.mu.Lock()
		s.request = raw.String()
		s.host = request.Host
		s.mu.Unlock()
		_, _ = io.WriteString(server, s.response)
	}()
	return client, nil
}

func (s *scriptedDeviceTransport) DialCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dials
}

func (s *scriptedDeviceTransport) Request() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.request
}

func (s *scriptedDeviceTransport) Host() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.host
}

func jsonHTTP(status string, body string, extraHeaders ...string) string {
	headers := "Content-Type: application/json\r\nConnection: close\r\n"
	for _, header := range extraHeaders {
		headers += header + "\r\n"
	}
	return fmt.Sprintf("HTTP/1.1 %s\r\n%sContent-Length: %d\r\n\r\n%s", status, headers, len(body), body)
}

func successEnvelope(data string) string {
	return `{"ok":true,"data":` + data + `,"meta":{"protocol_version":1,"request_id":"req-1"}}`
}

func TestDoJSONUsesOneConnectionAndValidatesVersion(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(`{"status":"ready"}`))}
	client := NewClient(tr, Target{DeviceID: "udid", Port: 9876}, "secret")
	var got struct {
		Status string `json:"status"`
	}
	meta, err := client.DoJSON(context.Background(), http.MethodGet, "/v1/health", nil, 4<<20, &got)
	require.NoError(t, err)
	require.Equal(t, "ready", got.Status)
	require.Equal(t, "req-1", meta.RequestID)
	require.Equal(t, 1, meta.ProtocolVersion)
	require.Contains(t, tr.Request(), "Authorization: Bearer secret\r\n")
	require.Contains(t, tr.Request(), "Connection: close\r\n")
	require.Contains(t, tr.Request(), "Accept: application/json\r\n")
	require.Equal(t, 1, tr.DialCount())
}

func TestDoJSONUsesAppPilotVirtualHost(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(`{}`))}

	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/health", nil, 1024, nil)

	require.NoError(t, err)
	require.Equal(t, "ap-ios-debug.local", tr.Host())
}

func TestDoJSONEncodesInputBeforeDialAndLimitsRequestSize(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(`{}`))}
	client := NewClient(tr, Target{DeviceID: "udid", Port: 9876}, "")
	_, err := client.DoJSON(context.Background(), http.MethodPost, "/v1/actions/activate", map[string]string{"value": strings.Repeat("x", (1<<20)+1)}, 1<<20, nil)
	require.Equal(t, contract.ArtifactTooLarge, contract.CodeOf(err))
	require.Zero(t, tr.DialCount())

	_, err = client.DoJSON(context.Background(), http.MethodPost, "/v1/actions/activate", func() {}, 1<<20, nil)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.Zero(t, tr.DialCount())
}

func TestDoJSONMapsAuthenticationStatusesWithoutLeakingPayloadOrToken(t *testing.T) {
	for _, testCase := range []struct {
		status string
		code   contract.Code
	}{
		{"401 Unauthorized", contract.AuthRequired},
		{"403 Forbidden", contract.AuthFailed},
	} {
		t.Run(testCase.status, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: jsonHTTP(testCase.status, "token secret Authorization: Bearer secret")}
			_, err := NewClient(tr, Target{Port: 9876}, "secret").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
			require.Equal(t, testCase.code, contract.CodeOf(err))
			require.NotContains(t, err.Error(), "secret")
			require.NotContains(t, err.Error(), "Authorization")
		})
	}
}

func TestDoJSONPreservesRecognizedAppError(t *testing.T) {
	body := `{"ok":false,"error":{"code":"action_disabled","message":"private message","hint":"private hint"},"meta":{"protocol_version":1,"request_id":"req-e"}}`
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("409 Conflict", body)}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodPost, "/v1/actions/activate", struct{}{}, 1024, nil)
	require.Equal(t, contract.ActionDisabled, contract.CodeOf(err))
	require.NotContains(t, err.Error(), "private")
}

func TestDoJSONRejectsIncompleteOrMixedErrorEnvelope(t *testing.T) {
	for _, body := range []string{
		`{"ok":false,"error":{"code":"action_disabled","message":"m"},"meta":{"protocol_version":1,"request_id":"req"}}`,
		`{"ok":false,"data":{},"error":{"code":"action_disabled","message":"m","hint":"h"},"meta":{"protocol_version":1,"request_id":"req"}}`,
	} {
		tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("409 Conflict", body)}
		_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
		require.Error(t, err)
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
	}
}

func TestDoJSONPreservesEveryAppCatalogCodeButRejectsClientOnlyCode(t *testing.T) {
	for _, code := range []contract.Code{
		contract.ConfigInvalid, contract.AppNotReachable, contract.RequestTimeout,
		contract.ProtocolMismatch, contract.AuthRequired, contract.AuthFailed,
	} {
		t.Run(string(code), func(t *testing.T) {
			body := fmt.Sprintf(`{"ok":false,"error":{"code":%q,"message":"m","hint":"h"},"meta":{"protocol_version":1,"request_id":"req"}}`, code)
			tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("400 Bad Request", body)}
			_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
			require.Equal(t, code, contract.CodeOf(err))
		})
	}

	body := `{"ok":false,"error":{"code":"action_requires_confirmation","message":"m","hint":"h"},"meta":{"protocol_version":1,"request_id":"req"}}`
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("409 Conflict", body)}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
}

func TestDoJSONRejectsMalformedProtocolResponses(t *testing.T) {
	tests := []struct {
		name     string
		response string
		maxBytes int64
		code     contract.Code
	}{
		{"wrong MIME", strings.Replace(jsonHTTP("200 OK", successEnvelope(`{}`)), "application/json", "text/plain", 1), 1024, contract.ProtocolMismatch},
		{"missing MIME", strings.Replace(jsonHTTP("200 OK", successEnvelope(`{}`)), "Content-Type: application/json\r\n", "", 1), 1024, contract.ProtocolMismatch},
		{"wrong version", jsonHTTP("200 OK", `{"ok":true,"data":{},"meta":{"protocol_version":2,"request_id":"req"}}`), 1024, contract.ProtocolMismatch},
		{"missing request ID", jsonHTTP("200 OK", `{"ok":true,"data":{},"meta":{"protocol_version":1,"request_id":""}}`), 1024, contract.ProtocolMismatch},
		{"missing data", jsonHTTP("200 OK", `{"ok":true,"meta":{"protocol_version":1,"request_id":"req"}}`), 1024, contract.ProtocolMismatch},
		{"status OK mismatch", jsonHTTP("500 Internal Server Error", successEnvelope(`{}`)), 1024, contract.ProtocolMismatch},
		{"status error mismatch", jsonHTTP("200 OK", `{"ok":false,"error":{"code":"action_failed","message":"m","hint":"h"},"meta":{"protocol_version":1,"request_id":"req"}}`), 1024, contract.ProtocolMismatch},
		{"unknown error", jsonHTTP("409 Conflict", `{"ok":false,"error":{"code":"future_error","message":"m","hint":"h"},"meta":{"protocol_version":1,"request_id":"req"}}`), 1024, contract.ProtocolMismatch},
		{"multiple JSON values", jsonHTTP("200 OK", successEnvelope(`{}`)+` {}`), 1024, contract.ProtocolMismatch},
		{"too large", jsonHTTP("200 OK", successEnvelope(`{"value":"long"}`)), 8, contract.ArtifactTooLarge},
		{"gzip", jsonHTTP("200 OK", successEnvelope(`{}`), "Content-Encoding: gzip"), 1024, contract.ProtocolMismatch},
		{"upgrade", jsonHTTP("200 OK", successEnvelope(`{}`), "Upgrade: websocket"), 1024, contract.ProtocolMismatch},
		{"HTTP 1.0", strings.Replace(jsonHTTP("200 OK", successEnvelope(`{}`)), "HTTP/1.1", "HTTP/1.0", 1), 1024, contract.ProtocolMismatch},
		{"truncated", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 50\r\n\r\n{}", 1024, contract.ProtocolMismatch},
		{"chunked", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n", 1024, contract.ProtocolMismatch},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: testCase.response}
			_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, testCase.maxBytes, nil)
			require.Error(t, err)
			require.Equal(t, testCase.code, contract.CodeOf(err), err)
		})
	}
}

func TestDoJSONMapsTimeoutAndNeverLeaksAuthorization(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, dialErr: context.DeadlineExceeded}
	_, err := NewClient(tr, Target{Port: 9876}, "very-secret").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
	require.NotContains(t, fmt.Sprintf("%v", err), "very-secret")
	require.NotContains(t, fmt.Sprintf("%+v", err), "Authorization")
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "timed out" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func TestDoJSONMapsNetworkTimeout(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, dialErr: timeoutError{}}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
}

func TestOpenBinaryValidatesHeadersAndLeavesBodyForCaller(t *testing.T) {
	body := "png bytes"
	sha := strings.Repeat("a", 64)
	response := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\nConnection: close\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: req-png\r\nX-IOS-Debug-SHA256: %s\r\nX-IOS-Debug-Capture-Method: drawHierarchy\r\nX-IOS-Debug-Pixel-Width: 100\r\nX-IOS-Debug-Pixel-Height: 200\r\nX-IOS-Debug-Scale: 2\r\n\r\n%s", len(body), sha, body)
	tr := &scriptedDeviceTransport{t: t, response: response}
	got, err := NewClient(tr, Target{Port: 9876}, "").OpenBinary(context.Background(), "/v1/screenshot", "image/png", 1024)
	require.NoError(t, err)
	require.Equal(t, int64(len(body)), got.ContentLength)
	require.Equal(t, sha, got.SHA256)
	require.Equal(t, "req-png", got.Meta.RequestID)
	require.Equal(t, "drawHierarchy", got.Header.Get("X-IOS-Debug-Capture-Method"))
	bytes, err := io.ReadAll(got.Body)
	require.NoError(t, err)
	require.Equal(t, body, string(bytes))
	require.NoError(t, got.Body.Close())
	require.Equal(t, 1, tr.DialCount())
}

func TestOpenBinaryRejectsInvalidMetadata(t *testing.T) {
	valid := func(headers ...string) string {
		all := []string{
			"Content-Type: image/png", "Content-Length: 3", "Connection: close",
			"X-IOS-Debug-Protocol-Version: 1", "X-IOS-Debug-Request-ID: req",
			"X-IOS-Debug-SHA256: " + strings.Repeat("a", 64),
		}
		all = append(all, headers...)
		return "HTTP/1.1 200 OK\r\n" + strings.Join(all, "\r\n") + "\r\n\r\npng"
	}
	tests := []struct {
		name     string
		response string
		max      int64
		code     contract.Code
	}{
		{"wrong MIME", strings.Replace(valid(), "image/png", "video/mp4", 1), 10, contract.ProtocolMismatch},
		{"too large", valid(), 2, contract.ArtifactTooLarge},
		{"bad protocol", strings.Replace(valid(), "Protocol-Version: 1", "Protocol-Version: 2", 1), 10, contract.ProtocolMismatch},
		{"missing request", strings.Replace(valid(), "X-IOS-Debug-Request-ID: req\r\n", "", 1), 10, contract.ProtocolMismatch},
		{"bad SHA", strings.Replace(valid(), strings.Repeat("a", 64), strings.Repeat("A", 64), 1), 10, contract.ProtocolMismatch},
		{"duplicate request ID", valid("X-IOS-Debug-Request-ID: second"), 10, contract.ProtocolMismatch},
		{"non-2xx", strings.Replace(valid(), "200 OK", "500 Internal Server Error", 1), 10, contract.ProtocolMismatch},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: testCase.response}
			_, err := NewClient(tr, Target{Port: 9876}, "").OpenBinary(context.Background(), "/v1/screenshot", "image/png", testCase.max)
			require.Error(t, err)
			require.Equal(t, testCase.code, contract.CodeOf(err), err)
		})
	}
}

func TestClientRejectsInvalidPathBeforeDial(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t}
	client := NewClient(tr, Target{Port: 9876}, "secret")
	_, err := client.DoJSON(context.Background(), http.MethodGet, "http://evil.invalid/v1/state", nil, 1024, nil)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.Zero(t, tr.DialCount())
}

func TestTimeoutRecognizesWrappedDeadline(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, dialErr: fmt.Errorf("wrapped: %w", context.DeadlineExceeded)}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
	require.True(t, errors.Is(err, context.DeadlineExceeded))
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
}

func TestDoJSONHonorsContextDeadline(t *testing.T) {
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	tr := &scriptedDeviceTransport{t: t, dialErr: ctx.Err()}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(ctx, http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
}

func TestDoHEADReturnsValidatedMetadataAndSendsExactRequest(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/json; charset=utf-8\r\n" +
		"Content-Length: 123\r\n" +
		"Connection: close\r\n" +
		"X-IOS-Debug-Protocol-Version: 1\r\n" +
		"X-IOS-Debug-Request-ID: req-head\r\n\r\n"
	tr := &scriptedDeviceTransport{t: t, response: response}

	metadata, err := NewClient(tr, Target{DeviceID: "udid", Port: 9876}, "secret").DoHEAD(
		context.Background(), "/v1/state",
	)
	require.NoError(t, err)
	require.Equal(t, 200, metadata.StatusCode)
	require.Equal(t, "123", metadata.Headers.Get("Content-Length"))
	require.Equal(t, "req-head", metadata.Headers.Get("X-IOS-Debug-Request-ID"))
	require.Contains(t, tr.Request(), "HEAD /v1/state HTTP/1.1\r\n")
	require.Contains(t, tr.Request(), "Authorization: Bearer secret\r\n")
	require.Contains(t, tr.Request(), "Connection: close\r\n")
	require.Equal(t, 1, tr.DialCount())
}

func TestDoHEADRejectsMissingProtocolMetadataAndInvalidPaths(t *testing.T) {
	response := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	tr := &scriptedDeviceTransport{t: t, response: response}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoHEAD(context.Background(), "/v1/state")
	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))

	invalid := &scriptedDeviceTransport{t: t}
	_, err = NewClient(invalid, Target{Port: 9876}, "").DoHEAD(context.Background(), "/v1/")
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.Zero(t, invalid.DialCount())
}
