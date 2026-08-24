# Session Volume and Mute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep each active Process Tap application's session gain stable across discovery refreshes, add reversible per-app mute, unify automatic and explicit attachment UI state, and publish the verified result as GitHub pre-release v0.7.0.

**Architecture:** Put state decisions in small pure types in `AppVolumeControlCore`, then have the existing `VolumeViewModel` apply them to CoreAudio and AppleScript. Keep session identity and mute restore values in memory, keyed by PID but verified against bundle ID; reuse the existing audio paths without new dependencies, timers, drivers, or permissions.

**Tech Stack:** Swift 6, SwiftUI, AppKit, CoreAudio Process Tap, Foundation `Process`, zsh packaging, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-08-24-session-volume-and-mute-design.md`

## Global Constraints

- Work only in `.worktrees/session-volume-mute` on `codex/session-volume-mute`, based on current `origin/main`.
- Keep automatic attachment and per-app memory off by default; clean-install gain and slider baseline remain 75%.
- Never present Process Tap gain as an app, player, or browser-tab internal volume.
- Do not create a Tap unless explicitly armed or the user enabled automatic attachment.
- Add no dependencies, virtual drivers, DSP, EQ, routing, network services, timers, or permissions.
- Do not deliberately start media playback; use existing safe active output if available and report any unverified sound path honestly.
- Run SwiftPM commands serially with `-j 1`.
- Preserve the root checkout's untracked `docs/AI_AGENT_HANDOFF_2026-08-19.md`; never stage it.
- The user explicitly authorized push, PR merge, and GitHub publication after every required verification passes.
- Publish `v0.7.0`, app `0.7.0`, Build `8`, as a pre-release because it remains ad-hoc signed and not notarized.

---

### Task 1: Pure session and mute policy

**Files:**
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift:50-157`
- Modify: `Sources/AppVolumeControlCore/VolumePolicy.swift:1-15`

**Interfaces:**
- Produces: `SessionIdentity`, `GainWriteIntent`, `MuteTransition`, and pure `VolumePolicy` functions used by Tasks 3-4.
- Preserves: `defaultLevel`, `settingsSchemaVersion`, and `migratedProcessGain`.

- [ ] **Step 1: Write failing behavior tests**

Add literal assertions after the existing `VolumeSettings.resolvedGain` assertion:

```swift
let firstSession = SessionIdentity(processID: 42, bundleIdentifier: "com.example.first")
let replacementSession = SessionIdentity(processID: 42, bundleIdentifier: "com.example.replacement")

expect(
    VolumePolicy.sessionGain(
        existingGain: 0.42,
        previousIdentity: firstSession,
        identity: firstSession,
        initialGain: 0.75
    ) == 0.42,
    "同一应用会话的当前增益不能被刷新覆盖"
)
expect(
    VolumePolicy.sessionGain(
        existingGain: 0.42,
        previousIdentity: firstSession,
        identity: replacementSession,
        initialGain: 0.60
    ) == 0.60,
    "相同 PID 的不同 bundle 不能继承旧会话增益"
)
expect(VolumePolicy.fallbackGain(candidates: [0, 0.50]) == 0.50, "恢复必须尊重非静音候选")
expect(VolumePolicy.fallbackGain(candidates: [0, 0]) == 0.75, "全零候选必须回到 75%")

let muteFromFortyTwo = VolumePolicy.toggleMute(
    currentGain: 0.42,
    restoreGain: nil,
    fallbackGain: 0.75
)
expect(muteFromFortyTwo.targetGain == 0, "42% 静音目标必须是 0%")
expect(muteFromFortyTwo.nextRestoreGain == 0.42, "静音必须记录 42%")
expect(muteFromFortyTwo.restoreGain(afterWriteSucceeded: false) == nil, "失败不能遗留恢复值")

let restoreToFortyTwo = VolumePolicy.toggleMute(
    currentGain: 0,
    restoreGain: 0.42,
    fallbackGain: 0.75
)
expect(restoreToFortyTwo.targetGain == 0.42, "恢复必须回到 42%")
expect(restoreToFortyTwo.nextRestoreGain == nil, "成功恢复后必须清除恢复值")
expect(restoreToFortyTwo.restoreGain(afterWriteSucceeded: false) == 0.42, "失败必须保留恢复值")

let restoreWithoutHistory = VolumePolicy.toggleMute(
    currentGain: 0,
    restoreGain: nil,
    fallbackGain: 0.50
)
expect(restoreWithoutHistory.targetGain == 0.50, "没有记录时必须使用回退值")
expect(VolumePolicy.isMuted(0.000_1), "阈值本身必须视为静音")
expect(!VolumePolicy.isMuted(0.000_11), "阈值以上必须视为非静音")
expect(VolumePolicy.shouldPersist(gain: 0.42, intent: .sliderCommit), "非零滑杆值可记忆")
expect(!VolumePolicy.shouldPersist(gain: 0, intent: .sliderCommit), "滑到 0% 不能覆盖记忆")
expect(!VolumePolicy.shouldPersist(gain: 0.42, intent: .temporaryMute), "按钮恢复不能改写记忆")
```

- [ ] **Step 2: Verify RED**

Run `swift run -j 1 AppVolumeControlTests`.

Expected: compilation fails because the new policy types and functions do not exist.

- [ ] **Step 3: Add the minimum pure implementation**

Add above `VolumePolicy`:

```swift
public struct SessionIdentity: Equatable, Sendable {
    public let processID: Int32
    public let bundleIdentifier: String

    public init(processID: Int32, bundleIdentifier: String) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum GainWriteIntent: Equatable, Sendable {
    case sliderCommit
    case temporaryMute
}

public struct MuteTransition: Equatable, Sendable {
    public let targetGain: Double
    public let previousRestoreGain: Double?
    public let nextRestoreGain: Double?

    public init(
        targetGain: Double,
        previousRestoreGain: Double?,
        nextRestoreGain: Double?
    ) {
        self.targetGain = targetGain
        self.previousRestoreGain = previousRestoreGain
        self.nextRestoreGain = nextRestoreGain
    }

    public func restoreGain(afterWriteSucceeded succeeded: Bool) -> Double? {
        succeeded ? nextRestoreGain : previousRestoreGain
    }
}
```

Add to `VolumePolicy`:

```swift
public static let muteThreshold = 0.000_1

public static func clamped(_ gain: Double) -> Double { min(max(gain, 0), 1) }
public static func isMuted(_ gain: Double) -> Bool { clamped(gain) <= muteThreshold }

public static func sessionGain(
    existingGain: Double?,
    previousIdentity: SessionIdentity?,
    identity: SessionIdentity,
    initialGain: Double
) -> Double {
    guard previousIdentity == identity, let existingGain else { return clamped(initialGain) }
    return clamped(existingGain)
}

public static func fallbackGain(candidates: [Double]) -> Double {
    for candidate in candidates {
        let gain = clamped(candidate)
        if !isMuted(gain) { return gain }
    }
    return defaultLevel
}

public static func toggleMute(
    currentGain: Double,
    restoreGain: Double?,
    fallbackGain: Double
) -> MuteTransition {
    let currentGain = clamped(currentGain)
    let restoreGain = restoreGain.map(clamped)
    if !isMuted(currentGain) {
        return MuteTransition(
            targetGain: 0,
            previousRestoreGain: restoreGain,
            nextRestoreGain: currentGain
        )
    }
    let target = restoreGain.flatMap { isMuted($0) ? nil : $0 } ?? clamped(fallbackGain)
    return MuteTransition(
        targetGain: target,
        previousRestoreGain: restoreGain,
        nextRestoreGain: nil
    )
}

public static func shouldPersist(gain: Double, intent: GainWriteIntent) -> Bool {
    intent == .sliderCommit && !isMuted(gain)
}
```

- [ ] **Step 4: Verify GREEN and commit**

```sh
swift run -j 1 AppVolumeControlTests
git add Sources/AppVolumeControlCore/VolumePolicy.swift Tests/AppVolumeControlTests/BaselineSnapperTests.swift
git commit -m "Add session gain and mute policy"
```

---

### Task 2: One attachment permission predicate

**Files:**
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift:86-156`
- Modify: `Sources/AppVolumeControlCore/ProcessGainPlan.swift:1-38`

**Interfaces:**
- Produces: `ProcessGainPlan.attachmentAllowed(explicitlyArmed:automaticallyAttachNewApps:)`.

- [ ] **Step 1: Add failing tests**

```swift
expect(ProcessGainPlan.attachmentAllowed(explicitlyArmed: true, automaticallyAttachNewApps: false), "手动启用必须允许接管")
expect(ProcessGainPlan.attachmentAllowed(explicitlyArmed: false, automaticallyAttachNewApps: true), "自动设置必须允许接管")
expect(!ProcessGainPlan.attachmentAllowed(explicitlyArmed: false, automaticallyAttachNewApps: false), "全部关闭时不能接管")
```

- [ ] **Step 2: Verify RED**

Run `swift run -j 1 AppVolumeControlTests`; expect only the missing function error.

- [ ] **Step 3: Implement the OR rule**

```swift
public static func attachmentAllowed(
    explicitlyArmed: Bool,
    automaticallyAttachNewApps: Bool
) -> Bool {
    explicitlyArmed || automaticallyAttachNewApps
}
```

- [ ] **Step 4: Verify GREEN and commit**

```sh
swift run -j 1 AppVolumeControlTests
git add Sources/AppVolumeControlCore/ProcessGainPlan.swift Tests/AppVolumeControlTests/BaselineSnapperTests.swift
git commit -m "Unify process tap attachment policy"
```

---

### Task 3: Stable session identity and complete cleanup

**Files:**
- Modify: `Sources/AppVolumeControl/main.swift:12-23,247-438,504-542`

**Interfaces:**
- Consumes: `SessionIdentity`, `VolumePolicy.sessionGain`, and `ProcessGainPlan.attachmentAllowed`.
- Produces: stable Process Tap values and one cleanup path for PID/bundle replacement and inactivity expiry.

- [ ] **Step 1: Remove the obsolete second source of truth**

Delete `reportedVolume` from `AudioApplication`, its constructor arguments, the discovery calculation, and the loop that copies `app.reportedVolume` back into `applicationVolumes`.

This is the root-cause fix: discovery can no longer transport a stored gain that overwrites the live value every second.

- [ ] **Step 2: Add session state and helpers**

Add to `VolumeViewModel`:

```swift
private var sessionIdentities: [pid_t: SessionIdentity] = [:]
private var muteRestoreVolumes: [pid_t: Double] = [:]
private var nativeWriteIDs: [pid_t: UUID] = [:]

private func sessionIdentity(for app: AudioApplication) -> SessionIdentity {
    SessionIdentity(processID: app.id, bundleIdentifier: app.bundleIdentifier)
}

private func attachmentAllowed(for app: AudioApplication) -> Bool {
    ProcessGainPlan.attachmentAllowed(
        explicitlyArmed: armedProcessIDs.contains(app.id),
        automaticallyAttachNewApps: settingsStore.settings.automaticallyAttachNewApps
    )
}

private func clearSession(for processID: pid_t) {
    processGainManager.stop(processID: processID)
    applicationVolumes[processID] = nil
    confirmedApplicationVolumes[processID] = nil
    editingApplicationIDs.remove(processID)
    inactiveSince[processID] = nil
    sessionIdentities[processID] = nil
    muteRestoreVolumes[processID] = nil
    armedProcessIDs.remove(processID)
    volumeReadTasks.removeValue(forKey: processID)?.cancel()
    nativeWriteTasks.removeValue(forKey: processID)?.cancel()
    nativeWriteIDs[processID] = nil
    if let task = pendingTasks.removeValue(forKey: processID), task.isRunning {
        task.terminate()
    }
}
```

- [ ] **Step 3: Seed only the first matching Process Tap session**

Immediately after `discoveredApplications` is built:

```swift
for app in discoveredApplications {
    let identity = sessionIdentity(for: app)
    let previousIdentity = sessionIdentities[app.id]
    if let previousIdentity, previousIdentity != identity {
        clearSession(for: app.id)
    }
    if app.controlKind == .processTap {
        applicationVolumes[app.id] = VolumePolicy.sessionGain(
            existingGain: applicationVolumes[app.id],
            previousIdentity: sessionIdentities[app.id],
            identity: identity,
            initialGain: settingsStore.resolvedGain(for: app.bundleIdentifier)
        )
    }
    sessionIdentities[app.id] = identity
}
```

After assigning `applications`, replace individual state filters with:

```swift
let currentIDs = Set(applications.map(\.id))
for processID in Set(sessionIdentities.keys).subtracting(currentIDs) {
    clearSession(for: processID)
}
```

The existing 0.8-second grace rows remain in `applications`, so cleanup happens only after expiry.

- [ ] **Step 4: Bind AppleScript reads to identity**

Capture `let identity = sessionIdentity(for: app)` in `readVolumeAsync`, pass it to `applyReadVolume`, and require:

```swift
guard sessionIdentities[processID] == identity,
      applications.contains(where: { $0.id == processID }),
      !editingApplicationIDs.contains(processID),
      let volume else { return }
```

- [ ] **Step 5: Route all attachment consumers through one helper**

Use `attachmentAllowed(for:)` in the Process Tap branch of `sliderEnabled`, the unarmed branch of `tapStatusText`, and the closure passed to `processGainManager.reconcile`.

Make `independentGainEnabled(for:)` return `attachmentAllowed(for:)`. In `enableIndependentGain(for:)`, arm the PID but initialize `applicationVolumes` only if it is absent; never reset a live session.

- [ ] **Step 6: Verify and commit**

```sh
swift run -j 1 AppVolumeControlTests
swift build -j 1 -c release -Xswiftc -warnings-as-errors
rg -n "reportedVolume|armedProcessIDs.contains" Sources/AppVolumeControl/main.swift
git add Sources/AppVolumeControl/main.swift
git commit -m "Keep active app gain stable across refreshes"
```

Expected: tests/build pass with no warnings; `reportedVolume` is absent; direct `armedProcessIDs.contains` remains only inside `attachmentAllowed(for:)`.

---

### Task 4: Reversible mute, async rollback, and accessible UI

**Files:**
- Modify: `Sources/AppVolumeControl/main.swift:455-610,651-720`

**Interfaces:**
- Consumes: `toggleMute`, `fallbackGain`, `shouldPersist`, and `MuteTransition.restoreGain(afterWriteSucceeded:)`.
- Produces: `toggleMute(for:)`, identity-guarded AppleScript completion, and the speaker button.

- [ ] **Step 1: Clear stale restore state on manual adjustment**

In `previewAppVolume`, after snapping, remove `muteRestoreVolumes[app.id]` whenever the value is greater than `muteThreshold`. Keep the existing atomic Process Tap preview and delayed AppleScript write.

- [ ] **Step 2: Add intent-aware writes**

Replace `setAppVolume` with:

```swift
func setAppVolume(
    _ value: Double,
    for app: AudioApplication,
    intent: GainWriteIntent = .sliderCommit,
    completion: (@MainActor (Bool) -> Void)? = nil
) {
    guard app.canControlVolume else {
        completion?(false)
        return
    }
    let gain = VolumePolicy.clamped(value)
    applicationVolumes[app.id] = gain

    if app.controlKind == .processTap {
        if VolumePolicy.shouldPersist(gain: gain, intent: intent) {
            settingsStore.storeGain(gain, for: app.bundleIdentifier)
        }
        processGainManager.updateGain(for: app.id, value: gain)
        monitorProcessTap()
        completion?(true)
        return
    }

    writeNativeVolume(gain, for: app, delay: 0, completion: completion)
}
```

`commitAppVolume` keeps the default `.sliderCommit` intent.

- [ ] **Step 3: Guard AppleScript completion by write and session identity**

Extend `writeNativeVolume`:

```swift
private func writeNativeVolume(
    _ value: Double,
    for app: AudioApplication,
    delay: TimeInterval,
    completion: (@MainActor (Bool) -> Void)? = nil
)
```

Cancel the current read/write, terminate the current running `Process`, create `let writeID = UUID()`, capture `let identity = sessionIdentity(for: app)`, and store `nativeWriteIDs[app.id] = writeID`.

At delayed-task entry, `task.run()` catch, and termination completion require:

```swift
guard self.nativeWriteIDs[processID] == writeID,
      self.sessionIdentities[processID] == identity else { return }
```

Only the current task may update `confirmedApplicationVolumes`, restore the captured confirmed value, or call the completion. Clear `nativeWriteIDs[processID]` before calling `completion?(true/false)`. Old terminated callbacks must return without changing current state.

- [ ] **Step 4: Add the mute action**

```swift
func toggleMute(for app: AudioApplication) {
    guard sliderEnabled(for: app) else { return }
    editingApplicationIDs.remove(app.id)
    let identity = sessionIdentity(for: app)
    let fallback = app.controlKind == .processTap
        ? VolumePolicy.fallbackGain(candidates: [
            settingsStore.resolvedGain(for: app.bundleIdentifier),
            settingsStore.settings.defaultOutputGain
        ])
        : VolumePolicy.defaultLevel
    let transition = VolumePolicy.toggleMute(
        currentGain: volumeValue(for: app),
        restoreGain: muteRestoreVolumes[app.id],
        fallbackGain: fallback
    )
    muteRestoreVolumes[app.id] = transition.nextRestoreGain
    setAppVolume(transition.targetGain, for: app, intent: .temporaryMute) { [weak self] succeeded in
        guard let self, self.sessionIdentities[app.id] == identity else { return }
        self.muteRestoreVolumes[app.id] = transition.restoreGain(afterWriteSucceeded: succeeded)
    }
}

func isMuted(_ app: AudioApplication) -> Bool {
    VolumePolicy.isMuted(volumeValue(for: app))
}
```

- [ ] **Step 5: Add the accessible speaker control**

Inside the existing `sliderEnabled` branch, add a button beside the percentage:

```swift
Button {
    model.toggleMute(for: app)
} label: {
    Image(systemName: model.isMuted(app) ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .frame(width: 18, height: 18)
}
.buttonStyle(.borderless)
.help(model.isMuted(app) ? "恢复 \(app.name) 音量" : "静音 \(app.name)")
.accessibilityLabel(Text(model.isMuted(app) ? "恢复 \(app.name) 音量" : "静音 \(app.name)"))
.accessibilityHint(Text("只影响这个应用的当前音频会话"))
```

Add to the slider call site:

```swift
.accessibilityLabel(Text(
    app.controlKind == .processTap ? "\(app.name) 系统级输出增益" : "\(app.name) 音量"
))
.accessibilityValue(Text(model.volumeText(for: app)))
```

Keep one row. Reduce the slider from 104 to 92 points only if actual UI inspection shows the new button needs space; do not add a second line.

- [ ] **Step 6: Verify and commit**

```sh
swift run -j 1 AppVolumeControlTests
swift build -j 1 -c release -Xswiftc -warnings-as-errors
git add Sources/AppVolumeControl/main.swift
git commit -m "Add reversible per-app mute"
```

---

### Task 5: Version 0.7.0, portable checksum, and bilingual release docs

**Files:**
- Modify: `scripts/build-app.sh:11-12,31,66-67,104`
- Modify: `README.md:1-93`
- Create: `docs/RELEASE_NOTES_v0.7.0.md`

**Interfaces:**
- Consumes: verified app source from Tasks 1-4.
- Produces: arm64 `0.7.0` Build `8`, a portable checksum, bilingual presentation, and release notes.

- [ ] **Step 1: Demonstrate old artifact metadata**

Run serially:

```sh
./scripts/build-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' outputs/AppVolumeControl.app/Contents/Info.plist)" = "0.7.0"
test "$(awk '{print $2}' outputs/AppVolumeControl.zip.sha256)" = "AppVolumeControl.zip"
```

Expected: the build succeeds, then the assertions fail on old `0.6.0` metadata and the absolute checksum path. These are the RED artifact checks.

- [ ] **Step 2: Update packaging**

Set:

```sh
VERSION="0.7.0"
BUILD_NUMBER="8"
```

Change the build command to `swift build -j 1 -c release`. Replace the usage description with:

```xml
<string>经用户授权后，对应用音频施加独立输出增益，不改变系统总音量。 / With your permission, applies per-app output gain without changing system volume.</string>
```

Write a portable checksum:

```sh
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ARCHIVE_PATH")" > "$(basename "$CHECKSUM_PATH")"
)
```

- [ ] **Step 3: Rebuild and verify GREEN artifacts**

```sh
./scripts/build-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' outputs/AppVolumeControl.app/Contents/Info.plist)" = "0.7.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' outputs/AppVolumeControl.app/Contents/Info.plist)" = "8"
test "$(awk '{print $2}' outputs/AppVolumeControl.zip.sha256)" = "AppVolumeControl.zip"
(
    cd outputs
    shasum -a 256 -c AppVolumeControl.zip.sha256
)
```

Expected: all checks pass and checksum reports `AppVolumeControl.zip: OK`.

- [ ] **Step 4: Measure exact sizes**

```sh
stat -f '%z' outputs/AppVolumeControl.zip
stat -f '%z' outputs/AppVolumeControl.zip.sha256
stat -f '%z' outputs/AppVolumeControl.app/Contents/MacOS/AppVolumeControl
du -sk outputs/AppVolumeControl.app
```

Compare with v0.6.0's 178,626-byte ZIP and approximately 636 KiB app. If app disk use grows by more than 50 KiB, remove unnecessary implementation before continuing.

- [ ] **Step 5: Update README in paired Chinese and English**

Change release references to `0.7.0`, insert exact measured sizes, and link `https://github.com/KDaSC/AppVolumeControl/releases/tag/v0.7.0`. Add paired bullets for reversible mute, transient zero, allowed-versus-connected attachment, Process Tap process-output boundaries, browser-tab limits, and the fact that AppleScript-backed apps may remain at 0% if either app exits before restore.

- [ ] **Step 6: Create bilingual release notes**

Create `docs/RELEASE_NOTES_v0.7.0.md` with paired Highlights, Safety and boundaries, Install, Verification, and Files sections. State `0.7.0 / Build 8`, arm64, macOS 18+, ad-hoc signed/not notarized, pre-release, exact sizes, stable session gain, reversible mute, unified attachment state, and portable SHA-256. Do not claim a real sound-path test unless performed.

- [ ] **Step 7: Commit release files**

```sh
git add scripts/build-app.sh README.md docs/RELEASE_NOTES_v0.7.0.md
git commit -m "Prepare AppVolumeControl 0.7.0 release"
```

---

### Task 6: Fresh verification and UI/resource QA

**Files:**
- Verify: all committed source and release artifacts.
- Modify only for a reproduced defect, with a failing regression test first.

**Interfaces:**
- Produces: evidence sufficient for merge and publication.

- [ ] **Step 1: Load required verification/UI skills**

Read and follow `superpowers:verification-before-completion`, then `computer-use:computer-use` before UI actions. On any defect, load `superpowers:systematic-debugging` before editing.

- [ ] **Step 2: Run fresh serial checks**

```sh
swift run -j 1 AppVolumeControlTests
swift build -j 1 -c release -Xswiftc -warnings-as-errors
./scripts/build-app.sh
(
    cd outputs
    shasum -a 256 -c AppVolumeControl.zip.sha256
)
codesign --verify --deep --strict outputs/AppVolumeControl.app
unzip -t outputs/AppVolumeControl.zip
lipo -archs outputs/AppVolumeControl.app/Contents/MacOS/AppVolumeControl
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' outputs/AppVolumeControl.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' outputs/AppVolumeControl.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' outputs/AppVolumeControl.app/Contents/Info.plist
```

Expected: tests/build/SHA/signature/ZIP pass; architecture `arm64`; minimum `18.0`; version/build `0.7.0`/`8`.

- [ ] **Step 3: Verify lifecycle and UI in the isolated desktop**

Identify and stop only this repository's old AppVolumeControl process, launch the new absolute binary, and fetch fresh UI state after every action. Verify cold launch, reopen, empty state, settings, and status item. If an already-active safe audio app exists, inspect long names, one-row layout, dynamic accessibility labels, keyboard focus, 42% across three refreshes, mute/restore, direct zero, and explicit/automatic attachment. If none exists, mark row-level/live-sound checks unverified instead of creating playback.

- [ ] **Step 4: Sample resources and process hygiene**

With panel closed and open, sample PID, `%CPU`, RSS, threads, and child processes at least three times. Confirm no stale `osascript`, duplicate app process, or unrelated process remains. Do not claim a performance improvement without comparable load.

- [ ] **Step 5: Review diff and state**

```sh
git diff origin/main...HEAD --check
git status --short --branch
git diff --stat origin/main...HEAD
git log --oneline --decorate origin/main..HEAD
rg -n "TBD|TODO|FIXME|placeholder|待定|占位" README.md docs/RELEASE_NOTES_v0.7.0.md Sources Tests scripts || true
```

Expected: clean worktree, no placeholders or unrelated files.

---

### Task 7: Independent code review and final fixes

**Files:**
- Review: `origin/main...codex/session-volume-mute`.
- Modify only for evidence-backed findings.

- [ ] **Step 1: Invoke `superpowers:requesting-code-review`**

Dispatch independent reviewers for spec compliance and code quality. Require exact evidence and focus on lifecycle, async identity, persistence, attachment safety, accessibility, build metadata, and docs.

- [ ] **Step 2: Resolve findings with TDD**

For every valid behavior defect, write a failing regression test, observe RED, apply the smallest fix, and rerun Task 6. Reject speculative feature expansion.

- [ ] **Step 3: Commit only real fixes**

Use a focused message such as `Fix mute session cleanup`; make no empty commit.

---

### Task 8: Publish GitHub PR and v0.7.0 pre-release

**Files:**
- Publish branch: `codex/session-volume-mute`
- Assets: `outputs/AppVolumeControl.zip`, `outputs/AppVolumeControl.zip.sha256`
- Notes: `docs/RELEASE_NOTES_v0.7.0.md`

**Interfaces:**
- Produces: merged `main`, tag/release `v0.7.0`, and independently verified downloads.

- [ ] **Step 1: Finish the branch and verify remote identity**

Load `superpowers:finishing-a-development-branch`. Verify `gh auth status`, `git ls-remote origin`, divergence, tag absence, and latest release. If the remote changed unexpectedly, reconcile it before publishing; never force-push.

- [ ] **Step 2: Push and create a bilingual PR**

```sh
git push -u origin codex/session-volume-mute
gh pr create \
  --repo KDaSC/AppVolumeControl \
  --base main \
  --head codex/session-volume-mute \
  --title "Add reversible per-app mute and stable session gain" \
  --body-file /tmp/appvolumecontrol-v070-pr.md
```

The temporary PR body must contain paired Chinese/English Summary, Safety boundaries, and Verification sections with exact results and no credentials or memory citations.

- [ ] **Step 3: Verify and merge**

Read the remote diff and checks, confirm they match the local reviewed commits, then run:

```sh
gh pr merge --repo KDaSC/AppVolumeControl --merge
```

Fetch `origin/main` and verify it contains the feature tip.

- [ ] **Step 4: Create the pre-release**

```sh
gh release create v0.7.0 \
  outputs/AppVolumeControl.zip \
  outputs/AppVolumeControl.zip.sha256 \
  --repo KDaSC/AppVolumeControl \
  --target main \
  --title "AppVolumeControl 0.7.0" \
  --notes-file docs/RELEASE_NOTES_v0.7.0.md \
  --prerelease
```

- [ ] **Step 5: Independently verify published assets**

Use `mktemp -d`, download both assets with `gh release download v0.7.0`, verify SHA from inside that directory, unzip, run strict `codesign`, and compare remote byte sizes with README.

- [ ] **Step 6: Verify public presentation and complete the goal**

Open repository/release pages; confirm paired Chinese/English README, latest pre-release status, downloadable assets, and visible limitations. Only after remote verification succeeds, mark the goal complete and report exact paths, commits, PR/release URLs, sizes, tests, resources, and any honestly unverified live sound path.

## Execution Handoff

The user explicitly instructed this task to continue through completion and authorized automatic publication. Execute inline in this session with `superpowers:executing-plans`; do not pause to offer execution choices unless a new permission prompt or materially unsafe external change appears.
