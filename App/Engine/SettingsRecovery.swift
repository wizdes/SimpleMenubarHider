import SMHCore

struct RecoveredSettings {
    let settings: Settings
    let note: String
    let firstLaunch: Bool
}

enum SettingsRecovery {
    static func load(store: SettingsStore) -> RecoveredSettings {
        switch store.load() {
        case .loaded(let settings):
            return RecoveredSettings(settings: settings, note: "", firstLaunch: false)
        case .missing:
            return RecoveredSettings(settings: Settings(), note: "", firstLaunch: true)
        case .corrupt(let defaults, let reason):
            store.save(defaults)
            return RecoveredSettings(settings: defaults, note: reason, firstLaunch: false)
        }
    }
}
