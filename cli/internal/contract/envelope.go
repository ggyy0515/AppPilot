package contract

import (
	"encoding/json"
	"errors"
	"io"
	"sync"
)

var ErrAlreadyEmitted = errors.New("JSON document already emitted")

type Meta struct {
	ProtocolVersion int    `json:"protocol_version"`
	DeviceID        string `json:"device_id,omitempty"`
	DurationMS      int64  `json:"duration_ms"`
}

type Emitter struct {
	writer  io.Writer
	mu      sync.Mutex
	emitted bool
}

func NewEmitter(writer io.Writer) *Emitter {
	return &Emitter{writer: writer}
}

func (e *Emitter) Success(data any, meta Meta) error {
	return e.emit(struct {
		OK   bool `json:"ok"`
		Data any  `json:"data"`
		Meta Meta `json:"meta"`
	}{OK: true, Data: data, Meta: meta})
}

func (e *Emitter) Failure(err error) error {
	stable := canonicalError(err)
	return e.emit(struct {
		OK    bool   `json:"ok"`
		Error *Error `json:"error"`
	}{OK: false, Error: stable})
}

func (e *Emitter) emit(value any) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.emitted {
		return ErrAlreadyEmitted
	}
	e.emitted = true
	encoder := json.NewEncoder(e.writer)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}
