package protocol

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
)

const maxRecordingBytes int64 = 500 << 20

var recordingIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

type RecordingStatus struct {
	State       string  `json:"state"`
	ElapsedMS   int64   `json:"elapsed_ms"`
	RecordingID *string `json:"recording_id"`
}

type RecordingStart struct {
	State       string  `json:"state"`
	ElapsedMS   int64   `json:"elapsed_ms"`
	RecordingID *string `json:"recording_id"`
}

type RecordingStop struct {
	RecordingID string `json:"recording_id"`
	ByteCount   int64  `json:"byte_count"`
	DurationMS  int64  `json:"duration_ms"`
	SHA256      string `json:"sha256"`
	MIME        string `json:"mime"`
}

type Recording struct {
	client *Client
}

type wireRecordingState struct {
	State              *string  `json:"state"`
	ElapsedMS          *int64   `json:"elapsed_ms"`
	RecordingID        **string `json:"recording_id"`
	recordingIDPresent bool
}

func (w *wireRecordingState) UnmarshalJSON(raw []byte) error {
	type plain wireRecordingState
	var decoded plain
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return err
	}
	_, decoded.recordingIDPresent = fields["recording_id"]
	*w = wireRecordingState(decoded)
	return nil
}

type wireRecordingStop struct {
	RecordingID *string `json:"recording_id"`
	ByteCount   *int64  `json:"byte_count"`
	DurationMS  *int64  `json:"duration_ms"`
	SHA256      *string `json:"sha256"`
	MIME        *string `json:"mime"`
}

func (w *wireRecordingStop) UnmarshalJSON(raw []byte) error {
	type plain wireRecordingStop
	var decoded plain
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	*w = wireRecordingStop(decoded)
	return nil
}

type wireRecordingDelete struct {
	RecordingID *string `json:"recording_id"`
	Deleted     *bool   `json:"deleted"`
}

func (w *wireRecordingDelete) UnmarshalJSON(raw []byte) error {
	type plain wireRecordingDelete
	var decoded plain
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	*w = wireRecordingDelete(decoded)
	return nil
}

func NewRecording(client *Client) Recording {
	return Recording{client: client}
}

func (r Recording) Status(ctx context.Context) (RecordingStatus, error) {
	state, err := r.state(ctx, http.MethodGet, "/v1/recording/status")
	return RecordingStatus(state), err
}

func (r Recording) Start(ctx context.Context) (RecordingStart, error) {
	state, err := r.state(ctx, http.MethodPost, "/v1/recording/start")
	return RecordingStart(state), err
}

func (r Recording) state(ctx context.Context, method, path string) (RecordingStatus, error) {
	var wire wireRecordingState
	var input any
	if method == http.MethodPost {
		input = struct{}{}
	}
	if _, err := r.client.DoJSON(ctx, method, path, input, 1<<20, &wire); err != nil {
		return RecordingStatus{}, err
	}
	if wire.State == nil || wire.ElapsedMS == nil || !wire.recordingIDPresent ||
		!validRecordingState(*wire.State) || *wire.ElapsedMS < 0 {
		return RecordingStatus{}, protocolError(errors.New("invalid recording state metadata"))
	}
	var recordingID *string
	if wire.RecordingID != nil {
		recordingID = *wire.RecordingID
	}
	if recordingID != nil && !recordingIDPattern.MatchString(*recordingID) {
		return RecordingStatus{}, protocolError(errors.New("invalid recording id"))
	}
	return RecordingStatus{State: *wire.State, ElapsedMS: *wire.ElapsedMS, RecordingID: recordingID}, nil
}

func (r Recording) Stop(ctx context.Context) (RecordingStop, error) {
	var wire wireRecordingStop
	_, err := r.client.DoJSON(ctx, http.MethodPost, "/v1/recording/stop", struct{}{}, 1<<20, &wire)
	if err != nil {
		return RecordingStop{}, err
	}
	if wire.RecordingID == nil || wire.ByteCount == nil || wire.DurationMS == nil || wire.SHA256 == nil || wire.MIME == nil ||
		!recordingIDPattern.MatchString(*wire.RecordingID) || *wire.MIME != "video/mp4" ||
		*wire.ByteCount < 0 || *wire.DurationMS < 0 || !lowercaseSHA256.MatchString(*wire.SHA256) {
		return RecordingStop{}, protocolError(errors.New("invalid recording stop metadata"))
	}
	return RecordingStop{
		RecordingID: *wire.RecordingID, ByteCount: *wire.ByteCount, DurationMS: *wire.DurationMS,
		SHA256: *wire.SHA256, MIME: *wire.MIME,
	}, nil
}

func (r Recording) Open(ctx context.Context, id string) (*BinaryResponse, error) {
	if !recordingIDPattern.MatchString(id) {
		return nil, protocolError(errors.New("invalid recording id"))
	}
	return r.client.OpenBinary(ctx, "/v1/recordings/"+id, "video/mp4", maxRecordingBytes)
}

func (r Recording) Delete(ctx context.Context, id string) error {
	if !recordingIDPattern.MatchString(id) {
		return protocolError(errors.New("invalid recording id"))
	}
	var wire wireRecordingDelete
	_, err := r.client.DoJSON(ctx, http.MethodDelete, "/v1/recordings/"+id, nil, 1<<20, &wire)
	if err != nil {
		return err
	}
	if wire.RecordingID == nil || wire.Deleted == nil || *wire.RecordingID != id || !*wire.Deleted {
		return protocolError(errors.New("invalid recording delete response"))
	}
	return nil
}

func validRecordingState(state string) bool {
	switch state {
	case "idle", "starting", "recording", "stopping", "ready", "failed":
		return true
	default:
		return false
	}
}
