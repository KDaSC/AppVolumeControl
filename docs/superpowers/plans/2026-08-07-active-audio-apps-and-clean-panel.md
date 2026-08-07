# 通用活跃音频应用与精简面板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 自动识别所有能由公开 Core Audio 进程接口观察到、当前正在输出音频的用户应用，去掉抖音专用识别分支，让无原生音量接口的应用统一使用 Process Tap 输出增益，并把默认目标固定为 75%，同时精简和动态收缩面板。

**Architecture:** 将“发现应用”“判断控制方式”“保存 75% 默认策略”“Process Tap 生命周期”和“面板展示”分开。发现层只根据 `kAudioProcessPropertyIsRunningOutput` 产生当前活跃应用；原生 AppleScript 适配器优先，其余应用统一进入公开 Process Tap 增益路径；面板只消费已分组的活跃应用，不保留抖音白名单或手动刷新入口。

**Tech Stack:** Swift 6、AppKit、SwiftUI、Core Audio HAL、`CATapDescription` / Process Tap、UserDefaults、macOS 14.2+。

## Global Constraints

- 不使用私有 API，不修改系统总音量。
- 不伪造应用内部音量；Process Tap 数值必须明确表示“输出增益”。
- 只显示 `IsRunningOutput == true` 且能归属到用户可见主应用的音频进程。
- 浏览器只能控制整个浏览器应用，不能伪装成标签页级音量。
- 默认目标和吸附基准固定为 75%；既有抖音旧默认 100% 需要一次性迁移到 75%。
- 不主动播放抖音或浏览器声音；验证只读取已有进程与 Core Audio 状态。
- 首次启动不自动弹窗；面板关闭后停止 UI 刷新。
- 当前目录不是 Git 仓库，所以任务检查点使用文件 diff、测试和构建结果，不写虚假的 commit 步骤。

---

## 当前证据

1. `CoreAudioSupport.audioProcesses()` 已能读取 PID 和 `IsRunningOutput`，但 `applyDiscovery` 先把所有 Core Audio 客户端加入 `hosts`，所以没有输出的应用仍可能显示。
2. `alwaysRecognizedMediaApps` 强制把抖音加入列表，即使抖音没有输出；这与“无声音不显示”直接冲突。
3. `monitorProcessTap()` 和 `tapEngine` 只服务 `com.bytedance.douyin.desktop`，通用发现与通用控制被抖音特例割裂。
4. 当前偏好数据是：Music 基准 `75%`，抖音基准 `100%`，抖音 Process Tap 增益 `100%`。
5. `storedProcessTapGain` 缺省为 `1.0`，`loadOrCreateBaseline` 又把首次读到的当前值当基准，因此代码本身没有保证 75%。
6. 当前包是 ad-hoc 签名，指定要求为当前二进制的 `cdhash`，没有 Team ID，也没有可用代码签名身份。每次构建会改变 `cdhash`，此前授予的系统音频捕获权限不能稳定沿用。
7. Apple 的公开 Process Tap 自 macOS 14.2 可用；当前 SDK 在 macOS 26 还提供 `CATapDescription.bundleIDs` 和 `isProcessRestoreEnabled`，可以减少 Electron 辅助进程 PID 变化导致的断连。

## 可选方案比较

### A. 继续维护应用专用适配器

- 优点：能读取 Music、Spotify 等应用真正的内部音量，资源最低。
- 缺点：每个应用都要单独适配，抖音、浏览器和未来应用会不断出现缺口。
- 结论：保留为优先控制方式，但不能继续作为发现全部音频应用的主体。

### B. Core Audio 活跃进程发现 + 通用 Process Tap（推荐）

- 优点：全部使用公开 API；能发现所有 HAL 可见的活跃输出进程；对没有原生接口的应用提供真实进程输出增益；不改变系统总音量。
- 缺点：数值是输出增益而非应用内部音量；需要系统音频权限和稳定代码签名；浏览器只能按整个应用控制。
- 结论：作为最终架构，原生适配器优先，其余应用落到通用 Process Tap。

### C. 虚拟音频设备或驱动扩展

- 优点：可以构建更完整的音频路由和混音系统。
- 缺点：安装、签名、权限、升级兼容和维护成本最高；仅凭虚拟默认输出设备仍不能天然知道混音前每个进程的来源。
- 结论：当前目标不需要驱动，不采用。

## 第一轮方案

1. 只保留 `IsRunningOutput == true` 的应用。
2. 删除抖音白名单，把所有无 AppleScript 适配器的活跃应用交给 Process Tap。
3. 把所有缺省值和基准线改为 75%。
4. 删除副标题和刷新按钮，面板高度随应用数量变化。
5. 继续用当前 1.5 秒发现轮询和 2.5 秒 tap 监控。

## 第一轮潜在问题与 Bug 审查

第一轮不能直接实施，发现以下问题：

1. **权限会再次失效。** 只改权限文案没有意义；ad-hoc 签名每次重建都会产生新 `cdhash`。
2. **“正在输出”不等于样本一定非零。** `IsRunningOutput` 表示存在活跃输出流；少数应用可能持续输出静音缓冲区。若为所有应用建立电平 tap 才能判断非零样本，会显著增加权限和资源成本。
3. **Electron/浏览器音频 PID 不是主进程。** 只按 PID 查 `NSRunningApplication` 会得到 Helper，必须沿父进程、Core Audio bundle ID 和 `.app` 路径归并。
4. **一个全局 tap 不能提供多个应用的独立增益。** 把多个应用混进一个 stereo tap 后无法再区分各自样本。
5. **一个应用可能有多个音频辅助进程。** tap 目标必须按主应用分组，并在 PID 集合变化时稳定更新；对象 ID 需要排序，避免仅顺序变化导致反复重建。
6. **旧偏好不会自动变成 75%。** 只改 `?? 1` 为 `?? 0.75` 不会处理已经保存的抖音 `1.0`。
7. **原生音量和输出增益语义不同。** Music 的 75% 是应用内部音量；抖音的 75% 是乘在内部音量后的增益，UI 不能用同一文案冒充同一数据。
8. **应用刚暂停时行可能闪烁。** 立即删除行会在短暂停顿或切歌时频繁跳动，需要很短的退出宽限，但不能让闲置应用长期保留。
9. **动态高度会影响面板定位。** 高度变化后必须重新按菜单栏锚点计算 frame，否则顶部位置或底部内容会跳动。
10. **重复权限按钮会让列表变乱。** 如果多个通用应用都需要 tap，不应每行放一个授权按钮。
11. **后台自动尝试会重复弹权限或空转。** 未授权时不能每 1 秒为每个活跃应用重建 tap；一次失败后必须等待用户操作或应用重新启动。
12. **测试 target 不能导入 executable target。** 分组和 tap 决策的纯逻辑必须放入 `AppVolumeControlCore`，具体的 AppKit/Core Audio 读取留在 executable target。

## 修订后的最终方案

### 1. 展示语义

- “有声音的应用”在实现上定义为：Core Audio 进程对象的 `IsRunningOutput == true`。
- 只显示可归属到 `.regular` 主应用的进程；`coreaudiod`、WindowServer、系统提示音服务和无法归属的守护进程不显示。
- `IsRunningOutput` 变为 false 后保留 0.8 秒，再删除该行；这只用于防切歌闪烁，不再保留抖音白名单。
- 浏览器辅助进程归并成 Safari、Chrome、Edge 等浏览器一行；不会显示或控制单独标签页。

### 2. 统一控制选择

```swift
enum VolumeControlKind: Equatable {
    case nativeVolume
    case processGain
    case unavailable
}
```

- Music、Spotify、VLC、QuickTime 继续使用现有公开 AppleScript 接口，显示真实内部音量。
- 其他具有 bundle ID 和 Core Audio 输出对象的用户应用统一使用 Process Tap，抖音不再是特例。
- 每个活跃应用拥有独立的 `ProcessTapEngine`，以保证增益互不影响；应用停止输出后立即销毁对应 tap 和私有聚合设备。
- macOS 26+ 优先用 `CATapDescription.bundleIDs` 和 `isProcessRestoreEnabled = true`；macOS 14.2–25 使用排序后的进程对象 ID。
- 已有稳定权限时，活跃的 Process Tap 应用自动应用保存的增益；没有权限时只记录 `.permissionRequired`，等用户在面板里点击一次全局授权按钮后再尝试，不在后台循环弹窗。
- tap 创建失败时保留应用行，滑杆显示保存的目标值但禁用；全局提示明确写“75% 尚未生效”，不把目标值冒充已应用值。
- 同一应用一次启动中出现权限或创建失败后不自动重试；只在用户点击重试、目标进程集合实际变化或应用重新启动时重试。

### 3. 75% 默认策略

```swift
public enum VolumePolicy {
    public static let defaultLevel = 0.75
    public static let settingsSchemaVersion = 2
}
```

- 滑杆基准线固定为 75%，吸附范围继续使用前后 3%。
- 删除“将当前音量设为基准”和基准值持久化；固定基准能减少状态和右键菜单复杂度。
- Process Tap 应用没有历史设置时，真实输出增益从 75% 启动。
- 一次性迁移规则：旧 schema 下抖音增益为 `nil` 或精确等于旧默认 `1.0` 时改为 `0.75`；其他用户主动设置过的数值保留。
- 旧 `baselineVolume.*` 不再参与运行逻辑，迁移完成后删除这些旧键。
- 原生应用仍显示它自己的真实当前音量，不在每次播放时强制改写；75% 是统一默认目标和吸附基准。这样不会在用户打开 Music 时突然改掉 Music 自己保存的音量。
- 在原生音量尚未读回时禁用滑杆并显示 `—`，不使用 75% 或 100% 伪装成已读取值。

### 4. 权限与稳定签名

- `NSAudioCaptureUsageDescription` 保留。
- `build-app.sh` 增加稳定签名身份参数，例如 `APP_VOLUME_SIGNING_IDENTITY`；正式交付构建不能再静默回退到 ad-hoc 签名。
- 当前 Keychain 没有代码签名身份。实施前需要二选一：
  1. 推荐：通过 Xcode/Apple ID 创建稳定的 Apple Development 身份。
  2. 仅本机使用：经用户明确批准后创建并信任一个本地自签名 Code Signing 证书。
- 构建后用 `codesign -d -r-` 检查指定要求必须由稳定证书和 bundle identifier 构成，不能只剩 `cdhash`。
- 权限状态以 Process Tap 实际启动结果为主；系统音频捕获不使用 `CGPreflightScreenCaptureAccess()` 预检，因为它针对屏幕录制且会错误阻断 Tap 启动。
- 如果系统要求重启应用，面板只显示一条“音频权限已更改，重新打开应用后生效”，不循环请求权限。

### 5. 精简面板

- 保留单行标题“应用音量”。
- 删除“只显示各应用音量，不显示系统总音量”。
- 删除手动刷新按钮；列表由自动发现刷新。
- 每行固定为：`22pt 图标 + 应用名 + 可选“增益”小标签 + 110pt 滑杆 + 百分比`。
- 原生音量不显示标签；Process Tap 行在名称后显示灰色“增益”，避免把数值误认为应用内部音量。
- 只有全局权限或 tap 故障时才出现一条紧凑提示栏。
- 空状态改成一行“当前没有应用输出声音”，去掉大图标。
- “退出”保留在底部右侧，避免无 Dock 菜单栏应用失去明显退出入口。
- 内容宽度保持 360pt，NSPanel 总宽度保持 392pt，避免重新引入横向定位问题。
- 高度规则：空状态约 116pt；1–6 行按每行 40pt 动态增长；超过 6 行固定最大高度并启用滚动。
- 面板高度变化后调用现有 `PanelGeometry.frame` 重新定位，顶部继续贴菜单栏下沿。

### 6. 刷新与资源策略

- 保留面板打开期间的低成本轮询，周期从 1.5 秒调整为 1.0 秒；移除手动刷新入口。
- 轮询只获取 Core Audio 进程对象、PID、bundle ID 和 `IsRunningOutput`；集合无变化时不重建 SwiftUI 列表。
- 面板关闭后停止 UI 轮询；Process Tap 管理器只监控当前存在的增益会话。
- 每个停止输出的应用在 0.8 秒宽限后销毁 tap；没有活跃增益应用时不保留 IO 回调或聚合设备。
- 不新增第三方依赖或虚拟音频驱动。

## 第二轮问题审查

- 权限持久性：由稳定签名解决，并有构建时验证。
- 抖音特例：删除，改成通用 bundle/PID 归并。
- 闲置应用显示：只从 running-output 集合建模，并有有限 0.8 秒宽限。
- 75% 旧数据：有 schema 迁移，不依赖缺省值替换。
- 多应用独立增益：每应用独立 tap，不混流后再猜来源。
- 多辅助进程：按主应用分组，目标 ID 排序；macOS 26 使用 bundle restore。
- UI 重复状态：权限错误集中显示，行内只保留短标签。
- 动态尺寸：高度更新后复用已有定位函数。
- 资源泄漏：每个会话有明确 stop 条件，退出时 stopAll。
- 权限重试：失败状态有闸门，不随发现轮询重复创建 tap。
- 测试边界：纯策略位于 Core target，测试不依赖 executable target。
- 仍存在的平台边界：`IsRunningOutput` 无法证明样本绝对非零，浏览器无法区分标签页。这是公开 API 的能力边界，不是未处理的实现 Bug。

第二轮未发现需要重写架构的问题，可以进入实施任务。

---

### Task 1: 固化默认策略和旧设置迁移

**Files:**
- Create: `Sources/AppVolumeControlCore/VolumePolicy.swift`
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift`
- Modify: `Sources/AppVolumeControl/main.swift`

**Interfaces:**
- Produces: `VolumePolicy.defaultLevel`, `VolumePolicy.settingsSchemaVersion`, `VolumePolicy.migratedProcessGain(stored:previousSchemaVersion:)`。

- [x] **Step 1: 写失败测试**

```swift
expect(VolumePolicy.defaultLevel == 0.75, "all default targets must be 75%")
expect(
    VolumePolicy.migratedProcessGain(stored: 1, previousSchemaVersion: 1) == 0.75,
    "the legacy 100% Douyin default must migrate to 75%"
)
expect(
    VolumePolicy.migratedProcessGain(stored: 0.62, previousSchemaVersion: 1) == 0.62,
    "an explicit user gain must survive migration"
)
```

- [x] **Step 2: 运行测试并确认因为 `VolumePolicy` 不存在而失败**

Run: `swift run AppVolumeControlTests`

- [x] **Step 3: 实现最小纯逻辑**

```swift
public enum VolumePolicy {
    public static let defaultLevel = 0.75
    public static let settingsSchemaVersion = 2

    public static func migratedProcessGain(
        stored: Double?,
        previousSchemaVersion: Int
    ) -> Double {
        if previousSchemaVersion < settingsSchemaVersion,
           stored == nil || stored == 1 {
            return defaultLevel
        }
        return min(max(stored ?? defaultLevel, 0), 1)
    }
}
```

- [x] **Step 4: 在 ViewModel 初始化时迁移一次，固定 baseline 为 0.75，并删除可变 baseline 菜单和旧运行路径**

- [x] **Step 5: 运行 `swift run AppVolumeControlTests`，确认通过**

### Task 2: 只发现当前输出的应用并可靠归并 Helper

**Files:**
- Create: `Sources/AppVolumeControlCore/ActiveAudioGrouping.swift`
- Create: `Sources/AppVolumeControl/AudioApplicationDiscovery.swift`
- Modify: `Sources/AppVolumeControl/main.swift`
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift`

**Interfaces:**
- Core produces: `ActiveAudioGrouping.visibleProcessIDs(from:)` and `ActiveAudioGrouping.sortedObjectIDs(_:)`。
- Executable produces: `AudioProcessSnapshot`、`ApplicationOwnerResolver`、`ActiveAudioApplicationGroup`。
- Each group contains: stable bundle ID, main PID, icon/name source, sorted process object IDs, latest running-output state.

- [x] **Step 1: 写分组规则失败测试**

```swift
expect(
    ActiveAudioGrouping.visibleProcessIDs(from: [
        .init(pid: 10, isRunningOutput: false),
        .init(pid: 20, isRunningOutput: true)
    ]) == [20],
    "idle audio clients must not be displayed"
)
expect(
    ActiveAudioGrouping.sortedObjectIDs([9, 3, 9]) == [3, 9],
    "tap targets must be unique and stable"
)
```

- [x] **Step 2: 运行测试并确认因新分组 API 缺失而失败**

Run: `swift run AppVolumeControlTests`

- [x] **Step 3: 扩展 Core Audio 快照，读取 `AudioObjectID`、PID、bundle ID 和 `IsRunningOutput`**

- [x] **Step 4: 实现所有者解析顺序**

```text
regular NSRunningApplication for PID
→ parent PID chain to regular application
→ Core Audio bundle ID matched to a regular running application
→ executable path outer .app bundle matched by bundle identifier
→ unresolved system process is omitted
```

- [x] **Step 5: 删除 `alwaysRecognizedMediaApps`、`douyinBundleID` 发现特例和从全部 audioProcessIDs 建 hosts 的逻辑**

- [ ] **Step 6: 加入 0.8 秒 inactive grace，并确保最终列表只含 active groups**

- [x] **Step 7: 运行测试和只读 Core Audio 探针；确认当前快照只保留 `IsRunningOutput == 1`，本次没有主动播放抖音声音**

### Task 3: 把 Process Tap 从抖音补丁改为通用增益管理器

**Files:**
- Create: `Sources/AppVolumeControlCore/ProcessGainPlan.swift`
- Create: `Sources/AppVolumeControl/ProcessGainManager.swift`
- Modify: `Sources/AppVolumeControlCore/ProcessTapEngine.swift`
- Modify: `Sources/AppVolumeControl/main.swift`
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift`

**Interfaces:**
- Core produces: `ProcessGainPlan.shouldRun(isOutputActive:gain:)`。
- Executable/Core Audio produces: `ProcessTapTarget`, `ProcessTapState`, `ProcessGainManager.reconcile(activeApps:gains:)`, `state(for:)`, `stopAll()`。

- [x] **Step 1: 写协调器状态测试，覆盖开始、对象 ID 变化、停止和应用间隔离**

```swift
expect(ProcessGainPlan.shouldRun(isOutputActive: true, gain: 0.75))
expect(!ProcessGainPlan.shouldRun(isOutputActive: false, gain: 0.75))
expect(!ProcessGainPlan.shouldRun(isOutputActive: true, gain: 1.0))
```

- [x] **Step 2: 运行测试并观察预期失败**

Run: `swift run AppVolumeControlTests`

- [ ] **Step 3: 将引擎入口改为通用 target**

```swift
public enum ProcessTapTarget: Equatable, Sendable {
    case bundleID(String)
    case processObjectIDs([AudioObjectID])
}
```

- [ ] **Step 4: macOS 26+ 用 bundle ID 和 process restore；旧系统用排序后的 process object IDs**

- [x] **Step 5: 用每个活跃应用 PID 独立管理 `ProcessTapEngine`，删除单一 `tapEngine`、`tappedProcessObjectIDs` 和抖音专用 monitor**

- [x] **Step 6: 加入失败重试闸门；权限缺失或创建失败后等待用户重试或目标集合变化，不随轮询重复创建**

- [x] **Step 7: 应用停止输出、增益回到 100%、切换输出设备或应用退出时销毁对应会话；应用退出时 `stopAll()`**

- [x] **Step 8: 运行测试和严格 release build**

Run: `swift build -c release -Xswiftc -warnings-as-errors`

### Task 4: 修复权限持久性和权限状态表达

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `Sources/AppVolumeControlCore/ProcessTapEngine.swift`
- Modify: `Sources/AppVolumeControl/main.swift`
- Modify: `README.md`

**Interfaces:**
- Build input: `APP_VOLUME_SIGNING_IDENTITY`。
- Runtime state: `.idle`, `.starting`, `.active`, `.permissionRequired`, `.failed(OSStatus)`。

- [ ] **Step 1: 在任何 Keychain 修改前停下，向用户确认 Apple Development 或本地自签名证书方案**

- [x] **Step 2: 支持 `APP_VOLUME_SIGNING_IDENTITY`；未提供时使用 ad-hoc 并打印权限会重置的警告**

- [x] **Step 3: 把 tap 实际启动状态回传到 UI；保留数值 OSStatus 供诊断，不把所有失败都叫“未授权”**

- [x] **Step 4: 权限提示集中成一条，授权按钮不在后台循环请求**

- [ ] **Step 5: 构建后验证签名身份稳定**

Run: `codesign -d -r- outputs/AppVolumeControl.app`

Expected: designated requirement contains stable certificate/anchor plus `identifier "com.codex.app-volume-control"`; it must not be only `cdhash H"..."`.

### Task 5: 精简面板并动态调整高度

**Files:**
- Modify: `Sources/AppVolumeControl/main.swift`
- Modify: `Sources/AppVolumeControlCore/PanelGeometry.swift`
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift`

**Interfaces:**
- Produces: `PanelLayout.height(applicationCount:showsPermissionNotice:)` and `PanelCoordinator.updateContentHeight(_:)`。

- [ ] **Step 1: 写高度失败测试**

```swift
expect(PanelLayout.height(applicationCount: 0, showsPermissionNotice: false) == 116)
expect(PanelLayout.height(applicationCount: 1, showsPermissionNotice: false) < 180)
expect(
    PanelLayout.height(applicationCount: 10, showsPermissionNotice: false)
        == PanelLayout.maximumHeight,
    "long lists must scroll instead of growing off-screen"
)
```

- [ ] **Step 2: 运行测试并确认新布局 API 缺失导致失败**

Run: `swift run AppVolumeControlTests`

- [x] **Step 3: 删除副标题、刷新按钮、大空状态图标和 baseline 右键菜单**

- [x] **Step 4: 实现单行紧凑 row、Process Tap“增益”短标签、全局权限提示和 6 行以上滚动**

- [x] **Step 5: 面板高度变化后重新调用 `PanelGeometry.frame`，保持顶部锚定**

- [ ] **Step 6: 运行布局测试，并在单屏、多屏、Hidden Bar 下检查 0/1/6/10 行状态**

### Task 6: 端到端验证与交付

**Files:**
- Modify: `README.md`
- Output: `outputs/AppVolumeControl.app`

- [x] **Step 1: 运行全部指定命令**

```sh
cd /Users/liudongkun/Documents/Codex/2026-08-03/new-chat
swift run AppVolumeControlTests
swift build -c release -Xswiftc -warnings-as-errors
./scripts/build-app.sh
```

- [x] **Step 2: 验证首次启动不弹窗、签名严格校验通过、当前没有持久 osascript/tap 子进程**

- [ ] **Step 3: 在不主动播放声音的前提下读取当前 Core Audio 状态；已有输出的抖音/浏览器应出现，停止输出 0.8 秒后应消失**

- [x] **Step 4: 验证旧 100% 抖音默认迁移为 75%，schema 为 2；用户手动设置的非 100% 增益保留逻辑通过测试**

- [ ] **Step 5: 验证两个同时输出的无原生接口应用拥有独立 gain session，调整一个不改变另一个或系统总音量**

- [x] **Step 6: 记录资源证据**

```sh
ps -o pid,%cpu,rss,etime,command -p "$(pgrep -f '/AppVolumeControl.app/Contents/MacOS/AppVolumeControl' | head -1)"
```

Acceptance: menu closed and no active tap 时 CPU 接近空闲；一个 active tap 时无持续异常增长；关闭音频应用后 RSS 不继续增长且对应 aggregate/tap 被销毁。

- [ ] **Step 7: 最终复查用户要求**

```text
通用发现：是
抖音专用补丁：已删除
稳定权限：签名证据通过
默认和基准：75%
闲置应用：不显示
副标题：已删除
刷新图标：已删除
窗口：紧凑且动态高度
不播放抖音测试：遵守
```
