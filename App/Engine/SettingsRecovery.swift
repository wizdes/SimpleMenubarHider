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
    /// What a user change did to the stored settings.
    enum UserSave: Equatable {
        /// A plain save.
        case saved
        /// Saves were held. The retried copy of the unreadable bytes worked, then the change saved.
        case copiedThenSaved(URL)
        /// Saves were held and the retried copy failed (this error), so the change replaced the bytes with no copy.
        case savedWithoutCopy(String)

        /// The popover's settings line after this save. `current` is the line shown now, or nil.
        /// Once the bytes are overwritten, the "left as they are" line must not stay.
        func settingsLine(current: String?) -> String? {
            switch self {
            case .saved: return current
            case .copiedThenSaved: return current == nil ? nil : PopoverText.settingsReplaced(copySaved: true)
            case .savedWithoutCopy: return PopoverText.settingsReplaced(copySaved: false)
            }
        }
    }

    private let store: SettingsStore
    private let backup: ((Data) throws -> URL)?
    private(set) var holdAutomaticSaves: Bool

    /// `backup` copies the unreadable bytes aside. A user change retries it while saves are held.
    init(store: SettingsStore, holdAutomaticSaves: Bool, backup: ((Data) throws -> URL)? = nil) {
        self.store = store
        self.holdAutomaticSaves = holdAutomaticSaves
        self.backup = backup
    }

    /// The user changed a setting. While saves are held, this first retries the copy of the
    /// unreadable bytes. It always saves the change, because the user's new choice matters more
    /// than bytes SMH cannot read, and it ends the hold.
    @discardableResult
    func saveUserChange(_ settings: Settings) -> UserSave {
        var result = UserSave.saved
        if holdAutomaticSaves, let bad = store.storedData() {
            if let backup {
                do { result = .copiedThenSaved(try backup(bad)) }
                catch { result = .savedWithoutCopy(error.localizedDescription) }
            } else {
                result = .savedWithoutCopy("no way to copy the settings was set up")
            }
        }
        holdAutomaticSaves = false
        store.save(settings)
        return result
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
