import AppKit
import SwiftUI
import SMHCore

@MainActor
final class PopoverModel: ObservableObject {
    static let headerTitle = "Hide menu bar icons for"
    static let delayTitle = "Hide Again After"
    static let actionTitles = ["Launch at Login", "Pause Hiding", "Quit Simple Menubar Hider"]

    @Published var apps: [MenuBarApp] = []
    @Published var running: Set<String> = []
    @Published var hidden: Set<String> = []
    @Published var names: [String: String] = [:]
    @Published var state: BarState = .expanded
    @Published var paused = false
    @Published var revealSeconds: Double = 10
    @Published var trusted = false
    @Published var scanning = true
    @Published var launchAtLogin = false
    @Published var loginError: String?
    @Published var competitors: [RunningCompetitor] = []
    /// SMH paused itself because a competing hider runs. `paused` stays the user's own choice.
    @Published var pausedForConflict = false
    /// The one-time "settings were reset" line, or nil.
    @Published var settingsResetLine: String?
    @Published var highlight = PopoverHighlight()
    /// Where the Hide Again After menu pops up. Only a view inside a window registers, so the
    /// off-screen copy that measures the popover size cannot take it over.
    let delayAnchor = MenuAnchor()
    private var openMouseLocation: NSPoint?
    var toggleApp: ((String) -> Void)?
    var setRevealSeconds: ((Double) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var setLaunchAtLogin: ((Bool) -> Void)?
    var openAccessibilitySettings: (() -> Void)?
    var quit: (() -> Void)?

    var rows: [PopoverRow] {
        PopoverRows.build(scanned: apps, hidden: hidden, names: names, running: running)
    }

    var footerVisible: Bool {
        guard !hidden.isEmpty && !paused && !pausedForConflict else { return false }
        if case .unavailable = state { return false }
        return true
    }

    var delayTrailing: String { "\(RevealDelayChoice.label(for: revealSeconds))  ›" }

    /// Width of the widest row, like a native menu. See PopoverLayout.width.
    var contentWidth: CGFloat {
        func measure(_ text: String, _ size: CGFloat) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
        }
        var widest = measure(Self.headerTitle, 11) - PopoverLayout.checkColumn
        // 16 pt is the row's minimum gap; 12 pt more covers SwiftUI drawing wider than NSString measures (the title was cut off).
        widest = max(widest, measure(Self.delayTitle, 13) + 16 + 12 + measure(delayTrailing, 13))
        for title in Self.actionTitles { widest = max(widest, measure(title, 13)) }
        if trusted {
            for row in rows {
                widest = max(widest, measure(row.name, 13) + (row.isRunning ? 0 : 4 + measure("not running", 10)))
            }
        }
        return PopoverLayout.width(widestText: widest)
    }

    var showsAppRows: Bool { PopoverRows.showsAppRows(trusted: trusted, scanning: scanning, scannedIsEmpty: apps.isEmpty) }

    /// The rows the keys act on: app rows only when they are on screen, then the general rows.
    var keyboardRows: [String] {
        PopoverRows.keyboardRows(apps: rows.map(\.bundleID), trusted: trusted, scanning: scanning, scannedIsEmpty: apps.isEmpty)
    }

    func popoverOpened() {
        highlight.popoverOpened()
        openMouseLocation = NSEvent.mouseLocation
    }

    /// Returns true when the key belongs to the popover list, so the caller swallows it.
    func handleKey(_ key: PopoverKey) -> Bool {
        var next = highlight
        let result = next.handle(key, rows: keyboardRows)
        if next != highlight { highlight = next }
        if case .toggle(let id) = result {
            if let row = GeneralRow(rawValue: id) { activate(row) } else { toggleApp?(id) }
        }
        return true
    }

    func activate(_ row: GeneralRow) {
        switch row {
        case .delay: showDelayMenu()
        case .launchAtLogin: setLaunchAtLogin?(!launchAtLogin)
        case .pause: setPaused?(!paused)
        case .quit: quit?()
        }
    }

    /// SwiftUI reports the pointer over a row also when the popover opens under a still pointer.
    /// Only a pointer that moved since the popover opened highlights a row and arms the keys.
    func pointer(_ phase: HoverPhase, over id: String) {
        var next = highlight
        switch phase {
        case .active:
            next.pointerEntered(id)
            if NSEvent.mouseLocation != openMouseLocation { next.pointerMoved() }
        case .ended:
            next.pointerExited(id)
        }
        if next != highlight { highlight = next }
    }

    func isHighlighted(_ id: String) -> Bool { highlight.highlightedID == id }

    func showDelayMenu() {
        guard let view = delayAnchor.view else { return }
        let menu = NSMenu()
        for option in RevealDelayChoice.options {
            let item = ClosureMenuItem(title: option.label) { [weak self] in self?.setRevealSeconds?(option.seconds) }
            item.state = option.seconds == revealSeconds ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.minY), in: view)
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    private let rowHeight = PopoverLayout.rowHeight
    private let edge = PopoverLayout.rowInset + PopoverLayout.listInset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PopoverModel.headerTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, edge)
                .padding(.top, 8)
                .padding(.bottom, 5)
            if let competitor = model.competitors.first {
                noteLine(PopoverText.conflict(name: competitor.name))
            }
            if let line = model.settingsResetLine {
                noteLine(line)
            }
            if !model.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow Accessibility access so SMH can find apps with menu bar icons.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings?() }
                        .focusable(false)
                }
                .font(.system(size: 13))
                .padding(.horizontal, edge).padding(.bottom, 8)
            } else {
                if let warning = warningText {
                    Text(warning)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, edge).padding(.bottom, 6)
                }
                let rows = model.rows
                if !model.showsAppRows {
                    HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Finding apps…") }
                        .font(.system(size: 13)).padding(.horizontal, edge).padding(.vertical, 8)
                } else if rows.isEmpty {
                    Text("No other apps have menu bar icons right now.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, edge).padding(.vertical, 8)
                } else {
                    // No focus and no starting highlight: StatusItemController routes arrow keys,
                    // Space and Return here through PopoverHighlight, which ignores them until armed.
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(rows) { row in
                                    appRow(row).id(row.id)
                                }
                            }.padding(.horizontal, PopoverLayout.listInset)
                        }
                        .frame(height: CGFloat(min(rows.count, PopoverLayout.maxVisibleRows)) * rowHeight)
                        .onChange(of: model.highlight.highlightedID) { _, id in
                            if let id, GeneralRow(rawValue: id) == nil { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            Divider().padding(.vertical, 5)
            delayRow
            actionRow(.launchAtLogin, PopoverModel.actionTitles[0], checked: model.launchAtLogin)
            if let error = model.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, edge).padding(.bottom, 4)
            }
            actionRow(.pause, PopoverModel.actionTitles[1], checked: model.paused)
            Divider().padding(.vertical, 5)
            actionRow(.quit, PopoverModel.actionTitles[2], checked: false)
            if model.footerVisible {
                Text("The Focus (moon) icon also hides while hiding is on. This is a macOS limit.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, edge).padding(.top, 6).padding(.bottom, 9)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .frame(width: model.contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }

    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, edge).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var warningText: String? {
        guard case .unavailable(let reason) = model.state else { return nil }
        switch reason {
        case .shimMissing:
            return "This version of macOS changed the private menu bar API. SMH is not hiding any icons. Your choices are saved."
        case .notInApplications:
            return "Move Simple Menubar Hider to the Applications folder. It can't hide icons from here."
        case .applyFailed(let message):
            return "Hiding failed: \(message). SMH is not hiding any icons. Your choices are saved."
        }
    }

    private func appRow(_ row: PopoverRow) -> some View {
        let checked = model.hidden.contains(row.bundleID)
        let selected = model.isHighlighted(row.bundleID)
        return Button {
            model.toggleApp?(row.bundleID)
        } label: {
            HStack(spacing: 0) {
                Text(checked ? "✓" : " ")
                    .frame(width: PopoverLayout.checkColumn, alignment: .leading)
                    .foregroundStyle(selected ? .white : .primary)
                Text(row.name)
                    .foregroundStyle(selected ? .white : (row.isRunning ? .primary : .secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !row.isRunning {
                    Text("not running").font(.system(size: 10))
                        .foregroundStyle(selected ? .white : .secondary)
                        .fixedSize()
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, PopoverLayout.rowInset)
            .frame(height: rowHeight)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onContinuousHover { phase in model.pointer(phase, over: row.bundleID) }
        .accessibilityRepresentation {
            Toggle(row.isRunning ? row.name : "\(row.name), not running", isOn: Binding(
                get: { model.hidden.contains(row.bundleID) },
                set: { _ in model.toggleApp?(row.bundleID) }
            ))
        }
    }

    private func menuRow(_ row: GeneralRow, _ title: String, trailing: String? = nil, checked: Bool = false) -> some View {
        let selected = model.isHighlighted(row.rawValue)
        return HStack(spacing: 0) {
            Text(checked ? "✓" : " ").frame(width: PopoverLayout.checkColumn, alignment: .leading)
            Text(title).lineLimit(1)
            Spacer(minLength: 16)
            if let trailing {
                Text(trailing).lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, PopoverLayout.rowInset)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(selected ? .white : .primary)
    }

    private func actionRow(_ row: GeneralRow, _ title: String, checked: Bool) -> some View {
        Button { model.activate(row) } label: { menuRow(row, title, checked: checked) }
            .buttonStyle(.plain)
            .focusable(false)
            .onContinuousHover { phase in model.pointer(phase, over: row.rawValue) }
            .padding(.horizontal, PopoverLayout.listInset)
            .accessibilityLabel(title)
            .accessibilityValue(checked ? "checked" : "unchecked")
    }

    /// A plain row; clicking it pops up a native menu of delays at the row's right edge.
    private var delayRow: some View {
        Button {
            model.showDelayMenu()
            // The pointer may have left while the menu tracked, without a hover end.
            model.pointer(.ended, over: GeneralRow.delay.rawValue)
        } label: {
            menuRow(.delay, PopoverModel.delayTitle, trailing: model.delayTrailing)
                .background(MenuAnchorView(anchor: model.delayAnchor))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onContinuousHover { phase in model.pointer(phase, over: GeneralRow.delay.rawValue) }
        .padding(.horizontal, PopoverLayout.listInset)
        .accessibilityLabel(PopoverModel.delayTitle)
        .accessibilityValue(RevealDelayChoice.label(for: model.revealSeconds))
    }
}

/// Holds the AppKit view behind a SwiftUI row, so an NSMenu can pop up next to it.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

private final class AnchorView: NSView {
    weak var anchor: MenuAnchor?
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { anchor?.view = self }
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.anchor = anchor
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.anchor = anchor
        if nsView.window != nil { anchor.view = nsView }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    @objc private func run() { handler?() }
}
