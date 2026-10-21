import Foundation
import SMHCore

// Pure rules for the popover. No AppKit or SwiftUI, so PopoverRulesTests.swift can test them directly.

struct MenuBarApp: Equatable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

enum PopoverKey: Equatable { case up, down, space, returnKey }

enum PopoverKeyResult: Equatable { case ignored, moved, toggle(String) }

/// The general rows below the app list, in keyboard order. The raw values are their row ids.
enum GeneralRow: String, CaseIterable {
    case delay = "smh.row.delay", launchAtLogin = "smh.row.login", pause = "smh.row.pause", quit = "smh.row.quit"
}

/// The highlighted row, and the "may toggle" rule for Space and Return.
///
/// The rule: when the popover opens, no row is highlighted and the keys are not armed.
/// Space and Return act on a row only after the user moved the highlight with an arrow key
/// or moved the mouse over a row in this popover session. So a stray key press while the popover
/// becomes key never changes settings. A pointer that already rests on a row when the popover
/// opens does not count until it moves.
struct PopoverHighlight: Equatable {
    private(set) var highlightedID: String?
    private(set) var armed = false
    private var pointerHasMoved = false
    private var pointerRowID: String?

    mutating func popoverOpened() {
        highlightedID = nil
        armed = false
        pointerHasMoved = false
        pointerRowID = nil
    }

    /// The pointer is over a row. This also fires when the popover opens under a still pointer.
    mutating func pointerEntered(_ id: String) {
        pointerRowID = id
        if pointerHasMoved { hoverBegan(id) }
    }

    mutating func pointerExited(_ id: String) {
        if pointerRowID == id { pointerRowID = nil }
        hoverEnded(id)
    }

    /// The mouse really moved after the popover opened.
    mutating func pointerMoved() {
        guard !pointerHasMoved else { return }
        pointerHasMoved = true
        if let pointerRowID { hoverBegan(pointerRowID) }
    }

    mutating func hoverBegan(_ id: String) {
        highlightedID = id
        armed = true
    }

    mutating func hoverEnded(_ id: String) {
        if highlightedID == id { highlightedID = nil }
    }

    mutating func handle(_ key: PopoverKey, rows: [String]) -> PopoverKeyResult {
        switch key {
        case .up, .down:
            guard !rows.isEmpty else { return .ignored }
            let offset = key == .down ? 1 : -1
            let index = rows.firstIndex { $0 == highlightedID } ?? (offset > 0 ? -1 : rows.count)
            highlightedID = rows[min(rows.count - 1, max(0, index + offset))]
            armed = true
            return .moved
        case .space, .returnKey:
            guard armed, let highlightedID, rows.contains(highlightedID) else { return .ignored }
            return .toggle(highlightedID)
        }
    }
}

struct PopoverRow: Equatable, Identifiable {
    let bundleID: String
    let name: String
    let isRunning: Bool
    let outsideApplications: Bool
    var id: String { bundleID }
}

enum PopoverRows {
    /// True for a third-party app whose running copy is not under /Applications. MenuBarAgent honors
    /// SMH's allow list only for copies in /Applications (measured on macOS 27.0.1). Apple's own
    /// processes run from /System and are never marked, and an unknown path is not marked either.
    static func isOutsideApplications(bundleID: String, bundlePath: String?) -> Bool {
        guard let bundlePath, !bundleID.hasPrefix("com.apple.") else { return false }
        return !bundlePath.hasPrefix("/Applications/") && !bundlePath.hasPrefix("/System/")
    }

    /// The footer note shows while a running, unticked app is outside /Applications. A ticked one is
    /// hidden on purpose, so it needs no note.
    static func outsideNoteVisible(rows: [PopoverRow], hidden: Set<String>) -> Bool {
        rows.contains { $0.isRunning && $0.outsideApplications && !hidden.contains($0.bundleID) }
    }

    /// The view shows app rows only when trusted and not on the first scan's spinner.
    static func showsAppRows(trusted: Bool, scanning: Bool, scannedIsEmpty: Bool) -> Bool {
        trusted && !(scanning && scannedIsEmpty)
    }

    /// The rows the arrow keys move through: the app rows that are on screen, then the general rows.
    /// A disabled Pause row is skipped, so no key can reach it.
    static func keyboardRows(apps: [String], trusted: Bool, scanning: Bool, scannedIsEmpty: Bool,
                             pauseEnabled: Bool = true) -> [String] {
        let shown = showsAppRows(trusted: trusted, scanning: scanning, scannedIsEmpty: scannedIsEmpty) ? apps : []
        let general = GeneralRow.allCases.filter { pauseEnabled || $0 != .pause }
        return shown + general.map(\.rawValue)
    }

    /// Drops the Apple system processes that the allow list never hides, so they are not offered.
    static func visibleScan(_ apps: [MenuBarApp]) -> [MenuBarApp] {
        apps.filter { !AllowList.neverHide.contains($0.bundleID) }
    }

    /// Scanned apps plus hidden apps the scan did not find, sorted by name.
    /// `running` is the real set of running bundle ids, because an app that answers
    /// Accessibility slowly is missing from the scan but still running.
    static func build(scanned: [MenuBarApp], hidden: Set<String>, names: [String: String],
                      running: Set<String>, outside: Set<String>) -> [PopoverRow] {
        var byID: [String: MenuBarApp] = [:]
        for app in visibleScan(scanned) { byID[app.bundleID] = app }
        for id in hidden where byID[id] == nil && !AllowList.neverHide.contains(id) {
            byID[id] = MenuBarApp(bundleID: id, name: names[id] ?? id)
        }
        return byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }.map {
            let isRunning = running.contains($0.bundleID)
            return PopoverRow(bundleID: $0.bundleID, name: $0.name, isRunning: isRunning,
                              outsideApplications: isRunning && outside.contains($0.bundleID))
        }
    }
}

/// Sizes the popover to its content, like a native menu.
enum PopoverLayout {
    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 14
    static let checkColumn: CGFloat = 19
    /// Space between the row highlight and the text, on each side.
    static let rowInset: CGFloat = 8
    /// Space between the popover edge and the row highlight, on each side.
    static let listInset: CGFloat = 6
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 300
    static var rowChrome: CGFloat { checkColumn + 2 * (rowInset + listInset) }
    /// Text wider than this truncates in the middle.
    static var textWidthLimit: CGFloat { maxWidth - rowChrome }

    static func width(widestText: CGFloat) -> CGFloat {
        min(maxWidth, max(minWidth, widestText.rounded(.up) + rowChrome))
    }
}

enum RevealDelayChoice {
    static let options: [(seconds: Double, label: String)] = [5, 10, 30, 60].map { ($0, label(for: $0)) }

    static func label(for seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole >= 60 && whole % 60 == 0 {
            let minutes = whole / 60
            return minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
        }
        return whole == 1 ? "1 Second" : "\(whole) Seconds"
    }
}

/// Reopens the popover after Accessibility is granted only when the user opened it while
/// untrusted in the last 5 minutes. Times are monotonic seconds (ProcessInfo.systemUptime).
enum TrustReopen {
    static let window: TimeInterval = 300

    static func shouldReopen(openedUntrustedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let openedUntrustedAt else { return false }
        return now - openedUntrustedAt <= window
    }
}

/// Spots an Accessibility grant. `lastTrusted` changes only in `check`, the 1 s trust check,
/// so a scan or a popover open that sees access first cannot hide the grant.
struct TrustWatch: Equatable {
    private(set) var lastTrusted: Bool
    private var openedUntrustedAt: TimeInterval?

    init(trusted: Bool) { lastTrusted = trusted }

    /// The user opened the popover, or pressed its Accessibility button, while untrusted.
    mutating func openedWhileUntrusted(now: TimeInterval) { openedUntrustedAt = now }

    /// Returns nil when access was not just granted. On a grant, returns whether to reopen the
    /// popover, and clears the open time so it is used only once.
    mutating func check(trusted: Bool, now: TimeInterval) -> Bool? {
        defer { lastTrusted = trusted }
        guard trusted && !lastTrusted else { return nil }
        let reopen = TrustReopen.shouldReopen(openedUntrustedAt: openedUntrustedAt, now: now)
        openedUntrustedAt = nil
        return reopen
    }
}

/// The Pause Hiding row. A pause for a competing hider shows a check mark and "<Name> running",
/// and disables the row, so it cannot change the user's saved pause.
struct PauseRow: Equatable {
    let checked: Bool
    /// "<Name> running". Set only while a competing hider pauses SMH.
    let trailing: String?
    /// The value a click gives the user's pause when the row is enabled.
    let clickSetsUserPause: Bool
    /// False while a competing hider pauses SMH.
    var enabled: Bool { trailing == nil }

    init(checked: Bool, trailing: String?, clickSetsUserPause: Bool) {
        self.checked = checked
        self.trailing = trailing
        self.clickSetsUserPause = clickSetsUserPause
    }

    init(userPaused: Bool, competitorName: String?) {
        self.init(checked: userPaused || competitorName != nil,
                  trailing: competitorName.map { "\($0) running" },
                  clickSetsUserPause: !userPaused)
    }

    /// The value a click or key gives the user's pause, or nil when the row is disabled.
    func click() -> Bool? { enabled ? clickSetsUserPause : nil }
}

/// Coalesces popover size updates: at most one per 0.2 s, and none while one is waiting.
struct SizeUpdateThrottle: Equatable {
    static let interval: TimeInterval = 0.2
    private var waiting = false
    private var lastRun: TimeInterval?

    /// Returns the delay for a new update, or nil when one is already waiting.
    mutating func request(now: TimeInterval) -> TimeInterval? {
        guard !waiting else { return nil }
        waiting = true
        guard let lastRun else { return 0 }
        return max(0, lastRun + Self.interval - now)
    }

    mutating func ran(now: TimeInterval) {
        waiting = false
        lastRun = now
    }
}

enum PopoverText {
    static let outsideTrailing = "outside /Applications"
    static let outsideNote = "Apps outside /\u{2060}Applications are hidden too (macOS\u{00A0}27 limit). Move them to /\u{2060}Applications."

    static func conflict(name: String) -> String {
        "\(name) is also hiding menu bar icons, so SMH has paused. Quit \(name) to use SMH."
    }

    static func settingsReset(backupError: String?) -> String {
        guard let backupError else { return "Settings could not be read and were reset. A copy was saved." }
        return "Settings could not be read and were reset. The copy could not be saved: \(backupError)"
    }

    /// The copy failed, so the stored settings were not touched.
    static func settingsLeft(backupError: String) -> String {
        "Settings could not be read and could not be backed up (\(backupError)). They were left as they are; SMH is using defaults for now."
    }

    /// A user change overwrote the unreadable settings, after a retried copy worked or failed.
    static func settingsReplaced(copySaved: Bool) -> String {
        copySaved ? "Settings could not be read. A copy was saved, and your change replaced them."
            : "Settings could not be read or backed up, and were replaced by your change."
    }
}
