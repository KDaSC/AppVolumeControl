# Safe Audio Handoff, Settings, and Web Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Stop new applications from being automatically and silently rerouted through a Process Tap, make the 75% default and per-app memory explicit in a Settings window, and define an honest opt-in path for browser-tab media volume.

**Architecture:** Separate discovery, attachment consent, and gain value. Discovery remains CoreAudio IsRunningOutput based. A generic app's Process Tap is created only after the user explicitly arms it, or explicitly enables automatic attachment in Settings. Persist global settings by default; persist an app gain only when remembering is enabled. Browser-tab media volume is an extension bridge, never a claim that CoreAudio can identify every webpage.

**Tech stack:** Swift 6, AppKit, SwiftUI, CoreAudio Process Tap on macOS 18+, UserDefaults, the existing C11 atomic helper, and later an optional Safari Web Extension or Chromium Manifest V3 extension.

## Global constraints

- Support Apple Silicon macOS 18, 26, and 27 only.
- Use public APIs only. Do not add private CoreAudio APIs, code injection, accessibility automation, virtual-audio drivers, or third-party routing dependencies.
- Keep the panel restricted to applications where IsRunningOutput equals 1.
- The global default gain remains 0.75. A proposed default must never be displayed as an already-applied internal app volume.
- automaticProcessTapAttachment defaults to false.
- rememberPerAppProcessTapGain defaults to false.
- Do not play any media from automated tests. End-to-end audio tests are performed only by a human who already has an authorized source playing.
- No discovery timer is permitted while the panel is closed and no manually armed tap exists.
- A failed tap for the same PID and object set does not retry until the user retries, the object set changes, or the explicit automatic-attachment setting is on.

---

## Evidence behind the plan

1. AppDelegate starts process-tap monitoring during app launch in Sources/AppVolumeControl/main.swift line 1010.
2. VolumeViewModel monitors every second, even with a hidden panel.
3. Every discovered generic app resolves to processTapGain.<bundleID> or the default 0.75.
4. ProcessGainPlan starts a tap for every active gain below 1.0.
5. ProcessTapEngine uses CATapMuteBehavior.mutedWhenTapped before the aggregate device and IO callback are proven ready.

This explains the observed sequence: the app emits audio normally; discovery notices output; the process is muted for Process Tap routing; routing can fail or be late. A public Process Tap cannot intercept an arbitrary process before that process begins output. The default must therefore preserve the original route.

## Non-goals

- Do not promise pre-first-frame interception for arbitrary applications.
- Do not replace mutedWhenTapped with unmuted. Unmuted sends the original source to audio hardware and risks duplicate playback.
- Do not show a fake browser-tab slider for a browser process.
- Do not add a virtual audio driver in this release.
- Do not clutter the compact active-app panel with Settings controls.

## File map

| File | Responsibility |
| --- | --- |
| Sources/AppVolumeControlCore/VolumeSettings.swift | Codable policy model, schema migration decisions, gain clamping, preference keys. |
| Sources/AppVolumeControlCore/ProcessGainPlan.swift | Pure attach/start/update/stop decisions. |
| Sources/AppVolumeControlCore/ProcessTapReadiness.swift | Pure idle, starting, active, failed startup state. |
| Sources/AppVolumeControlCore/ProcessTapEngine.swift | CoreAudio lifecycle, callback heartbeat, one-shot startup failure teardown. |
| Sources/AppVolumeControl/VolumeSettingsStore.swift | Main-actor UserDefaults adapter and session/per-bundle value rules. |
| Sources/AppVolumeControl/ProcessGainManager.swift | Engine ownership and attachment-policy enforcement. |
| Sources/AppVolumeControl/SettingsWindowController.swift | Separate AppKit-hosted Settings window. |
| Sources/AppVolumeControl/main.swift | Panel actions, truthful status text, visibility-aware refresh. |
| Tests/AppVolumeControlTests/BaselineSnapperTests.swift | Existing executable harness; add pure regression coverage. |
| README.md | Correct behavior and browser-tab limitations. |

## User-facing states

| Item | Default | Meaning |
| --- | --- | --- |
| Default output gain | 75% | Proposed gain applied only after the user enables independent output gain for a generic app. |
| Automatically attach new apps | Off | Off preserves original routing and avoids automatic mute/reroute. |
| Remember each app gain | Off | Off removes and ignores legacy per-bundle gains. |
| Discovered generic app | Unarmed | Display 原始输出 · 未启用独立增益. Do not show a false 75% measurement. |
| Tap startup | Starting | Display 准备输出增益接管 and disable the slider. |
| Tap active | Active | Display 输出增益 and enable the existing slider. |

---

### Task 1: Add the pure settings policy

**Files**

- Create Sources/AppVolumeControlCore/VolumeSettings.swift.
- Modify Sources/AppVolumeControlCore/VolumePolicy.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    public struct VolumeSettings: Codable, Equatable, Sendable {
        public var defaultOutputGain: Double
        public var automaticallyAttachNewApps: Bool
        public var rememberPerAppProcessTapGain: Bool
    }

    public static func resolvedGain(
        settings: VolumeSettings,
        storedGain: Double?
    ) -> Double

- [ ] Write failing tests: default gain is 0.75; automatic attachment and per-app memory are false; stored 0.22 resolves to 0.75 when memory is off; stored 0.22 resolves to 0.22 only when memory is on.
- [ ] Run swift run AppVolumeControlTests. Confirm the new settings symbols fail before implementation.
- [ ] Implement the model with a single public default value and clamping to 0...1. Increase VolumePolicy.settingsSchemaVersion from 3 to 4.
- [ ] Add a pure migration helper that returns all legacy processTapGain. keys for removal when the new policy disables memory.
- [ ] Re-run swift run AppVolumeControlTests and require exit code 0.
- [ ] Commit only these task files with: git commit -m "feat: add explicit output gain settings policy".

### Task 2: Require attachment consent before Process Tap creation

**Files**

- Modify Sources/AppVolumeControlCore/ProcessGainPlan.swift.
- Modify Sources/AppVolumeControl/ProcessGainManager.swift.
- Modify Sources/AppVolumeControl/main.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    static func action(
        isOutputActive: Bool,
        isAttachmentAllowed: Bool,
        gain: Double,
        requestedObjectIDs: [UInt32],
        currentObjectIDs: [UInt32]?,
        hasActiveEngine: Bool
    ) -> Action

    func shouldAttachProcessTap(for app: AudioApplication) -> Bool

- [ ] Write a failing regression: output active plus gain 0.75 plus isAttachmentAllowed false returns .none when no engine exists.
- [ ] Write a failing regression: identical input with isAttachmentAllowed true returns .start using 0.75.
- [ ] Confirm failure with swift run AppVolumeControlTests.
- [ ] Add a session-only Set<pid_t> named armedProcessIDs to VolumeViewModel. This set must not be written to UserDefaults.
- [ ] Implement shouldAttachProcessTap as settings.automaticallyAttachNewApps OR armedProcessIDs.contains(app.id).
- [ ] Pass that decision through ProcessGainManager.reconcile. It may create an engine only when output is active and attachment is allowed.
- [ ] When a user disarms an app, return .stop for an existing engine. When the PID disappears, remove it from armedProcessIDs.
- [ ] When remember is on, remember only the scalar gain; a fresh PID must still not be auto-armed merely because the old gain exists.
- [ ] Re-run the harness, then commit only Task 2 files with: git commit -m "fix: require explicit process tap attachment".

### Task 3: Add startup readiness and release the original route on failure

**Files**

- Create Sources/AppVolumeControlCore/ProcessTapReadiness.swift.
- Modify Sources/AppVolumeControlCore/ProcessTapEngine.swift.
- Modify Sources/AppVolumeControl/ProcessGainManager.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    public enum ProcessTapReadiness: Equatable, Sendable {
        case idle
        case starting
        case active
        case failed(String)
    }

    public enum ProcessTapStartupAction: Equatable {
        case wait
        case activate
        case fail(String)
    }

- [ ] Write failing pure tests: no callback before deadline returns wait; first callback returns activate; no callback after deadline returns fail("未收到音频回调").
- [ ] Confirm failure with swift run AppVolumeControlTests.
- [ ] At successful AudioDeviceStart, publish starting rather than active.
- [ ] Add a C atomic callback-heartbeat flag. In processAudio set it before sample processing; do not lock, allocate, or log in the audio callback.
- [ ] Schedule exactly one readiness check on the serial engine queue, 400 ms after AudioDeviceStart, bound to a monotonically increasing start generation.
- [ ] If the callback flag is false for the matching generation, call the existing fail path. It must destroy the IO proc, aggregate device, and Process Tap so macOS restores the source route.
- [ ] If the flag is true, set readiness active. Do not classify all-zero samples as failure because silence can be legitimate.
- [ ] Keep mutedWhenTapped. Do not use unmuted as a fallback.
- [ ] Surface starting, active, and failed state in ProcessGainManager.statusText.
- [ ] Re-run the harness and commit only Task 3 files with: git commit -m "fix: fail safe when a process tap never becomes ready".

### Task 4: Make refresh visibility- and attachment-aware

**Files**

- Create Sources/AppVolumeControlCore/RefreshPolicy.swift.
- Modify Sources/AppVolumeControl/main.swift.
- Modify Sources/AppVolumeControl/ProcessGainManager.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    static func interval(
        panelVisible: Bool,
        hasArmedTap: Bool
    ) -> TimeInterval?

- [ ] Write failing tests: hidden panel plus no armed tap gives nil; visible panel gives 1.0; hidden panel plus armed tap gives 2.0.
- [ ] Confirm failure with swift run AppVolumeControlTests.
- [ ] Remove model.startProcessTapMonitoring from applicationDidFinishLaunching.
- [ ] Keep NSWorkspace launch, activation, and termination notifications, but funnel them through a 250 ms debouncer.
- [ ] On opening the panel, run one immediate discovery and start the 1-second fallback timer.
- [ ] On closing the panel, cancel that timer. Do not discover or attach unrelated apps.
- [ ] If an armed engine is starting or active while the panel is hidden, run only a 2-second lifecycle reconciliation timer. Cancel it immediately when no such engine remains.
- [ ] Re-run the harness and commit only Task 4 files with: git commit -m "fix: limit audio discovery to visible or armed sessions".

### Task 5: Build the separate Settings window and migrate legacy values

**Files**

- Create Sources/AppVolumeControl/VolumeSettingsStore.swift.
- Create Sources/AppVolumeControl/SettingsWindowController.swift.
- Modify Sources/AppVolumeControl/main.swift.
- Modify Sources/AppVolumeControlCore/AudioApplicationStatus.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    @MainActor final class VolumeSettingsStore: ObservableObject {
        @Published private(set) var settings: VolumeSettings
        func updateDefaultOutputGain(_ value: Double)
        func setAutomaticallyAttachNewApps(_ enabled: Bool)
        func setRememberPerAppProcessTapGain(_ enabled: Bool)
        func resetRememberedGains()
    }

    func showSettings()

- [ ] Write failing tests: migration removes processTapGain.com.example.player when memory is off; AudioApplicationStatus.unarmedProcessGainText equals 原始输出 · 未启用独立增益.
- [ ] Confirm failure with swift run AppVolumeControlTests.
- [ ] Persist VolumeSettings as one JSON Data value under volumeSettings.v4.
- [ ] On v4 migration remove every processTapGain. key. When the user turns memory from on to off, remove those keys immediately. Turning it back on only persists future explicit commits; never revive a deleted historical gain.
- [ ] Change setAppVolume so generic-app values update memory immediately but are written to processTapGain.<bundleID> only when remembering is on.
- [ ] Add a dedicated AppKit Settings window hosting SettingsView. It opens through a gearshape button in the panel header and reuses one window.
- [ ] Include controls in this order: default output gain slider; automatic attachment toggle; per-app memory toggle; destructive Clear remembered app gains button with confirmation; a disabled browser-volume status row.
- [ ] Do not add back the manual refresh button or old explanatory subtitle.
- [ ] Re-run the harness. Perform a UI-only check: open the panel, open Settings twice, and verify only one settings window exists. Do not play audio.
- [ ] Commit only Task 5 files with: git commit -m "feat: add explicit audio gain settings window".

### Task 6: Make the panel controls truthful and reversible

**Files**

- Modify Sources/AppVolumeControl/main.swift.
- Modify Sources/AppVolumeControlCore/AudioApplicationStatus.swift.
- Modify Tests/AppVolumeControlTests/BaselineSnapperTests.swift.

**Interfaces**

    func enableIndependentGain(for app: AudioApplication)
    func disableIndependentGain(for app: AudioApplication)

- [ ] Write failing copy/state tests: idle returns action title 启用独立增益; active returns 停止独立增益.
- [ ] Confirm failure with swift run AppVolumeControlTests.
- [ ] For a generic unarmed app, show 原始输出 · 未启用独立增益 and one compact 启用独立增益 button instead of a numeric slider.
- [ ] Enabling arms the PID, assigns the global default to this session, and begins readiness checks.
- [ ] While starting, show a disabled slider and 准备输出增益接管. While active, show the existing baseline slider and 输出增益.
- [ ] Add an accessible secondary Stop independent gain action. It disarms the PID and destroys the engine immediately.
- [ ] Keep native AppleScript app behavior unchanged except discovery must never write a volume. It continues to show a genuine read value or 音量未知.
- [ ] Re-run the harness and commit only Task 6 files with: git commit -m "feat: expose reversible independent gain controls".

### Task 7: Plan browser-tab volume as a separate opt-in extension

**Files**

- Create docs/browser-volume-extension.md.
- Create later, only after browser choice: BrowserVolumeExtension.
- Modify SettingsWindowController and README only after the bridge works.

**Interfaces**

    struct BrowserMediaSession {
        let browser: String
        let tabID: String
        let title: String
        let host: String
        let isControllable: Bool
        let gain: Double?
    }

    enum BrowserBridgeMessage {
        case listMediaSessions
        case setMediaGain
        case connectionState
    }

- [ ] Write the boundary document first. It must say CoreAudio sees a browser process, not a webpage. The extension controls only accessible HTML audio and video elements on user-approved sites.
- [ ] Ask the user to choose Safari first or Chromium first. Do not start both implementations together.
- [ ] Safari path: use a Safari Web Extension with native messaging and app groups. It requires an Xcode app-extension target and stable signing.
- [ ] Chromium path: use a Manifest V3 extension and registered native-messaging host. It needs per-browser registration and update handling.
- [ ] The extension content script identifies eligible HTMLMediaElement values and applies only a clamped requested element.volume. It sends title, host, and ephemeral tab identity; it must not send raw page HTML, cookies, URLs beyond the displayed host, or media bytes.
- [ ] Require host permission only for sites selected by the user. Validate every native message.
- [ ] State unsupported cases in UI and README: Web Audio, DRM, inaccessible cross-origin frames, native browser audio, pages without HTML media, and multiple indistinguishable players.
- [ ] Test one normal video element with a human tester. Verify one tab changes while another tab remains unchanged. Commit extension work separately from CoreAudio work.

### Task 8: Verify, document, and release only with evidence

**Files**

- Modify README.md.
- Modify scripts/build-app.sh only if the Settings source or icon resources need packaging; otherwise leave it untouched.

- [ ] Update README: default behavior is no automatic Process Tap attachment; 75% is a proposed gain after explicit enable; per-app memory is opt-in; browser tabs need an extension and have listed limits.
- [ ] Run exactly:

    cd /Users/liudongkun/Documents/Codex/2026-08-03/new-chat
    swift run AppVolumeControlTests
    swift build -c release -Xswiftc -warnings-as-errors
    ./scripts/build-app.sh
    git diff --check

- [ ] Require every command to exit 0.
- [ ] Have a human tester who already has permitted audio run these cases: new app plays before panel open; opening panel creates no tap; enabling a generic app shows starting then active; disabling returns original routing; a second app does not inherit the first app's slider; remembered gain persists only with memory enabled; default-device change either reconnects safely or releases the route with an error.
- [ ] With the panel hidden and no armed taps, verify no discovery timer and no tap/aggregate device exist. With one armed tap, verify one engine for that PID and only the 2-second lifecycle timer.
- [ ] Commit documentation only after the evidence is captured.

## Completion checklist

- [ ] New generic apps are never automatically muted or routed under default Settings.
- [ ] Opening the panel does not create a Process Tap.
- [ ] Tap creation requires an explicit per-session action or opt-in automatic attachment.
- [ ] A tap without a callback tears down once and leaves original output available.
- [ ] Per-app values do not cross app launches unless memory is enabled.
- [ ] Settings contains all policy and the panel remains compact.
- [ ] Browser-tab media is labeled extension-only and limited to supported HTML media.
- [ ] Automated builds pass; human audio checks are recorded separately; README matches observed behavior.

