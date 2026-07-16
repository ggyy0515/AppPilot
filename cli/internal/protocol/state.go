package protocol

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/ggyy0515/AppPilot/internal/contract"
)

const (
	maxStateBytes = 4 << 20
	// The state limit applies to the raw data value. The complete protocol
	// envelope gets a fixed, bounded 64 KiB allowance for metadata and framing.
	maxStateEnvelopeBytes = maxStateBytes + (64 << 10)
)

type State struct {
	client *Client
}

func NewState(client *Client) State {
	return State{client: client}
}

func (s State) Get(ctx context.Context) (json.RawMessage, error) {
	var out json.RawMessage
	_, err := s.client.DoJSON(ctx, http.MethodGet, "/v1/state", nil, maxStateEnvelopeBytes, &out)
	if err != nil {
		return nil, err
	}
	if len(out) > maxStateBytes {
		return nil, contract.New(contract.ArtifactTooLarge, nil)
	}
	return out, nil
}
