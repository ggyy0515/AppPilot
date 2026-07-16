#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$root"

required_files=(
  LICENSE
  NOTICE
  CONTRIBUTING.md
  CODE_OF_CONDUCT.md
  SECURITY.md
  CHANGELOG.md
  THIRD_PARTY_NOTICES.md
  .github/CODEOWNERS
  .github/dependabot.yml
  .github/pull_request_template.md
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/config.yml
  .github/workflows/ci.yml
  .github/workflows/release.yml
  docs/releasing.md
)
for file in "${required_files[@]}"; do
  [[ -s "$file" ]] || { echo "FAIL: missing or empty $file" >&2; exit 1; }
done

grep -Fq 'Apache License' LICENSE
grep -Fq 'Version 2.0, January 2004' LICENSE
grep -Fq 'Copyright 2026 Tristan' NOTICE
grep -Fq 'github.com/ggyy0515/AppPilot' README.md
grep -Fq 'Apache-2.0' README.md
grep -Fxq '* @ggyy0515' .github/CODEOWNERS

[[ "$(cd cli && GOWORK=off go list -m -f '{{.Path}}')" == github.com/ggyy0515/AppPilot ]]
bundle_ids="$(ruby -e '
  values = File.readlines(ARGV.fetch(0)).map { |line| line[/^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);\s*$/, 1] }.compact
  puts values.uniq.sort
' Examples/ap-ios-debug-demo/ap-ios-debug-demo.xcodeproj/project.pbxproj)"
[[ "$bundle_ids" == $'com.ggyy.ap-ios-debug-demo\ncom.ggyy.ap-ios-debug-demo.tests' ]]

if [[ -e docs/superpowers ]]; then
  echo 'FAIL: docs/superpowers remains in the public tree' >&2
  exit 1
fi

tracked="$(mktemp)"
trap 'rm -f "$tracked"' EXIT
: >"$tracked"
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] && printf '%s\0' "$file" >>"$tracked"
done < <(git ls-files -z --cached --others --exclude-standard)
old_module='github.com/'"yangy003/ap-ios-debug-system"
old_bundle='com.'"openai.ap-ios-debug-demo"
local_path='/Users/'"tristan/"
pdf_title='我 vibe coding 了一个 iOS 调试工具，让 Claude '"Code 自己去操作 App.pdf"
for forbidden in "$old_module" "$old_bundle" "$local_path" "$pdf_title"; do
  if xargs -0 grep -IlF -- "$forbidden" <"$tracked" | grep -q .; then
    echo "FAIL: public tree contains forbidden private or legacy text: $forbidden" >&2
    exit 1
  fi
done

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' .github/workflows/ci.yml
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' .github/workflows/release.yml
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' .github/dependabot.yml

if grep -R -q 'pull_request_target' .github/workflows; then
  echo 'FAIL: workflows must not use pull_request_target' >&2
  exit 1
fi
grep -Fq 'permissions:' .github/workflows/ci.yml
grep -Fq 'contents: read' .github/workflows/ci.yml
grep -Fq 'make clean && make verify && make clean' .github/workflows/ci.yml

echo 'PASS: open-source-readiness'
