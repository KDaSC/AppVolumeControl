public enum VolumePolicy {
    public static let defaultLevel = 0.75
    public static let settingsSchemaVersion = 4

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
