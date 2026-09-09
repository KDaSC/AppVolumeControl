import AppVolumeControlCore
import CoreAudio

@MainActor
final class ProcessGainManager {
    var onStateChange: (() -> Void)?
    private var engines: [pid_t: ProcessTapEngine] = [:]
    private var targetObjectIDs: [pid_t: [AudioObjectID]] = [:]
    private var lifecycleRequestIDs: [pid_t: UUID] = [:]

    func reconcile(
        applications: [AudioApplication],
        gainFor: (AudioApplication) -> Double,
        attachmentAllowed: (AudioApplication) -> Bool = { _ in true }
    ) {
        let processTapApplications = applications.filter { $0.controlKind == .processTap }
        let activeIDs = Set(processTapApplications.map(\.id))

        for processID in Set(engines.keys).subtracting(activeIDs) {
            stop(processID: processID)
        }

        guard #available(macOS 18, *) else {
            return
        }

        for app in processTapApplications {
            guard attachmentAllowed(app) else {
                stop(processID: app.id)
                continue
            }
            let gain = min(max(gainFor(app), 0), 1)
            let objectIDs = ActiveAudioGrouping.sortedObjectIDs(
                app.processObjectIDs.filter { CoreAudioSupport.isRunningOutput(processObject: $0) }
            )
            guard ProcessGainPlan.shouldStartSystemAudioCapture(isOutputActive: !objectIDs.isEmpty, gain: gain),
                  !objectIDs.isEmpty else {
                stop(processID: app.id)
                continue
            }

            let action = ProcessGainPlan.action(
                isOutputActive: true,
                isAttachmentAllowed: true,
                gain: gain,
                requestedObjectIDs: objectIDs,
                currentObjectIDs: targetObjectIDs[app.id],
                hasActiveEngine: engines[app.id]?.isActive == true
            )

            switch action {
            case .none:
                continue
            case .stop:
                stop(processID: app.id)
            case let .update(updatedGain):
                engines[app.id]?.setVolume(Float(VolumePolicy.outputGain(displayLevel: updatedGain)))
            case let .start(startObjectIDs, startGain):
                lifecycleRequestIDs[app.id] = UUID()
                let engine = engines[app.id] ?? {
                    let newEngine = ProcessTapEngine { [weak self] in
                        Task { @MainActor [weak self] in self?.onStateChange?() }
                    }
                    engines[app.id] = newEngine
                    return newEngine
                }()
                targetObjectIDs[app.id] = startObjectIDs.map { AudioObjectID($0) }
                engine.start(processObjectIDs: objectIDs, volume: Float(VolumePolicy.outputGain(displayLevel: startGain)))
            }
        }
    }

    func resetFailures() {
        targetObjectIDs.removeAll()
    }

    func updateGain(for processID: pid_t, value: Double) {
        engines[processID]?.setVolume(Float(VolumePolicy.outputGain(displayLevel: value)))
    }

    func canEdit(_ app: AudioApplication) -> Bool {
        guard app.controlKind == .processTap,
              #available(macOS 18, *),
              !app.processObjectIDs.isEmpty else { return false }
        return engines[app.id]?.lastError == nil
    }

    func statusText(for app: AudioApplication) -> String? {
        guard app.controlKind == .processTap else { return nil }
        guard #available(macOS 18, *) else {
            return "需要 macOS 18"
        }
        guard let engine = engines[app.id] else {
            return app.processObjectIDs.isEmpty ? "等待音频对象" : "等待输出增益接管"
        }
        if engine.isActive {
            return AudioApplicationStatus.processGainConnectedText
        }
        return engine.lastError ?? "等待输出增益接管"
    }

    func stop(processID: pid_t) {
        targetObjectIDs[processID] = nil
        let requestID = UUID()
        lifecycleRequestIDs[processID] = requestID
        guard let engine = engines[processID] else {
            lifecycleRequestIDs[processID] = nil
            return
        }
        engine.stop { [weak self, weak engine] in
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine else { return }
                let shouldRelease = ProcessGainPlan.shouldReleaseEngine(
                    cleanupRequestIsCurrent: self.lifecycleRequestIDs[processID] == requestID,
                    engineIsCurrent: self.engines[processID] === engine,
                    hasReplacementTarget: self.targetObjectIDs[processID] != nil
                )
                guard shouldRelease else { return }
                self.engines[processID] = nil
                self.lifecycleRequestIDs[processID] = nil
            }
        }
    }

    func stopAll() {
        for engine in engines.values {
            engine.stop()
        }
        engines.removeAll()
        targetObjectIDs.removeAll()
        lifecycleRequestIDs.removeAll()
    }
}
