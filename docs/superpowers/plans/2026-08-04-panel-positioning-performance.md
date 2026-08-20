# 应用音量面板定位与打开性能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fragile popover offset with a screen-coordinate anchored panel and make opening non-blocking.

**Architecture:** A pure `PanelGeometry` helper calculates a clamped top-aligned panel frame from an anchor rect and visible screen frame. `AppDelegate` owns a borderless panel and coalesced anchor tracking. `VolumeViewModel` shows cached rows immediately and performs CoreAudio/process discovery and AppleScript reads asynchronously.

**Tech Stack:** Swift 6, AppKit, SwiftUI, CoreAudio, Foundation, executable test runner.

## Global Constraints

- Keep macOS deployment target at macOS 14, which includes macOS 18+.
- Keep the delivered app arm64 and avoid adding dependencies.
- Do not open the panel on first launch.
- Do not display system master volume.
- Keep unsupported applications honest as “音量未知”.
- Never block the main thread waiting for an external process.

---

### Task 1: Add testable panel geometry

**Files:**
- Create: `Sources/AppVolumeControlCore/PanelGeometry.swift`
- Modify: `Tests/AppVolumeControlTests/BaselineSnapperTests.swift`

**Interfaces:**
- Produces `PanelGeometry.frame(anchor:panelSize:screenFrame:gap:) -> CGRect`.
- Uses screen coordinates with origin at the lower-left, matching AppKit window frames.

- [ ] **Step 1: Add failing geometry assertions**

```swift
let frame = PanelGeometry.frame(
    anchor: CGRect(x: 1000, y: 900, width: 24, height: 30),
    panelSize: CGSize(width: 386, height: 282),
    screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    gap: 0
)
precondition(frame.maxY == 900)
precondition(abs(frame.midX - 1012) < 0.001)
```

- [ ] **Step 2: Run `swift run AppVolumeControlTests` and verify the missing symbol fails**
- [ ] **Step 3: Implement clamped top alignment and multi-display coordinates**
- [ ] **Step 4: Add edge and negative-origin cases, then rerun the test runner**
- [ ] **Step 5: Keep the helper free of AppKit dependencies**

### Task 2: Replace NSPopover positioning with anchored NSPanel

**Files:**
- Modify: `Sources/AppVolumeControl/main.swift`

**Interfaces:**
- `PanelCoordinator` owns the panel frame and anchor tracking.
- `AppDelegate` calls `panelCoordinator.show(anchor:)`, `hide()`, and `updateAnchor()`.

- [ ] **Step 1: Add a failing integration seam around the geometry helper**
- [ ] **Step 2: Create a borderless nonactivating `NSPanel` with the existing SwiftUI content**
- [ ] **Step 3: Calculate the anchor using `statusItem.button` and its window converted to screen coordinates**
- [ ] **Step 4: Observe status-bar window move/resize, screen changes, and button frame changes**
- [ ] **Step 5: Add a low-frequency visible-only fallback check that only calls `setFrameOrigin` after a real anchor delta**
- [ ] **Step 6: Remove `NSPopover`, `origin.y += 28`, and `popover.animates` usage**
- [ ] **Step 7: Preserve quiet first launch and Dock reopen behavior with a safe fallback position**

### Task 3: Make discovery and volume reads asynchronous

**Files:**
- Modify: `Sources/AppVolumeControl/main.swift`

**Interfaces:**
- `VolumeViewModel.refresh()` publishes cached data immediately and schedules background discovery.
- `AppVolumeAdapter.currentVolumeAsync(bundleID:completion:)` never waits on the main actor.

- [ ] **Step 1: Add a timeout test to the executable test runner for the async adapter contract**
- [ ] **Step 2: Move CoreAudio PID collection and parent traversal off the main actor**
- [ ] **Step 3: Replace synchronous AppleScript reads with `Process.terminationHandler` and a timeout**
- [ ] **Step 4: Update rows on the main actor as each result arrives**
- [ ] **Step 5: Cancel pending processes when an app disappears or the panel closes**
- [ ] **Step 6: Remove every `waitUntilExit()` call from the application target**

### Task 4: Verify end-to-end behavior and package

**Files:**
- Modify: `README.md`
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Run `swift run AppVolumeControlTests`**
- [ ] **Step 2: Run `swift build -c release -Xswiftc -warnings-as-errors`**
- [ ] **Step 3: Build, lint, ad-hoc sign, and strict-verify the app bundle**
- [ ] **Step 4: Verify first launch has zero panel windows**
- [ ] **Step 5: Verify reopen shows one panel and its frame top matches the menu-bar boundary**
- [ ] **Step 6: Verify no child processes remain after closing/terminating the app**
- [ ] **Step 7: Sample CPU/RSS after warm-up and document platform limitations**

