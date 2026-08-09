public enum ProcessGainPlan {
    public static func shouldRun(isOutputActive: Bool, gain: Double) -> Bool {
        isOutputActive && gain < 0.999
    }

    public static func shouldStartSystemAudioCapture(isOutputActive: Bool, gain: Double) -> Bool {
        shouldRun(isOutputActive: isOutputActive, gain: gain)
    }
}
