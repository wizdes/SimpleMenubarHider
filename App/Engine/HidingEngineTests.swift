#if SMH_ENGINE_TESTS
// Regression tests for HidingEngine with a fake shim. The app target never sees this code.
// Run from the repo root, with DIR set to any scratch folder:
//   xcrun swiftc -emit-module -emit-library -parse-as-library -module-name SMHCore \
//     Packages/SMHCore/Sources/SMHCore/*.swift -emit-module-path $DIR/SMHCore.swiftmodule -o $DIR/libSMHCore.dylib
//   xcrun swiftc -D SMH_ENGINE_TESTS -I $DIR -L $DIR -lSMHCore \
//     App/Engine/HidingEngine.swift App/Engine/ApplyCounter.swift App/Engine/HidingEngineTests.swift -o $DIR/hiding-engine-tests
//   DYLD_LIBRARY_PATH=$DIR $DIR/hiding-engine-tests
// It prints "N/N checks passed" and exits 0, or prints each FAIL line and exits 1.
import Foundation
import SMHCore

/// Acts like SMHMenuBarShim: a new apply cancels the pending one at once with
/// SMHShim code 2 ("superseded"), and the test decides when the newest one finishes.
final class FakeShim: MenuBarShimming {
    private(set) var applied: [[String]] = []
    private(set) var releases = 0
    private var pending: ((Error?) -> Void)?

    func applyAllowedBundleIDs(_ ids: [String], systemItems: [NSNumber], completion: @escaping @Sendable (Error?) -> Void) {
        applied.append(ids)
        supersede()
        pending = completion
    }

    func releaseAll() {
        releases += 1
        supersede()
    }

    /// Finishes the newest pending apply.
    func finish(_ error: Error? = nil) {
        let completion = pending
        pending = nil
        completion?(error)
    }

    private func supersede() {
        let completion = pending
        pending = nil
        completion?(NSError(domain: "SMHShim", code: 2, userInfo: [NSLocalizedDescriptionKey: "superseded"]))
    }
}

@main
struct HidingEngineTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(what): got \(actual), expected \(expected)")
        }
    }

    @MainActor static func main() {
        supersededDuplicateDoesNotClearPending()
        unchangedListIsSkippedWhenIdle()
        failureKeepsOldList()
        forceAppliesUnchangedList()
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // M4 review bug 1: apply(L) twice, the shim supersedes the first L at once, then apply(X)
    // with X the active list must still reach the shim, and X must win.
    @MainActor static func supersededDuplicateDoesNotClearPending() {
        let shim = FakeShim()
        let engine = HidingEngine(shim: shim)
        let x = ["self", "x"], l = ["self"]
        engine.apply(list: x) { _ in }
        shim.finish()
        expect(engine.activeList, x, "X is active")

        var results: [String] = []
        engine.apply(list: l) { results.append("L1 \(($0 as NSError?)?.code ?? 0)") }
        engine.apply(list: l) { results.append("L2 \(($0 as NSError?)?.code ?? 0)") }
        engine.apply(list: x) { results.append("X \(($0 as NSError?)?.code ?? 0)") }
        expect(shim.applied, [x, l, l, x], "apply(X) while L is pending reaches the shim")
        shim.finish()
        expect(results, ["L1 2", "L2 2", "X 0"], "both L requests are superseded and X succeeds")
        expect(engine.activeList, x, "the newest request (X) wins")
        expect(engine.applyCount, 2, "only the two real successes count")
    }

    @MainActor static func unchangedListIsSkippedWhenIdle() {
        let shim = FakeShim()
        let engine = HidingEngine(shim: shim)
        let x = ["self", "x"]
        engine.apply(list: x) { _ in }
        shim.finish()
        var skipped = false
        engine.apply(list: x) { skipped = $0 == nil }
        expect(skipped, true, "the no-op calls back at once with no error")
        expect(shim.applied.count, 1, "an unchanged list with nothing pending is not sent again")
        expect(engine.applyCount, 1, "a skipped no-op does not count")
    }

    @MainActor static func failureKeepsOldList() {
        let shim = FakeShim()
        let engine = HidingEngine(shim: shim)
        let x = ["self", "x"], l = ["self"]
        engine.apply(list: x) { _ in }
        shim.finish()
        engine.apply(list: l) { _ in }
        shim.finish(NSError(domain: "SMHShim", code: 3, userInfo: nil))
        expect(engine.activeList, x, "a failed apply leaves the old list active")
        engine.apply(list: x) { _ in }
        expect(shim.applied.count, 2, "after the failure finished, X is still active, so it is skipped")
        engine.release()
        expect(engine.isApplied, false, "release clears the active list")
        expect(shim.releases, 1, "release reaches the shim")
    }

    // M4 review item 3: wake, display change and MenuBarAgent restart send the same list again.
    @MainActor static func forceAppliesUnchangedList() {
        let shim = FakeShim()
        let engine = HidingEngine(shim: shim)
        let x = ["self", "x"]
        engine.apply(list: x) { _ in }
        shim.finish()
        engine.apply(list: x, force: true) { _ in }
        expect(shim.applied, [x, x], "a forced apply reaches the shim even with the list unchanged")
        shim.finish()
        expect(engine.applyCount, 2, "the forced apply counts as a real apply")
        engine.apply(list: x) { _ in }
        expect(shim.applied.count, 2, "ordinary applies still skip the unchanged list")
    }
}
#endif
