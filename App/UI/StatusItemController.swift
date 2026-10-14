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
    private var content: NSHostingController<PopoverView>?
    private var keyMonitor: Any?
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
        model.popoverOpened()
        onOpen?()
        let content = NSHostingController(rootView: PopoverView(model: model))
        // fittingSize alone sizes the popover. Ignoring the window's safe area keeps a blank band off the top.
        content.sizingOptions = []
        content.safeAreaRegions = []
        self.content = content
        let size = fittingSize()
        content.preferredContentSize = size
        installKeyMonitor()
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
        let panel = FallbackPanel(contentRect: NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height - 6,
                                                      width: size.width, height: size.height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = content
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        onEvent?(.menuOpened)
    }

    func updatePopoverSize() {
        guard isOpen, let content else { return }
        let size = fittingSize()
        content.preferredContentSize = size
        if popover.isShown { popover.contentSize = size }
        if let panel {
            var frame = panel.frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height
            panel.setFrame(frame, display: true)
        }
    }

    /// Measures a fresh copy of the view, because the shown one picks up model changes only on its next update.
    private func fittingSize() -> NSSize {
        let measure = NSHostingController(rootView: PopoverView(model: model))
        let size = measure.sizeThatFits(in: NSSize(width: PopoverLayout.maxWidth, height: 10_000))
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    /// Routes arrow keys, Space and Return to the app list without giving the list focus.
    /// PopoverHighlight decides whether Space and Return may toggle a row.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.content?.view.window, event.window === window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let key: PopoverKey
            switch event.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 49: key = .space
            case 36, 76: key = .returnKey
            default: return event
            }
            return self.model.handleKey(key) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func closePopover() {
        if popover.isShown { popover.close() }
        if let panel {
            panel.close()
            self.panel = nil
            removeKeyMonitor()
            content = nil
            onEvent?(.menuClosed(now: Date()))
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        content = nil
        onEvent?(.menuClosed(now: Date()))
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            togglePopover()
        } else {
            onEvent?(.revealClicked(now: Date()))
        }
    }
}
