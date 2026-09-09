#if DEBUG
import AppKit
import AppVolumeControlCore
import AVFAudio

/// 仅调试构建包含；使用隔离偏好和零值测试音频。 / Debug-only, isolated defaults and silent output.
@MainActor
enum AppSelfChecks {
    // 渲染回调在实时线程执行，不能继承 MainActor。 / Render callbacks must not inherit MainActor.
    nonisolated private static func silentSource() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }

    static func run() async throws {
        let suite = "com.codex.app-volume-control.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = VolumeSettings(defaultOutputGain: 0.75, automaticallyAttachNewApps: false,
                                    rememberPerAppProcessTapGain: true)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "volumeSettings.v4")
        defaults.set(0.42, forKey: "processTapGain.com.example.player")
        let migrated = VolumeSettingsStore(defaults: defaults)
        precondition(migrated.settings.defaultOutputGain == 0.75)
        precondition(migrated.settings.automaticallyAttachNewApps)
        precondition(abs(migrated.resolvedGain(for: "com.example.player") - 0.315) < 0.00001)
        migrated.settings.automaticallyAttachNewApps = false
        let relaunched = VolumeSettingsStore(defaults: defaults)
        precondition(!relaunched.settings.automaticallyAttachNewApps)
        precondition(defaults.double(forKey: "processTapGain.com.example.player") == 0.42)
        defaults.removePersistentDomain(forName: suite)
        print("PASS isolated v4 migration and v5 preference persistence")

        let model = VolumeViewModel(defaults: defaults)
        defer { model.stopMonitoring(); model.shutdownProcessTap() }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw NSError(domain: "SelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finder required for read-only host fixture"])
        }
        // 0 是无效音频对象：测试生产状态合并，不接管 Finder 或任何真实声音。 / Invalid object prevents capture.
        let fixture = CoreAudioSupport.ProcessInfo(pid: finder.processIdentifier, objectID: 0,
                                                  bundleIdentifier: "com.apple.finder", isRunningOutput: true)
        let hosts = [finder.processIdentifier: finder]
        model.applyDiscovery(audioProcesses: [fixture], runningApplications: hosts)
        let row = model.applications.first!
        precondition(model.volumeValue(for: row) == 0.75)
        precondition(model.sliderEnabled(for: row))
        model.settingsStore.settings.rememberPerAppProcessTapGain = true
        model.setAppVolume(0.42, for: row)
        for _ in 0..<5 { model.applyDiscovery(audioProcesses: [fixture], runningApplications: hosts) }
        precondition(model.volumeValue(for: row) == 0.42)
        model.toggleMute(for: row)
        precondition(model.volumeValue(for: row) == 0)
        precondition(model.settingsStore.resolvedGain(for: row.bundleIdentifier) == 0.42)
        model.toggleMute(for: row)
        precondition(model.volumeValue(for: row) == 0.42)
        model.setAppVolume(0, for: row)
        precondition(model.settingsStore.resolvedGain(for: row.bundleIdentifier) == 0.42)
        model.toggleMute(for: row)
        precondition(model.volumeValue(for: row) == 0.42)
        model.setAutomaticallyAttachNewApps(false)
        precondition(!model.sliderEnabled(for: row))
        model.enableIndependentGain(for: row)
        precondition(model.sliderEnabled(for: row))
        model.disableIndependentGain(for: row)
        precondition(!model.sliderEnabled(for: row))
        model.stopMonitoring()
        model.applyDiscovery(audioProcesses: [], runningApplications: hosts)
        try await Task.sleep(for: .seconds(1.2))
        precondition(!model.applications.contains { $0.id == row.id })
        precondition(model.applicationVolumes[row.id] == nil)
        print("PASS production discovery, automatic readiness, repeated refresh, mute, memory and inactive expiry")

        let observer = AudioOutputObserver()
        observer.start {}
        defer { observer.stop() }
        try await Task.sleep(for: .seconds(1))
        precondition(observer.listenerCount >= 2 && observer.lastError == nil)
        let before = observer.deliveryCount
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let silence = silentSource()
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
        try engine.start()
        try await Task.sleep(for: .seconds(2))
        let afterStart = observer.deliveryCount
        precondition(afterStart > before, "CoreAudio start event must be delivered")
        engine.stop()
        try await Task.sleep(for: .seconds(0.8))
        precondition(observer.deliveryCount > afterStart, "CoreAudio stop event must be delivered")
        print("PASS real CoreAudio silent start/stop notifications; listeners=\(observer.listenerCount), events=\(observer.notificationCount), deliveries=\(observer.deliveryCount)")
        observer.stop()
        let stopped = observer.deliveryCount
        precondition(observer.listenerCount == 0)
        try await Task.sleep(for: .seconds(0.3))
        precondition(observer.deliveryCount == stopped)
        print("PASS listener cleanup; SELF_CHECK_OK")
    }
}
#endif
