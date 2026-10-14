#if SMH_ADVERSARIAL_TESTS
// Run from the repo root, with DIR set to any scratch folder:
//   xcrun swiftc -emit-module -emit-library -parse-as-library -module-name SMHCore \
//     Packages/SMHCore/Sources/SMHCore/*.swift -emit-module-path $DIR/SMHCore.swiftmodule -o $DIR/libSMHCore.dylib
//   xcrun swiftc -D SMH_ADVERSARIAL_TESTS -I $DIR -L $DIR -lSMHCore \
//     App/Engine/ConflictDetector.swift App/Engine/ApplyCounter.swift App/Engine/SettingsRecovery.swift \
//     App/Engine/AdversarialRulesTests.swift -o $DIR/adversarial-rules-tests
//   DYLD_LIBRARY_PATH=$DIR $DIR/adversarial-rules-tests
import Foundation
import SMHCore

@main
struct AdversarialRulesTests {
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
        expect(matches.map(\.bundleID), ["com.dwarvesv.minimalbar", "com.jordanbaird.Ice",
                                        "com.stonerl.Thaw", "com.surteesstudios.Bartender",
                                        "com.surteesstudios.Bartender-setapp", "dev.yili.smh.fixture.competitor"], "all competitors, sorted and deduplicated")
        expect(matches.first?.name, "Hidden Bar", "localized running name")
        expect(ConflictDetector.detect([("com.example.other", "Other")]).isEmpty, true, "other apps ignored")

        var count = ApplyCounter()
        count.recordSuccess()
        count.recordSuccess()
        expect(count.value, 2, "only real successful applies are recorded")

        let backing = InMemoryStore()
        let store = SettingsStore(store: backing)
        backing.set(Data("bad json".utf8), forKey: SettingsStore.key)
        let recovered = SettingsRecovery.load(store: store)
        expect(recovered.settings, Settings(), "corrupt settings use defaults")
        expect(recovered.note.isEmpty, false, "corrupt reason is exposed")
        expect(store.load(), .loaded(Settings()), "defaults overwrite bad bytes")
        let second = SettingsRecovery.load(store: store)
        expect(second.note, "", "next launch has no corruption note")
        expect(second.firstLaunch, false, "recovered settings are not a new install")
        print("9/9 checks passed")
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ context: String) {
        guard actual == expected else {
            fputs("FAIL \(context): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
    }
}
#endif
