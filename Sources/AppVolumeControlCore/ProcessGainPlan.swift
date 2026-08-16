public enum ProcessGainPlan {
    public enum Action: Equatable {
        case none
        case start(objectIDs: [UInt32], gain: Double)
        case update(Double)
        case stop
    }

    public static func shouldRun(isOutputActive: Bool, gain: Double) -> Bool {
        isOutputActive && gain < 0.999
    }

    public static func shouldStartSystemAudioCapture(isOutputActive: Bool, gain: Double) -> Bool {
        shouldRun(isOutputActive: isOutputActive, gain: gain)
    }

    public static func action(
        isOutputActive: Bool,
        isAttachmentAllowed: Bool = true,
        gain: Double,
        requestedObjectIDs: [UInt32],
        currentObjectIDs: [UInt32]?,
        hasActiveEngine: Bool
    ) -> Action {
        let objectIDs = Array(Set(requestedObjectIDs)).sorted()
        guard isAttachmentAllowed else {
            return currentObjectIDs == nil && !hasActiveEngine ? .none : .stop
        }
        guard shouldRun(isOutputActive: isOutputActive, gain: gain), !objectIDs.isEmpty else {
            return currentObjectIDs == nil && !hasActiveEngine ? .none : .stop
        }

        guard currentObjectIDs == objectIDs else {
            return .start(objectIDs: objectIDs, gain: min(max(gain, 0), 1))
        }
        return hasActiveEngine ? .update(min(max(gain, 0), 1)) : .none
    }
}
