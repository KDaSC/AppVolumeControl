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

public enum VolumePolicy {
    public static let defaultLevel = 0.75
    public static let settingsSchemaVersion = 4
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
