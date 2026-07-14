package fakeapp_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/testutil/fakeapp"
)

func do(t *testing.T, client *http.Client, method, url string) (*http.Response, map[string]any) {
	t.Helper()
	request, err := http.NewRequest(method, url, nil)
	require.NoError(t, err)
	response, err := client.Do(request)
	require.NoError(t, err)
	t.Cleanup(func() { _ = response.Body.Close() })
	var envelope map[string]any
	require.NoError(t, json.NewDecoder(response.Body).Decode(&envelope))
	require.NoError(t, response.Body.Close())
	return response, envelope
}

func recordingState(t *testing.T, app *fakeapp.FakeApp) string {
	t.Helper()
	_, envelope := do(t, http.DefaultClient, http.MethodGet, app.URL+"/v1/recording/status")
	return envelope["data"].(map[string]any)["state"].(string)
}

func TestStartServesBoundedProtocolAndRecordsRequests(t *testing.T) {
	app := fakeapp.Start(t)
	response, err := http.Get(app.URL + "/v1/health")
	require.NoError(t, err)
	defer response.Body.Close()
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.True(t, response.Close)
	var envelope map[string]any
	require.NoError(t, json.NewDecoder(response.Body).Decode(&envelope))
	require.Equal(t, true, envelope["ok"])
	require.Equal(t, float64(1), envelope["meta"].(map[string]any)["protocol_version"])
	require.NotEmpty(t, envelope["meta"].(map[string]any)["request_id"])
	require.Equal(t, []fakeapp.RecordedRequest{{Method: "GET", Path: "/v1/health"}}, app.Requests())
}

func TestStartRejectsOversizedRequestBody(t *testing.T) {
	app := fakeapp.Start(t)
	request, err := http.NewRequest(http.MethodPost, app.URL+"/v1/actions/activate", strings.NewReader(strings.Repeat("x", (1<<20)+1)))
	require.NoError(t, err)
	response, err := http.DefaultClient.Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	require.Equal(t, http.StatusRequestEntityTooLarge, response.StatusCode)
}

func TestStartRejectsMoreThan32KiBOfHeaders(t *testing.T) {
	app := fakeapp.Start(t)
	request, err := http.NewRequest(http.MethodGet, app.URL+"/v1/health", nil)
	require.NoError(t, err)
	request.Header.Set("X-Oversized", strings.Repeat("x", 33<<10))
	response, err := http.DefaultClient.Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	require.Equal(t, http.StatusRequestHeaderFieldsTooLarge, response.StatusCode)
}

func TestRecordingStateMachineRejectsInvalidTransitionsWithoutMutation(t *testing.T) {
	app := fakeapp.Start(t)
	require.Equal(t, "idle", recordingState(t, app))

	response, _ := do(t, http.DefaultClient, http.MethodPost, app.URL+"/v1/recording/stop")
	require.Equal(t, http.StatusConflict, response.StatusCode)
	require.Equal(t, "idle", recordingState(t, app))
	download, _ := do(t, http.DefaultClient, http.MethodGet, app.URL+"/v1/recordings/recording-1")
	require.Equal(t, http.StatusNotFound, download.StatusCode)

	response, _ = do(t, http.DefaultClient, http.MethodPost, app.URL+"/v1/recording/start")
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.Equal(t, "recording", recordingState(t, app))
	repeated, _ := do(t, http.DefaultClient, http.MethodPost, app.URL+"/v1/recording/start")
	require.Equal(t, http.StatusConflict, repeated.StatusCode)
	require.Equal(t, "recording", recordingState(t, app))
	download, _ = do(t, http.DefaultClient, http.MethodGet, app.URL+"/v1/recordings/recording-1")
	require.Equal(t, http.StatusNotFound, download.StatusCode)

	response, stopped := do(t, http.DefaultClient, http.MethodPost, app.URL+"/v1/recording/stop")
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.Equal(t, "recording-1", stopped["data"].(map[string]any)["recording_id"])
	require.Equal(t, "ready", recordingState(t, app))
	repeated, _ = do(t, http.DefaultClient, http.MethodPost, app.URL+"/v1/recording/stop")
	require.Equal(t, http.StatusConflict, repeated.StatusCode)
	require.Equal(t, "ready", recordingState(t, app))

	request, err := http.NewRequest(http.MethodGet, app.URL+"/v1/recordings/recording-1", nil)
	require.NoError(t, err)
	file, err := http.DefaultClient.Do(request)
	require.NoError(t, err)
	contents, err := io.ReadAll(file.Body)
	require.NoError(t, err)
	require.NoError(t, file.Body.Close())
	require.Equal(t, http.StatusOK, file.StatusCode)
	require.True(t, bytes.Equal(app.RecordingBytes(), contents))

	response, _ = do(t, http.DefaultClient, http.MethodDelete, app.URL+"/v1/recordings/recording-1")
	require.Equal(t, http.StatusOK, response.StatusCode)
	require.Equal(t, "idle", recordingState(t, app))
	download, _ = do(t, http.DefaultClient, http.MethodGet, app.URL+"/v1/recordings/recording-1")
	require.Equal(t, http.StatusNotFound, download.StatusCode)
}

func TestConcurrentRecordingStartsHaveExactlyOneWinner(t *testing.T) {
	app := fakeapp.Start(t)
	statuses := make(chan int, 8)
	var group sync.WaitGroup
	for range 8 {
		group.Add(1)
		go func() {
			defer group.Done()
			request, err := http.NewRequest(http.MethodPost, app.URL+"/v1/recording/start", nil)
			if err != nil {
				statuses <- 0
				return
			}
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				statuses <- 0
				return
			}
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			statuses <- response.StatusCode
		}()
	}
	group.Wait()
	close(statuses)
	winners := 0
	conflicts := 0
	for status := range statuses {
		switch status {
		case http.StatusOK:
			winners++
		case http.StatusConflict:
			conflicts++
		default:
			t.Fatalf("unexpected status %d", status)
		}
	}
	require.Equal(t, 1, winners)
	require.Equal(t, 7, conflicts)
	require.Equal(t, "recording", recordingState(t, app))
}
