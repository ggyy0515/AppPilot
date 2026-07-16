# AppPilot 0.1.0 Source Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish AppPilot 0.1.0 from `github.com/ggyy0515/AppPilot` as a verified source-only GitHub Release.

**Architecture:** Keep the repository as the single distributable unit and remove unsigned binary packaging from the release workflow. Use one reusable verification job for manual dry runs and tag releases, a tag-gated least-privilege publish job, repository rulesets for immutable release inputs, and a clean-clone source installation test before tagging.

**Tech Stack:** GitHub Actions YAML, Bash, Make, Git, GitHub CLI, Go, Swift, Xcode

---

## File map

- `.github/workflows/release.yml`: manual dry-run and tag-driven source Release automation.
- `scripts/tests/open-source-readiness-test.sh`: executable contract for source-only release policy and documentation.
- `README.md`: supported tagged-source installation instructions in English and Chinese.
- `docs/releasing.md`: maintainer runbook for dry run, visibility, clean clone, tagging, and post-release verification.
- `CHANGELOG.md`: final dated 0.1.0 release notes.
- GitHub repository settings: metadata, security features, branch ruleset, and tag ruleset.

### Task 1: Specify the source-only release contract

**Files:**
- Modify: `scripts/tests/open-source-readiness-test.sh`
- Test: `scripts/tests/open-source-readiness-test.sh`

- [ ] **Step 1: Add failing workflow assertions**

Add these assertions before the final PASS line:

```bash
release_workflow=.github/workflows/release.yml
grep -Fq 'workflow_dispatch:' "$release_workflow"
grep -Fq 'github.event_name == '\''push'\''' "$release_workflow"
grep -Fq 'gh release create "$GITHUB_REF_NAME"' "$release_workflow"

if grep -Eq 'Build release archives|GOARCH=|dist/|SHA256SUMS' "$release_workflow"; then
  echo 'FAIL: source-only release workflow still packages binaries' >&2
  exit 1
fi
```

- [ ] **Step 2: Add failing documentation assertions**

Add these exact checks:

```bash
grep -Fq 'git clone --branch v0.1.0 --depth 1' README.md
grep -Fq 'source-only' README.md
grep -Fq 'workflow_dispatch' docs/releasing.md
grep -Fq 'clean temporary directory' docs/releasing.md
```

- [ ] **Step 3: Run the focused test and confirm RED**

Run:

```bash
./scripts/tests/open-source-readiness-test.sh
```

Expected: FAIL because `release.yml` has no `workflow_dispatch` trigger and still contains `Build release archives`.

- [ ] **Step 4: Commit the failing contract with the implementation**

Do not commit the red test alone. Keep it unstaged until Tasks 2 and 3 make it pass.

### Task 2: Convert release automation to source-only

**Files:**
- Modify: `.github/workflows/release.yml`
- Test: `scripts/tests/open-source-readiness-test.sh`

- [ ] **Step 1: Replace workflow triggers and top-level permissions**

Use this header:

```yaml
name: Release

on:
  workflow_dispatch:
  push:
    tags:
      - "v[0-9]+.[0-9]+.[0-9]+"

permissions:
  contents: read
```

- [ ] **Step 2: Rename the existing job to verification and remove packaging**

Keep checkout, Go setup, and the complete gate. Gate tag validation so manual runs do not require a tag:

```yaml
jobs:
  verify:
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - name: Check out source
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6
        with:
          fetch-depth: 0
      - name: Set up Go
        uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16 # v6
        with:
          go-version: 1.26.2
          cache-dependency-path: cli/go.sum
      - name: Validate release tag
        if: github.event_name == 'push'
        run: |
          version="${GITHUB_REF_NAME#v}"
          [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
          git tag --points-at HEAD | grep -Fxq "$GITHUB_REF_NAME"
      - name: Verify
        run: make clean && make verify && make clean
```

Delete the binary archive and checksum step completely.

- [ ] **Step 3: Add the least-privilege publish job**

Append this job:

```yaml
  publish:
    if: github.event_name == 'push'
    needs: verify
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Publish source release
        env:
          GH_TOKEN: ${{ github.token }}
        run: >-
          gh release create "$GITHUB_REF_NAME"
          --repo "$GITHUB_REPOSITORY"
          --verify-tag
          --generate-notes
          --title "AppPilot $GITHUB_REF_NAME"
```

- [ ] **Step 4: Run the readiness test and confirm the workflow half is GREEN**

Run:

```bash
./scripts/tests/open-source-readiness-test.sh
```

Expected: it progresses past workflow checks and fails on the still-missing README source-only text.

### Task 3: Document tagged-source installation

**Files:**
- Modify: `README.md`
- Modify: `docs/releasing.md`
- Test: `scripts/tests/open-source-readiness-test.sh`
- Test: `scripts/check-docs.sh`

- [ ] **Step 1: Replace both README clone commands**

Use the tagged source in both English and Chinese installation blocks:

```bash
git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git
cd AppPilot
make verify
make install-local
command -v ap-ios-debug
```

- [ ] **Step 2: Add the English source-only policy**

Immediately after the English installation block, add:

```markdown
AppPilot 0.1.0 is a source-only release. Building from the tagged repository is
the supported installation path because the CLI, Swift Debug Kit, Codex skill,
Demo, and installation checks are versioned together. No unsigned prebuilt
macOS binaries are distributed.
```

- [ ] **Step 3: Add the equivalent Chinese source-only policy**

Immediately after the Chinese installation block, add:

```markdown
AppPilot 0.1.0 仅以源码形式发布。推荐从对应标签构建，因为 CLI、Swift Debug
Kit、Codex skill、Demo 与安装检查需要保持同一版本；项目不分发未经签名的
macOS 预编译二进制文件。
```

- [ ] **Step 4: Rewrite the maintainer release runbook**

Make `docs/releasing.md` cover these exact commands and gates:

```bash
make clean && make verify && make clean
git status --short
git tag -a v0.1.0 -m 'AppPilot v0.1.0.'
git push origin v0.1.0
```

Document that the Actions `Release` workflow is first run with
`workflow_dispatch`, that it creates no Release on a manual run, and that a
fresh public installation is tested in a clean temporary directory:

```bash
tmp="$(mktemp -d)"
git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git "$tmp/AppPilot"
make -C "$tmp/AppPilot" clean
make -C "$tmp/AppPilot" verify
make -C "$tmp/AppPilot" clean
rm -rf "$tmp"
```

State that a released tag is immutable; a release failure is corrected with a
new patch version rather than moving the existing tag.

- [ ] **Step 5: Run focused documentation checks and confirm GREEN**

Run:

```bash
./scripts/tests/open-source-readiness-test.sh
./scripts/tests/check-docs-test.sh
./scripts/check-docs.sh
```

Expected: all three commands print PASS.

- [ ] **Step 6: Commit release policy changes**

Run:

```bash
git add .github/workflows/release.yml README.md docs/releasing.md scripts/tests/open-source-readiness-test.sh
git diff --cached --check
git commit -m '+ Add source release workflow.'
```

### Task 4: Provision and protect the GitHub repository

**Files:**
- External: `github.com/ggyy0515/AppPilot`
- Local Git metadata: `origin`

- [ ] **Step 1: Confirm GitHub CLI prerequisites**

Run:

```bash
gh --version
gh auth status
```

Expected: `gh` is installed and authenticated as `ggyy0515`. If either check
fails, stop and ask the user to install or authenticate GitHub CLI as required
by the publishing workflow.

- [ ] **Step 2: Create the private repository without initializing content**

Run:

```bash
gh repo create ggyy0515/AppPilot --private --description 'Debug-only iOS development and diagnostics loop for agents and developers.'
git remote add origin https://github.com/ggyy0515/AppPilot.git
```

Expected: the empty private repository exists and `git remote get-url origin`
prints the canonical HTTPS URL.

- [ ] **Step 3: Push the rewritten main history**

Run:

```bash
git push -u origin main
```

Expected: `main` is created at the current local HEAD without introducing any
unrelated remote history.

- [ ] **Step 4: Configure repository metadata**

Run:

```bash
gh repo edit ggyy0515/AppPilot \
  --description 'Debug-only iOS development and diagnostics loop for agents and developers.' \
  --add-topic ios \
  --add-topic ios-development \
  --add-topic swift \
  --add-topic golang \
  --add-topic codex \
  --enable-issues=true
```

Expected: GitHub recognizes the Apache-2.0 license from `LICENSE` and displays
the description and topics.

- [ ] **Step 5: Enable security features available to the repository**

Use repository Settings to enable private vulnerability reporting, Dependabot
alerts, Dependabot security updates, secret scanning, and push protection.
Confirm `.github/dependabot.yml` is accepted after the first default-branch
push.

- [ ] **Step 6: Create the main branch ruleset after the first CI run**

Target the default branch and enable:

- require a pull request before merging;
- require the `verify` status check from the `CI` workflow;
- block force pushes;
- block branch deletion.

Do not require signed commits because the rewritten historical commits are not
signed.

- [ ] **Step 7: Create the version tag ruleset**

Target tags matching `v*` and restrict updates and deletions. Leave tag
creation available to the repository owner so `v0.1.0` can be published.

### Task 5: Exercise GitHub automation and public source installation

**Files:**
- External: GitHub Actions and repository visibility
- Local: clean temporary clone outside the workspace

- [ ] **Step 1: Wait for the pushed main CI run**

Run:

```bash
gh run list --repo ggyy0515/AppPilot --workflow CI --limit 1
gh run watch --repo ggyy0515/AppPilot --exit-status "$(gh run list --repo ggyy0515/AppPilot --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: the `CI / verify` check completes successfully.

- [ ] **Step 2: Run the manual source release dry run**

Run:

```bash
gh workflow run Release --repo ggyy0515/AppPilot --ref main
run_id="$(gh run list --repo ggyy0515/AppPilot --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch --repo ggyy0515/AppPilot --exit-status "$run_id"
```

Expected: verification passes and no GitHub Release is created.

- [ ] **Step 3: Change repository visibility to public**

Run:

```bash
gh repo edit ggyy0515/AppPilot --visibility public --accept-visibility-change-consequences
```

Expected: `https://github.com/ggyy0515/AppPilot` is publicly readable.

- [ ] **Step 4: Verify a clean public clone before tagging**

Run:

```bash
tmp="$(mktemp -d)"
git clone --depth 1 https://github.com/ggyy0515/AppPilot.git "$tmp/AppPilot"
make -C "$tmp/AppPilot" clean
make -C "$tmp/AppPilot" verify
make -C "$tmp/AppPilot" clean
rm -rf "$tmp"
```

Expected: the complete gate passes without using files or configuration from
the original workspace.

### Task 6: Finalize and publish 0.1.0

**Files:**
- Modify: `CHANGELOG.md`
- Test: complete local and GitHub gates
- External: protected `v0.1.0` tag and GitHub Release

- [ ] **Step 1: Write the final dated changelog section**

Keep an empty `Unreleased` heading and replace the planned section with:

```markdown
## Unreleased

## 0.1.0 - 2026-07-16

### Added

- Debug-only iOS runtime integration through `APIOSDebugKit`.
- Stable JSON CLI for device discovery, readiness checks, semantic actions,
  state snapshots, screenshots, and short ReplayKit recordings.
- Paired USB and loopback TCP transports with explicit safety boundaries.
- Codex operating skill, Demo targets, integration documentation, and
  verification scripts.
- Apache-2.0 licensing, community policies, GitHub CI, dependency updates,
  issue templates, and source Release automation.

### Changed

- Go module path to `github.com/ggyy0515/AppPilot`.
- Demo bundle identifiers to the `com.ggyy` namespace.

### Distribution

- AppPilot 0.1.0 is source-only and does not include unsigned prebuilt macOS
  binaries.
```

- [ ] **Step 2: Run the final local gate**

Run:

```bash
make clean && make verify && make clean
git status --short
```

Expected: `PASS: make verify`; only the intended changelog change is present.

- [ ] **Step 3: Commit and push the changelog**

Run:

```bash
git add CHANGELOG.md
git diff --cached --check
git commit -m '+ AppPilot 0.1.0 release.'
git push origin main
```

- [ ] **Step 4: Wait for final GitHub CI**

Run:

```bash
run_id="$(gh run list --repo ggyy0515/AppPilot --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch --repo ggyy0515/AppPilot --exit-status "$run_id"
```

Expected: the CI run for the release commit passes.

- [ ] **Step 5: Create and push the annotated release tag**

Run:

```bash
git tag -a v0.1.0 -m 'AppPilot v0.1.0.'
git push origin v0.1.0
```

Expected: the protected tag is created exactly once from the CI-green release
commit.

- [ ] **Step 6: Verify the Release and source-only policy**

Run:

```bash
gh release view v0.1.0 --repo ggyy0515/AppPilot --json tagName,targetCommitish,url,assets
```

Expected: the Release exists for `v0.1.0`, points to the expected commit, and
has no uploaded binary assets. GitHub's standard source archives remain
available on the Release page.

- [ ] **Step 7: Run the documented tagged-source installation check**

Run:

```bash
tmp="$(mktemp -d)"
git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git "$tmp/AppPilot"
make -C "$tmp/AppPilot" clean
make -C "$tmp/AppPilot" verify
make -C "$tmp/AppPilot" clean
rm -rf "$tmp"
```

Expected: the exact public release source passes the complete gate.
