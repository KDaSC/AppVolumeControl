import AppVolumeControlCore
import SwiftUI

@MainActor
final class VolumeSettingsStore: ObservableObject {
    private static let settingsKey = "volumeSettings.v4"
    private static let gainKeyPrefix = "processTapGain."

    @Published var settings: VolumeSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(VolumeSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .defaultValue
        }
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
