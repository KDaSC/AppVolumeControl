@preconcurrency import AppKit
import AppVolumeControlCore
import CoreAudio
import Darwin
import SwiftUI

enum VolumeControlKind: Equatable {
    case appleScript
    case processTap
}

struct AudioApplication: Identifiable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String
    let icon: NSImage
    let processObjectIDs: [AudioObjectID]
    let isRunningOutput: Bool
    let controlKind: VolumeControlKind?
    let reportedVolume: Double?

    var canControlVolume: Bool { controlKind != nil }
}

// MARK: - Audio process discovery

enum CoreAudioSupport {
    struct ProcessInfo: Hashable, Sendable {
        let pid: pid_t
        let objectID: AudioObjectID
        let bundleIdentifier: String?
        let isRunningOutput: Bool
    }

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func audioConnectedApplications() -> [pid_t] {
        audioProcesses().map(\.pid)
    }

    static func audioProcesses() -> [ProcessInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }

        var objects = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects.compactMap { object in
            guard let pid = processPID(object) else { return nil }
            return ProcessInfo(
                pid: pid,
                objectID: object,
                bundleIdentifier: processBundleIdentifier(object),
                isRunningOutput: isRunningOutput(processObject: object)
            )
        }
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid > 0 ? pid : nil
    }

    private static func processBundleIdentifier(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleIdentifier: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutableBytes(of: &bundleIdentifier) { rawBuffer in
            AudioObjectGetPropertyData(
                object,
                &address,
                0,
                nil,
                &size,
                rawBuffer.baseAddress!
            )
        }
        return status == noErr ? bundleIdentifier as String : nil
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(0)
        var pidValue = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        ) == noErr, objectID > 0 else { return nil }
        return objectID
    }

    static func isRunningOutput(processObject objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}

enum ProcessTree {
    static func hostApplication(
        for pid: pid_t,
        runningApplications: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        var current = pid
        var visited = Set<pid_t>()

        while current > 1, visited.insert(current).inserted {
            if let app = runningApplications[current],
               app.activationPolicy == .regular,
               app.bundleIdentifier != "com.apple.WindowServer" {
                return app
            }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        return result == 0 ? info.kp_eproc.e_ppid : nil
    }
}

// MARK: - Application volume adapters

enum AppVolumeAdapter {
    static let supportedBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "org.videolan.vlc",
        "com.apple.QuickTimePlayerX"
    ]

    static func supports(_ bundleID: String) -> Bool {
        supportedBundleIDs.contains(bundleID)
    }

    static func currentVolume(bundleID: String, timeout: TimeInterval = 2) -> Double? {
        let script: String
        switch bundleID {
        case "com.apple.Music":
            script = "tell application \"Music\" to get sound volume"
        case "com.spotify.client":
            script = "tell application \"Spotify\" to get sound volume"
        case "org.videolan.vlc":
            script = "tell application \"VLC\" to get audio volume"
        case "com.apple.QuickTimePlayerX":
            script = "tell application \"QuickTime Player\" to get sound volume of front document"
        default:
            return nil
        }

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            let deadline = Date().addingTimeInterval(timeout)
            while task.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if task.isRunning {
                task.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.25)
                while task.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return nil
            }
        } catch {
            return nil
        }

        guard task.terminationStatus == 0,
              let raw = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        switch bundleID {
        case "org.videolan.vlc": return min(max(value / 1000, 0), 1)
        case "com.apple.Music", "com.spotify.client": return min(max(value / 100, 0), 1)
        default: return min(max(value, 0), 1)
        }
    }

    static func script(bundleID: String, percent: Int, normalizedValue: Float) -> String? {
        switch bundleID {
        case "com.apple.Music":
            return "tell application \"Music\" to set sound volume to \(percent)"
        case "com.spotify.client":
            return "tell application \"Spotify\" to set sound volume to \(percent)"
        case "org.videolan.vlc":
            return "tell application \"VLC\" to set audio volume to \(percent * 10)"
        case "com.apple.QuickTimePlayerX":
            return "tell application \"QuickTime Player\" to set sound volume of front document to \(normalizedValue)"
        default:
            return nil
        }
    }
}

// MARK: - View model

@MainActor
final class VolumeViewModel: ObservableObject {
    @Published var applications: [AudioApplication] = []
    @Published var applicationVolumes: [pid_t: Double] = [:]
    @Published var isRefreshing = false

    private var pendingTasks: [pid_t: Process] = [:]
    private var volumeReadTasks: [pid_t: Task<Void, Never>] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var confirmedApplicationVolumes: [pid_t: Double] = [:]
    private var lastAudioProcessIDs = Set<pid_t>()
    private var lastRunningOutputProcessIDs = Set<pid_t>()
    private let defaults = UserDefaults.standard
    private let processTapGainKeyPrefix = "processTapGain."
    private let settingsSchemaKey = "volumeSettingsSchemaVersion"

    private static let hiddenBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.PowerChime",
        "com.apple.loginwindow",
        "com.apple.WebKit.GPU",
        "com.tencent.flue.WeChatAppEx",
        "cn.better365.iShotHelper",
        "com.openai.sky.CUAService"
    ]

    private let processGainManager = ProcessGainManager()
    private var tapMonitorTimer: Timer?

    init() {
        migrateSettingsIfNeeded()
    }

    private func migrateSettingsIfNeeded() {
        let previousVersion = defaults.integer(forKey: settingsSchemaKey)
        guard previousVersion < VolumePolicy.settingsSchemaVersion else { return }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(processTapGainKeyPrefix) {
            let stored = (defaults.object(forKey: key) as? NSNumber)?.doubleValue
            let migrated = VolumePolicy.migratedProcessGain(
                stored: stored,
                previousSchemaVersion: previousVersion
            )
            defaults.set(migrated, forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("baselineVolume.") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(VolumePolicy.settingsSchemaVersion, forKey: settingsSchemaKey)
    }

    private func isUserFacingApplication(_ app: NSRunningApplication, name: String, bundleID: String) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        if Self.hiddenBundleIDs.contains(bundleID) { return false }
        if bundleID.hasPrefix("com.openai.sky.") || bundleID.hasPrefix("com.apple.SafariPlatformSupport") {
            return false
        }
        return !name.localizedCaseInsensitiveContains("Graphics and Media")
            && !name.localizedCaseInsensitiveContains("Helper")
    }

    func refresh(readVolumes: Bool = true, forceDiscovery: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let runningApplications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }
        )

        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            let audioProcesses = await Task.detached(priority: .utility) {
                CoreAudioSupport.audioProcesses()
            }.value
            guard !Task.isCancelled else { return }
            self?.applyDiscovery(
                audioProcesses: audioProcesses,
                runningApplications: runningApplications,
                forceDiscovery: forceDiscovery,
                readVolumes: readVolumes
            )
        }
    }

    private func applyDiscovery(
        audioProcesses: [CoreAudioSupport.ProcessInfo],
        runningApplications: [pid_t: NSRunningApplication],
        forceDiscovery: Bool,
        readVolumes: Bool
    ) {
        let audioProcessIDs = Set(audioProcesses.map(\.pid))
        let runningOutputProcessIDs = Set(audioProcesses.filter(\.isRunningOutput).map(\.pid))
        if !readVolumes,
           !forceDiscovery,
           audioProcessIDs == lastAudioProcessIDs,
           runningOutputProcessIDs == lastRunningOutputProcessIDs {
            isRefreshing = false
            return
        }
        lastAudioProcessIDs = audioProcessIDs
        lastRunningOutputProcessIDs = runningOutputProcessIDs
        var hosts: [pid_t: NSRunningApplication] = [:]
        var processObjectIDsByHost: [pid_t: [AudioObjectID]] = [:]

        for process in audioProcesses where process.isRunningOutput {
            let host = ProcessTree.hostApplication(for: process.pid, runningApplications: runningApplications)
                ?? process.bundleIdentifier.flatMap { bundleIdentifier in
                    runningApplications.values.first {
                        $0.activationPolicy == .regular && $0.bundleIdentifier == bundleIdentifier
                    }
                }
            guard let host else { continue }
            hosts[host.processIdentifier] = host
            processObjectIDsByHost[host.processIdentifier, default: []].append(process.objectID)
        }

        applications = hosts.values.compactMap { app in
            guard let name = app.localizedName,
                  let bundleID = app.bundleIdentifier,
                  bundleID != "com.codex.app-volume-control",
                  isUserFacingApplication(app, name: name, bundleID: bundleID) else { return nil }
            let controlKind: VolumeControlKind? = AppVolumeAdapter.supports(bundleID)
                ? .appleScript
                : .processTap
            let reportedVolume: Double? = controlKind == .processTap
                ? storedProcessTapGain(for: bundleID)
                : applicationVolumes[app.processIdentifier]
            let processObjectIDs = ActiveAudioGrouping.sortedObjectIDs(
                processObjectIDsByHost[app.processIdentifier, default: []]
            )
            return AudioApplication(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: bundleID,
                icon: app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!,
                processObjectIDs: processObjectIDs,
                isRunningOutput: true,
                controlKind: controlKind,
                reportedVolume: reportedVolume
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let currentIDs = Set(applications.map(\.id))
        applicationVolumes = applicationVolumes.filter { currentIDs.contains($0.key) }
        confirmedApplicationVolumes = confirmedApplicationVolumes.filter { currentIDs.contains($0.key) }
        pendingTasks = pendingTasks.filter { currentIDs.contains($0.key) }
        for app in applications {
            if let volume = app.reportedVolume {
                applicationVolumes[app.id] = volume
                confirmedApplicationVolumes[app.id] = volume
            }
        }
        isRefreshing = false

        guard readVolumes else { return }
        for app in applications where app.controlKind == .appleScript {
            readVolumeAsync(for: app)
        }
    }

    private func readVolumeAsync(for app: AudioApplication) {
        volumeReadTasks[app.id]?.cancel()
        let bundleID = app.bundleIdentifier
        let processID = app.id
        volumeReadTasks[app.id] = Task.detached(priority: .utility) { [weak self] in
            let volume = AppVolumeAdapter.currentVolume(bundleID: bundleID)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyReadVolume(volume, processID: processID)
            }
        }
    }

    private func applyReadVolume(_ volume: Double?, processID: pid_t) {
        volumeReadTasks[processID] = nil
        guard applications.contains(where: { $0.id == processID }), let volume else { return }
        applicationVolumes[processID] = volume
        confirmedApplicationVolumes[processID] = volume
    }

    func baseline(for app: AudioApplication) -> Double? {
        app.canControlVolume ? VolumePolicy.defaultLevel : nil
    }

    func previewAppVolume(_ value: Double, for app: AudioApplication) {
        guard app.canControlVolume else { return }
        applicationVolumes[app.id] = BaselineSnapper.value(value, baseline: baseline(for: app))
    }

    func commitAppVolume(for app: AudioApplication) {
        guard let value = applicationVolumes[app.id] else { return }
        setAppVolume(value, for: app)
    }

    func volumeValue(for app: AudioApplication) -> Double {
        applicationVolumes[app.id] ?? VolumePolicy.defaultLevel
    }

    func volumeText(for app: AudioApplication) -> String {
        guard let value = applicationVolumes[app.id] else {
            return app.controlKind == .processTap ? "75%" : "—"
        }
        return "\(Int((value * 100).rounded()))%"
    }

    var panelHeight: CGFloat {
        PanelLayout.height(
            applicationCount: applications.count,
            showsPermissionNotice: false
        )
    }

    // MARK: - Process tap (system-level per-app gain for apps without AppleScript volume)

    func startProcessTapMonitoring() {
        guard tapMonitorTimer == nil else { return }
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitorProcessTap()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tapMonitorTimer = timer
        monitorProcessTap()
    }

    func stopProcessTapMonitoring() {
        tapMonitorTimer?.invalidate()
        tapMonitorTimer = nil
    }

    func shutdownProcessTap() {
        stopProcessTapMonitoring()
        processGainManager.stopAll()
    }

    func tapStatusText(for app: AudioApplication) -> String? {
        processGainManager.statusText(for: app)
    }

    private func storedProcessTapGain(for bundleID: String) -> Double {
        let key = processTapGainKeyPrefix + bundleID
        let stored = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? VolumePolicy.defaultLevel
        return min(max(stored, 0), 1)
    }

    private func monitorProcessTap() {
        processGainManager.reconcile(
            applications: applications,
            gainFor: { [weak self] app in self?.applicationVolumes[app.id] ?? VolumePolicy.defaultLevel }
        )
    }

    func setAppVolume(_ value: Double, for app: AudioApplication) {
        guard app.canControlVolume else { return }
        let clampedValue = min(max(value, 0), 1)
        applicationVolumes[app.id] = clampedValue

        if app.controlKind == .processTap {
            defaults.set(clampedValue, forKey: processTapGainKeyPrefix + app.bundleIdentifier)
            processGainManager.reconcile(
                applications: applications,
                gainFor: { [weak self] application in
                    self?.applicationVolumes[application.id] ?? VolumePolicy.defaultLevel
                },
                forceIDs: [app.id]
            )
            return
        }

        if let pendingTask = pendingTasks.removeValue(forKey: app.id), pendingTask.isRunning {
            pendingTask.terminate()
        }

        let percent = Int((clampedValue * 100).rounded())
        guard let script = AppVolumeAdapter.script(
            bundleID: app.bundleIdentifier,
            percent: percent,
            normalizedValue: Float(clampedValue)
        ) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        let taskIdentifier = ObjectIdentifier(task)
        let processID = app.id
        let lastConfirmedValue = confirmedApplicationVolumes[processID]
        task.terminationHandler = { [weak self] finishedTask in
            let succeeded = finishedTask.terminationStatus == 0
            Task { @MainActor [weak self] in
                guard let self,
                      let currentTask = self.pendingTasks[processID],
                      ObjectIdentifier(currentTask) == taskIdentifier else { return }
                self.pendingTasks[processID] = nil
                if succeeded {
                    self.confirmedApplicationVolumes[processID] = clampedValue
                } else if let lastConfirmedValue {
                    self.applicationVolumes[processID] = lastConfirmedValue
                }
            }
        }
        pendingTasks[app.id] = task
        do {
            try task.run()
        } catch {
            pendingTasks[app.id] = nil
            if let lastConfirmedValue {
                applicationVolumes[app.id] = lastConfirmedValue
            }
        }
    }

    deinit {
        discoveryTask?.cancel()
        volumeReadTasks.values.forEach { $0.cancel() }
        pendingTasks.values.forEach { $0.terminate() }
    }
}

// MARK: - Menu bar interface

struct BaselineSlider: View {
    @Binding var value: Double
    let baseline: Double?
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            Slider(value: $value, in: 0...1, onEditingChanged: onEditingChanged)
            if let baseline {
                GeometryReader { geometry in
                    let clamped = min(max(baseline, 0), 1)
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: 14)
                        .position(
                            x: 8 + CGFloat(clamped) * max(geometry.size.width - 16, 0),
                            y: geometry.size.height / 2
                        )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct AppVolumeRow: View {
    @ObservedObject var model: VolumeViewModel
    let app: AudioApplication

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 22, height: 22)
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .lineLimit(1)
                    if app.controlKind == .processTap {
                        Text("增益")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = model.tapStatusText(for: app), status != "输出增益已连接" {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if app.canControlVolume {
                BaselineSlider(
                    value: Binding(
                        get: { model.volumeValue(for: app) },
                        set: { model.previewAppVolume($0, for: app) }
                    ),
                    baseline: model.baseline(for: app),
                    onEditingChanged: { editing in
                        if !editing { model.commitAppVolume(for: app) }
                    }
                )
                .frame(width: 104, height: 20)
                .help(
                    app.controlKind == .processTap
                        ? "控制该应用的系统级输出增益"
                        : "拖到基准线前后 3% 会轻微吸附"
                )

                Text(model.volumeText(for: app))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(AudioApplicationStatus.unavailableText(isRunningOutput: app.isRunningOutput))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 34)
    }
}

struct VolumePopoverView: View {
    @ObservedObject var model: VolumeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("应用音量", systemImage: "slider.horizontal.3")
                .font(.headline)

            if model.applications.isEmpty {
                Text("当前没有正在输出音频的应用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.applications) { app in
                            AppVolumeRow(model: model, app: app)
                        }
                    }
                }
                .frame(maxHeight: PanelLayout.maximumHeight - 92)
            }

            Divider()

            HStack {
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: PanelLayout.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }
}

@MainActor
final class PanelCoordinator: NSObject {
    private static let panelWidth = PanelLayout.width
    private static let initialPanelSize = CGSize(width: panelWidth, height: PanelLayout.minimumHeight)

    let panel: NSPanel
    private weak var anchorButton: NSStatusBarButton?
    private var anchorWindow: NSWindow?
    private var trackingTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var lastAnchorRect: CGRect?
    private var lastPanelSize: CGSize?

    var isVisible: Bool { panel.isVisible }

    init(contentViewController: NSViewController) {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.initialPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.contentViewController = contentViewController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(Self.initialPanelSize)
    }

    func show(anchorButton: NSStatusBarButton?, fallbackScreen: NSScreen?) {
        self.anchorButton = anchorButton
        anchorWindow = anchorButton?.window
        position(fallbackScreen: fallbackScreen)
        panel.orderFrontRegardless()
        panel.makeKey()
        installTracking()
    }

    func hide() {
        stopTracking()
        panel.orderOut(nil)
    }

    func updateAnchor(fallbackScreen: NSScreen?) {
        guard isVisible else { return }
        position(fallbackScreen: fallbackScreen)
    }

    func updateContentHeight(_ height: CGFloat) {
        let size = CGSize(width: Self.panelWidth, height: height)
        guard panel.contentView?.bounds.size != size else { return }
        panel.setContentSize(size)
        updateAnchor(fallbackScreen: NSScreen.main)
    }

    private func position(fallbackScreen: NSScreen?) {
        let anchor = currentAnchor()
        let screen = anchor.flatMap { screenContaining($0) }
            ?? anchorWindow?.screen
            ?? fallbackScreen
            ?? NSScreen.main
        guard let screen else { return }

        let anchorRect = anchor ?? CGRect(
            x: screen.visibleFrame.maxX - 24,
            y: screen.visibleFrame.maxY,
            width: 24,
            height: 0
        )
        let panelSize = panel.frame.size == .zero ? Self.initialPanelSize : panel.frame.size
        guard anchorRect != lastAnchorRect || panelSize != lastPanelSize else {
            return
        }
        lastAnchorRect = anchorRect
        lastPanelSize = panelSize
        let frame = PanelGeometry.frame(
            anchor: anchorRect,
            panelSize: panelSize,
            screenFrame: screen.visibleFrame,
            gap: 0
        )
        panel.setFrame(frame, display: true)
    }

    private func currentAnchor() -> CGRect? {
        guard let button = anchorButton,
              let window = button.window,
              window.isVisible,
              button.isHidden == false else { return nil }
        let buttonRect = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonRect)
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func installTracking() {
        stopTracking()
        anchorWindow = anchorButton?.window
        if let anchorWindow {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: anchorWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateAnchor(fallbackScreen: NSScreen.main)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: anchorWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateAnchor(fallbackScreen: NSScreen.main)
                }
            })
        }
        if let button = anchorButton {
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: button,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateAnchor(fallbackScreen: NSScreen.main)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAnchor(fallbackScreen: NSScreen.main)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAnchor(fallbackScreen: NSScreen.main)
            }
        })

        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAnchor(fallbackScreen: NSScreen.main)
            }
        }
        RunLoop.main.add(trackingTimer!, forMode: .common)

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let location = NSEvent.mouseLocation
            if !self.panel.frame.contains(location), !(self.currentAnchor()?.contains(location) ?? false) {
                self.hide()
                return nil
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let location = NSEvent.mouseLocation
            if !self.panel.frame.contains(location), !(self.currentAnchor()?.contains(location) ?? false) {
                Task { @MainActor [weak self] in self?.hide() }
            }
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
        lastAnchorRect = nil
        lastPanelSize = nil
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelCoordinator: PanelCoordinator!
    private let model = VolumeViewModel()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "应用音量")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.toolTip = "应用音量"
        statusItem.autosaveName = "com.codex.app-volume-control.status-item"

        panelCoordinator = PanelCoordinator(
            contentViewController: NSHostingController(rootView: VolumePopoverView(model: model))
        )
        panelCoordinator.updateContentHeight(model.panelHeight)
        model.startProcessTapMonitoring()

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.panelCoordinator.isVisible else { return }
                    self.model.refresh(readVolumes: false, forceDiscovery: true)
                }
            }
        }
    }

    @objc private func togglePopover() {
        if panelCoordinator.isVisible {
            panelCoordinator.hide()
            stopRefreshTimer()
        } else {
            panelCoordinator.updateContentHeight(model.panelHeight)
            panelCoordinator.show(anchorButton: statusItem.button, fallbackScreen: NSScreen.main)
            model.refresh(readVolumes: true)
            startRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panelCoordinator.isVisible else { return }
                self.model.refresh(readVolumes: false, forceDiscovery: true)
                self.panelCoordinator.updateContentHeight(self.model.panelHeight)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening from Dock is allowed to show the panel; initial launch stays quiet.
        if !panelCoordinator.isVisible {
            panelCoordinator.updateContentHeight(model.panelHeight)
            panelCoordinator.show(anchorButton: statusItem.button, fallbackScreen: NSScreen.main)
            model.refresh(readVolumes: true)
            startRefreshTimer()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRefreshTimer()
        panelCoordinator.hide()
        model.shutdownProcessTap()
    }

}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
