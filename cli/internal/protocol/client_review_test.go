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

type stallingBodyTransport struct {
	t       *testing.T
	header  string
	closed  chan struct{}
	request chan *http.Request
}

func (s *stallingBodyTransport) Name() string { return "stalling" }

func (s *stallingBodyTransport) Dial(context.Context, string, uint16) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		defer close(s.closed)
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			s.t.Error(err)
			return
		}
		s.request <- request
		if _, err := io.WriteString(server, s.header); err != nil {
			return
		}
		var scratch [1]byte
		_, _ = server.Read(scratch[:])
	}()
	return client, nil
}

func TestDoJSONMapsDeadlineWhileReadingBody(t *testing.T) {
	tr := &stallingBodyTransport{
		t:       t,
		header:  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n",
		closed:  make(chan struct{}),
		request: make(chan *http.Request, 1),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(ctx, http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err), err)
	select {
	case <-tr.closed:
	case <-time.After(time.Second):
		t.Fatal("connection remained open after body-read deadline")
	}
}

func TestOpenBinaryMapsCancellationAndClosesConnection(t *testing.T) {
	tr := &stallingBodyTransport{
		t: t,
		header: "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 100\r\nConnection: close\r\n" +
			"X-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: req\r\n" +
			"X-IOS-Debug-SHA256: " + strings.Repeat("a", 64) + "\r\n\r\n",
		closed:  make(chan struct{}),
		request: make(chan *http.Request, 1),
	}
	ctx, cancel := context.WithCancel(context.Background())
	response, err := NewClient(tr, Target{Port: 9876}, "").OpenBinary(ctx, "/v1/screenshot", "image/png", 1024)
	require.NoError(t, err)
	cancel()
	_, err = response.Body.Read(make([]byte, 1))
	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err), err)
	select {
	case <-tr.closed:
	case <-time.After(time.Second):
		t.Fatal("connection remained open after binary cancellation")
	}
	require.NoError(t, response.Body.Close())
}

func TestClientUsesExactResponseHeaderLimitAndMapsOverflow(t *testing.T) {
	client := NewClient(&scriptedDeviceTransport{t: t}, Target{Port: 9876}, "")
	transport, ok := client.http.Transport.(*http.Transport)
	require.True(t, ok)
	require.Equal(t, int64(32<<10), transport.MaxResponseHeaderBytes)

	body := successEnvelope(`{}`)
	tr := &scriptedDeviceTransport{t: t, response: fmt.Sprintf(
		"HTTP/1.1 200 OK\r\nX-Oversized: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		strings.Repeat("x", (32<<10)+1), len(body), body,
	)}
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
	require.Equal(t, contract.ArtifactTooLarge, contract.CodeOf(err), err)
}

func TestDecodeEnvelopeRejectsInvalidUTF8BeforeJSONDecode(t *testing.T) {
	body := append([]byte(`{"ok":true,"data":{"value":"`), 0xff)
	body = append(body, []byte(`"},"meta":{"protocol_version":1,"request_id":"req"}}`)...)
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", string(body))}
	var output map[string]string
	_, err := NewClient(tr, Target{Port: 9876}, "").DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, &output)
	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err), err)
}

func TestValidateHTTPResponseRejectsProhibitedHeadersEvenWhenEmptyOrRepeated(t *testing.T) {
	for _, key := range []string{"Content-Encoding", "Upgrade", "Transfer-Encoding"} {
		t.Run(key, func(t *testing.T) {
			response := &http.Response{
				ProtoMajor: 1, ProtoMinor: 1, Close: true, ContentLength: 0,
				Header: http.Header{key: []string{"", ""}},
			}
			err := validateHTTPResponse(response)
			require.Error(t, err)
			require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err), err)
		})
	}
}

func TestClientSupportsConcurrentOneShotRequests(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(`{}`))}
	client := NewClient(tr, Target{Port: 9876}, "token")
	const count = 12
	var group sync.WaitGroup
	errors := make(chan error, count)
	for range count {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := client.DoJSON(context.Background(), http.MethodGet, "/v1/state", nil, 1024, nil)
			errors <- err
		}()
	}
	group.Wait()
	close(errors)
	for err := range errors {
		require.NoError(t, err)
	}
	require.Equal(t, count, tr.DialCount())
}

type failingReadCloser struct {
	err    error
	closed bool
}

func (r *failingReadCloser) Read([]byte) (int, error) { return 0, r.err }
func (r *failingReadCloser) Close() error {
	r.closed = true
	return nil
}

type permanentNetworkError struct{}

func (permanentNetworkError) Error() string   { return "connection reset" }
func (permanentNetworkError) Timeout() bool   { return false }
func (permanentNetworkError) Temporary() bool { return false }

func TestBinaryBodyClassifiesReadFailures(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code contract.Code
	}{
		{name: "truncated framing", err: io.ErrUnexpectedEOF, code: contract.ProtocolMismatch},
		{name: "transport failure", err: permanentNetworkError{}, code: contract.TransportFailure},
		{name: "opaque protocol failure", err: errors.New("bad body"), code: contract.ProtocolMismatch},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			underlying := &failingReadCloser{err: testCase.err}
			body := newContextReadCloser(context.Background(), underlying)
			_, err := body.Read(make([]byte, 1))
			require.Equal(t, testCase.code, contract.CodeOf(err), err)
			require.NoError(t, body.Close())
			require.True(t, underlying.closed)
		})
	}
}

func TestDoHEADMapsAuthenticationBeforeMetadataValidation(t *testing.T) {
	response := "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	tr := &scriptedDeviceTransport{t: t, response: response}
	_, err := NewClient(tr, Target{Port: 9876}, "wrong").DoHEAD(context.Background(), "/v1/state")
	require.Equal(t, contract.AuthRequired, contract.CodeOf(err), err)
}
