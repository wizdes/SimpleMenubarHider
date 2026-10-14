import AppKit
import OSLog
import SwiftUI
import SMHCore

private final class FallbackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let logger = Logger(subsystem: "dev.yili.smh", category: "popover")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var panel: FallbackPanel?
    private let model: PopoverModel
    var onEvent: ((BarEvent) -> Void)?
    var onOpen: (() -> Void)?
    var onQuit: (() -> Void)?
    var isOpen: Bool { popover.isShown || panel?.isVisible == true }

    init(model: PopoverModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Simple Menubar Hider")
        }
        render(state: .expanded, hiddenCount: 0, paused: false)
    }

    func render(state: BarState, hiddenCount: Int, paused: Bool) {
        let symbol: String
        switch state {
        case .collapsed: symbol = "eye.slash"
        case .expanded, .revealing: symbol = "eye"
        case .unavailable: symbol = "exclamationmark.triangle"
        }
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

    func togglePopover() { isOpen ? closePopover() : openPopover() }

    func openPopover() {
        if isOpen { return }
        onOpen?()
        let content = NSHostingController(rootView: PopoverView(model: model))
        let height = contentHeight
        content.preferredContentSize = NSSize(width: 280, height: height)
        if let button = statusItem.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = NSScreen.screens.contains { $0.frame.intersects(frame) }
            if visible {
                logger.info("popover anchor button frame: \(String(describing: frame), privacy: .public); path=button")
                popover.contentViewController = content
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                onEvent?(.menuOpened)
                return
            }
            logger.warning("popover anchor button frame off-screen: \(String(describing: frame), privacy: .public); path=mouse-panel")
        } else {
            logger.warning("popover anchor has no button window; path=mouse-panel")
        }
        let mouse = NSEvent.mouseLocation
        let panel = FallbackPanel(contentRect: NSRect(x: mouse.x - 140, y: mouse.y - height - 6, width: 280, height: height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = content
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        onEvent?(.menuOpened)
    }

    func updatePopoverSize() {
        guard isOpen else { return }
        let size = NSSize(width: 280, height: contentHeight)
        if popover.isShown { popover.contentSize = size }
        if let panel {
            var frame = panel.frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height
            panel.setFrame(frame, display: true)
        }
    }

    private var contentHeight: CGFloat {
        let rowCount = model.trusted ? min(model.rows.count, 14) : 0
        let messageHeight: CGFloat = model.trusted ? (model.scanning || model.rows.isEmpty ? 48 : 0) : 85
        let footerHeight: CGFloat = model.footerVisible ? 48 : 0
        let warningHeight: CGFloat
        if case .unavailable = model.state, model.trusted { warningHeight = 65 }
        else { warningHeight = 0 }
        return 145 + CGFloat(rowCount) * 22 + messageHeight + footerHeight + warningHeight
            + (model.loginError == nil ? 0 : 35)
    }

    func closePopover() {
        if popover.isShown { popover.close() }
        if let panel {
            panel.close()
            self.panel = nil
            onEvent?(.menuClosed(now: Date()))
        }
    }

    func popoverDidClose(_ notification: Notification) { onEvent?(.menuClosed(now: Date())) }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            togglePopover()
        } else {
            onEvent?(.revealClicked(now: Date()))
        }
    }
}
