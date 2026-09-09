public struct VolumeSettings: Codable, Equatable, Sendable {
    public static let defaultValue = VolumeSettings(
        defaultOutputGain: VolumePolicy.defaultLevel,
        automaticallyAttachNewApps: true,
        rememberPerAppProcessTapGain: false
    )

    public var defaultOutputGain: Double
    public var automaticallyAttachNewApps: Bool
    public var rememberPerAppProcessTapGain: Bool

    public init(
        defaultOutputGain: Double = VolumePolicy.defaultLevel,
        automaticallyAttachNewApps: Bool = true,
        rememberPerAppProcessTapGain: Bool = false
    ) {
        self.defaultOutputGain = min(max(defaultOutputGain, 0), 1)
        self.automaticallyAttachNewApps = automaticallyAttachNewApps
        self.rememberPerAppProcessTapGain = rememberPerAppProcessTapGain
    }

    public static func resolvedGain(settings: VolumeSettings, storedGain: Double?) -> Double {
        let candidate = settings.rememberPerAppProcessTapGain
            ? (storedGain ?? settings.defaultOutputGain)
            : settings.defaultOutputGain
        return min(max(candidate, 0), 1)
    }
}
