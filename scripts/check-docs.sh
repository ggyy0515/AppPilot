#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
files=(README.md docs/integration.md docs/protocol.md docs/troubleshooting.md)
historical_cli="$root/docs/superpowers/plans/2026-07-13-ap-ios-debug-cli.md"
historical_delivery="$root/docs/superpowers/plans/2026-07-13-ap-ios-debug-integration-delivery.md"
historical_design="$root/docs/superpowers/specs/2026-07-12-ap-ios-debug-system-design.md"
legacy_scan_files=("$root/README.md")
while IFS= read -r -d '' file; do
    case "$file" in
        "$root/docs/superpowers/specs/2026-07-15-ap-ios-debug-system-rename-design.md"|\
        "$root/docs/superpowers/plans/2026-07-15-ap-ios-debug-system-rename.md")
            continue
            ;;
    esac
    legacy_scan_files+=("$file")
done < <(find "$root/docs" -type f -name '*.md' -print0)

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
require_fixed '# AppPilot' "$root/README.md"
require_fixed '# AppPilot' "$root/docs/integration.md"
require_fixed '# AppPilot' "$root/docs/protocol.md"
require_fixed '# AppPilot' "$root/docs/troubleshooting.md"
require_fixed 'command -v ap-ios-debug' "$root/README.md"
require_fixed 'ap-ios-debug --json doctor' "$root/README.md"
require_fixed '.ap-ios-debug/artifacts' "$root/README.md"
require_fixed 'APIOSDebugKit' "$root/README.md"
require_fixed 'APIOSDebugBootstrap' "$root/docs/integration.md"
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
if reject_extended 'ap-ios-debug .*request (post|put|patch|delete)' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose a raw write request" >&2
    exit 1
fi
if reject_extended 'ap-ios-debug .*--token|^[[:space:]]*token[[:space:]]*=' "$root/README.md" "$root/docs"; then
    echo "FAIL: docs expose an unsupported token source" >&2
    exit 1
fi
if reject_extended 'product only to (the )?.*Debug configuration' "$root/docs/integration.md"; then
    echo "FAIL: docs prescribe unsupported configuration-scoped package linking" >&2
    exit 1
fi
for legacy_pattern in \
    '(^|[^[:alnum:]-])ios-debug' \
    '(^|[^[:alnum:]])sx-ios-debug' \
    '(^|[^[:alnum:]])IOSDebug' \
    '(^|[^[:alnum:]_])IOS_DEBUG' \
    '(^|[^[:alnum:]])\.ios-debug' \
    '(^|[^[:alnum:]])DebugDemo'; do
    if reject_extended "$legacy_pattern" "${legacy_scan_files[@]}"; then
        echo "FAIL: docs expose a legacy AppPilot name matching '$legacy_pattern'" >&2
        exit 1
    fi
done

for required_text in \
    'Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj' \
    'ap-ios-debug-demo.xcscheme' \
    'ap-ios-debug-demo-release.xcscheme' \
    '-scheme ap-ios-debug-demo ' \
    '-scheme ap-ios-debug-demo-release ' \
    'com.openai.ap-ios-debug-demo'; do
    require_fixed "$required_text" "$historical_delivery"
done
for forbidden_text in \
    'Examples/ap-ios-debug-demo/APIOSDebugDemo.xcodeproj' \
    'ReferencedContainer="container:APIOSDebugDemo.xcodeproj"' \
    '-scheme APIOSDebugDemo ' \
    'DEMO_SCHEME := APIOSDebugDemo' \
    'com.openai.iosdebug.APIOSDebugDemo'; do
    if grep -Fq -- "$forbidden_text" "$historical_delivery"; then
        echo "FAIL: delivery plan confuses an external name with a Swift identifier: '$forbidden_text'" >&2
        exit 1
    fi
done

for required_text in \
    'testdata/ap-ios-debug-kit' \
    'DebugTools", "ap-ios-debug-kit' \
    '"share", "ap-ios-debug", "ap-ios-debug-kit"' \
    '"swift", "ap-ios-debug-kit"' \
    'AppPilot ap-ios-debug version 0.1.0-dev'; do
    require_fixed "$required_text" "$historical_cli"
done
for forbidden_text in \
    'testdata/APIOSDebugKit' \
    'DebugTools", "APIOSDebugKit' \
    '"share", "ap-ios-debug", "APIOSDebugKit"' \
    '"swift", "APIOSDebugKit"' \
    'prints `ap-ios-debug version 0.1.0-dev`'; do
    if grep -Fq -- "$forbidden_text" "$historical_cli"; then
        echo "FAIL: CLI plan confuses an external name with a Swift identifier: '$forbidden_text'" >&2
        exit 1
    fi
done

require_fixed 'ap-ios-debug-demo.xcodeproj' "$historical_design"
if grep -Fq -- 'APIOSDebugDemo.xcodeproj' "$historical_design"; then
    echo 'FAIL: design spec uses a Swift identifier as the Xcode project filename' >&2
    exit 1
fi

echo "PASS: docs-check"
