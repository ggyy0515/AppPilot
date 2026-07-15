package protocol

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

func TestStateAllowsExactlyFourMiBOfRawDataIncludingEnvelopeOverhead(t *testing.T) {
	data := `"` + strings.Repeat("x", maxStateBytes-2) + `"`
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}

	got, err := NewState(NewClient(tr, Target{Port: 9876}, "")).Get(context.Background())

	require.NoError(t, err)
	require.Len(t, got, maxStateBytes)
	require.Equal(t, data, string(got))
}

func TestStateRejectsRawDataLargerThanFourMiB(t *testing.T) {
	data := `"` + strings.Repeat("x", maxStateBytes-1) + `"`
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}

	_, err := NewState(NewClient(tr, Target{Port: 9876}, "")).Get(context.Background())

	require.Error(t, err)
	require.Equal(t, contract.ArtifactTooLarge, contract.CodeOf(err), err)
}

func TestStatePreservesLargeIntegerAndEscapedControlBytes(t *testing.T) {
	data := `{"counter":9007199254740993,"control":"\u0000\n"}`
	tr := &scriptedDeviceTransport{t: t, response: jsonHTTP("200 OK", successEnvelope(data))}

	got, err := NewState(NewClient(tr, Target{Port: 9876}, "")).Get(context.Background())

	require.NoError(t, err)
	require.Equal(t, data, string(got))
}
