#if SMH_SHIM_TESTS
// Tests for the real App/Shim/SMHMenuBarShim.m, run against fake MenuBarClientCore classes.
// The app target never sees this code or the shim's test hook, because only these commands set SMH_SHIM_TESTS.
// Run from the repo root, with DIR set to any scratch folder:
//   xcrun clang -fobjc-arc -DSMH_SHIM_TESTS -c App/Shim/SMHMenuBarShim.m -o $DIR/SMHMenuBarShim.o
//   xcrun swiftc -parse-as-library -module-cache-path $DIR/module-cache -D SMH_SHIM_TESTS -Xcc -DSMH_SHIM_TESTS \
//     -import-objc-header App/Shim/SMHMenuBarShim.h \
//     App/Shim/SMHMenuBarShimTests.swift $DIR/SMHMenuBarShim.o -o $DIR/shim-tests
//   $DIR/shim-tests
// It prints "N/N checks passed" and exits 0, or prints each FAIL line and exits 1.
import Foundation

/// Everything the fakes did, in order, such as "a1 active" or "a1 invalidate".
nonisolated(unsafe) var events: [String] = []

@objc(SMHFakeConfiguration)
final class FakeConfiguration: NSObject {
    let ids: [String]

    @objc init(allowedSystemItems items: [NSNumber], allowedBundleIdentifiers ids: [String]) {
        self.ids = ids
        super.init()
    }
}

/// Acts like MBAssessmentModeAssertion in the worst case: an invalidate that comes before the
/// activation finished does not stop it, so the assertion can still turn active later.
@objc(SMHFakeAssertion)
final class FakeAssertion: NSObject {
    nonisolated(unsafe) static var made: [FakeAssertion] = []
    let name: String
    private(set) var active = false
    private(set) var invalidations = 0
    private var completion: ((Error?) -> Void)?

    override init() {
        name = "a\(FakeAssertion.made.count + 1)"
        super.init()
        FakeAssertion.made.append(self)
    }

    @objc(activateWithConfiguration:completionHandler:)
    func activate(configuration: Any, completionHandler: @escaping (Error?) -> Void) {
        completion = completionHandler
        events.append("\(name) activate")
    }

    @objc func invalidate() {
        active = false
        invalidations += 1
        events.append("\(name) invalidate")
    }

    /// The system finishes the activation with success.
    func succeed() {
        active = true
        events.append("\(name) active")
        completion?(nil)
    }

    func fail() {
        events.append("\(name) failed")
        completion?(NSError(domain: "Fake", code: 9, userInfo: [NSLocalizedDescriptionKey: "fake failure"]))
    }
}

@main
struct SMHMenuBarShimTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0
    static let timeout: TimeInterval = 0.3

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(what): got \(actual), expected \(expected)")
        }
    }

    /// Lets the shim's main-queue work run (its completion handler hops to the main queue).
    static func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func code(_ error: Error?) -> Int { (error as NSError?)?.code ?? 0 }

    static func main() {
        SMHMenuBarShim.useTestConfigurationClass("SMHFakeConfiguration", assertionClass: "SMHFakeAssertion",
                                                 activationTimeout: timeout)
        expect(SMHMenuBarShim.isAvailable(), true, "the fake classes count as available, without dlopen")
        supersededLateSuccessIsInvalidated()
        timedOutLateSuccessIsInvalidated()
        releasedLateSuccessIsInvalidated()
        successReplacesOldOnlyAfterSuccess()
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    static func supersededLateSuccessIsInvalidated() {
        let shim = SMHMenuBarShim()
        var results: [Int] = []
        shim.applyAllowedBundleIDs(["one"], systemItems: []) { results.append(code($0)) }
        let first = FakeAssertion.made.last!
        shim.applyAllowedBundleIDs(["two"], systemItems: []) { results.append(code($0)) }
        let second = FakeAssertion.made.last!
        expect(results, [2], "the first request is superseded at once")
        first.succeed()
        drain()
        expect(first.active, false, "a superseded request that later succeeds is invalidated")
        expect(second.invalidations, 0, "the newer request is left alone")
        second.succeed()
        drain()
        expect(results, [2, 0], "the newer request succeeds")
        expect(second.active, true, "the newer assertion stays active")
        shim.releaseAll()
        expect(second.active, false, "releaseAll ends the active assertion")
    }

    static func timedOutLateSuccessIsInvalidated() {
        let shim = SMHMenuBarShim()
        var results: [Int] = []
        shim.applyAllowedBundleIDs(["one"], systemItems: []) { results.append(code($0)) }
        let late = FakeAssertion.made.last!
        drain(timeout + 0.2)
        expect(results, [3], "the request times out")
        late.succeed()
        drain()
        expect(late.active, false, "a timed-out request that later succeeds is invalidated")
        expect(results, [3], "the completion ran only once")
    }

    static func releasedLateSuccessIsInvalidated() {
        let shim = SMHMenuBarShim()
        var results: [Int] = []
        shim.applyAllowedBundleIDs(["one"], systemItems: []) { results.append(code($0)) }
        let late = FakeAssertion.made.last!
        shim.releaseAll()
        expect(results, [2], "releaseAll finishes the pending request as superseded")
        late.succeed()
        drain()
        expect(late.active, false, "a request released while pending that later succeeds is invalidated")
    }

    static func successReplacesOldOnlyAfterSuccess() {
        let shim = SMHMenuBarShim()
        var results: [Int] = []
        shim.applyAllowedBundleIDs(["one"], systemItems: []) { results.append(code($0)) }
        let old = FakeAssertion.made.last!
        old.succeed()
        drain()
        expect(results, [0], "the first request succeeds")
        shim.applyAllowedBundleIDs(["two"], systemItems: []) { results.append(code($0)) }
        let new = FakeAssertion.made.last!
        drain()
        expect(old.active, true, "the old assertion stays while the new one is pending")
        expect(old.invalidations, 0, "nothing invalidated the old assertion yet")
        events = []
        new.succeed()
        drain()
        expect(results, [0, 0], "the new request succeeds")
        expect(events, ["\(new.name) active", "\(old.name) invalidate"], "the old assertion ends only after the new one is active")
        expect(new.active, true, "the new assertion is active")
        expect(old.active, false, "the old assertion was invalidated")

        shim.applyAllowedBundleIDs(["three"], systemItems: []) { results.append(code($0)) }
        let failing = FakeAssertion.made.last!
        failing.fail()
        drain()
        expect(results, [0, 0, 9], "a failed request reports the system's error")
        expect(new.active, true, "a failed request leaves the active assertion in place")
        expect(failing.invalidations, 1, "the failed assertion is invalidated")
        shim.releaseAll()
        drain(timeout + 0.2)
        expect(results.count, 3, "no late timeout callback after the requests finished")
    }
}
#endif
