@preconcurrency import AppKit
import AppVolumeControlCore
import CoreAudio
import Darwin
import SwiftUI

enum VolumeControlKind: Equatable {
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
        audioProcesses().filter(\.isRunningOutput).map(\.pid)
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
               (app.activationPolicy == .regular || app.activationPolicy == .accessory),
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

// MARK: - View model

@MainActor
final class VolumeViewModel: ObservableObject {
    @Published var applications: [AudioApplication] = []
    @Published var applicationVolumes: [pid_t: Double] = [:]
    @Published var isRefreshing = false

    private var discoveryTask: Task<Void, Never>?
    private var refreshPending = false
    private var inactiveCleanup: DispatchWorkItem?
    private let audioObserver = AudioOutputObserver()
    @Published private(set) var monitorMessage = "后台被动监听 · 75% 为原声"
    var onApplicationsChanged: (() -> Void)?
    let permissionController = AudioPermissionController()
    private var editingApplicationIDs = Set<pid_t>()
    private var inactiveSince: [pid_t: Date] = [:]
    private var sessionIdentities: [pid_t: SessionIdentity] = [:]
    private var muteRestoreVolumes: [pid_t: Double] = [:]
    private let inactiveGrace: TimeInterval = 0.8
    let settingsStore: VolumeSettingsStore
    private var armedProcessIDs = Set<pid_t>()

    private static let hiddenBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.PowerChime",
        "com.apple.loginwindow",
        "com.apple.WebKit.GPU",
        "com.apple.SafariPlatformSupport"
    ]

    private let processGainManager = ProcessGainManager()

    init(defaults: UserDefaults = .standard) {
        settingsStore = VolumeSettingsStore(defaults: defaults)
        processGainManager.onStateChange = { [weak self] in self?.objectWillChange.send() }
    }

    func startMonitoring() {
        audioObserver.start(onServiceRestart: { [weak self] in
            self?.processGainManager.stopAll()
        }) { [weak self] in
            guard let self else { return }
            self.monitorMessage = self.audioObserver.lastError.map { "监听异常（\($0)），请重新连接" }
                ?? "后台被动监听 · 75% 为原声"
            self.refresh()
        }
    }

    func retryAudioControl() {
        processGainManager.resetFailures()
        startMonitoring()
        refresh()
    }

    func stopMonitoring() {
        audioObserver.stop()
        inactiveCleanup?.cancel()
        inactiveCleanup = nil
        discoveryTask?.cancel()
        refreshPending = false
        isRefreshing = false
    }

    private func sessionIdentity(for app: AudioApplication) -> SessionIdentity {
        SessionIdentity(processID: app.id, bundleIdentifier: app.bundleIdentifier)
    }

    private func attachmentAllowed(for app: AudioApplication) -> Bool {
        ProcessGainPlan.attachmentAllowed(
            explicitlyArmed: armedProcessIDs.contains(app.id),
            automaticallyAttachNewApps: settingsStore.settings.automaticallyAttachNewApps
        )
    }

    func setAutomaticallyAttachNewApps(_ value: Bool) {
        let previous = settingsStore.settings.automaticallyAttachNewApps
        guard ProcessGainPlan.automaticAttachmentChanged(from: previous, to: value) else { return }
        settingsStore.settings.automaticallyAttachNewApps = value
        monitorProcessTap()
        objectWillChange.send()
        refresh()
    }

    private func clearSession(for processID: pid_t) {
        processGainManager.stop(processID: processID)
        applicationVolumes[processID] = nil
        editingApplicationIDs.remove(processID)
        inactiveSince[processID] = nil
        sessionIdentities[processID] = nil
        muteRestoreVolumes[processID] = nil
        armedProcessIDs.remove(processID)
    }

    private func isUserFacingApplication(_ app: NSRunningApplication, name: String, bundleID: String) -> Bool {
        guard app.activationPolicy == .regular || app.activationPolicy == .accessory else { return false }
        if Self.hiddenBundleIDs.contains(bundleID) { return false }
        if bundleID.hasPrefix("com.openai.sky.") || bundleID.hasPrefix("com.apple.SafariPlatformSupport") {
            return false
        }
        return !name.isEmpty
    }

    func refresh() {
        guard !isRefreshing else { refreshPending = true; return }
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
                runningApplications: runningApplications
            )
        }
    }

    func applyDiscovery(
        audioProcesses: [CoreAudioSupport.ProcessInfo],
        runningApplications: [pid_t: NSRunningApplication]
    ) {
        defer {
            isRefreshing = false
            onApplicationsChanged?()
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
        let now = Date()
        var hosts: [pid_t: NSRunningApplication] = [:]
        var processObjectIDsByHost: [pid_t: [AudioObjectID]] = [:]

        for process in audioProcesses where process.isRunningOutput {
            let host = ProcessTree.hostApplication(for: process.pid, runningApplications: runningApplications)
                ?? process.bundleIdentifier.flatMap { bundleIdentifier in
                    runningApplications.values.first {
                        ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
                            && $0.bundleIdentifier == bundleIdentifier
                    }
                }
            guard let host else { continue }
            hosts[host.processIdentifier] = host
            processObjectIDsByHost[host.processIdentifier, default: []].append(process.objectID)
        }

        let discoveredApplications: [AudioApplication] = hosts.values.compactMap { app in
            guard let name = app.localizedName,
                  let bundleID = app.bundleIdentifier,
                  bundleID != "com.codex.app-volume-control",
                  isUserFacingApplication(app, name: name, bundleID: bundleID) else { return nil }
            // 所有应用共用相对输出刻度，保持播放器内部音量不变。 / One relative scale for every app.
            let controlKind: VolumeControlKind? = .processTap
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
                controlKind: controlKind
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

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

        let discoveredIDs = Set(discoveredApplications.map(\.id))
        for app in discoveredApplications {
            inactiveSince[app.id] = nil
        }
        var nextApplications = discoveredApplications
        for previous in applications where !discoveredIDs.contains(previous.id) {
            let startedAt = inactiveSince[previous.id] ?? now
            inactiveSince[previous.id] = startedAt
            guard now.timeIntervalSince(startedAt) < inactiveGrace else { continue }
            nextApplications.append(AudioApplication(
                id: previous.id,
                name: previous.name,
                bundleIdentifier: previous.bundleIdentifier,
                icon: previous.icon,
                processObjectIDs: previous.processObjectIDs,
                isRunningOutput: false,
                controlKind: previous.controlKind
            ))
        }
        applications = nextApplications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        inactiveSince = inactiveSince.filter { currentID, startedAt in
            discoveredIDs.contains(currentID)
                || now.timeIntervalSince(startedAt) < inactiveGrace
        }

        let currentIDs = Set(applications.map(\.id))
        for processID in Set(sessionIdentities.keys).subtracting(currentIDs) {
            clearSession(for: processID)
        }
        inactiveCleanup?.cancel()
        inactiveCleanup = nil
        if let earliest = inactiveSince.values.min() {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            inactiveCleanup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, inactiveGrace - now.timeIntervalSince(earliest) + 0.02), execute: work)
        }
        isRefreshing = false
        monitorProcessTap()
    }

    func baseline(for app: AudioApplication) -> Double? {
        app.canControlVolume ? VolumePolicy.defaultLevel : nil
    }

    func sliderEnabled(for app: AudioApplication) -> Bool {
        switch app.controlKind {
        case .processTap:
            return attachmentAllowed(for: app) && processGainManager.canEdit(app)
        case nil:
            return false
        }
    }

    func beginEditing(_ app: AudioApplication) {
        editingApplicationIDs.insert(app.id)
    }

    func endEditing(_ app: AudioApplication) {
        editingApplicationIDs.remove(app.id)
    }

    func previewAppVolume(_ value: Double, for app: AudioApplication) {
        guard app.canControlVolume else { return }
        let snappedValue = BaselineSnapper.value(value, baseline: baseline(for: app))
        applicationVolumes[app.id] = snappedValue
        if snappedValue > VolumePolicy.muteThreshold {
            muteRestoreVolumes[app.id] = nil
        }
        processGainManager.updateGain(for: app.id, value: snappedValue)
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
            return "—"
        }
        let percent = Int((value * 100).rounded())
        return app.controlKind == .processTap ? "\(percent)%" : "\(percent)%"
    }

    var panelHeight: CGFloat {
        PanelLayout.height(
            applicationCount: applications.count,
            showsPermissionNotice: false
        )
    }

    // MARK: - Process tap (automatic by default; manual opt-out remains available)

    func shutdownProcessTap() {
        processGainManager.stopAll()
    }

    func tapStatusText(for app: AudioApplication) -> String? {
        if app.controlKind == .processTap, !attachmentAllowed(for: app) {
            return AudioApplicationStatus.unarmedProcessGainText
        }
        if app.controlKind == .processTap,
           !ProcessGainPlan.shouldRun(isOutputActive: true, gain: volumeValue(for: app)) {
            return "自动就绪 · 75% 为原声"
        }
        return processGainManager.statusText(for: app)
    }

    private func monitorProcessTap() {
        processGainManager.reconcile(
            applications: applications,
            gainFor: { [weak self] app in
                self?.applicationVolumes[app.id] ?? self?.settingsStore.resolvedGain(for: app.bundleIdentifier) ?? VolumePolicy.defaultLevel
            },
            attachmentAllowed: { [weak self] app in
                guard let self else { return false }
                return self.attachmentAllowed(for: app)
            }
        )
    }

    func enableIndependentGain(for app: AudioApplication) {
        guard app.controlKind == .processTap else { return }
        armedProcessIDs.insert(app.id)
        if applicationVolumes[app.id] == nil {
            applicationVolumes[app.id] = settingsStore.resolvedGain(for: app.bundleIdentifier)
        }
        monitorProcessTap()
    }

    func disableIndependentGain(for app: AudioApplication) {
        armedProcessIDs.remove(app.id)
        monitorProcessTap()
    }

    func independentGainEnabled(for app: AudioApplication) -> Bool {
        attachmentAllowed(for: app)
    }

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
    }

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

    deinit {
        discoveryTask?.cancel()
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
                    Text("相对音量")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = model.tapStatusText(for: app), status != AudioApplicationStatus.processGainConnectedText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if app.canControlVolume && model.sliderEnabled(for: app) {
                BaselineSlider(
                    value: Binding(
                        get: { model.volumeValue(for: app) },
                        set: { model.previewAppVolume($0, for: app) }
                    ),
                    baseline: model.baseline(for: app),
                    onEditingChanged: { editing in
                        if editing {
                            model.beginEditing(app)
                        } else {
                            model.commitAppVolume(for: app)
                            model.endEditing(app)
                        }
                    }
                )
                .frame(width: 104, height: 20)
                .help("相对原声：75% = 1 倍，100% ≈ 1.33 倍；增强可能产生失真")
                .accessibilityLabel(Text("\(app.name) 系统级输出增益"))
                .accessibilityValue(Text(model.volumeText(for: app)))

                Text(model.volumeText(for: app))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                Button {
                    model.toggleMute(for: app)
                } label: {
                    Image(systemName: model.isMuted(app) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(model.isMuted(app) ? "恢复 \(app.name) 音量" : "静音 \(app.name)")
                .accessibilityLabel(Text(model.isMuted(app) ? "恢复 \(app.name) 音量" : "静音 \(app.name)"))
                .accessibilityHint(Text("只影响这个应用当前 Process Tap 会话的输出增益"))
            } else {
                if app.controlKind == .processTap && !model.independentGainEnabled(for: app) {
                    Button(AudioApplicationStatus.enableProcessGainText) {
                        model.enableIndependentGain(for: app)
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                } else {
                    Text(AudioApplicationStatus.unknownVolumeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 34)
    }
}

struct VolumePanelView: View {
    @ObservedObject var model: VolumeViewModel
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("应用音量", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")
            }

            if model.applications.isEmpty {
                Text("当前没有应用输出声音")
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
                Text(model.monitorMessage).font(.caption2).foregroundStyle(.secondary)
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
    private let onHide: () -> Void

    var isVisible: Bool { panel.isVisible }

    init(contentViewController: NSViewController, onHide: @escaping () -> Void) {
        self.onHide = onHide
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
        handleHidden()
        panel.orderOut(nil)
    }

    private func handleHidden() {
        stopTracking()
        onHide()
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
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.panel.isVisible else { return }
                self.handleHidden()
            }
        })
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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "应用音量")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        statusItem.button?.toolTip = "应用音量"
        statusItem.autosaveName = "com.codex.app-volume-control.status-item"

        panelCoordinator = PanelCoordinator(
            contentViewController: NSHostingController(rootView: VolumePanelView(
                model: model,
                onSettings: { [weak self] in self?.showSettings() }
            )),
            onHide: {}
        )
        panelCoordinator.updateContentHeight(model.panelHeight)
        model.onApplicationsChanged = { [weak self] in
            guard let self else { return }
            self.panelCoordinator.updateContentHeight(self.model.panelHeight)
        }
        model.startMonitoring()

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.model.refresh()
                }
            })
        }
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: model.settingsStore,
                permission: model.permissionController,
                onRetry: { [weak model] in model?.retryAudioControl() },
                onAutomaticAttachmentChange: { [weak model] value in
                    model?.setAutomaticallyAttachNewApps(value)
                }
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePanel() {
        if panelCoordinator.isVisible {
            panelCoordinator.hide()
        } else {
            panelCoordinator.updateContentHeight(model.panelHeight)
            panelCoordinator.show(anchorButton: statusItem.button, fallbackScreen: NSScreen.main)
            model.refresh()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening from Dock is allowed to show the panel; initial launch stays quiet.
        if !panelCoordinator.isVisible {
            panelCoordinator.updateContentHeight(model.panelHeight)
            panelCoordinator.show(anchorButton: statusItem.button, fallbackScreen: NSScreen.main)
            model.refresh()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopMonitoring()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        panelCoordinator.hide()
        model.shutdownProcessTap()
    }

}

let app = NSApplication.shared
#if DEBUG
if CommandLine.arguments.contains("--self-check") {
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await AppSelfChecks.run(); exit(0) }
        catch { print("SELF_CHECK_FAILED: \(error)"); exit(1) }
    }
    app.run()
    exit(0)
}
#endif
let delegate = AppDelegate()
app.delegate = delegate
app.run()
