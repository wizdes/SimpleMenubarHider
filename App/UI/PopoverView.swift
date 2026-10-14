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
    @Published var highlight = PopoverHighlight()
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
        guard !hidden.isEmpty && !paused else { return false }
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

    func popoverOpened() { highlight.popoverOpened() }

    /// Returns true when the key belongs to the popover list, so the caller swallows it.
    func handleKey(_ key: PopoverKey) -> Bool {
        if case .toggle(let id) = highlight.handle(key, rows: rows.map(\.bundleID)) { toggleApp?(id) }
        return true
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @State private var hoveredAction: String?
    @State private var delayAnchor = MenuAnchor()
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
                if model.scanning && model.apps.isEmpty {
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
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            Divider().padding(.vertical, 5)
            delayRow
            actionRow(PopoverModel.actionTitles[0], checked: model.launchAtLogin) {
                model.setLaunchAtLogin?(!model.launchAtLogin)
            }
            if let error = model.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, edge).padding(.bottom, 4)
            }
            actionRow(PopoverModel.actionTitles[1], checked: model.paused) { model.setPaused?(!model.paused) }
            Divider().padding(.vertical, 5)
            actionRow(PopoverModel.actionTitles[2], checked: false) { model.quit?() }
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
        let selected = model.highlight.highlightedID == row.bundleID
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
        .onHover { inside in
            if inside { model.highlight.hoverBegan(row.bundleID) } else { model.highlight.hoverEnded(row.bundleID) }
        }
        .accessibilityRepresentation {
            Toggle(row.isRunning ? row.name : "\(row.name), not running", isOn: Binding(
                get: { model.hidden.contains(row.bundleID) },
                set: { _ in model.toggleApp?(row.bundleID) }
            ))
        }
    }

    private func menuRow(_ title: String, trailing: String? = nil, checked: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(checked ? "✓" : " ").frame(width: PopoverLayout.checkColumn, alignment: .leading)
            Text(title).lineLimit(1)
            Spacer(minLength: 16)
            if let trailing {
                Text(trailing).lineLimit(1)
                    .foregroundStyle(hoveredAction == title ? Color.white : Color.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, PopoverLayout.rowInset)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(hoveredAction == title ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(hoveredAction == title ? .white : .primary)
    }

    private func actionRow(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuRow(title, checked: checked) }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { inside in hoveredAction = inside ? title : nil }
            .padding(.horizontal, PopoverLayout.listInset)
            .accessibilityLabel(title)
            .accessibilityValue(checked ? "checked" : "unchecked")
    }

    /// A plain row; clicking it pops up a native menu of delays at the row's right edge.
    private var delayRow: some View {
        Button { showDelayMenu() } label: {
            menuRow(PopoverModel.delayTitle, trailing: model.delayTrailing)
                .background(MenuAnchorView(anchor: delayAnchor))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in hoveredAction = inside ? PopoverModel.delayTitle : nil }
        .padding(.horizontal, PopoverLayout.listInset)
        .accessibilityLabel(PopoverModel.delayTitle)
        .accessibilityValue(RevealDelayChoice.label(for: model.revealSeconds))
    }

    private func showDelayMenu() {
        guard let view = delayAnchor.view else { return }
        let menu = NSMenu()
        for option in RevealDelayChoice.options {
            let item = ClosureMenuItem(title: option.label) { [model] in model.setRevealSeconds?(option.seconds) }
            item.state = option.seconds == model.revealSeconds ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.minY), in: view)
        hoveredAction = nil
    }
}

/// Holds the AppKit view behind a SwiftUI row, so an NSMenu can pop up next to it.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
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
