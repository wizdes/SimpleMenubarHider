#if SMH_POPOVER_TESTS
// Regression tests for the pure popover rules in PopoverRules.swift.
// The app target never sees this code, because SMH_POPOVER_TESTS is only set by the command below.
// Run from the repo root, with DIR set to any scratch folder:
//   xcrun swiftc -emit-module -emit-library -parse-as-library -module-name SMHCore \
//     Packages/SMHCore/Sources/SMHCore/*.swift -emit-module-path $DIR/SMHCore.swiftmodule -o $DIR/libSMHCore.dylib
//   xcrun swiftc -D SMH_POPOVER_TESTS -I $DIR -L $DIR -lSMHCore \
//     App/UI/PopoverRules.swift App/UI/PopoverRulesTests.swift -o $DIR/popover-rules-tests
//   DYLD_LIBRARY_PATH=$DIR $DIR/popover-rules-tests
// It prints "N/N checks passed" and exits 0, or prints each FAIL line and exits 1.
import Foundation
import SMHCore

@main
struct PopoverRulesTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(what): got \(actual), expected \(expected)")
        }
    }

    static func main() {
        openingNeverToggles()
        keysToggleOnlyAfterUserMovesHighlight()
        hoverArmsAndLeavingClears()
        rowsUseRealRunningSetAndSkipSystemApps()
        scanSkipsSystemApps()
        widthFitsWidestRow()
        revealDelayLabels()
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // Bug 1: a stray Space or Return right after the popover opens must not toggle a row.
    static func openingNeverToggles() {
        let ids = ["com.example.catpad", "com.example.fixtureone"]
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        expect(highlight.highlightedID, nil, "no row is highlighted on open")
        expect(highlight.handle(.space, rows: ids), .ignored, "Space right after open")
        expect(highlight.handle(.returnKey, rows: ids), .ignored, "Return right after open")
        expect(highlight.highlightedID, nil, "still no highlight after stray keys")
    }

    static func keysToggleOnlyAfterUserMovesHighlight() {
        let ids = ["a", "b", "c"]
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        expect(highlight.handle(.down, rows: ids), .moved, "first Down")
        expect(highlight.highlightedID, "a", "Down from nothing highlights the first row")
        expect(highlight.handle(.down, rows: ids), .moved, "second Down")
        expect(highlight.handle(.space, rows: ids), .toggle("b"), "Space after arrows toggles the highlighted row")
        expect(highlight.handle(.returnKey, rows: ids), .toggle("b"), "Return after arrows toggles the highlighted row")
        expect(highlight.handle(.up, rows: ids), .moved, "Up")
        expect(highlight.handle(.up, rows: ids), .moved, "Up at the top stays on the top row")
        expect(highlight.highlightedID, "a", "Up stops at the first row")
        expect(highlight.handle(.space, rows: ["b", "c"]), .ignored, "Space on a row that went away")

        highlight.popoverOpened()
        expect(highlight.highlightedID, nil, "a new popover session clears the highlight")
        expect(highlight.handle(.space, rows: ids), .ignored, "a new session must be armed again")
        var fresh = PopoverHighlight()
        fresh.popoverOpened()
        expect(fresh.handle(.up, rows: ids), .moved, "Up from nothing")
        expect(fresh.highlightedID, "c", "Up from nothing highlights the last row")
        expect(fresh.handle(.down, rows: []), .ignored, "arrows do nothing in an empty list")
    }

    static func hoverArmsAndLeavingClears() {
        let ids = ["a", "b"]
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        highlight.hoverBegan("b")
        expect(highlight.highlightedID, "b", "hover highlights the row")
        expect(highlight.handle(.space, rows: ids), .toggle("b"), "Space after hover toggles")
        highlight.hoverBegan("a")
        highlight.hoverEnded("b")
        expect(highlight.highlightedID, "a", "leaving the old row keeps the new row highlighted")
        highlight.hoverEnded("a")
        expect(highlight.highlightedID, nil, "leaving the list clears the highlight")
        expect(highlight.handle(.space, rows: ids), .ignored, "Space with no highlight")
    }

    // Bugs 5 and 6.
    static func rowsUseRealRunningSetAndSkipSystemApps() {
        let scanned = [MenuBarApp(bundleID: "com.example.catpad", name: "CatPad"),
                       MenuBarApp(bundleID: "com.apple.MenuBarAgent", name: "MenuBarAgent")]
        let rows = PopoverRows.build(
            scanned: scanned,
            hidden: ["com.example.slow", "com.example.gone", "com.apple.controlcenter"],
            names: ["com.example.slow": "Slow App", "com.example.gone": "Gone App"],
            running: ["com.example.catpad", "com.example.slow", "com.apple.MenuBarAgent"])
        expect(rows.map(\.bundleID), ["com.example.catpad", "com.example.gone", "com.example.slow"],
               "rows are sorted by name and skip Apple system processes")
        expect(rows.map(\.isRunning), [true, false, true],
               "an app that answered AX slowly is still running; a quit app is not")
        expect(rows.map(\.name), ["CatPad", "Gone App", "Slow App"], "saved names fill in unscanned apps")
    }

    static func scanSkipsSystemApps() {
        let scanned = [MenuBarApp(bundleID: "com.apple.Spotlight", name: "Spotlight"),
                       MenuBarApp(bundleID: "com.example.tailscale", name: "Tailscale"),
                       MenuBarApp(bundleID: "com.apple.systemuiserver", name: "SystemUIServer")]
        expect(PopoverRows.visibleScan(scanned).map(\.bundleID), ["com.example.tailscale"],
               "scan results drop AllowList.neverHide ids")
    }

    // Bug 2.
    static func widthFitsWidestRow() {
        expect(PopoverLayout.width(widestText: 40), 180, "short rows use the 180 pt minimum")
        expect(PopoverLayout.width(widestText: 170.2), 218, "width is text plus check column and padding")
        expect(PopoverLayout.width(widestText: 900), 300, "long rows stop at the 300 pt maximum")
        expect(PopoverLayout.textWidthLimit, 253, "names wider than this truncate")
    }

    // Bug 3.
    static func revealDelayLabels() {
        expect(RevealDelayChoice.options.map(\.label), ["5 Seconds", "10 Seconds", "30 Seconds", "1 Minute"],
               "menu items")
        expect(RevealDelayChoice.options.map(\.seconds), [5, 10, 30, 60], "menu values")
        expect(RevealDelayChoice.label(for: 60), "1 Minute", "label for 60 s")
        expect(RevealDelayChoice.label(for: 10), "10 Seconds", "label for 10 s")
        expect(RevealDelayChoice.label(for: 3), "3 Seconds", "label for a value set by the debug channel")
        expect(RevealDelayChoice.label(for: 120), "2 Minutes", "label for whole minutes")
    }
}
#endif
