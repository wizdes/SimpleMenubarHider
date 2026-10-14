import AppKit
import SwiftUI
import SMHCore

@MainActor
final class PopoverModel: ObservableObject {
    @Published var apps: [MenuBarApp] = []
    @Published var hidden: Set<String> = []
    @Published var names: [String: String] = [:]
    @Published var state: BarState = .expanded
    @Published var paused = false
    @Published var revealSeconds: Double = 10
    @Published var trusted = false
    @Published var scanning = true
    @Published var launchAtLogin = false
    @Published var loginError: String?
    var toggleApp: ((String) -> Void)?
    var setRevealSeconds: ((Double) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var setLaunchAtLogin: ((Bool) -> Void)?
    var openAccessibilitySettings: (() -> Void)?
    var quit: (() -> Void)?

    var rows: [MenuBarApp] {
        var byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        for id in hidden where byID[id] == nil {
            byID[id] = MenuBarApp(bundleID: id, name: names[id] ?? id)
        }
        return byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }

    var runningIDs: Set<String> { Set(apps.map(\.bundleID)) }
    var footerVisible: Bool {
        guard !hidden.isEmpty && !paused else { return false }
        if case .unavailable = state { return false }
        return true
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @State private var highlightedID: String?
    @State private var hoveredAction: String?
    @FocusState private var listFocused: Bool
    private let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hide menu bar icons for")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)
            if !model.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow Accessibility access so SMH can find apps with menu bar icons.")
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings?() }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).padding(.bottom, 8)
            } else {
                if let warning = warningText {
                    Text(warning)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
                if model.scanning && model.apps.isEmpty {
                    HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Finding apps…") }
                        .font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 8)
                } else if model.rows.isEmpty {
                    Text("No other apps have menu bar icons right now.")
                        .font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 8)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(model.rows) { app in
                                    appRow(app).id(app.id)
                                }
                            }.padding(.horizontal, 6)
                        }
                        .frame(maxHeight: rowHeight * 14)
                        .focusable()
                        .focused($listFocused)
                        .focusEffectDisabled()
                        .onAppear {
                            highlightedID = model.rows.first?.id
                            listFocused = true
                        }
                        .onKeyPress(.upArrow) { moveHighlight(-1, proxy: proxy); return .handled }
                        .onKeyPress(.downArrow) { moveHighlight(1, proxy: proxy); return .handled }
                        .onKeyPress(.space) { activateHighlighted(); return .handled }
                        .onKeyPress(.return) { activateHighlighted(); return .handled }
                    }
                }
            }
            Divider().padding(.vertical, 5)
            Menu {
                ForEach([5, 10, 30, 60], id: \.self) { seconds in
                    Button("\(seconds) seconds") { model.setRevealSeconds?(Double(seconds)) }
                }
            } label: {
                menuRow("Hide Again After", trailing: "\(Int(model.revealSeconds)) seconds  ▸")
            }.menuStyle(.borderlessButton)
                .onHover { inside in hoveredAction = inside ? "Hide Again After" : nil }
            actionRow("Launch at Login", checked: model.launchAtLogin) {
                model.setLaunchAtLogin?(!model.launchAtLogin)
            }
            if let error = model.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 4)
            }
            actionRow("Pause Hiding", checked: model.paused) { model.setPaused?(!model.paused) }
            Divider().padding(.vertical, 5)
            actionRow("Quit Simple Menubar Hider", checked: false) { model.quit?() }
            if model.footerVisible {
                Text("The Focus (moon) icon also hides while hiding is on. This is a macOS limit.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 9)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .frame(width: 280)
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

    private func appRow(_ app: MenuBarApp) -> some View {
        let checked = model.hidden.contains(app.bundleID)
        let running = model.runningIDs.contains(app.bundleID)
        let selected = highlightedID == app.bundleID
        return Button {
            highlightedID = app.bundleID
            model.toggleApp?(app.bundleID)
        } label: {
            HStack(spacing: 0) {
                Text(checked ? "✓" : " ")
                    .frame(width: 19, alignment: .leading)
                    .foregroundStyle(selected ? .white : .primary)
                Text(app.name)
                    .foregroundStyle(selected ? .white : (running ? .primary : .secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !running {
                    Text("not running").font(.system(size: 10))
                        .foregroundStyle(selected ? .white : .secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { highlightedID = app.bundleID } }
        .accessibilityRepresentation {
            Toggle(running ? app.name : "\(app.name), not running", isOn: Binding(
                get: { model.hidden.contains(app.bundleID) },
                set: { _ in model.toggleApp?(app.bundleID) }
            ))
        }
    }

    private func menuRow(_ title: String, trailing: String? = nil, checked: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(checked ? "✓" : " ").frame(width: 19, alignment: .leading)
            Text(title)
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(hoveredAction == title ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(hoveredAction == title ? .white : .primary)
    }

    private func actionRow(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuRow(title, checked: checked) }
            .buttonStyle(.plain)
            .onHover { inside in hoveredAction = inside ? title : nil }
            .accessibilityLabel(title)
            .accessibilityValue(checked ? "checked" : "unchecked")
    }

    private func moveHighlight(_ offset: Int, proxy: ScrollViewProxy) {
        let rows = model.rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.bundleID == highlightedID } ?? (offset > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, index + offset))
        highlightedID = rows[next].bundleID
        proxy.scrollTo(rows[next].id)
    }

    private func activateHighlighted() {
        if let highlightedID { model.toggleApp?(highlightedID) }
    }
}
