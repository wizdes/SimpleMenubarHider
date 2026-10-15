#if SMH_ADVERSARIAL_TESTS
// Run from the repo root, with DIR set to any scratch folder:
//   xcrun swiftc -emit-module -emit-library -parse-as-library -module-name SMHCore \
//     Packages/SMHCore/Sources/SMHCore/*.swift -emit-module-path $DIR/SMHCore.swiftmodule -o $DIR/libSMHCore.dylib
//   xcrun swiftc -D SMH_ADVERSARIAL_TESTS -I $DIR -L $DIR -lSMHCore \
//     App/Engine/ConflictDetector.swift App/Engine/ApplyCounter.swift App/Engine/SettingsRecovery.swift \
//     App/UI/PopoverRules.swift App/Engine/AdversarialRulesTests.swift -o $DIR/adversarial-rules-tests
//   DYLD_LIBRARY_PATH=$DIR $DIR/adversarial-rules-tests
//   xcrun swiftc -D SMH_ADVERSARIAL_TESTS -D DEBUG -I $DIR -L $DIR -lSMHCore \
//     App/Engine/ConflictDetector.swift App/Engine/ApplyCounter.swift App/Engine/SettingsRecovery.swift \
//     App/UI/PopoverRules.swift App/Engine/AdversarialRulesTests.swift -o $DIR/adversarial-rules-tests-debug
//   DYLD_LIBRARY_PATH=$DIR $DIR/adversarial-rules-tests-debug
// Run it twice, as above: once with Release rules and once with -D DEBUG (Debug rules).
import Foundation
import SMHCore

@main
struct AdversarialRulesTests {
    nonisolated(unsafe) static var checks = 0

    static func main() {
        let matches = ConflictDetector.detect([
            ("com.example.other", "Other"),
            ("com.jordanbaird.Ice", "Ice"),
            ("com.stonerl.Thaw", "Thaw"),
            ("com.surteesstudios.Bartender", "Bartender"),
            ("com.surteesstudios.Bartender-setapp", "Bartender Setapp"),
            ("com.dwarvesv.minimalbar", "Hidden Bar"),
            ("dev.yili.smh.fixture.competitor", "Fixture"),
            ("com.jordanbaird.Ice", "Ice")
        ])
        var competitors = ["com.dwarvesv.minimalbar", "com.jordanbaird.Ice",
                           "com.stonerl.Thaw", "com.surteesstudios.Bartender",
                           "com.surteesstudios.Bartender-setapp"]
        #if DEBUG
        // M4 review item 5: the test fixture counts as a competitor only in Debug builds.
        competitors.append("dev.yili.smh.fixture.competitor")
        expect(ConflictDetector.bundleIDs.contains("dev.yili.smh.fixture.competitor"), true, "Debug list has the fixture")
        #else
        expect(ConflictDetector.bundleIDs.contains("dev.yili.smh.fixture.competitor"), false, "Release list has no fixture")
        #endif
        expect(matches.map(\.bundleID), competitors, "all competitors, sorted and deduplicated")
        expect(matches.first?.name, "Hidden Bar", "localized running name")
        expect(ConflictDetector.detect([("com.example.other", "Other")]).isEmpty, true, "other apps ignored")

        var count = ApplyCounter()
        count.recordSuccess()
        count.recordSuccess()
        expect(count.value, 2, "only real successful applies are recorded")

        let backing = InMemoryStore()
        let store = SettingsStore(store: backing)
        backing.set(Data("bad json".utf8), forKey: SettingsStore.key)
        var backedUp: [Data] = []
        let backup: (Data) throws -> URL = { data in
            backedUp.append(data)
            return URL(fileURLWithPath: "/tmp/settings-corrupt-test.json")
        }
        let recovered = SettingsRecovery.load(store: store, backup: backup)
        expect(recovered.settings, Settings(), "corrupt settings use defaults")
        expect(recovered.note.isEmpty, false, "corrupt reason is exposed")
        expect(store.load(), .loaded(Settings()), "defaults overwrite bad bytes")
        let second = SettingsRecovery.load(store: store, backup: backup)
        expect(second.note, "", "next launch has no corruption note")
        expect(second.firstLaunch, false, "recovered settings are not a new install")

        // M4 review item 11: the bad bytes are copied aside before they are overwritten.
        expect(backedUp, [Data("bad json".utf8)], "the backup gets the exact bad bytes, once")
        expect(recovered.backupURL?.lastPathComponent, "settings-corrupt-test.json", "backup location is reported")
        expect(recovered.backupError, nil, "no backup error")
        backing.set(Data("bad json".utf8), forKey: SettingsStore.key)
        let failedBackup = SettingsRecovery.load(store: store) { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        }
        expect(failedBackup.backupError, "disk full", "a failed backup is reported, not hidden")
        // M4 fix round 2 item 1: with no copy, the unreadable bytes are the only copy, so they stay.
        expect(backing.data(forKey: SettingsStore.key), Data("bad json".utf8), "the stored bytes stay when the copy failed")
        expect(failedBackup.settings, Settings(), "SMH runs on defaults in memory")
        expect(failedBackup.holdAutomaticSaves, true, "automatic saves wait for a user change")
        expect(recovered.holdAutomaticSaves, false, "a backed-up reset saves as usual")

        // Item 1: automatic saves (app names) keep the bad bytes; the first user change saves.
        let writer = SettingsWriter(store: store, holdAutomaticSaves: failedBackup.holdAutomaticSaves)
        writer.saveAutomatic(Settings(names: ["dev.example.app": "Example"]))
        expect(backing.data(forKey: SettingsStore.key), Data("bad json".utf8), "an automatic save does not overwrite the bad bytes")
        let chosen = Settings(hidden: ["dev.example.app"], revealSeconds: 30)
        writer.saveUserChange(chosen)
        expect(store.load(), .loaded(chosen), "a later user change does save")
        let named = Settings(hidden: ["dev.example.app"], revealSeconds: 30, names: ["dev.example.app": "Example"])
        writer.saveAutomatic(named)
        expect(store.load(), .loaded(named), "after a user change, automatic saves work again")
        let normalWriter = SettingsWriter(store: store, holdAutomaticSaves: false)
        normalWriter.saveAutomatic(Settings())
        expect(store.load(), .loaded(Settings()), "a writer that holds nothing saves at once")

        // M4 review item 9: never-hide ids are dropped on load and the cleaned set is saved.
        store.save(Settings(hidden: ["com.apple.controlcenter", "dev.example.app"], revealSeconds: 30))
        let cleaned = SettingsRecovery.load(store: store, backup: backup)
        expect(cleaned.settings.hidden, ["dev.example.app"], "neverHide ids dropped")
        expect(cleaned.droppedNeverHide, ["com.apple.controlcenter"], "dropped ids are reported for one log line")
        expect(cleaned.settings.revealSeconds, 30, "other settings kept")
        expect(store.load(), .loaded(cleaned.settings), "the cleaned set is saved, so the log happens once")
        expect(SettingsRecovery.load(store: store, backup: backup).droppedNeverHide, [], "nothing to drop next time")

        heldUserChangeRetriesTheCopy()
        print("\(checks)/\(checks) checks passed")
    }

    // M4 fix round 3 item 1: while saves are held, a user change first retries the copy.
    // The user's change always saves, and the "left as they are" line never stays after that.
    static func heldUserChangeRetriesTheCopy() {
        let bad = Data("bad json".utf8)
        let leftLine = PopoverText.settingsLeft(backupError: "disk full")

        let backing = InMemoryStore()
        let store = SettingsStore(store: backing)
        backing.set(bad, forKey: SettingsStore.key)
        var copied: [Data] = []
        let copyURL = URL(fileURLWithPath: "/tmp/settings-corrupt-retry.json")
        let writer = SettingsWriter(store: store, holdAutomaticSaves: true) { data in
            copied.append(data)
            return copyURL
        }
        let first = Settings(hidden: ["dev.example.app"])
        expect(writer.saveUserChange(first), .copiedThenSaved(copyURL), "the retried copy worked, then the change saved")
        expect(copied, [bad], "the retry copies the exact bad bytes")
        expect(store.load(), .loaded(first), "the user's change is saved")
        expect(writer.holdAutomaticSaves, false, "the hold ends")
        let second = Settings(hidden: ["dev.example.app"], revealSeconds: 30)
        expect(writer.saveUserChange(second), .saved, "with no hold, a change just saves")
        expect(copied.count, 1, "no second copy")

        let failBacking = InMemoryStore()
        let failStore = SettingsStore(store: failBacking)
        failBacking.set(bad, forKey: SettingsStore.key)
        let failWriter = SettingsWriter(store: failStore, holdAutomaticSaves: true) { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        }
        expect(failWriter.saveUserChange(first), .savedWithoutCopy("disk full"), "the retry failed, and this is reported")
        expect(failStore.load(), .loaded(first), "the user's change still saves over the unreadable bytes")
        expect(failWriter.holdAutomaticSaves, false, "the hold ends, since the bytes are gone")

        expect(SettingsWriter.UserSave.savedWithoutCopy("disk full").settingsLine(current: leftLine),
               "Settings could not be read or backed up, and were replaced by your change.",
               "the line after a change replaced the bytes without a copy")
        expect(SettingsWriter.UserSave.savedWithoutCopy("disk full").settingsLine(current: nil),
               "Settings could not be read or backed up, and were replaced by your change.",
               "that line shows even when the earlier line was already closed")
        let afterCopy = SettingsWriter.UserSave.copiedThenSaved(copyURL).settingsLine(current: leftLine)
        expect(afterCopy == leftLine, false, "the left-as-they-are line never stays after the bytes were overwritten")
        expect(afterCopy, PopoverText.settingsReplaced(copySaved: true), "the line says a copy was saved")
        expect(SettingsWriter.UserSave.copiedThenSaved(copyURL).settingsLine(current: nil), nil,
               "a closed line does not come back when nothing was lost")
        expect(SettingsWriter.UserSave.saved.settingsLine(current: "other line"), "other line", "a plain save keeps the line")
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ context: String) {
        checks += 1
        guard actual == expected else {
            fputs("FAIL \(context): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
    }
}
#endif
