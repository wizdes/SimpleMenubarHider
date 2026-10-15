import Foundation
import SMHCore

struct RecoveredSettings {
    let settings: Settings
    let note: String
    let firstLaunch: Bool
    /// Where the unreadable settings were copied, when they were corrupt and the copy worked.
    var backupURL: URL?
    /// Why the copy failed, when it did. Then the stored bytes are left as they are.
    var backupError: String?
    /// True when the unreadable bytes could not be copied aside. SMH then runs on defaults in memory,
    /// and only a user change (or a later launch that reads the settings) saves.
    var holdAutomaticSaves = false
    /// Never-hide ids that were in the saved hidden set and were removed.
    var droppedNeverHide: [String] = []
}

/// Saves settings for the app. While `holdAutomaticSaves` is on, only a user change saves,
/// so unreadable settings that could not be copied aside are not lost to an automatic save.
final class SettingsWriter {
    private let store: SettingsStore
    private(set) var holdAutomaticSaves: Bool

    init(store: SettingsStore, holdAutomaticSaves: Bool) {
        self.store = store
        self.holdAutomaticSaves = holdAutomaticSaves
    }

    /// The user changed a setting. This always saves, and ends the hold.
    func saveUserChange(_ settings: Settings) {
        holdAutomaticSaves = false
        store.save(settings)
    }

    /// A save the user did not ask for, such as updated app names. Returns false when it was held.
    @discardableResult
    func saveAutomatic(_ settings: Settings) -> Bool {
        guard !holdAutomaticSaves else { return false }
        store.save(settings)
        return true
    }
}

enum SettingsRecovery {
    /// `backup` copies the unreadable bytes aside before they are overwritten with defaults.
    /// When the copy fails, nothing is overwritten.
    static func load(store: SettingsStore, backup: (Data) throws -> URL) -> RecoveredSettings {
        switch store.load() {
        case .loaded(let settings):
            let (clean, dropped) = settings.removingNeverHide()
            if !dropped.isEmpty { store.save(clean) }
            return RecoveredSettings(settings: clean, note: "", firstLaunch: false, droppedNeverHide: dropped)
        case .missing:
            return RecoveredSettings(settings: Settings(), note: "", firstLaunch: true)
        case .corrupt(let defaults, let reason):
            var result = RecoveredSettings(settings: defaults, note: reason, firstLaunch: false)
            if let bad = store.storedData() {
                do { result.backupURL = try backup(bad) }
                catch {
                    result.backupError = error.localizedDescription
                    result.holdAutomaticSaves = true
                    return result
                }
            }
            store.save(defaults)
            return result
        }
    }

    /// `~/Library/Application Support/Simple Menubar Hider`, where corrupt settings are copied.
    static func backupFolder() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Simple Menubar Hider", isDirectory: true)
    }
}
