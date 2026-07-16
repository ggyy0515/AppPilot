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

validate_go_module_floor() {
  local module="$1"
  local floor="$2"
  local metadata
  if ! metadata="$(cd cli && GOWORK=off go list -m -json "$module")"; then
    echo "FAIL: cannot resolve $module metadata for the AppPilot 0.1.0 security floor" >&2
    exit 1
  fi

  ruby -r json -r rubygems -e '
    module_path = ARGV.fetch(0)
    floor_text = ARGV.fetch(1)

    def fail_floor(message)
      warn "FAIL: #{message}"
      exit 1
    end

    begin
      metadata = JSON.parse(STDIN.read)
    rescue JSON::ParserError => error
      fail_floor("cannot parse #{module_path} metadata for the AppPilot 0.1.0 security floor: #{error.message}")
    end
    fail_floor("invalid #{module_path} metadata for the AppPilot 0.1.0 security floor") unless metadata.is_a?(Hash)
    fail_floor("resolved module metadata does not identify #{module_path} for the AppPilot 0.1.0 security floor") unless metadata["Path"] == module_path

    version_text = metadata["Version"]
    unless version_text.is_a?(String) && !version_text.empty?
      fail_floor("#{module_path} metadata is missing Version for the AppPilot 0.1.0 security floor")
    end
    unless metadata["Replace"].nil?
      fail_floor("the AppPilot 0.1.0 security floor does not allow module replacement for #{module_path}")
    end

    begin
      version = Gem::Version.new(version_text.delete_prefix("v"))
      floor = Gem::Version.new(floor_text.delete_prefix("v"))
    rescue ArgumentError => error
      fail_floor("cannot compare #{module_path} version for the AppPilot 0.1.0 security floor: #{error.message}")
    end
    if version < floor
      fail_floor("#{module_path} #{version_text} is below the AppPilot 0.1.0 security floor #{floor_text}")
    end
  ' "$module" "$floor" <<<"$metadata"
}

validate_go_module_floor golang.org/x/crypto v0.52.0
validate_go_module_floor golang.org/x/net v0.55.0

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

ruby <<'RUBY'
require 'yaml'

def assert_contract(condition, message)
  return if condition

  warn "FAIL: #{message}"
  exit 1
end

def assert_ripgrep_install_before_verify(steps, workflow_name)
  install_indices = steps.each_index.select { |index| steps[index]['name'] == 'Install ripgrep' }
  verify_indices = steps.each_index.select { |index| steps[index]['name'] == 'Verify' }
  assert_contract(
    install_indices.length == 1 && steps.fetch(install_indices.fetch(0))['run'] == 'brew install ripgrep',
    "#{workflow_name} workflow must install ripgrep with the exact Homebrew command"
  )
  assert_contract(
    verify_indices.length == 1 && install_indices.fetch(0) < verify_indices.fetch(0),
    "#{workflow_name} workflow must install ripgrep before Verify"
  )
end

ci_workflow = YAML.load_file('.github/workflows/ci.yml')
ci_jobs = ci_workflow['jobs']
ci_verify_job = ci_jobs.is_a?(Hash) ? ci_jobs['verify'] : nil
assert_contract(ci_verify_job.is_a?(Hash), 'CI workflow is missing the verify job')
ci_verify_steps = ci_verify_job['steps']
assert_contract(ci_verify_steps.is_a?(Array), 'CI verify steps must be a list')
assert_contract(ci_verify_steps.all? { |step| step.is_a?(Hash) }, 'CI verify steps must be mappings')
assert_ripgrep_install_before_verify(ci_verify_steps, 'CI')

workflow_path = '.github/workflows/release.yml'
workflow_source = File.read(workflow_path)
workflow = YAML.load_file(workflow_path)
triggers = workflow['on'] || workflow[true]
assert_contract(triggers.is_a?(Hash), 'release workflow triggers must be a mapping')
assert_contract(
  triggers.key?('workflow_dispatch') && triggers['workflow_dispatch'].nil?,
  'release workflow must have an empty workflow_dispatch trigger'
)
push = triggers['push']
assert_contract(
  push.is_a?(Hash) && push['tags'] == ['v[0-9]+.[0-9]+.[0-9]+'],
  'release workflow must trigger on semantic version tags'
)
assert_contract(
  workflow['permissions'].is_a?(Hash) && workflow['permissions']['contents'] == 'read',
  'release workflow top-level contents permission must be read'
)

jobs = workflow['jobs']
verify_job = jobs.is_a?(Hash) ? jobs['verify'] : nil
assert_contract(verify_job.is_a?(Hash), 'release workflow is missing the verify job')
verify_steps = verify_job['steps']
assert_contract(verify_steps.is_a?(Array), 'release verify steps must be a list')
assert_contract(verify_steps.all? { |step| step.is_a?(Hash) }, 'release verify steps must be mappings')
assert_contract(
  verify_steps.map { |step| step['name'] } == ['Check out source', 'Set up Go', 'Install ripgrep', 'Validate release tag', 'Verify'],
  'release verify job must contain only checkout, Go setup, ripgrep install, tag validation, and verification'
)
checkout_step, setup_go_step = verify_steps
assert_contract(
  checkout_step['uses'] == 'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10' &&
    checkout_step['with'].is_a?(Hash) && checkout_step['with']['fetch-depth'] == 0,
  'release checkout step must stay pinned and fetch tags'
)
assert_contract(
  setup_go_step['uses'] == 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' &&
    setup_go_step['with'].is_a?(Hash) && setup_go_step['with']['go-version'] == '1.26.2' &&
    setup_go_step['with']['cache-dependency-path'] == 'cli/go.sum',
  'release Go setup step must stay pinned to Go 1.26.2'
)
assert_ripgrep_install_before_verify(verify_steps, 'release')
validate_steps = verify_steps.select { |step| step['name'] == 'Validate release tag' }
assert_contract(validate_steps.length == 1, 'release workflow must have one Validate release tag step')
validate_step = validate_steps.fetch(0)
assert_contract(
  validate_step['if'] == "github.event_name == 'push'",
  'release tag validation must run only for tag pushes'
)
validate_lines = validate_step['run'].to_s.lines.map(&:strip)
strict_tag_check = '[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]'
assert_contract(
  validate_lines == [
    'version="${GITHUB_REF_NAME#v}"',
    strict_tag_check,
    'git tag --points-at HEAD | grep -Fxq "$GITHUB_REF_NAME"'
  ],
  'release tag validation must strictly validate the version and tag target'
)
gate_steps = verify_steps.select { |step| step['name'] == 'Verify' }
assert_contract(
  gate_steps.length == 1 && gate_steps.fetch(0)['run'].to_s.strip == 'make clean && make verify && make clean',
  'release verify step must run the complete gate'
)

publish_job = jobs['publish']
assert_contract(publish_job.is_a?(Hash), 'release workflow is missing the publish job')
assert_contract(
  publish_job['if'] == "github.event_name == 'push'",
  'release publish job must run only for tag pushes'
)
assert_contract(publish_job['needs'] == 'verify', 'release publish job must need verify')
assert_contract(
  publish_job['permissions'].is_a?(Hash) && publish_job['permissions']['contents'] == 'write',
  'release publish job contents permission must be write'
)
publish_steps = publish_job['steps']
assert_contract(publish_steps.is_a?(Array), 'release publish steps must be a list')
assert_contract(publish_steps.all? { |step| step.is_a?(Hash) }, 'release publish steps must be mappings')
assert_contract(
  publish_steps.length == 1 && publish_steps.none? { |step| step.key?('uses') },
  'release publish job must contain only the source release command and use no actions'
)
source_release_steps = publish_steps.select { |step| step['name'] == 'Publish source release' }
assert_contract(
  source_release_steps.length == 1,
  'release publish job must have one Publish source release step'
)
source_release_step = source_release_steps.fetch(0)
assert_contract(
  source_release_step['env'].is_a?(Hash) && source_release_step['env']['GH_TOKEN'] == '${{ github.token }}',
  'source release GH_TOKEN must use github.token'
)
expected_release_command = 'gh release create "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --verify-tag --generate-notes --title "AppPilot $GITHUB_REF_NAME"'
actual_release_command = source_release_step['run'].to_s.split.join(' ')
assert_contract(
  actual_release_command == expected_release_command,
  'source release command must not upload binary attachments or accept extra arguments'
)
assert_contract(
  !workflow_source.match?(/Build release archives|GOARCH=|dist\/|SHA256SUMS|actions\/upload-artifact|gh release upload|\.tar\.gz/),
  'source-only workflow still packages binaries'
)

readme = File.read('README.md')
english_anchor = '<a id="readme-english"></a>'
chinese_anchor = '<a id="readme-中文"></a>'
english_start = readme.index(english_anchor)
chinese_start = readme.index(chinese_anchor)
assert_contract(
  readme.scan(english_anchor).length == 1 && readme.scan(chinese_anchor).length == 1 &&
    english_start && chinese_start && english_start < chinese_start,
  'README language anchors are missing or out of order'
)
english = readme[english_start...chinese_start]
chinese = readme[chinese_start..]
english_prerequisites = english[/^### Prerequisites\s*$\n(.*?)(?=^### )/m, 1]
chinese_prerequisites = chinese[/^### 前置条件\s*$\n(.*?)(?=^### )/m, 1]
assert_contract(
  english_prerequisites&.match?(/ripgrep.*`rg`.*`PATH`/i),
  'English prerequisites must require ripgrep (rg) on PATH'
)
assert_contract(
  chinese_prerequisites&.match?(/ripgrep.*`rg`.*`PATH`/i),
  'Chinese prerequisites must require ripgrep (rg) on PATH'
)
tagged_clone = 'git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git'
assert_contract(readme.scan(tagged_clone).length == 2, 'README must contain exactly two tagged clone commands')
assert_contract(english.scan(tagged_clone).length == 1, 'English install must use the tagged clone command')
assert_contract(chinese.scan(tagged_clone).length == 1, 'Chinese install must use the tagged clone command')
assert_contract(english.include?('source-only'), 'English README must describe the source-only release')
assert_contract(chinese.include?('仅以源码形式发布'), 'Chinese README must describe the source-only release')
RUBY

failed=0
if ! grep -Fq 'workflow_dispatch' docs/releasing.md; then
  echo 'FAIL: release guide does not document the manual workflow dry run' >&2
  failed=1
fi
if ! grep -Fq 'clean temporary directory' docs/releasing.md; then
  echo 'FAIL: release guide does not require a clean temporary directory' >&2
  failed=1
fi
((failed == 0)) || exit 1

echo 'PASS: open-source-readiness'
