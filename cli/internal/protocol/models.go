package protocol

import (
	"io"
	"net/http"
)

const DefaultPort uint16 = 9876

type Target struct {
	DeviceID string
	Port     uint16
}

type ResponseMeta struct {
	ProtocolVersion int    `json:"protocol_version"`
	RequestID       string `json:"request_id"`
}

// ResponseMetadata is the validated status line and headers returned by a
// bodyless HEAD request. Headers is an owned copy and may be safely mutated by
// the caller.
type ResponseMetadata struct {
	StatusCode int         `json:"status_code"`
	Headers    http.Header `json:"headers"`
}

type BinaryResponse struct {
	Body          io.ReadCloser
	ContentLength int64
	SHA256        string
	Meta          ResponseMeta
	Header        http.Header
}
