#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
files=(README.md docs/integration.md docs/protocol.md docs/troubleshooting.md)

require_fixed() {
    local pattern="$1"
    local file="$2"
    local status

    if grep -Fq -- "$pattern" "$file"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        echo "FAIL: missing '$pattern' in ${file#"$root/"}" >&2
    else
        echo "FAIL: grep failed while checking ${file#"$root/"} (status $status)" >&2
    fi
    exit 1
}

reject_extended() {
    local pattern="$1"
    shift
    local status

    if grep -REq -- "$pattern" "$@"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 1 ]]; then
        return 1
    fi
    echo "FAIL: grep failed while checking forbidden documentation content (status $status)" >&2
    exit 2
}

for file in "${files[@]}"; do
    if [[ ! -s "$root/$file" ]]; then
        echo "FAIL: missing or empty $file" >&2
        exit 1
    fi
done

for heading in '## Install' '## Quick start' '## Safety boundary' '## Verification'; do
    require_fixed "$heading" "$root/README.md"
done
for heading in '## Add the local package' '## Start and stop the runtime' '## Register actions' '## Provide state' '## Scaffold'; do
    require_fixed "$heading" "$root/docs/integration.md"
done
require_fixed 'package product dependencies are target-scoped, not configuration-scoped' "$root/docs/integration.md"
require_fixed 'dedicated Debug app target' "$root/docs/integration.md"
require_fixed 'duplicate the production App target' "$root/docs/integration.md"
require_fixed 'Keep Profile and Archive on the production target' "$root/docs/integration.md"
require_fixed 'Do not schedule start and stop together' "$root/docs/integration.md"
require_fixed 'only protocol version, `auth_required: true`, and `reachable: true`' "$root/docs/protocol.md"
for route in /v1/health /v1/capabilities /v1/actions /v1/state /v1/screenshot /v1/recording/status /v1/recording/start /v1/recording/stop '/v1/recordings/{id}'; do
    require_fixed "$route" "$root/docs/protocol.md"
done
for code in config_invalid tool_missing no_device multiple_devices device_untrusted device_locked app_not_reachable transport_failure request_timeout protocol_mismatch auth_required auth_failed action_not_found action_disabled action_failed action_requires_confirmation state_encoding_failed screenshot_failed recording_not_available recording_invalid_state recording_permission_timeout artifact_too_large artifact_checksum_mismatch io_failure; do
    require_fixed "$code" "$root/docs/troubleshooting.md"
done
for command in 'make install-local' 'make uninstall-local' 'make verify' 'make device-smoke'; do
    require_fixed "$command" "$root/README.md"
done
for link in '[App integration](docs/integration.md)' '[protocol v1](docs/protocol.md)' '[troubleshooting](docs/troubleshooting.md)'; do
    require_fixed "$link" "$root/README.md"
done
for file in docs/integration.md docs/protocol.md docs/troubleshooting.md; do
    require_fixed '(../README.md)' "$root/$file"
done
require_fixed '(protocol.md)' "$root/docs/integration.md"
require_fixed '(troubleshooting.md)' "$root/docs/integration.md"
require_fixed '(integration.md)' "$root/docs/protocol.md"
require_fixed '(troubleshooting.md)' "$root/docs/protocol.md"
require_fixed '(integration.md)' "$root/docs/troubleshooting.md"
require_fixed '(protocol.md)' "$root/docs/troubleshooting.md"
for route in \
    'GET /v1/health' 'GET /v1/capabilities' 'GET /v1/actions' \
    'POST /v1/actions/activate' 'GET /v1/state' 'GET /v1/screenshot' \
    'GET /v1/recording/status' 'POST /v1/recording/start' \
    'POST /v1/recording/stop' 'GET /v1/recordings/{id}' \
    'DELETE /v1/recordings/{id}'; do
    require_fixed "$route" "$root/docs/protocol.md"
done
if reject_extended 'ios-debug .*request (post|put|patch|delete)' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose a raw write request" >&2
    exit 1
fi
if reject_extended 'ios-debug .*--token|^[[:space:]]*token[[:space:]]*=' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose an unsupported token source" >&2
    exit 1
fi
if reject_extended 'product only to (the )?.*Debug configuration' "$root/docs/integration.md"; then
    echo "FAIL: docs prescribe unsupported configuration-scoped package linking" >&2
    exit 1
fi

echo "PASS: docs-check"
