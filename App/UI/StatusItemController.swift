import AppKit
import SMHCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Showing all", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Hiding", action: #selector(togglePause), keyEquivalent: "")
    private var paused = false
    private var state: BarState = .expanded
    var onEvent: ((BarEvent) -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Simple Menubar Hider", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Simple Menubar Hider")
        }
        render(state: .expanded, hiddenCount: 0, paused: false)
    }

    func render(state: BarState, hiddenCount: Int, paused: Bool) {
        self.state = state
        self.paused = paused
        let symbol: String
        switch state {
        case .collapsed:
            symbol = "eye.slash"
            statusLine.title = "Hiding \(hiddenCount) apps"
        case .expanded:
            symbol = "eye"
            statusLine.title = paused ? "Paused" : "Showing all"
        case .revealing:
            symbol = "eye"
            statusLine.title = "Showing all"
        case .unavailable(let reason):
            symbol = "exclamationmark.triangle"
            statusLine.title = Self.warningText(reason)
        }
        pauseItem.title = paused ? "Resume Hiding" : "Pause Hiding"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Simple Menubar Hider")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    static func warningText(_ reason: Reason) -> String {
        switch reason {
        case .shimMissing(let detail): "Hiding unavailable: \(detail)"
        case .notInApplications: "Move the app to /Applications to hide icons"
        case .applyFailed(let detail): "Hiding failed: \(detail)"
        }
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onEvent?(.revealClicked(now: Date()))
        }
    }

    @objc private func togglePause() { onEvent?(.pauseToggled(now: Date())) }
    @objc private func quitClicked() { onQuit?() }
    func menuWillOpen(_ menu: NSMenu) { onEvent?(.menuOpened) }
    func menuDidClose(_ menu: NSMenu) { onEvent?(.menuClosed(now: Date())) }
}
