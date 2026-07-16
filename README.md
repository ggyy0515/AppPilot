# AppPilot

[English](#readme-english) | [中文](#readme-中文)

<a id="readme-english"></a>

## English

AppPilot is a Debug-only iOS development and diagnostics loop. The `ap-ios-debug` CLI talks to an explicitly integrated App through `APIOSDebugKit`, while `ap-ios-debug-skill` gives Codex a safe, repeatable operating sequence. Source is hosted at [github.com/ggyy0515/AppPilot](https://github.com/ggyy0515/AppPilot) under the Apache-2.0 license.

### What AppPilot can do

- discover, resolve, and readiness-check paired physical iOS devices;
- probe an opted-in Debug App over paired USB or loopback TCP;
- list and activate developer-registered semantic actions;
- read an App-provided Codable state snapshot;
- capture the foreground App window as PNG;
- record, download, checksum, and clean up short ReplayKit MP4 captures;
- emit stable JSON response envelopes and error codes for agent orchestration.

### Current limits

- AppPilot does not expose arbitrary coordinates, selectors, scripts, taps, swipes, or text entry. Register semantic actions or use project-owned XCUITest automation.
- Recording produces a finalized MP4; it is not a live video stream.
- AppPilot has no native continuous App log command. Use Xcode, devicectl launch output, and project logging until a structured log bridge is added.
- Build, signing, installation, and launch remain project-specific. The included real-device smoke workflow demonstrates the complete path for the demo App.
- The CLI can technically send activation for any currently registered, enabled action, including one with the `destructive` role. Immediate user approval for a destructive action is an operator policy enforced by `ap-ios-debug-skill` and the agent workflow, not by a CLI authorization mechanism.

### Install

```bash
set -euo pipefail
git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git
cd AppPilot
make verify
make install-local
command -v ap-ios-debug
```

AppPilot 0.1.0 is a source-only release. Building from the tagged repository is the supported installation path because the CLI, Swift Debug Kit, Codex skill, Demo, and installation checks must stay on the same version. AppPilot does not distribute unsigned prebuilt macOS binaries.

The installation transaction owns `~/.local/bin/ap-ios-debug`, `~/.local/share/ap-ios-debug/ap-ios-debug-kit`, and `~/.codex/skills/ap-ios-debug-skill`. During `make install-local`, it also retires exactly the three predecessor global destinations enumerated in `scripts/local-install.sh`; it does not search for or delete project data. Add `~/.local/bin` to `PATH` if `command -v ap-ios-debug` is empty. Remove the current installed copies with `make uninstall-local`.

### Prerequisites

- a current Go toolchain available on `PATH`;
- a current Xcode selected by `xcode-select`;
- `ripgrep` (`rg`) available on `PATH`, as required by the validation scripts (for example, installed with Homebrew);
- an unlocked, trusted physical device with Developer Mode enabled;
- a valid Development Team and provisioning setup for the target App;
- one explicitly selected device when several devices are connected;
- `APIOSDebugKit` linked only to a dedicated Debug App target.

### Quick start

Preview and apply the project-local scaffold:

```bash
set -euo pipefail
ap-ios-debug app scaffold --into "$PWD" --dry-run
ap-ios-debug app scaffold --into "$PWD"
```

Follow [App integration](docs/integration.md), [protocol v1](docs/protocol.md), and [troubleshooting](docs/troubleshooting.md). Scaffolding does not edit the Xcode project: finish the documented Xcode integration, then use the project's own commands to build and sign the dedicated Debug target, install it on the exact device, and launch it. The App must be running before doctor or probe can succeed.

Resolve one exact device name into a temporary JSON file, extract the selected identifier locally, and only then address the running Debug App:

```bash
set -euo pipefail
DEVICE_NAME='My iPhone'
DEVICE_JSON="$(mktemp)"
trap 'rm -f "$DEVICE_JSON"' EXIT

ap-ios-debug --json devices list
ap-ios-debug --json devices resolve --name "$DEVICE_NAME" >"$DEVICE_JSON"
DEVICE_ID="$(plutil -extract meta.device_id raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(plutil -extract data.device.udid raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
fi
test -n "$DEVICE_ID"
rm -f "$DEVICE_JSON"
trap - EXIT

ap-ios-debug --json doctor --device "$DEVICE_ID"
ap-ios-debug --json app probe --device "$DEVICE_ID"
ap-ios-debug --json actions list --device "$DEVICE_ID"
ap-ios-debug --json state get --device "$DEVICE_ID"
```

Never guess a device. Controlled local stdout, including the demo-specific `make device-smoke` output, may display the selected `device_id` so the current command can address the device. Never copy that identifier into chat, a shared or persistent report, a persistent log, or any non-temporary file.

### Agent-assisted development loop

For an integrated real App, Codex can follow this evidence loop:

1. implement the requested feature and run focused tests;
2. build and sign the Debug target;
3. install and launch it on the explicitly selected device;
4. run doctor, probe the App, and refresh the current action list;
5. inspect state and capture a screenshot before mutation;
6. dry-run the selected semantic action; if real activation is needed, let the operator policy and `ap-ios-debug-skill` govern authorization and execution, then capture state and a screenshot again;
7. correlate visual evidence with tests and available build, launch, and App logs;
8. fix, rebuild, and repeat until the acceptance criteria are supported by evidence.

### Observe and operate

Create a unique evidence directory, save the current action response in a mode-0600 temporary file, and capture before-state evidence:

```bash
set -euo pipefail
test -n "${DEVICE_ID:-}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR=".ap-ios-debug/artifacts/$RUN_ID"
mkdir -p .ap-ios-debug/artifacts
mkdir "$ARTIFACT_DIR"

ACTIONS_JSON="$(mktemp)"
DRY_RUN_JSON="$(mktemp)"
trap 'rm -f "$ACTIONS_JSON" "$DRY_RUN_JSON"' EXIT
ap-ios-debug --json actions list --device "$DEVICE_ID" >"$ACTIONS_JSON"
plutil -p "$ACTIONS_JSON"
ap-ios-debug --json state get --device "$DEVICE_ID"
ap-ios-debug --json screenshot capture --device "$DEVICE_ID" \
  --out "$ARTIFACT_DIR/before.png"
```

Inspect `ACTIONS_JSON` locally and choose one exact enabled identifier from that current response; never select the first action automatically. The next block is inspection-only: replace the identifier placeholder with that exact value, save the dry-run response in the mode-0600 `DRY_RUN_JSON` temporary file, parse `data.action.role`, and report that role. Dry-run and activation are separate, non-atomic requests, so the registered Action or its role can change between them. The CLI accepts no expected role or Action generation and provides no technical authorization check. For those reasons, this generic copyable block executes no real Action; operator policy and `ap-ios-debug-skill` manage any actual activation after a fresh action-list and dry-run review.

```bash
ACTION_ID='<exact-enabled-identifier-from-current-actions-response>'
[[ "$ACTION_ID" != '<exact-enabled-identifier-from-current-actions-response>' ]]

ap-ios-debug --json actions activate "$ACTION_ID" --device "$DEVICE_ID" --dry-run >"$DRY_RUN_JSON"
ROLE="$(plutil -extract data.action.role raw -o - "$DRY_RUN_JSON")"
test -n "$ROLE"
printf 'Dry-run role: %s. This generic block does not activate actions.\n' "$ROLE"
rm -f "$ACTIONS_JSON" "$DRY_RUN_JSON"
trap - EXIT
```

Use a short recording in the same unique run directory only when motion or timing matters:

```bash
set -euo pipefail
test -n "${DEVICE_ID:-}"
test -n "${ARTIFACT_DIR:-}"
OUT="$ARTIFACT_DIR/motion.mp4"
STATUS_JSON="$(mktemp)"
cleanup_intent=false
cleanup_recording() {
  local cleanup_exit_status=$?
  local cleanup_attempt=0
  local cleanup_state=''
  if "$cleanup_intent"; then
    while [[ "$cleanup_attempt" -lt 65 ]]; do
      cleanup_attempt=$((cleanup_attempt + 1))
      cleanup_state=''
      if ap-ios-debug --json recording status --device "$DEVICE_ID" >"$STATUS_JSON"; then
        cleanup_state="$(plutil -extract data.state raw -o - "$STATUS_JSON" 2>/dev/null || true)"
      fi
      case "$cleanup_state" in
        idle|failed|ready)
          break
          ;;
        recording)
          if ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT"; then
            break
          fi
          ;;
        starting|stopping)
          # Starting cannot be stopped; poll through the runtime's 60-second permission timeout.
          ;;
        *)
          # Status failed or was unknown: attempt stop, then poll again.
          ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT" || true
          ;;
      esac
      sleep 1 || true
    done
  fi
  rm -f "$STATUS_JSON" || true
  return "$cleanup_exit_status"
}
trap cleanup_recording EXIT
ap-ios-debug --json recording status --device "$DEVICE_ID" >"$STATUS_JSON"
INITIAL_STATE="$(plutil -extract data.state raw -o - "$STATUS_JSON")"
test "$INITIAL_STATE" = idle
cleanup_intent=true
ap-ios-debug --json recording start --device "$DEVICE_ID"
# Perform only the short sequence for which video adds diagnostic value.
ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT"
cleanup_intent=false
rm -f "$STATUS_JSON"
trap - EXIT
test -s "$OUT"
```

### Real-device verification

The physical-device smoke flow is a demo-specific sample. It builds, signs, installs, launches, probes, activates a demo action, verifies state, and captures PNG/MP4 evidence. Its recording cleanup is armed only after `recording start` returns successfully. If start partially succeeds but the CLI reports failure, the script cannot guarantee a normal stop or download. On exit it still makes a best-effort attempt to terminate the App process it launched and deletes host-side temporary data, but its internally generated random token is not retained after the run. Treat that run's video evidence as failed or incomplete. Before retrying, confirm on the device that the recording indicator has disappeared; if it remains abnormal, restart the Debug App and rerun the flow. The script does not uninstall the demo App from the device. The flow is opt-in and requires an exact device name and the Development Team configured in Xcode:

```bash
AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1 \
AP_IOS_DEBUG_DEVICE='My iPhone' \
AP_IOS_DEBUG_DEVELOPMENT_TEAM='TEAM_ID_FROM_XCODE' \
make device-smoke
```

### Safety boundary

Release contains no server. The listener is loopback-only, USB uses the paired Mac boundary, and raw writes plus arbitrary selectors, coordinates, and scripts are unavailable. The high-level CLI can still activate registered actions. Under the operator policy, a current `destructive` action requires explicit user approval immediately before activation; `ap-ios-debug-skill` and the agent workflow enforce that policy, not the CLI. `AP_IOS_DEBUG_TOKEN` is the only token source and must never be printed or committed.

Controlled local device discovery, resolution, and demo `device-smoke` stdout may display the selected `device_id`. Never copy that identifier into chat, a shared or persistent report, a persistent log, or any non-temporary file. Never expose pairing data, bearer values, token values, or unrelated App payloads.

Screenshots and recordings are sensitive mode-0600 artifacts. The manual flow above stores them below its unique run directory in `.ap-ios-debug/artifacts`; CLI commands with an explicit `--out` and repository smoke workflows may use other explicit paths. Keep evidence local and report when it is created. A Simulator pass is never evidence of a physical-device pass.

### Verification

```bash
make clean && make verify && make clean
```

`make verify` runs naming and documentation gates, Go/Swift tests, both App configurations, scaffold checks, Simulator E2E, Release scans, skill validation, and isolated install smoke. `make device-smoke` prints `SKIP` unless explicitly enabled.

<a id="readme-中文"></a>

## 中文

AppPilot 是一个仅用于 Debug 构建的 iOS 开发与诊断闭环。`ap-ios-debug` CLI 通过显式集成的 `APIOSDebugKit` 与 App 通信，`ap-ios-debug-skill` 则为 Codex 提供安全、可重复的操作顺序。源代码托管于 [github.com/ggyy0515/AppPilot](https://github.com/ggyy0515/AppPilot)，采用 Apache-2.0 许可证。

### AppPilot 当前能力

- 发现、解析并检查已配对的 iOS 真机状态；
- 通过配对 USB 或本机回环 TCP 探测已接入的 Debug App；
- 列出并执行开发者注册的语义 Action；
- 读取 App 提供的 Codable 状态快照；
- 将前台 App 窗口截取为 PNG；
- 录制、下载、校验并清理短时 ReplayKit MP4；
- 输出稳定的 JSON 响应封装和错误码，便于代理编排。

### 当前限制

- AppPilot 不提供任意坐标、选择器、脚本、点击、滑动或文字输入。此类操作应注册为语义 Action，或使用项目自有的 XCUITest。
- 录屏会在结束后生成 MP4，并非实时视频流。
- 当前没有持续抓取 App 日志的原生命令；结构化日志桥完成前，使用 Xcode、devicectl 启动输出和项目日志。
- 构建、签名、安装和启动方式与具体工程相关；仓库中的真机 smoke 展示了 Demo App 的完整链路。
- CLI 在技术上可以向任何当前已注册且启用的 Action 发送执行请求，包括 role 为 `destructive` 的 Action。`destructive` Action 的即时用户授权是由 `ap-ios-debug-skill` 与代理操作流程执行的操作者策略，并非 CLI 的授权机制。

### 安装

```bash
set -euo pipefail
git clone --branch v0.1.0 --depth 1 https://github.com/ggyy0515/AppPilot.git
cd AppPilot
make verify
make install-local
command -v ap-ios-debug
```

AppPilot 0.1.0 仅以源码形式发布。受支持的安装方式是从对应 tag 的仓库源码构建，因为 CLI、Swift Debug Kit、Codex skill、Demo 和安装检查必须保持同一版本。AppPilot 不分发未经签名的预构建 macOS 二进制文件。

安装事务管理当前的 `~/.local/bin/ap-ios-debug`、`~/.local/share/ap-ios-debug/ap-ios-debug-kit` 和 `~/.codex/skills/ap-ios-debug-skill`。执行 `make install-local` 时，它还会精确退役 `scripts/local-install.sh` 中列出的三个前代全局目标路径；不会搜索或删除项目数据。若找不到命令，请将 `~/.local/bin` 加入 `PATH`；使用 `make uninstall-local` 移除当前安装副本。

### 前置条件

- 当前 Go 工具链已在 `PATH` 中可用；
- 已通过 `xcode-select` 选择当前 Xcode；
- 验证脚本所需的 `ripgrep`（`rg`）已在 `PATH` 中可用（例如通过 Homebrew 安装）；
- 真机已解锁、信任当前 Mac 并开启开发者模式；
- 目标 App 具备有效的 Development Team 与描述文件；
- 连接多台设备时必须明确选择唯一目标；
- `APIOSDebugKit` 只能链接到独立的 Debug App target。

### 快速开始

先预览并应用项目内 scaffold：

```bash
set -euo pipefail
ap-ios-debug app scaffold --into "$PWD" --dry-run
ap-ios-debug app scaffold --into "$PWD"
```

继续阅读 [App 接入](docs/integration.md)、[v1 协议](docs/protocol.md) 与 [故障排查](docs/troubleshooting.md)。Scaffold 不会编辑 Xcode 工程：必须按接入文档完成 Xcode 配置，再用项目自身的命令构建并签名独立 Debug target，将其安装到准确选择的设备并启动。App 运行后，doctor 与 probe 才可能成功。

将准确设备名称解析到临时 JSON 文件，仅在本地提取选中设备标识符，然后再访问运行中的 Debug App：

```bash
set -euo pipefail
DEVICE_NAME='My iPhone'
DEVICE_JSON="$(mktemp)"
trap 'rm -f "$DEVICE_JSON"' EXIT

ap-ios-debug --json devices list
ap-ios-debug --json devices resolve --name "$DEVICE_NAME" >"$DEVICE_JSON"
DEVICE_ID="$(plutil -extract meta.device_id raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(plutil -extract data.device.udid raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
fi
test -n "$DEVICE_ID"
rm -f "$DEVICE_JSON"
trap - EXIT

ap-ios-debug --json doctor --device "$DEVICE_ID"
ap-ios-debug --json app probe --device "$DEVICE_ID"
ap-ios-debug --json actions list --device "$DEVICE_ID"
ap-ios-debug --json state get --device "$DEVICE_ID"
```

不得猜测设备。受控的本地标准输出（包括 Demo 专用的 `make device-smoke` 输出）可以显示选中的 `device_id`，供当前命令访问设备；但不得将该标识符复制到聊天、共享或持久化报告、持久化日志或任何非临时文件中。

### 代理辅助开发闭环

真实 App 完成接入后，Codex 可以按以下证据链工作：

1. 实现需求并运行针对性测试；
2. 构建并签名 Debug target；
3. 安装到明确选择的真机并启动；
4. 运行 doctor、探测 App，并刷新当前 Action 列表；
5. 操作前读取状态并截图；
6. 对选中的语义 Action 执行 dry-run；若确需真实执行，由操作者策略与 `ap-ios-debug-skill` 管理授权和执行，再次采集状态和截图；
7. 将视觉证据与测试、构建、启动及可用 App 日志结合分析；
8. 修复、重建并重复验证，直到验收条件得到证据支持。

### 页面观察与操作

创建唯一证据目录，将当前 Action 响应保存到权限为 0600 的临时文件，并采集操作前的状态证据：

```bash
set -euo pipefail
test -n "${DEVICE_ID:-}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR=".ap-ios-debug/artifacts/$RUN_ID"
mkdir -p .ap-ios-debug/artifacts
mkdir "$ARTIFACT_DIR"

ACTIONS_JSON="$(mktemp)"
DRY_RUN_JSON="$(mktemp)"
trap 'rm -f "$ACTIONS_JSON" "$DRY_RUN_JSON"' EXIT
ap-ios-debug --json actions list --device "$DEVICE_ID" >"$ACTIONS_JSON"
plutil -p "$ACTIONS_JSON"
ap-ios-debug --json state get --device "$DEVICE_ID"
ap-ios-debug --json screenshot capture --device "$DEVICE_ID" \
  --out "$ARTIFACT_DIR/before.png"
```

在本地检查 `ACTIONS_JSON`，从当前响应中选择一个准确且已启用的 identifier；不得自动选择第一个 Action。下一段仅用于检查：必须用该准确值替换 identifier 占位符，将 dry-run 响应写入权限为 0600 的临时文件 `DRY_RUN_JSON`，解析 `data.action.role` 并报告该 role。Dry-run 与真实执行是两个非原子请求，其间已注册 Action 或 role 可能变化；CLI 不接收预期 role 或 Action generation，也不提供技术层面的授权检查。因此，这个可复制的通用代码块不会真实执行任何 Action；刷新 Action 列表并重新审查 dry-run 后，任何真实执行均由操作者策略与 `ap-ios-debug-skill` 管理。

```bash
ACTION_ID='<exact-enabled-identifier-from-current-actions-response>'
[[ "$ACTION_ID" != '<exact-enabled-identifier-from-current-actions-response>' ]]

ap-ios-debug --json actions activate "$ACTION_ID" --device "$DEVICE_ID" --dry-run >"$DRY_RUN_JSON"
ROLE="$(plutil -extract data.action.role raw -o - "$DRY_RUN_JSON")"
test -n "$ROLE"
printf 'Dry-run role：%s。此通用代码块不会执行任何 Action。\n' "$ROLE"
rm -f "$ACTIONS_JSON" "$DRY_RUN_JSON"
trap - EXIT
```

只有在动画或时序确实需要时，才在同一个唯一运行目录中使用短录屏：

```bash
set -euo pipefail
test -n "${DEVICE_ID:-}"
test -n "${ARTIFACT_DIR:-}"
OUT="$ARTIFACT_DIR/motion.mp4"
STATUS_JSON="$(mktemp)"
cleanup_intent=false
cleanup_recording() {
  local cleanup_exit_status=$?
  local cleanup_attempt=0
  local cleanup_state=''
  if "$cleanup_intent"; then
    while [[ "$cleanup_attempt" -lt 65 ]]; do
      cleanup_attempt=$((cleanup_attempt + 1))
      cleanup_state=''
      if ap-ios-debug --json recording status --device "$DEVICE_ID" >"$STATUS_JSON"; then
        cleanup_state="$(plutil -extract data.state raw -o - "$STATUS_JSON" 2>/dev/null || true)"
      fi
      case "$cleanup_state" in
        idle|failed|ready)
          break
          ;;
        recording)
          if ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT"; then
            break
          fi
          ;;
        starting|stopping)
          # starting 状态无法停止；轮询覆盖 runtime 的 60 秒权限超时。
          ;;
        *)
          # status 查询失败或状态未知：尝试停止，然后继续轮询。
          ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT" || true
          ;;
      esac
      sleep 1 || true
    done
  fi
  rm -f "$STATUS_JSON" || true
  return "$cleanup_exit_status"
}
trap cleanup_recording EXIT
ap-ios-debug --json recording status --device "$DEVICE_ID" >"$STATUS_JSON"
INITIAL_STATE="$(plutil -extract data.state raw -o - "$STATUS_JSON")"
test "$INITIAL_STATE" = idle
cleanup_intent=true
ap-ios-debug --json recording start --device "$DEVICE_ID"
# 只执行确实需要用视频诊断的短操作序列。
ap-ios-debug --json recording stop --device "$DEVICE_ID" --out "$OUT"
cleanup_intent=false
rm -f "$STATUS_JSON"
trap - EXIT
test -s "$OUT"
```

### 真机验证

真机 smoke 是面向 Demo 的样例流程。它会完成构建、签名、安装、启动、探测、执行 Demo Action、状态检查及 PNG/MP4 证据采集。只有 `recording start` 成功返回后，脚本才会启用录屏清理；若 start 已部分成功但 CLI 报错，脚本无法保证正常停止或下载。退出时，脚本仍会尽力终止自身启动的 App 进程并删除主机临时数据，但内部随机生成的 token 不会在该次运行结束后保留。因此，该次运行的视频证据必须视为失败或不完整。重试前，应在设备上确认录屏指示已消失；若仍异常，请重新启动 Debug App 并重新运行该流程。脚本不会从设备卸载 Demo App。该流程必须显式启用，并提供准确的设备名称与 Xcode 中配置的 Development Team：

```bash
AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1 \
AP_IOS_DEBUG_DEVICE='My iPhone' \
AP_IOS_DEBUG_DEVELOPMENT_TEAM='TEAM_ID_FROM_XCODE' \
make device-smoke
```

### 安全边界

Release 不包含调试服务。监听器仅绑定回环地址，USB 依赖已配对 Mac 的信任边界；不提供原始写请求或任意选择器、坐标与脚本。高级 CLI 命令仍可执行已注册 Action。按照操作者策略，当前 role 为 `destructive` 的 Action 必须在执行前立即取得用户明确授权；该策略由 `ap-ios-debug-skill` 与代理操作流程执行，并非 CLI 强制。`AP_IOS_DEBUG_TOKEN` 是唯一令牌来源，严禁打印或提交。

受控的本地设备发现、解析以及 Demo `device-smoke` 标准输出可以显示选中的 `device_id`。不得将该标识符复制到聊天、共享或持久化报告、持久化日志或任何非临时文件中；也不得暴露配对数据、Bearer 值、令牌值或无关 App 数据。

截图与录屏是权限为 0600 的敏感产物。上方手动流程将它们存放在 `.ap-ios-debug/artifacts` 下的唯一运行目录中；带显式 `--out` 的 CLI 命令及仓库 smoke 流程可以使用其他明确路径。证据必须保留在本地并在创建时报告。Simulator 通过不能被描述为真机通过。

### 验证

```bash
make clean && make verify && make clean
```

`make verify` 会运行命名与文档门禁、Go/Swift 测试、两种 App 配置、scaffold、Simulator E2E、Release 扫描、Skill 校验和隔离安装 smoke。`make device-smoke` 默认输出 `SKIP`，只有显式启用后才运行真机流程。
