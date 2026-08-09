import AppVolumeControlCore
import CoreAudio

@MainActor
final class ProcessGainManager {
    private var engines: [pid_t: ProcessTapEngine] = [:]
    private var targetObjectIDs: [pid_t: [AudioObjectID]] = [:]
    private var attemptedObjectIDs: [pid_t: [AudioObjectID]] = [:]

    func reconcile(
        applications: [AudioApplication],
        gainFor: (AudioApplication) -> Double,
        forceIDs: Set<pid_t> = []
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
            let gain = min(max(gainFor(app), 0), 1)
            let objectIDs = ActiveAudioGrouping.sortedObjectIDs(
                app.processObjectIDs.filter { CoreAudioSupport.isRunningOutput(processObject: $0) }
            )
            guard ProcessGainPlan.shouldStartSystemAudioCapture(isOutputActive: !objectIDs.isEmpty, gain: gain),
                  !objectIDs.isEmpty else {
                stop(processID: app.id)
                continue
            }

            if forceIDs.contains(app.id) {
                attemptedObjectIDs[app.id] = nil
            }

            let engine = engines[app.id] ?? {
                let newEngine = ProcessTapEngine()
                engines[app.id] = newEngine
                return newEngine
            }()

            if targetObjectIDs[app.id] != objectIDs || attemptedObjectIDs[app.id] != objectIDs {
                engine.stop()
                targetObjectIDs[app.id] = objectIDs
                attemptedObjectIDs[app.id] = objectIDs
                engine.start(processObjectIDs: objectIDs, volume: Float(gain))
            } else {
                engine.setVolume(Float(gain))
            }
        }
    }

    func retryAll(
        applications: [AudioApplication],
        gainFor: (AudioApplication) -> Double
    ) {
        attemptedObjectIDs.removeAll()
        reconcile(applications: applications, gainFor: gainFor)
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
            return "输出增益已连接"
        }
        return engine.lastError ?? "等待输出增益接管"
    }

    func stop(processID: pid_t) {
        engines[processID]?.stop()
        engines[processID] = nil
        targetObjectIDs[processID] = nil
        attemptedObjectIDs[processID] = nil
    }

    func stopAll() {
        for engine in engines.values {
            engine.stop()
        }
        engines.removeAll()
        targetObjectIDs.removeAll()
        attemptedObjectIDs.removeAll()
    }
}
