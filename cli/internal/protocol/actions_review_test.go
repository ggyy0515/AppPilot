package protocol

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

func actionsEnvelope(data string) string {
	return jsonHTTP("200 OK", successEnvelope(data))
}

func actionJSON(identifier, role string, enabledJSON string, generation uint64) string {
	return fmt.Sprintf(`{"identifier":%q,"role":%q,"description":"description","enabled":%s,"generation":%d}`,
		identifier, role, enabledJSON, generation)
}

func TestActionsListAcceptsCanonicalSnapshotWithOlderRegistrationGenerations(t *testing.T) {
	body := fmt.Sprintf(`{"actions":[%s,%s],"generation":9}`,
		actionJSON("account.erase", "destructive", "true", 7),
		actionJSON("header.settings", "navigation", "false", 9),
	)
	tr := &scriptedDeviceTransport{t: t, response: actionsEnvelope(body)}

	got, err := NewActions(NewClient(tr, Target{Port: 9876}, "")).List(context.Background())

	require.NoError(t, err)
	require.Equal(t, uint64(7), got.Actions[0].Generation)
	require.False(t, got.Actions[1].Enabled)
}

func TestActionsListAcceptsInitialEmptySnapshotAtGenerationZero(t *testing.T) {
	tr := &scriptedDeviceTransport{t: t, response: actionsEnvelope(`{"actions":[],"generation":0}`)}

	got, err := NewActions(NewClient(tr, Target{Port: 9876}, "")).List(context.Background())

	require.NoError(t, err)
	require.Empty(t, got.Actions)
	require.Zero(t, got.Generation)
}

func TestActionsListRejectsMalformedOrNonCanonicalSnapshots(t *testing.T) {
	valid := actionJSON("header.settings", "navigation", "true", 9)
	tests := map[string]string{
		"not sorted":               fmt.Sprintf(`{"actions":[%s,%s],"generation":9}`, valid, actionJSON("account.erase", "mutation", "true", 8)),
		"duplicate identifier":     fmt.Sprintf(`{"actions":[%s,%s],"generation":9}`, valid, valid),
		"invalid role":             fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("header.settings", "admin", "true", 9)),
		"empty identifier":         fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("", "navigation", "true", 9)),
		"invalid identifier":       fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("header..settings", "navigation", "true", 9)),
		"missing enabled":          `{"actions":[{"identifier":"header.settings","role":"navigation","description":"d","generation":9}],"generation":9}`,
		"non boolean enabled":      fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("header.settings", "navigation", `"yes"`, 9)),
		"future action generation": fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("header.settings", "navigation", "true", 10)),
		"zero action generation":   fmt.Sprintf(`{"actions":[%s],"generation":9}`, actionJSON("header.settings", "navigation", "true", 0)),
		"zero snapshot generation": fmt.Sprintf(`{"actions":[%s],"generation":0}`, actionJSON("header.settings", "navigation", "true", 0)),
		"unknown snapshot field":   fmt.Sprintf(`{"actions":[%s],"generation":9,"future":true}`, valid),
		"unknown action field":     `{"actions":[{"identifier":"header.settings","role":"navigation","description":"d","enabled":true,"generation":9,"future":true}],"generation":9}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: actionsEnvelope(body)}
			_, err := NewActions(NewClient(tr, Target{Port: 9876}, "")).List(context.Background())
			require.Error(t, err)
			require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err), err)
		})
	}
}

func TestActionsActivateRequiresExactSuccessData(t *testing.T) {
	tests := map[string]string{
		"missing activated":  `{"identifier":"header.settings","generation":9}`,
		"activated false":    `{"identifier":"header.settings","generation":9,"activated":false}`,
		"wrong identifier":   `{"identifier":"other.action","generation":9,"activated":true}`,
		"missing generation": `{"identifier":"header.settings","activated":true}`,
		"unexpected role":    `{"identifier":"header.settings","generation":9,"activated":true,"role":"navigation"}`,
	}
	for name, data := range tests {
		t.Run(name, func(t *testing.T) {
			tr := &scriptedDeviceTransport{t: t, response: actionsEnvelope(data)}
			_, err := NewActions(NewClient(tr, Target{Port: 9876}, "")).Activate(context.Background(), "header.settings")
			require.Error(t, err)
			require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err), err)
		})
	}
}
