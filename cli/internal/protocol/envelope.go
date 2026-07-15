package protocol

import (
	"encoding/json"

	"github.com/yangy003/ap-ios-debug-system/internal/contract"
)

type wireEnvelope struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error *wireError      `json:"error,omitempty"`
	Meta  ResponseMeta    `json:"meta"`
}

type wireError struct {
	Code    contract.Code `json:"code"`
	Message string        `json:"message"`
	Hint    string        `json:"hint"`
}

func recognizedAppCode(code contract.Code) bool {
	switch code {
	case contract.ConfigInvalid,
		contract.AppNotReachable,
		contract.RequestTimeout,
		contract.ProtocolMismatch,
		contract.AuthRequired,
		contract.AuthFailed,
		contract.ActionNotFound,
		contract.ActionDisabled,
		contract.ActionFailed,
		contract.StateEncodingFailed,
		contract.ScreenshotFailed,
		contract.RecordingNotAvailable,
		contract.RecordingInvalidState,
		contract.RecordingPermissionTimeout,
		contract.ArtifactTooLarge:
		return true
	default:
		return false
	}
}
