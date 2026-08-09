public enum BaselineSnapper {
    public static let threshold = 0.03
    private static let floatingPointTolerance = 0.000_000_1

    public static func value(_ value: Double, baseline: Double?) -> Double {
        let clampedValue = min(max(value, 0), 1)
        guard let baseline else { return clampedValue }
        let clampedBaseline = min(max(baseline, 0), 1)
        return abs(clampedValue - clampedBaseline) <= threshold + floatingPointTolerance
            ? clampedBaseline
            : clampedValue
    }
}
