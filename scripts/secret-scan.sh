#!/usr/bin/env bash

# Scan captured files for exact secrets. Returns 0 when clean, 1 when a secret
# is found, and preserves any other status returned by the scanner.
scan_directory_for_secrets() {
  local directory="$1"
  local diagnostic="$2"
  shift 2
  local grep_bin="${GREP_BIN:-/usr/bin/grep}"
  local file_list="$diagnostic.files"
  local file secret scanner_status

  : >"$diagnostic"
  if ! /usr/bin/find "$directory" -type f -print0 >"$file_list" 2>"$diagnostic.find"; then
    echo "Secret scanner could not enumerate captured files." | tee -a "$diagnostic" >&2
    return 2
  fi

  for secret in "$@"; do
    [ -n "$secret" ] || continue
    while IFS= read -r -d '' file; do
      if "$grep_bin" -F -q -- "$secret" "$file" 2>"$diagnostic.scanner"; then
        echo "Secret detected in captured output: <redacted>." | tee -a "$diagnostic" >&2
        return 1
      else
        scanner_status=$?
      fi
      case "$scanner_status" in
        1) ;;
        *)
          echo "Secret scanner failed with exit $scanner_status." | tee -a "$diagnostic" >&2
          return "$scanner_status"
          ;;
      esac
    done <"$file_list"
  done
  return 0
}
