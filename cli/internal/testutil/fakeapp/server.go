package fakeapp

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const maxBodyBytes = 1 << 20

type RecordedRequest struct {
	Method string
	Path   string
	Body   []byte
}

type FakeApp struct {
	URL  string
	Host string
	Port uint16

	listener       net.Listener
	server         *http.Server
	close          sync.Once
	mu             sync.Mutex
	requests       []RecordedRequest
	counter        int
	recordingState string
	recordingID    string
	requestID      atomic.Uint64
	dials          atomic.Int64
	closes         atomic.Int64
	blockNext      atomic.Bool
	png            []byte
	mp4            []byte
}

func Start(t testing.TB) *FakeApp {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for fake App: %v", err)
	}
	address := listener.Addr().(*net.TCPAddr)
	fake := &FakeApp{
		URL: "http://" + listener.Addr().String(), Host: "127.0.0.1", Port: uint16(address.Port),
		listener: listener, recordingState: "idle", recordingID: "recording-1",
		png: validPNG(), mp4: validMP4(),
	}
	fake.server = &http.Server{
		MaxHeaderBytes:    32 << 10,
		ReadHeaderTimeout: time.Second,
		Handler:           http.HandlerFunc(fake.serveHTTP),
		ConnState: func(_ net.Conn, state http.ConnState) {
			switch state {
			case http.StateNew:
				fake.dials.Add(1)
			case http.StateClosed:
				fake.closes.Add(1)
			}
		},
	}
	go func() { _ = fake.server.Serve(listener) }()
	t.Cleanup(fake.Close)
	return fake
}

func (f *FakeApp) Close() {
	f.close.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = f.server.Shutdown(ctx)
		_ = f.listener.Close()
	})
}

func (f *FakeApp) Requests() []RecordedRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]RecordedRequest, len(f.requests))
	for i, request := range f.requests {
		result[i] = request
		result[i].Body = append([]byte(nil), request.Body...)
	}
	return result
}

func (f *FakeApp) DialCount() int64        { return f.dials.Load() }
func (f *FakeApp) CloseCount() int64       { return f.closes.Load() }
func (f *FakeApp) BlockNextRequest()       { f.blockNext.Store(true) }
func (f *FakeApp) ScreenshotBytes() []byte { return append([]byte(nil), f.png...) }
func (f *FakeApp) RecordingBytes() []byte  { return append([]byte(nil), f.mp4...) }

func (f *FakeApp) serveHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Connection", "close")
	r.Close = true
	if requestHeaderBytes(r) > 32<<10 {
		f.writeFailure(w, http.StatusRequestHeaderFieldsTooLarge, "artifact_too_large")
		return
	}
	if r.ContentLength > maxBodyBytes {
		f.writeFailure(w, http.StatusRequestEntityTooLarge, "artifact_too_large")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		f.writeFailure(w, http.StatusRequestEntityTooLarge, "artifact_too_large")
		return
	}
	f.mu.Lock()
	f.requests = append(f.requests, RecordedRequest{Method: r.Method, Path: r.URL.EscapedPath(), Body: append([]byte(nil), body...)})
	f.mu.Unlock()
	if f.blockNext.Swap(false) {
		<-r.Context().Done()
		return
	}

	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/v1/health":
		f.writeJSON(w, http.StatusOK, map[string]any{"protocol_version": 1, "auth_required": false, "reachable": true})
	case (r.Method == http.MethodGet || r.Method == http.MethodHead) && r.URL.Path == "/v1/capabilities":
		f.writeJSON(w, http.StatusOK, map[string]any{"actions": true, "state": true, "screenshot": true, "recording": true})
	case r.Method == http.MethodGet && r.URL.Path == "/v1/actions":
		f.writeJSON(w, http.StatusOK, map[string]any{"generation": 1, "actions": []any{map[string]any{"identifier": "counter.increment", "role": "mutation", "description": "Increment the fake counter", "enabled": true, "generation": 1}}})
	case r.Method == http.MethodPost && r.URL.Path == "/v1/actions/activate":
		var input struct {
			Identifier string `json:"identifier"`
		}
		if json.Unmarshal(body, &input) != nil || input.Identifier != "counter.increment" {
			f.writeFailure(w, http.StatusNotFound, "action_not_found")
			return
		}
		f.mu.Lock()
		f.counter++
		f.mu.Unlock()
		f.writeJSON(w, http.StatusOK, map[string]any{"identifier": input.Identifier, "generation": 1, "activated": true})
	case r.Method == http.MethodGet && r.URL.Path == "/v1/state":
		f.mu.Lock()
		counter := f.counter
		f.mu.Unlock()
		f.writeJSON(w, http.StatusOK, map[string]any{"counter": counter})
	case r.Method == http.MethodGet && r.URL.Path == "/v1/screenshot":
		w.Header().Set("X-IOS-Debug-Capture-Method", "window")
		w.Header().Set("X-IOS-Debug-Pixel-Width", "1")
		w.Header().Set("X-IOS-Debug-Pixel-Height", "1")
		w.Header().Set("X-IOS-Debug-Scale", "1")
		f.writeBinary(w, "image/png", f.png)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/recording/status":
		f.mu.Lock()
		state := f.recordingState
		id := f.recordingID
		f.mu.Unlock()
		data := map[string]any{"state": state, "elapsed_ms": 0, "recording_id": nil}
		if state != "idle" {
			data["recording_id"] = id
		}
		f.writeJSON(w, http.StatusOK, data)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/recording/start":
		f.mu.Lock()
		valid := f.recordingState == "idle"
		if valid {
			f.recordingState = "recording"
		}
		id := f.recordingID
		f.mu.Unlock()
		if !valid {
			f.writeFailure(w, http.StatusConflict, "recording_invalid_state")
			return
		}
		f.writeJSON(w, http.StatusOK, map[string]any{"state": "recording", "elapsed_ms": 0, "recording_id": id})
	case r.Method == http.MethodPost && r.URL.Path == "/v1/recording/stop":
		f.mu.Lock()
		valid := f.recordingState == "recording"
		if valid {
			f.recordingState = "ready"
		}
		id := f.recordingID
		f.mu.Unlock()
		if !valid {
			f.writeFailure(w, http.StatusConflict, "recording_invalid_state")
			return
		}
		digest := sha256.Sum256(f.mp4)
		f.writeJSON(w, http.StatusOK, map[string]any{"recording_id": id, "byte_count": len(f.mp4), "duration_ms": 1, "sha256": hex.EncodeToString(digest[:]), "mime": "video/mp4"})
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/recordings/"):
		id := strings.TrimPrefix(r.URL.Path, "/v1/recordings/")
		f.mu.Lock()
		ready := f.recordingState == "ready" && id == f.recordingID
		f.mu.Unlock()
		if !ready {
			f.writeFailure(w, http.StatusNotFound, "recording_not_available")
			return
		}
		f.writeBinary(w, "video/mp4", f.mp4)
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/recordings/"):
		id := strings.TrimPrefix(r.URL.Path, "/v1/recordings/")
		f.mu.Lock()
		deleted := f.recordingState == "ready" && id == f.recordingID
		if deleted {
			f.recordingState = "idle"
		}
		f.mu.Unlock()
		if !deleted {
			f.writeFailure(w, http.StatusNotFound, "recording_not_available")
			return
		}
		f.writeJSON(w, http.StatusOK, map[string]any{"recording_id": id, "deleted": true})
	default:
		f.writeFailure(w, http.StatusNotFound, "config_invalid")
	}
}

func requestHeaderBytes(r *http.Request) int {
	size := len("Host: ") + len(r.Host) + 2 + 2
	for name, values := range r.Header {
		for _, value := range values {
			size += len(name) + 2 + len(value) + 2
		}
	}
	return size
}

func (f *FakeApp) writeJSON(w http.ResponseWriter, status int, data any) {
	meta := f.meta()
	w.Header().Set("X-IOS-Debug-Protocol-Version", "1")
	w.Header().Set("X-IOS-Debug-Request-ID", meta["request_id"].(string))
	body, _ := json.Marshal(map[string]any{"ok": true, "data": data, "meta": meta})
	f.write(w, status, "application/json", body)
}

func (f *FakeApp) writeFailure(w http.ResponseWriter, status int, code string) {
	meta := f.meta()
	w.Header().Set("X-IOS-Debug-Protocol-Version", "1")
	w.Header().Set("X-IOS-Debug-Request-ID", meta["request_id"].(string))
	body, _ := json.Marshal(map[string]any{"ok": false, "error": map[string]any{"code": code, "message": "Fake App request failed.", "hint": "Check the request and retry."}, "meta": meta})
	f.write(w, status, "application/json", body)
}

func (f *FakeApp) writeBinary(w http.ResponseWriter, contentType string, body []byte) {
	digest := sha256.Sum256(body)
	meta := f.meta()
	w.Header().Set("X-IOS-Debug-Protocol-Version", "1")
	w.Header().Set("X-IOS-Debug-Request-ID", meta["request_id"].(string))
	w.Header().Set("X-IOS-Debug-SHA256", hex.EncodeToString(digest[:]))
	f.write(w, http.StatusOK, contentType, body)
}

func (f *FakeApp) meta() map[string]any {
	return map[string]any{"protocol_version": 1, "request_id": "fake-" + strconv.FormatUint(f.requestID.Add(1), 10)}
}

func (f *FakeApp) write(w http.ResponseWriter, status int, contentType string, body []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func validPNG() []byte {
	var output strings.Builder
	writer := &stringWriter{builder: &output}
	imageData := image.NewRGBA(image.Rect(0, 0, 1, 1))
	imageData.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
	_ = png.Encode(writer, imageData)
	return []byte(output.String())
}

type stringWriter struct{ builder *strings.Builder }

func (w *stringWriter) Write(p []byte) (int, error) { return w.builder.WriteString(string(p)) }

func validMP4() []byte {
	body := make([]byte, 28)
	binary.BigEndian.PutUint32(body[0:4], 20)
	copy(body[4:8], "ftyp")
	copy(body[8:12], "isom")
	copy(body[16:20], "isom")
	binary.BigEndian.PutUint32(body[20:24], 8)
	copy(body[24:28], "moov")
	return body
}
