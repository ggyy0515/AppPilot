package doctor

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/require"
)

func TestSafeOneLineScrubsExactSecretsBeforeControlsAndTruncation(t *testing.T) {
	for _, sample := range []struct {
		output string
		secret string
	}{
		{"secret first line\nignored", "secret"},
		{"prefix secret suffix", "secret"},
		{"前缀密钥🔐后缀", "密钥🔐"},
		{"prefix\x00secret\tsuffix", "secret"},
		{"prefix key\x00part suffix", "key\x00part"},
	} {
		got := safeOneLine([]byte(sample.output), "", sample.secret)
		require.NotContains(t, got, sample.secret)
		require.NotContains(t, got, "\x00")
	}
	require.Equal(t, "visible", safeOneLine([]byte("visible"), ""))
}

func TestSafeOneLineBoundsCapturedFragmentByBytesAtRuneBoundary(t *testing.T) {
	require.Len(t, []byte(safeOneLine([]byte(strings.Repeat("a", 256)))), 256)
	require.Len(t, []byte(safeOneLine([]byte(strings.Repeat("a", 257)))), 256)
	got := safeOneLine([]byte(strings.Repeat("a", 255) + "界"))
	require.True(t, utf8.ValidString(got))
	require.Len(t, []byte(got), 255)
}
