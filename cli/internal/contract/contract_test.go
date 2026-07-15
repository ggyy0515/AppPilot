package contract_test

import (
	"bytes"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
)

func TestEmitterWritesExactlyOneStableErrorDocument(t *testing.T) {
	var out bytes.Buffer
	emitter := contract.NewEmitter(&out)
	cause := errors.New("dial tcp: secret payload")
	err := contract.New(contract.AppNotReachable, cause)

	require.NoError(t, emitter.Failure(err))
	require.Equal(t, "{\"ok\":false,\"error\":{\"code\":\"app_not_reachable\",\"message\":\"Debug server is not reachable.\",\"hint\":\"Launch a Debug build, keep the device unlocked, and resume the App if it is paused at a breakpoint.\"}}\n", out.String())
	require.NotContains(t, out.String(), "secret payload")
	require.ErrorIs(t, emitter.Failure(err), contract.ErrAlreadyEmitted)
	require.Equal(t, 4, contract.ExitCode(err))
	require.ErrorIs(t, err, cause)
}

func TestEmitterWritesStableSuccessMetaWithoutEscapingHTML(t *testing.T) {
	var out bytes.Buffer
	emitter := contract.NewEmitter(&out)

	require.NoError(t, emitter.Success(map[string]string{"value": "<ready>"}, contract.Meta{
		ProtocolVersion: 1,
		DurationMS:      42,
	}))
	require.Equal(t, "{\"ok\":true,\"data\":{\"value\":\"<ready>\"},\"meta\":{\"protocol_version\":1,\"duration_ms\":42}}\n", out.String())
	require.ErrorIs(t, emitter.Success(nil, contract.Meta{}), contract.ErrAlreadyEmitted)
}

func TestStableErrorHelpers(t *testing.T) {
	cause := errors.New("bad input")
	err := contract.NewWithHint(contract.ConfigInvalid, cause, "Use a valid value.")

	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.Equal(t, 2, contract.ExitCode(err))
	require.Equal(t, "Use a valid value.", err.Hint)
	require.ErrorIs(t, err, cause)
	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(cause))
	require.Equal(t, 5, contract.ExitCode(cause))
}

func TestUnknownCodeUsesProtocolMismatchDescriptor(t *testing.T) {
	err := contract.New(contract.Code("unknown"), nil)

	require.Equal(t, contract.ProtocolMismatch, err.Code)
	require.Equal(t, "The App debug protocol is incompatible.", err.Message)
	require.Equal(t, 5, contract.ExitCode(err))
}

func TestExitCodeFallsBackForExternallyConstructedUnknownError(t *testing.T) {
	err := &contract.Error{
		Code:    contract.Code("unknown"),
		Message: "secret message",
		Hint:    "secret hint",
	}
	var out bytes.Buffer
	emitter := contract.NewEmitter(&out)

	require.Equal(t, contract.ProtocolMismatch, contract.CodeOf(err))
	require.Equal(t, 5, contract.ExitCode(err))
	require.NoError(t, emitter.Failure(err))
	require.Equal(t, "{\"ok\":false,\"error\":{\"code\":\"protocol_mismatch\",\"message\":\"The App debug protocol is incompatible.\",\"hint\":\"Use an APIOSDebugKit build that implements protocol version 1.\"}}\n", out.String())
	require.NotContains(t, out.String(), "secret")
}

func TestEmitterCanonicalizesExternallyConstructedKnownError(t *testing.T) {
	err := &contract.Error{
		Code:    contract.ConfigInvalid,
		Message: "secret message",
		Hint:    "secret hint",
	}
	var out bytes.Buffer

	require.NoError(t, contract.NewEmitter(&out).Failure(err))
	require.Equal(t, "{\"ok\":false,\"error\":{\"code\":\"config_invalid\",\"message\":\"Configuration is invalid.\",\"hint\":\"Fix the named flag, environment variable, or TOML field.\"}}\n", out.String())
}

func TestEmitterPreservesHintFromStableConstructor(t *testing.T) {
	err := contract.NewWithHint(contract.ConfigInvalid, nil, "Use a port from 1 through 65535.")
	var out bytes.Buffer

	require.NoError(t, contract.NewEmitter(&out).Failure(err))
	require.Contains(t, out.String(), "Use a port from 1 through 65535.")
}

func TestEmitterIgnoresMutationAfterNew(t *testing.T) {
	cause := &mutableError{text: "initial secret cause"}
	err := contract.New(contract.AppNotReachable, cause)
	err.Code = contract.ConfigInvalid
	err.Message = "mutated secret message"
	err.Hint = "mutated secret hint"
	cause.text = "mutated secret cause"
	var out bytes.Buffer

	require.Equal(t, contract.AppNotReachable, contract.CodeOf(err))
	require.Equal(t, 4, contract.ExitCode(err))
	require.Equal(t, "Debug server is not reachable.", err.Error())
	require.ErrorIs(t, err, cause)
	require.NoError(t, contract.NewEmitter(&out).Failure(err))
	require.Equal(t, "{\"ok\":false,\"error\":{\"code\":\"app_not_reachable\",\"message\":\"Debug server is not reachable.\",\"hint\":\"Launch a Debug build, keep the device unlocked, and resume the App if it is paused at a breakpoint.\"}}\n", out.String())
	require.NotContains(t, out.String(), "secret")
}

func TestEmitterIgnoresPublicMutationAfterNewWithHint(t *testing.T) {
	err := contract.NewWithHint(contract.ConfigInvalid, nil, "Use a stable override.")
	err.Code = contract.IOFailure
	err.Message = "mutated secret message"
	err.Hint = "mutated secret hint"
	var out bytes.Buffer

	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.Equal(t, 2, contract.ExitCode(err))
	require.Equal(t, "Configuration is invalid.", err.Error())
	require.NoError(t, contract.NewEmitter(&out).Failure(err))
	require.Equal(t, "{\"ok\":false,\"error\":{\"code\":\"config_invalid\",\"message\":\"Configuration is invalid.\",\"hint\":\"Use a stable override.\"}}\n", out.String())
	require.NotContains(t, out.String(), "secret")
}

type mutableError struct{ text string }

func (e *mutableError) Error() string { return e.text }
