package protocol

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"regexp"

	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

var actionIdentifier = regexp.MustCompile(`^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)+$`)

type Action struct {
	Identifier  string `json:"identifier"`
	Role        string `json:"role"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
	Generation  uint64 `json:"generation"`
}

type ActionsData struct {
	Actions    []Action `json:"actions"`
	Generation uint64   `json:"generation"`
}

type ActivateData struct {
	Identifier string `json:"identifier"`
	Role       string `json:"role"`
	Generation uint64 `json:"generation"`
}

type Actions struct {
	client *Client
}

type wireAction struct {
	Identifier  *string `json:"identifier"`
	Role        *string `json:"role"`
	Description *string `json:"description"`
	Enabled     *bool   `json:"enabled"`
	Generation  *uint64 `json:"generation"`
}

func (data *wireAction) UnmarshalJSON(raw []byte) error {
	type plainWireAction wireAction
	var decoded plainWireAction
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	*data = wireAction(decoded)
	return nil
}

type wireActionsData struct {
	Actions    *[]wireAction `json:"actions"`
	Generation *uint64       `json:"generation"`
}

func (data *wireActionsData) UnmarshalJSON(raw []byte) error {
	type plainWireActionsData wireActionsData
	var decoded plainWireActionsData
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	*data = wireActionsData(decoded)
	return nil
}

type wireActivateData struct {
	Identifier *string `json:"identifier"`
	Generation *uint64 `json:"generation"`
	Activated  *bool   `json:"activated"`
}

func (data *wireActivateData) UnmarshalJSON(raw []byte) error {
	type plainWireActivateData wireActivateData
	var decoded plainWireActivateData
	if err := decodeStrictJSON(raw, &decoded); err != nil {
		return err
	}
	*data = wireActivateData(decoded)
	return nil
}

func decodeStrictJSON(raw []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	return decoder.Decode(output)
}

func NewActions(client *Client) Actions {
	return Actions{client: client}
}

func (a Actions) List(ctx context.Context) (ActionsData, error) {
	var wire wireActionsData
	_, err := a.client.DoJSON(ctx, http.MethodGet, "/v1/actions", nil, 1<<20, &wire)
	if err != nil {
		return ActionsData{}, err
	}
	if wire.Actions == nil || wire.Generation == nil {
		return ActionsData{}, protocolError(nil)
	}
	if len(*wire.Actions) > 0 && *wire.Generation == 0 {
		return ActionsData{}, protocolError(nil)
	}
	out := ActionsData{Generation: *wire.Generation, Actions: make([]Action, 0, len(*wire.Actions))}
	previousIdentifier := ""
	for index, item := range *wire.Actions {
		if item.Identifier == nil || item.Role == nil || item.Description == nil ||
			item.Enabled == nil || item.Generation == nil {
			return ActionsData{}, protocolError(nil)
		}
		identifier := *item.Identifier
		if !actionIdentifier.MatchString(identifier) || (index > 0 && identifier <= previousIdentifier) ||
			!validActionRole(*item.Role) || *item.Generation == 0 || *item.Generation > *wire.Generation {
			return ActionsData{}, protocolError(nil)
		}
		out.Actions = append(out.Actions, Action{
			Identifier: identifier, Role: *item.Role, Description: *item.Description,
			Enabled: *item.Enabled, Generation: *item.Generation,
		})
		previousIdentifier = identifier
	}
	return out, nil
}

func (a Actions) Activate(ctx context.Context, identifier string) (ActivateData, error) {
	var wire wireActivateData
	_, err := a.client.DoJSON(ctx, http.MethodPost, "/v1/actions/activate", struct {
		Identifier string `json:"identifier"`
	}{Identifier: identifier}, 1<<20, &wire)
	if err != nil {
		return ActivateData{}, err
	}
	if wire.Identifier == nil || wire.Generation == nil || wire.Activated == nil ||
		!*wire.Activated || *wire.Identifier != identifier {
		return ActivateData{}, protocolError(nil)
	}
	return ActivateData{Identifier: *wire.Identifier, Generation: *wire.Generation}, nil
}

func (a Actions) Validate(ctx context.Context, identifier string) (Action, error) {
	snapshot, err := a.List(ctx)
	if err != nil {
		return Action{}, err
	}
	for _, action := range snapshot.Actions {
		if action.Identifier != identifier {
			continue
		}
		if !action.Enabled {
			return Action{}, contract.New(contract.ActionDisabled, nil)
		}
		return action, nil
	}
	return Action{}, contract.New(contract.ActionNotFound, nil)
}

func validActionRole(role string) bool {
	switch role {
	case "navigation", "mutation", "destructive":
		return true
	default:
		return false
	}
}
