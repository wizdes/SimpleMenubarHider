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

/// The highlighted app row, and the "may toggle" rule for Space and Return.
///
/// The rule: when the popover opens, no row is highlighted and the keys are not armed.
/// Space and Return toggle a row only after the user moved the highlight with an arrow key
/// or hovered a row in this popover session. So a stray key press while the popover
/// becomes key never changes settings.
struct PopoverHighlight: Equatable {
    private(set) var highlightedID: String?
    private(set) var armed = false

    mutating func popoverOpened() {
        highlightedID = nil
        armed = false
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
    var id: String { bundleID }
}

enum PopoverRows {
    /// Drops the Apple system processes that the allow list never hides, so they are not offered.
    static func visibleScan(_ apps: [MenuBarApp]) -> [MenuBarApp] {
        apps.filter { !AllowList.neverHide.contains($0.bundleID) }
    }

    /// Scanned apps plus hidden apps the scan did not find, sorted by name.
    /// `running` is the real set of running bundle ids, because an app that answers
    /// Accessibility slowly is missing from the scan but still running.
    static func build(scanned: [MenuBarApp], hidden: Set<String>, names: [String: String],
                      running: Set<String>) -> [PopoverRow] {
        var byID: [String: MenuBarApp] = [:]
        for app in visibleScan(scanned) { byID[app.bundleID] = app }
        for id in hidden where byID[id] == nil && !AllowList.neverHide.contains(id) {
            byID[id] = MenuBarApp(bundleID: id, name: names[id] ?? id)
        }
        return byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }.map { PopoverRow(bundleID: $0.bundleID, name: $0.name, isRunning: running.contains($0.bundleID)) }
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
