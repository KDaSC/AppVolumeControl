import AppVolumeControlCore
import SwiftUI

@MainActor
final class VolumeSettingsStore: ObservableObject {
    private static let settingsKey = "volumeSettings.v5"
    private static let gainKeyPrefix = "processTapLevel.v5."

    @Published var settings: VolumeSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(VolumeSettings.self, from: data) {
            settings = decoded
        } else if let data = defaults.data(forKey: "volumeSettings.v4"),
                  var legacy = try? JSONDecoder().decode(VolumeSettings.self, from: data) {
            // 升级启用自动就绪；自定义衰减保留实际响度。 / Enable automatic readiness on upgrade.
            legacy.automaticallyAttachNewApps = true
            if legacy.defaultOutputGain != VolumePolicy.defaultLevel {
                legacy.defaultOutputGain = VolumePolicy.displayLevel(legacyGain: legacy.defaultOutputGain)
            }
            settings = legacy
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("processTapGain.") {
                guard let gain = value as? NSNumber else { continue }
                let bundleID = String(key.dropFirst("processTapGain.".count))
                defaults.set(VolumePolicy.displayLevel(legacyGain: gain.doubleValue), forKey: Self.gainKeyPrefix + bundleID)
            }
        } else {
            settings = .defaultValue
        }
        persist()
    }

    func resolvedGain(for bundleID: String) -> Double {
        let stored = (defaults.object(forKey: Self.gainKeyPrefix + bundleID) as? NSNumber)?.doubleValue
        return VolumeSettings.resolvedGain(settings: settings, storedGain: stored)
    }

    func storeGain(_ value: Double, for bundleID: String) {
        guard settings.rememberPerAppProcessTapGain else { return }
        defaults.set(min(max(value, 0), 1), forKey: Self.gainKeyPrefix + bundleID)
    }

    func clearRememberedGains() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.gainKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        objectWillChange.send()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}
