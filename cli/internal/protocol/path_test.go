package protocol

import (
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

func TestValidateRawPathRejectsEscapeForms(t *testing.T) {
	for _, value := range []string{
		"/v1/", "/v1/../state", "http://host/v1/state", "/v1/state?x=1",
		"/v1/state#x", "//v1/state", "/v1//state", "/v1/%2e%2e/state",
		"/v1/actions%2Factivate", "v1/state", "/other/state",
	} {
		err := ValidateRawPath(value)
		require.Error(t, err, value)
		require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err), value)
	}
	require.NoError(t, ValidateRawPath("/v1/capabilities"))
	require.NoError(t, ValidateRawPath("/v1/recordings/rec-1"))
}
