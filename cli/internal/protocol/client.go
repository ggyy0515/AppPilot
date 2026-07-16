package protocol

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/ggyy0515/AppPilot/internal/transport"
)

const (
	protocolVersion = 1
	maxRequestBytes = 1 << 20
	maxHeaderBytes  = 32 << 10
	baseURL         = "http://ap-ios-debug.local"
)

var lowercaseSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Client struct {
	http   *http.Client
	target Target
	token  string
}

func NewClient(tr transport.DeviceTransport, target Target, token string) *Client {
	roundTripper := &http.Transport{
		DisableKeepAlives:      true,
		DisableCompression:     true,
		MaxResponseHeaderBytes: maxHeaderBytes,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return tr.Dial(ctx, target.DeviceID, target.Port)
		},
	}
	return &Client{
		http:   &http.Client{Transport: roundTripper},
		target: target,
		token:  token,
	}
}

func (c *Client) DoJSON(ctx context.Context, method, rawPath string, input any, maxBytes int64, output any) (ResponseMeta, error) {
	var zero ResponseMeta
	if maxBytes < 0 {
		return zero, contract.New(contract.ConfigInvalid, nil)
	}
	body, err := encodeInput(input)
	if err != nil {
		return zero, err
	}
	request, err := c.newRequest(ctx, method, rawPath, body, "application/json")
	if err != nil {
		return zero, err
	}
	response, err := c.do(request)
	if err != nil {
		return zero, err
	}
	defer response.Body.Close()

	if authErr := authenticationError(response.StatusCode); authErr != nil {
		return zero, authErr
	}
	if err := validateHTTPResponse(response); err != nil {
		return zero, err
	}
	if err := requireMIME(response.Header, "application/json"); err != nil {
		return zero, err
	}
	if response.ContentLength > maxBytes {
		return zero, contract.New(contract.ArtifactTooLarge, nil)
	}

	envelope, err := decodeEnvelope(ctx, response.Body, maxBytes)
	if err != nil {
		return zero, err
	}
	if err := validateMeta(envelope.Meta); err != nil {
		return zero, err
	}
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		if !envelope.OK || envelope.Error != nil || len(envelope.Data) == 0 {
			return zero, protocolError(nil)
		}
		if output != nil {
			if len(envelope.Data) == 0 {
				return zero, protocolError(nil)
			}
			if err := decodeOne(envelope.Data, output); err != nil {
				return zero, protocolError(err)
			}
		}
		return envelope.Meta, nil
	}

	if err := validateFailureEnvelope(envelope); err != nil {
		return zero, protocolError(nil)
	}
	return zero, contract.New(envelope.Error.Code, nil)
}

// DoHEAD performs one authenticated HTTP/1.1 HEAD request and returns only
// validated response metadata. It intentionally does not consume a body.
func (c *Client) DoHEAD(ctx context.Context, rawPath string) (ResponseMetadata, error) {
	var zero ResponseMetadata
	request, err := c.newRequest(ctx, http.MethodHead, rawPath, nil, "application/json")
	if err != nil {
		return zero, err
	}
	response, err := c.do(request)
	if err != nil {
		return zero, err
	}
	defer response.Body.Close()

	if authErr := authenticationError(response.StatusCode); authErr != nil {
		return zero, authErr
	}
	if err := validateHTTPResponse(response); err != nil {
		return zero, err
	}
	if _, err := protocolHeaderMetadata(response.Header); err != nil {
		return zero, err
	}
	return ResponseMetadata{StatusCode: response.StatusCode, Headers: response.Header.Clone()}, nil
}

func (c *Client) OpenBinary(ctx context.Context, rawPath, expectedMIME string, maxBytes int64) (*BinaryResponse, error) {
	if maxBytes < 0 {
		return nil, contract.New(contract.ConfigInvalid, nil)
	}
	request, err := c.newRequest(ctx, http.MethodGet, rawPath, nil, expectedMIME)
	if err != nil {
		return nil, err
	}
	response, err := c.do(request)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (*BinaryResponse, error) {
		_ = response.Body.Close()
		return nil, err
	}

	if authErr := authenticationError(response.StatusCode); authErr != nil {
		return fail(authErr)
	}
	if err := validateHTTPResponse(response); err != nil {
		return fail(err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if err := requireMIME(response.Header, "application/json"); err != nil {
			return fail(err)
		}
		if response.ContentLength > maxBytes {
			return fail(contract.New(contract.ArtifactTooLarge, nil))
		}
		envelope, err := decodeEnvelope(ctx, response.Body, maxBytes)
		if err != nil {
			return fail(err)
		}
		if err := validateMeta(envelope.Meta); err != nil {
			return fail(err)
		}
		if err := validateFailureEnvelope(envelope); err != nil {
			return fail(protocolError(nil))
		}
		return fail(contract.New(envelope.Error.Code, nil))
	}
	if err := requireMIME(response.Header, expectedMIME); err != nil {
		return fail(err)
	}
	if response.ContentLength > maxBytes {
		return fail(contract.New(contract.ArtifactTooLarge, nil))
	}

	meta, sha, err := binaryMetadata(response.Header)
	if err != nil {
		return fail(err)
	}
	return &BinaryResponse{
		Body:          newContextReadCloser(ctx, response.Body),
		ContentLength: response.ContentLength,
		SHA256:        sha,
		Meta:          meta,
		Header:        response.Header.Clone(),
	}, nil
}

func encodeInput(input any) ([]byte, error) {
	if input == nil {
		return nil, nil
	}
	body, err := json.Marshal(input)
	if err != nil {
		return nil, contract.New(contract.ConfigInvalid, err)
	}
	if len(body) > maxRequestBytes {
		return nil, contract.New(contract.ArtifactTooLarge, nil)
	}
	return body, nil
}

func (c *Client) newRequest(ctx context.Context, method, rawPath string, body []byte, accept string) (*http.Request, error) {
	if err := ValidateRawPath(rawPath); err != nil {
		return nil, err
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, baseURL+rawPath, reader)
	if err != nil {
		return nil, contract.New(contract.ConfigInvalid, err)
	}
	request.Header.Set("Accept", accept)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	request.Header.Set("Connection", "close")
	request.Close = true
	return request, nil
}

func (c *Client) do(request *http.Request) (*http.Response, error) {
	response, err := c.http.Do(request)
	if err == nil {
		return response, nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return nil, contract.New(contract.RequestTimeout, err)
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return nil, contract.New(contract.RequestTimeout, err)
	}
	if strings.Contains(err.Error(), "response headers exceeded") {
		return nil, contract.New(contract.ArtifactTooLarge, err)
	}
	code := contract.CodeOf(err)
	if code != contract.ProtocolMismatch {
		return nil, contract.New(code, err)
	}
	return nil, contract.New(contract.AppNotReachable, err)
}

func validateHTTPResponse(response *http.Response) error {
	valid := response.ProtoMajor == 1 && response.ProtoMinor == 1 && response.Close &&
		len(response.TransferEncoding) == 0 && response.ContentLength >= 0 &&
		!hasHeader(response.Header, "Transfer-Encoding") &&
		!hasHeader(response.Header, "Content-Encoding") && !hasHeader(response.Header, "Upgrade")
	if !valid {
		return protocolError(nil)
	}
	return nil
}

func authenticationError(status int) error {
	switch status {
	case http.StatusUnauthorized:
		return contract.New(contract.AuthRequired, nil)
	case http.StatusForbidden:
		return contract.New(contract.AuthFailed, nil)
	default:
		return nil
	}
}

func requireMIME(header http.Header, expected string) error {
	value, ok := singleHeader(header, "Content-Type")
	if !ok {
		return protocolError(nil)
	}
	actualType, _, err := mime.ParseMediaType(value)
	if err != nil {
		return protocolError(err)
	}
	expectedType, _, err := mime.ParseMediaType(expected)
	if err != nil || actualType != expectedType {
		return protocolError(err)
	}
	return nil
}

func decodeEnvelope(ctx context.Context, reader io.Reader, maxBytes int64) (wireEnvelope, error) {
	var envelope wireEnvelope
	limited := io.LimitReader(reader, maxBytes+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return envelope, classifyReadError(ctx, err)
	}
	if int64(len(body)) > maxBytes {
		return envelope, contract.New(contract.ArtifactTooLarge, nil)
	}
	if !utf8.Valid(body) {
		return envelope, protocolError(nil)
	}
	if err := decodeOne(body, &envelope); err != nil {
		return envelope, protocolError(err)
	}
	return envelope, nil
}

func decodeOne(body []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(output); err != nil {
		return err
	}
	var extra any
	err := decoder.Decode(&extra)
	if !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return err
	}
	return nil
}

func validateMeta(meta ResponseMeta) error {
	if meta.ProtocolVersion != protocolVersion || strings.TrimSpace(meta.RequestID) == "" {
		return protocolError(nil)
	}
	return nil
}

func validateFailureEnvelope(envelope wireEnvelope) error {
	valid := !envelope.OK && len(envelope.Data) == 0 && envelope.Error != nil &&
		recognizedAppCode(envelope.Error.Code) && strings.TrimSpace(envelope.Error.Message) != "" &&
		strings.TrimSpace(envelope.Error.Hint) != ""
	if !valid {
		return protocolError(nil)
	}
	return nil
}

func binaryMetadata(header http.Header) (ResponseMeta, string, error) {
	meta, err := protocolHeaderMetadata(header)
	if err != nil {
		return ResponseMeta{}, "", err
	}
	sha, shaOK := singleHeader(header, "X-IOS-Debug-SHA256")
	if !shaOK {
		return ResponseMeta{}, "", protocolError(nil)
	}
	if !lowercaseSHA256.MatchString(sha) {
		return ResponseMeta{}, "", protocolError(nil)
	}
	return meta, sha, nil
}

func protocolHeaderMetadata(header http.Header) (ResponseMeta, error) {
	version, versionOK := singleHeader(header, "X-IOS-Debug-Protocol-Version")
	requestID, requestIDOK := singleHeader(header, "X-IOS-Debug-Request-ID")
	meta := ResponseMeta{ProtocolVersion: protocolVersion, RequestID: requestID}
	if !versionOK || !requestIDOK || version != "1" || strings.TrimSpace(requestID) == "" {
		return ResponseMeta{}, protocolError(nil)
	}
	return meta, nil
}

func singleHeader(header http.Header, key string) (string, bool) {
	values := header.Values(key)
	returnValue := ""
	if len(values) == 1 {
		returnValue = values[0]
	}
	return returnValue, len(values) == 1
}

func hasHeader(header http.Header, key string) bool {
	for existing := range header {
		if strings.EqualFold(existing, key) {
			return true
		}
	}
	return false
}

func classifyReadError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return contract.New(contract.RequestTimeout, ctxErr)
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return contract.New(contract.RequestTimeout, err)
	}
	var networkError net.Error
	if errors.As(err, &networkError) {
		if networkError.Timeout() {
			return contract.New(contract.RequestTimeout, err)
		}
		return contract.New(contract.TransportFailure, err)
	}
	return protocolError(err)
}

type contextReadCloser struct {
	ctx  context.Context
	body io.ReadCloser
	done chan struct{}
	once sync.Once
}

func newContextReadCloser(ctx context.Context, body io.ReadCloser) *contextReadCloser {
	result := &contextReadCloser{ctx: ctx, body: body, done: make(chan struct{})}
	go func() {
		select {
		case <-ctx.Done():
			_ = result.Close()
		case <-result.done:
		}
	}()
	return result
}

func (r *contextReadCloser) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		_ = r.Close()
		return 0, contract.New(contract.RequestTimeout, err)
	}
	count, err := r.body.Read(buffer)
	if err == nil {
		return count, nil
	}
	if errors.Is(err, io.EOF) {
		_ = r.Close()
		return count, err
	}
	return count, classifyReadError(r.ctx, err)
}

func (r *contextReadCloser) Close() error {
	var closeErr error
	r.once.Do(func() {
		close(r.done)
		closeErr = r.body.Close()
	})
	return closeErr
}

func protocolError(cause error) error {
	return contract.New(contract.ProtocolMismatch, cause)
}
