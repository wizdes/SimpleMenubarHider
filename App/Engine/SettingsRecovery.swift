import Foundation
import SMHCore

struct RecoveredSettings {
    let settings: Settings
    let note: String
    let firstLaunch: Bool
    /// Where the unreadable settings were copied, when they were corrupt and the copy worked.
    var backupURL: URL?
    /// Why the copy failed, when it did. The settings are reset anyway.
    var backupError: String?
    /// Never-hide ids that were in the saved hidden set and were removed.
    var droppedNeverHide: [String] = []
}

enum SettingsRecovery {
    /// `backup` copies the unreadable bytes aside before they are overwritten with defaults.
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
                catch { result.backupError = error.localizedDescription }
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
