package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/config"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ios-debug-system/cli/internal/transport"
)

type actionStateResponse struct {
	status int
	body   string
}

type actionStateRequest struct {
	line string
	body string
}

type actionStateTransport struct {
	t         *testing.T
	responses []actionStateResponse
	mu        sync.Mutex
	requests  []actionStateRequest
}

func newActionStateTransport(t *testing.T, responses ...actionStateResponse) *actionStateTransport {
	t.Helper()
	return &actionStateTransport{t: t, responses: responses}
}

func (f *actionStateTransport) Name() string { return "action-state-test" }

func (f *actionStateTransport) Dial(context.Context, string, uint16) (net.Conn, error) {
	f.mu.Lock()
	if len(f.requests) >= len(f.responses) {
		f.mu.Unlock()
		return nil, fmt.Errorf("unexpected request")
	}
	response := f.responses[len(f.requests)]
	f.mu.Unlock()

	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			f.t.Error(err)
			return
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			f.t.Error(err)
			return
		}
		f.mu.Lock()
		f.requests = append(f.requests, actionStateRequest{
			line: request.Method + " " + request.URL.RequestURI(),
			body: string(body),
		})
		f.mu.Unlock()
		status := response.status
		if status == 0 {
			status = http.StatusOK
		}
		_, _ = fmt.Fprintf(server, "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, http.StatusText(status), len(response.body), response.body)
	}()
	return client, nil
}

func (f *actionStateTransport) snapshot() []actionStateRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]actionStateRequest(nil), f.requests...)
}

func actionStateDependencies(t *testing.T, tr transport.DeviceTransport) Dependencies {
	t.Helper()
	deps := commandDependencies(t, &fakeDeviceDiscoverer{}, tr)
	deps.LoadConfig = func(context.Context, config.LoadOptions) (config.Config, error) {
		return config.Config{Transport: "tcp", TCPHost: "127.0.0.1", Port: 9876}, nil
	}
	return deps
}

func actionsResponse(actions ...map[string]any) actionStateResponse {
	body, err := json.Marshal(map[string]any{
		"ok":   true,
		"data": map[string]any{"actions": actions, "generation": 9},
		"meta": map[string]any{"protocol_version": 1, "request_id": "actions-1"},
	})
	if err != nil {
		panic(err)
	}
	return actionStateResponse{body: string(body)}
}

func testAction(identifier, role string, enabled bool) map[string]any {
	return map[string]any{
		"identifier":  identifier,
		"role":        role,
		"description": "Open settings",
		"enabled":     enabled,
		"generation":  9,
	}
}

func actionSuccess(identifier string) actionStateResponse {
	return actionStateResponse{body: fmt.Sprintf(`{"ok":true,"data":{"identifier":%q,"generation":9,"activated":true},"meta":{"protocol_version":1,"request_id":"activate-1"}}`, identifier)}
}

func actionSuccessWithGeneration(identifier string, generation uint64) actionStateResponse {
	return actionStateResponse{body: fmt.Sprintf(`{"ok":true,"data":{"identifier":%q,"generation":%d,"activated":true},"meta":{"protocol_version":1,"request_id":"activate-1"}}`, identifier, generation)}
}

func actionFailure(code, internal string) actionStateResponse {
	return actionStateResponse{status: http.StatusInternalServerError, body: fmt.Sprintf(`{"ok":false,"error":{"code":%q,"message":%q,"hint":"private hint"},"meta":{"protocol_version":1,"request_id":"activate-failure"}}`, code, internal)}
}

func TestActionsListReturnsCurrentSnapshot(t *testing.T) {
	fake := newActionStateTransport(t, actionsResponse(testAction("header.settings", "navigation", true)))
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "list")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":true,"data":{"actions":[{"identifier":"header.settings","role":"navigation","description":"Open settings","enabled":true,"generation":9}],"generation":9},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
	require.Equal(t, []actionStateRequest{{line: "GET /v1/actions"}}, fake.snapshot())
}

func TestActivateDryRunOnlyListsAndValidates(t *testing.T) {
	fake := newActionStateTransport(t, actionsResponse(testAction("header.settings", "navigation", true)))
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "header.settings", "--dry-run")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Equal(t, []actionStateRequest{{line: "GET /v1/actions"}}, fake.snapshot())
	require.JSONEq(t, `{"ok":true,"data":{"dry_run":true,"action":{"identifier":"header.settings","role":"navigation","description":"Open settings","enabled":true,"generation":9}},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
}

func TestActivateDryRunReturnsDestructiveMetadataWithoutActivation(t *testing.T) {
	fake := newActionStateTransport(t, actionsResponse(testAction("account.erase", "destructive", true)))
	stdout, _, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "account.erase", "--dry-run")

	require.Equal(t, 0, code)
	require.Equal(t, []actionStateRequest{{line: "GET /v1/actions"}}, fake.snapshot())
	require.Contains(t, stdout, `"role":"destructive"`)
	require.Contains(t, stdout, `"dry_run":true`)
}

func TestActivateRealDestructiveActionRemainsAvailableAndSendsExactBody(t *testing.T) {
	fake := newActionStateTransport(t,
		actionsResponse(testAction("account.erase", "destructive", true)),
		actionSuccess("account.erase"),
	)
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "account.erase")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":true,"data":{"identifier":"account.erase","role":"destructive","generation":9},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
	require.Equal(t, []actionStateRequest{
		{line: "GET /v1/actions"},
		{line: "POST /v1/actions/activate", body: `{"identifier":"account.erase"}`},
	}, fake.snapshot())
}

func TestActivateValidationMapsMissingAndDisabledActions(t *testing.T) {
	for _, test := range []struct {
		name     string
		actions  []map[string]any
		expected contract.Code
	}{
		{name: "missing", actions: []map[string]any{testAction("other.action", "navigation", true)}, expected: contract.ActionNotFound},
		{name: "disabled", actions: []map[string]any{testAction("header.settings", "navigation", false)}, expected: contract.ActionDisabled},
	} {
		t.Run(test.name, func(t *testing.T) {
			fake := newActionStateTransport(t, actionsResponse(test.actions...))
			stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "header.settings")

			require.Equal(t, 5, code)
			require.Empty(t, stderr)
			require.Contains(t, stdout, `"code":"`+string(test.expected)+`"`)
			require.Equal(t, []actionStateRequest{{line: "GET /v1/actions"}}, fake.snapshot())
		})
	}
}

func TestActivateFailureIsStableAndRedactsAppErrorText(t *testing.T) {
	fake := newActionStateTransport(t,
		actionsResponse(testAction("header.settings", "navigation", true)),
		actionFailure("action_failed", "closure leaked its database password"),
	)
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "header.settings")

	require.Equal(t, 5, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":false,"error":{"code":"action_failed","message":"The registered action failed.","hint":"Inspect App state and Debug logs, correct the action closure, then retry."}}`, stdout)
	require.NotContains(t, stdout, "database password")
}

func TestActivateRejectsGenerationMismatchBeforeMergingValidatedRole(t *testing.T) {
	action := testAction("header.settings", "navigation", true)
	action["generation"] = 7
	fake := newActionStateTransport(t, actionsResponse(action), actionSuccessWithGeneration("header.settings", 8))

	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "header.settings")

	require.Equal(t, 5, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, `"code":"protocol_mismatch"`)
	require.NotContains(t, stdout, `"role":"navigation"`)
}

func TestActivateAcceptsReplacementWhoseRegistrationGenerationPredatesSnapshot(t *testing.T) {
	action := testAction("header.settings", "mutation", true)
	action["generation"] = 7
	fake := newActionStateTransport(t, actionsResponse(action), actionSuccessWithGeneration("header.settings", 7))

	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "actions", "activate", "header.settings")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.JSONEq(t, `{"ok":true,"data":{"identifier":"header.settings","role":"mutation","generation":7},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
}

func TestStateReturnsArbitraryJSONWithoutReencodingLoss(t *testing.T) {
	fake := newActionStateTransport(t, actionStateResponse{body: `{"ok":true,"data":{"counter":9007199254740993},"meta":{"protocol_version":1,"request_id":"state-1"}}`})
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, fake), "--json", "--transport", "tcp", "state", "get")

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, "9007199254740993")
	require.JSONEq(t, `{"ok":true,"data":{"counter":9007199254740993},"meta":{"protocol_version":1,"duration_ms":0}}`, stdout)
	require.Equal(t, []actionStateRequest{{line: "GET /v1/state"}}, fake.snapshot())
}

func TestStateRejectsDeclaredBodiesLargerThanBoundedEnvelopeLimit(t *testing.T) {
	client, server := net.Pipe()
	tr := &oneShotActionStateConn{conn: client}
	go func() {
		defer server.Close()
		_, _ = http.ReadRequest(bufio.NewReader(server))
		_, _ = io.WriteString(server, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4260000\r\nConnection: close\r\n\r\n")
	}()
	stdout, stderr, code := executeReadCommand(t, actionStateDependencies(t, tr), "--json", "--transport", "tcp", "state", "get")

	require.Equal(t, 6, code)
	require.Empty(t, stderr)
	require.Contains(t, stdout, `"code":"artifact_too_large"`)
}

type oneShotActionStateConn struct{ conn net.Conn }

func (o *oneShotActionStateConn) Name() string { return "one-shot" }
func (o *oneShotActionStateConn) Dial(context.Context, string, uint16) (net.Conn, error) {
	return o.conn, nil
}
