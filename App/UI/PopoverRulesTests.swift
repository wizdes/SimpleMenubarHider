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
        outsideApplicationsRules()
        scanSkipsSystemApps()
        widthFitsWidestRow()
        revealDelayLabels()
        keyboardRowsAreOnlyRowsOnScreen()
        arrowsReachGeneralRows()
        hoverAtOpenWithoutMovementDoesNotArm()
        reopenOnlyAfterRecentUntrustedOpen()
        sizeUpdatesAreCoalesced()
        popoverLines()
        settingsLeftLine()
        pauseRowShowsCompetitorPause()
        trustGrantUsesOwnLastValue()
        pauseRowDisabledWhileCompetitorPauses()
        settingsReplacedLines()
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
            running: ["com.example.catpad", "com.example.slow", "com.apple.MenuBarAgent"], outside: [])
        expect(rows.map(\.bundleID), ["com.example.catpad", "com.example.gone", "com.example.slow"],
               "rows are sorted by name and skip Apple system processes")
        expect(rows.map(\.isRunning), [true, false, true],
               "an app that answered AX slowly is still running; a quit app is not")
        expect(rows.map(\.name), ["CatPad", "Gone App", "Slow App"], "saved names fill in unscanned apps")
    }

    static func outsideApplicationsRules() {
        let x = "com.example.x"
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: nil), false, "a missing path is unknown")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/Applications/X.app"), false, "app in Applications")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/Applications/Sub/X.app"), false, "app in an Applications subfolder")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/Users/yili/Applications/X.app"), true, "app in a home Applications folder")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/ApplicationsOther/X.app"), true, "a similar prefix is outside")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/Volumes/CatPad/CatPad.app"), true, "app on a disk image")
        expect(PopoverRows.isOutsideApplications(bundleID: x, bundlePath: "/System/Applications/X.app"), false, "an app under /System is Apple's")
        expect(PopoverRows.isOutsideApplications(bundleID: "com.apple.Safari", bundlePath: "/Users/yili/Applications/Safari.app"), false, "an Apple bundle id is never marked")

        let scanned = [MenuBarApp(bundleID: "running", name: "Running"),
                       MenuBarApp(bundleID: "stopped", name: "Stopped")]
        let rows = PopoverRows.build(scanned: scanned, hidden: [], names: [:],
                                     running: ["running"], outside: ["running", "stopped", "absent"])
        expect(rows.map(\.outsideApplications), [true, false], "only a running row carries the outside flag")
        expect(rows.map(\.bundleID), ["running", "stopped"], "an outside app missing from the scan adds no row")
        expect(PopoverRows.outsideNoteVisible(rows: rows, hidden: []), true, "an unchecked outside app shows the note")
        expect(PopoverRows.outsideNoteVisible(rows: rows, hidden: ["running"]), false, "a checked outside app does not show the note")
        let noOutside = PopoverRows.build(scanned: scanned, hidden: [], names: [:],
                                          running: ["running"], outside: [])
        expect(PopoverRows.outsideNoteVisible(rows: noOutside, hidden: []), false, "no outside app hides the note")
        let stoppedOutside = PopoverRows.build(scanned: scanned, hidden: [], names: [:],
                                               running: [], outside: ["running"])
        expect(PopoverRows.outsideNoteVisible(rows: stoppedOutside, hidden: []), false, "an outside app that stopped hides the note")
        expect(PopoverText.outsideTrailing, "outside /Applications", "outside row text")
        expect(PopoverText.outsideNote,
               "Apps outside /\u{2060}Applications are hidden too (macOS\u{00A0}27 limit). Move them to /\u{2060}Applications.",
               "outside footer text")
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

    // M4 review item 6: keys act only on rows that are on screen.
    static func keyboardRowsAreOnlyRowsOnScreen() {
        let apps = ["com.example.a", "com.example.b"]
        let general = GeneralRow.allCases.map(\.rawValue)
        expect(PopoverRows.keyboardRows(apps: apps, trusted: false, scanning: false, scannedIsEmpty: false), general,
               "untrusted: the app list is not shown, so only the general rows")
        expect(PopoverRows.keyboardRows(apps: apps, trusted: true, scanning: true, scannedIsEmpty: true), general,
               "first scan: the spinner is shown, so only the general rows (even with saved hidden apps)")
        expect(PopoverRows.keyboardRows(apps: apps, trusted: true, scanning: true, scannedIsEmpty: false), apps + general,
               "a rescan keeps the old rows on screen")
        expect(PopoverRows.keyboardRows(apps: apps, trusted: true, scanning: false, scannedIsEmpty: true), apps + general,
               "scan done")
        expect(PopoverRows.showsAppRows(trusted: true, scanning: true, scannedIsEmpty: true), false, "spinner")
        expect(PopoverRows.showsAppRows(trusted: false, scanning: false, scannedIsEmpty: false), false, "untrusted")

        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        highlight.hoverBegan("com.example.a")
        let untrustedRows = PopoverRows.keyboardRows(apps: apps, trusted: false, scanning: false, scannedIsEmpty: false)
        expect(highlight.handle(.space, rows: untrustedRows), .ignored, "a highlighted app row that is not on screen is not toggled")
    }

    // M4 review item 6: arrows go through the app rows, then Hide Again After, Launch at Login, Pause Hiding, Quit.
    static func arrowsReachGeneralRows() {
        let rows = PopoverRows.keyboardRows(apps: ["a"], trusted: true, scanning: false, scannedIsEmpty: false)
        expect(rows, ["a", "smh.row.delay", "smh.row.login", "smh.row.pause", "smh.row.quit"], "row order")
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        expect(highlight.handle(.returnKey, rows: rows), .ignored, "nothing happens before an arrow key")
        var seen: [String?] = []
        for _ in 0..<6 {
            _ = highlight.handle(.down, rows: rows)
            seen.append(highlight.highlightedID)
        }
        expect(seen, ["a", "smh.row.delay", "smh.row.login", "smh.row.pause", "smh.row.quit", "smh.row.quit"],
               "Down walks every row and stops at Quit")
        expect(highlight.handle(.space, rows: rows), .toggle("smh.row.quit"), "Space activates the highlighted general row")
        expect(GeneralRow(rawValue: "smh.row.pause"), .pause, "the model maps the id back to the row")
        expect(GeneralRow(rawValue: "a"), nil, "app ids are not general rows")
    }

    // M4 review item 6: the pointer resting on a row when the popover opens does not arm the keys.
    static func hoverAtOpenWithoutMovementDoesNotArm() {
        let rows = ["a", "b"]
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        highlight.pointerEntered("a")
        expect(highlight.highlightedID, nil, "no highlight from a pointer that has not moved")
        expect(highlight.handle(.space, rows: rows), .ignored, "Space does nothing")
        highlight.pointerMoved()
        expect(highlight.highlightedID, "a", "the first real movement highlights the row under the pointer")
        expect(highlight.handle(.space, rows: rows), .toggle("a"), "and arms the keys")
        highlight.pointerExited("a")
        highlight.pointerEntered("b")
        expect(highlight.highlightedID, "b", "after movement, entering a row highlights it at once")

        highlight.popoverOpened()
        highlight.pointerEntered("b")
        expect(highlight.handle(.returnKey, rows: rows), .ignored, "a new session starts unarmed again")
        highlight.pointerExited("b")
        highlight.pointerMoved()
        expect(highlight.highlightedID, nil, "moving after leaving the row highlights nothing")
        expect(highlight.handle(.returnKey, rows: rows), .ignored, "moving outside any row does not arm")
    }

    // M4 review item 7.
    static func reopenOnlyAfterRecentUntrustedOpen() {
        expect(TrustReopen.shouldReopen(openedUntrustedAt: nil, now: 1_000), false, "never opened while untrusted")
        expect(TrustReopen.shouldReopen(openedUntrustedAt: 1_000, now: 1_100), true, "opened 100 s ago")
        expect(TrustReopen.shouldReopen(openedUntrustedAt: 1_000, now: 1_300), true, "exactly 5 minutes")
        expect(TrustReopen.shouldReopen(openedUntrustedAt: 1_000, now: 1_301), false, "more than 5 minutes ago")
    }

    // M4 review item 15: at most one size update per 0.2 s, and none while one is waiting.
    static func sizeUpdatesAreCoalesced() {
        var throttle = SizeUpdateThrottle()
        expect(throttle.request(now: 10), 0, "the first request runs on the next turn")
        expect(throttle.request(now: 10), nil, "a burst while one is waiting adds nothing")
        throttle.ran(now: 10)
        expect(throttle.request(now: 10.05).map { ($0 * 1000).rounded() }, 150, "the next one waits until 0.2 s after the last (ms)")
        expect(throttle.request(now: 10.06), nil, "still waiting")
        throttle.ran(now: 10.2)
        expect(throttle.request(now: 11), 0, "a quiet gap runs at once")
    }

    // M4 review items 5 and 11.
    static func popoverLines() {
        expect(PopoverText.conflict(name: "Thaw"),
               "Thaw is also hiding menu bar icons, so SMH has paused. Quit Thaw to use SMH.", "conflict line")
        expect(PopoverText.settingsReset(backupError: nil),
               "Settings could not be read and were reset. A copy was saved.", "reset line")
        expect(PopoverText.settingsReset(backupError: "disk full"),
               "Settings could not be read and were reset. The copy could not be saved: disk full", "reset line, no copy")
    }

    // M4 fix round 2 item 1: with no copy, the settings stay as they are and SMH runs on defaults.
    static func settingsLeftLine() {
        expect(PopoverText.settingsLeft(backupError: "disk full"),
               "Settings could not be read and could not be backed up (disk full). They were left as they are; SMH is using defaults for now.",
               "line when the copy failed")
    }

    // M4 fix round 2 item 7: a pause for a competing hider shows on the Pause row, and a click
    // still flips only the user's own pause.
    static func pauseRowShowsCompetitorPause() {
        expect(PauseRow(userPaused: false, competitorName: nil), PauseRow(checked: false, trailing: nil, clickSetsUserPause: true),
               "not paused")
        expect(PauseRow(userPaused: true, competitorName: nil), PauseRow(checked: true, trailing: nil, clickSetsUserPause: false),
               "user paused")
        expect(PauseRow(userPaused: false, competitorName: "Thaw"), PauseRow(checked: true, trailing: "Thaw running", clickSetsUserPause: true),
               "paused for a competitor: check mark, name, and a click turns the user's pause on")
        expect(PauseRow(userPaused: true, competitorName: "Thaw"), PauseRow(checked: true, trailing: "Thaw running", clickSetsUserPause: false),
               "both pauses: a click turns the user's pause off")
    }

    // M4 fix round 2 item 8: only the 1 s trust check updates lastTrusted, and an open time is used once.
    static func trustGrantUsesOwnLastValue() {
        var watch = TrustWatch(trusted: false)
        watch.openedWhileUntrusted(now: 100)
        expect(watch.check(trusted: false, now: 101), nil, "still untrusted: no grant")
        expect(watch.check(trusted: true, now: 110), true, "a grant soon after an untrusted open reopens")
        expect(watch.lastTrusted, true, "the check records the new value")
        expect(watch.check(trusted: true, now: 111), nil, "no second grant while trusted")
        expect(watch.check(trusted: false, now: 120), nil, "access removed")
        expect(watch.check(trusted: true, now: 130), false, "the earlier open time was used up, so this grant does not reopen")
        var stale = TrustWatch(trusted: false)
        stale.openedWhileUntrusted(now: 100)
        expect(stale.check(trusted: true, now: 500), false, "an open more than 5 minutes ago does not reopen")
        expect(stale.check(trusted: false, now: 501), nil, "access removed again")
        expect(stale.check(trusted: true, now: 502), false, "the old open time is cleared even when it was too old")
        var trustedAtLaunch = TrustWatch(trusted: true)
        expect(trustedAtLaunch.check(trusted: true, now: 1), nil, "trusted at launch is not a grant")
    }

    // M4 fix round 3 item 2: while a competitor pauses SMH, the Pause row shows the check mark and
    // "<Name> running", and it is disabled: a click or a key never changes the user's saved pause.
    static func pauseRowDisabledWhileCompetitorPauses() {
        let competitor = PauseRow(userPaused: false, competitorName: "Thaw")
        expect(competitor.checked, true, "check mark while a competitor pauses SMH")
        expect(competitor.trailing, "Thaw running", "names the competitor")
        expect(competitor.enabled, false, "disabled while a competitor pauses SMH")
        expect(competitor.click(), nil, "a click does nothing")
        let both = PauseRow(userPaused: true, competitorName: "Thaw")
        expect(both.enabled, false, "disabled also when the user paused too")
        expect(both.click(), nil, "a click does not undo the user's own pause")
        expect(PauseRow(userPaused: false, competitorName: nil).enabled, true, "enabled with no competitor")
        expect(PauseRow(userPaused: false, competitorName: nil).click(), true, "a click pauses")
        expect(PauseRow(userPaused: true, competitorName: nil).click(), false, "a click resumes")

        let general = GeneralRow.allCases.map(\.rawValue)
        let pause = GeneralRow.pause.rawValue
        let rows = PopoverRows.keyboardRows(apps: ["a"], trusted: true, scanning: false, scannedIsEmpty: false,
                                            pauseEnabled: false)
        expect(rows, ["a"] + general.filter { $0 != pause }, "the arrow keys skip the disabled Pause row")
        expect(PopoverRows.keyboardRows(apps: ["a"], trusted: true, scanning: false, scannedIsEmpty: false, pauseEnabled: true),
               ["a"] + general, "an enabled Pause row is in the keyboard order")
        var highlight = PopoverHighlight()
        highlight.popoverOpened()
        highlight.pointerMoved()
        highlight.hoverBegan(pause)
        expect(highlight.handle(.space, rows: rows), .ignored, "Space on the hovered disabled Pause row does nothing")
        expect(highlight.handle(.returnKey, rows: rows), .ignored, "Return on the hovered disabled Pause row does nothing")
        highlight.hoverBegan(GeneralRow.launchAtLogin.rawValue)
        expect(highlight.handle(.down, rows: rows), .moved, "Down from Launch at Login")
        expect(highlight.highlightedID, GeneralRow.quit.rawValue, "skips the disabled Pause row to Quit")
    }

    // M4 fix round 3 item 1: the lines after a user change replaced unreadable settings.
    static func settingsReplacedLines() {
        expect(PopoverText.settingsReplaced(copySaved: false),
               "Settings could not be read or backed up, and were replaced by your change.",
               "line when the retried copy failed")
        expect(PopoverText.settingsReplaced(copySaved: true),
               "Settings could not be read. A copy was saved, and your change replaced them.",
               "line when the retried copy worked")
    }
}
#endif
