package protocol

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

func TestRecordingStatusAndStartUseExactRoutes(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		call   func(Recording) (RecordingStatus, error)
	}{
		{name: "status", method: http.MethodGet, path: "/v1/recording/status", call: func(r Recording) (RecordingStatus, error) {
			return r.Status(context.Background())
		}},
		{name: "start", method: http.MethodPost, path: "/v1/recording/start", call: func(r Recording) (RecordingStatus, error) {
			started, err := r.Start(context.Background())
			return RecordingStatus(started), err
		}},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			body := successEnvelope(`{"state":"recording","elapsed_ms":12,"recording_id":"rec_1"}`)
			tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", body)}
			got, err := testCase.call(NewRecording(NewClient(tr, Target{Port: 9876}, "")))
			require.NoError(t, err)
			require.Equal(t, "recording", got.State)
			require.Equal(t, int64(12), got.ElapsedMS)
			require.NotNil(t, got.RecordingID)
			require.Equal(t, "rec_1", *got.RecordingID)
			require.Contains(t, tr.Request(), testCase.method+" "+testCase.path+" HTTP/1.1")
		})
	}
}

func TestRecordingStopValidatesMetadata(t *testing.T) {
	validSHA := strings.Repeat("a", 64)
	tests := map[string]string{
		"invalid id character": `{"recording_id":"rec.1","byte_count":24,"duration_ms":900,"sha256":"` + validSHA + `","mime":"video/mp4"}`,
		"id too long":          `{"recording_id":"` + strings.Repeat("a", 129) + `","byte_count":24,"duration_ms":900,"sha256":"` + validSHA + `","mime":"video/mp4"}`,
		"negative bytes":       `{"recording_id":"rec-1","byte_count":-1,"duration_ms":900,"sha256":"` + validSHA + `","mime":"video/mp4"}`,
		"negative duration":    `{"recording_id":"rec-1","byte_count":24,"duration_ms":-1,"sha256":"` + validSHA + `","mime":"video/mp4"}`,
		"uppercase checksum":   `{"recording_id":"rec-1","byte_count":24,"duration_ms":900,"sha256":"` + strings.Repeat("A", 64) + `","mime":"video/mp4"}`,
		"wrong MIME":           `{"recording_id":"rec-1","byte_count":24,"duration_ms":900,"sha256":"` + validSHA + `","mime":"application/octet-stream"}`,
	}
	for name, data := range tests {
		t.Run(name, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}
			_, err := NewRecording(NewClient(tr, Target{Port: 9876}, "")).Stop(context.Background())
			require.Error(t, err)
			require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
		})
	}
}

func TestRecordingStopAcceptsMaximumLengthID(t *testing.T) {
	id := strings.Repeat("a", 128)
	data := fmt.Sprintf(`{"recording_id":%q,"byte_count":24,"duration_ms":900,"sha256":%q,"mime":"video/mp4"}`, id, strings.Repeat("a", 64))
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}
	got, err := NewRecording(NewClient(tr, Target{Port: 9876}, "")).Stop(context.Background())
	require.NoError(t, err)
	require.Equal(t, id, got.RecordingID)
}

func TestRecordingOpenAndDeleteValidateIDAndRoutes(t *testing.T) {
	sha := strings.Repeat("b", 64)
	binary := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 3\r\nConnection: close\r\nX-IOS-Debug-Protocol-Version: 1\r\nX-IOS-Debug-Request-ID: open-1\r\nX-IOS-Debug-SHA256: %s\r\n\r\nmp4", sha)
	openTransport := &scriptedDeviceTransport{t: t, response: binary}
	service := NewRecording(NewClient(openTransport, Target{Port: 9876}, ""))
	opened, err := service.Open(context.Background(), "rec_1")
	require.NoError(t, err)
	_, err = io.Copy(io.Discard, opened.Body)
	require.NoError(t, err)
	require.NoError(t, opened.Body.Close())
	require.Contains(t, openTransport.Request(), "GET /v1/recordings/rec_1 HTTP/1.1")

	deleteTransport := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(`{"recording_id":"rec_1","deleted":true}`))}
	err = NewRecording(NewClient(deleteTransport, Target{Port: 9876}, "")).Delete(context.Background(), "rec_1")
	require.NoError(t, err)
	require.Contains(t, deleteTransport.Request(), "DELETE /v1/recordings/rec_1 HTTP/1.1")

	for _, invalid := range []string{"", "rec.1", strings.Repeat("x", 129)} {
		tr := &scriptedDeviceTransport{t: t}
		invalidService := NewRecording(NewClient(tr, Target{Port: 9876}, ""))
		_, openErr := invalidService.Open(context.Background(), invalid)
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(openErr))
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(invalidService.Delete(context.Background(), invalid)))
		require.Zero(t, tr.DialCount())
	}
}

func TestRecordingDeleteRequiresDeletedTrueAndMatchingID(t *testing.T) {
	for _, data := range []string{
		`{"recording_id":"rec-1","deleted":false}`,
		`{"recording_id":"other","deleted":true}`,
		`{"deleted":true}`,
	} {
		tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}
		err := NewRecording(NewClient(tr, Target{Port: 9876}, "")).Delete(context.Background(), "rec-1")
		require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
	}
}
