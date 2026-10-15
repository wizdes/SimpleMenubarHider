#if DEBUG
import AppKit
import OSLog

@MainActor
final class DebugChannel: NSObject {
    private let logger = Logger(subsystem: "dev.yili.smh", category: "debug")
    private weak var controller: AppController?
    private let center = DistributedNotificationCenter.default()
    private let commandName = Notification.Name("dev.yili.smh.debug.command")
    private let replyName = Notification.Name("dev.yili.smh.debug.state")

    init(controller: AppController) {
        self.controller = controller
        super.init()
        center.addObserver(self, selector: #selector(commandReceived), name: commandName,
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit { center.removeObserver(self) }

    @objc private func commandReceived(_ notification: Notification) {
        guard let values = notification.userInfo as? [String: String],
              let id = values["id"], let command = values["cmd"],
              let controller else {
            logger.error("invalid debug command")
            return
        }
        let reply: () -> Void = { [weak self] in self?.sendReply(id: id) }
        switch command {
        case "setHidden":
            guard let arg = values["arg"] else { logger.error("setHidden missing arg"); reply(); return }
            let ids = Set(arg.split(separator: ",", omittingEmptySubsequences: true).map(String.init))
            controller.setHidden(ids, completion: reply)
        case "setRevealSeconds":
            guard let arg = values["arg"], let seconds = Double(arg), seconds.isFinite else {
                logger.error("invalid reveal seconds")
                reply()
                return
            }
            controller.setRevealSeconds(seconds)
            reply()
        case "reveal":
            controller.receive(.revealClicked(now: Date()), completion: reply)
        case "pause":
            controller.setPaused(true, completion: reply)
        case "resume":
            controller.setPaused(false, completion: reply)
        case "openPopover":
            controller.openPopover()
            reply()
        case "closePopover":
            controller.closePopover()
            reply()
        case "toggleApp":
            guard let id = values["arg"], !id.isEmpty else {
                logger.error("toggleApp missing bundle id")
                reply()
                return
            }
            controller.toggleApp(id, completion: reply)
        case "scan":
            controller.scanApps { [weak self] in
                self?.sendReply(id: id, extra: ["found": controller.scanFound])
            }
        case "failNextApplies":
            guard let arg = values["arg"], let count = Int(arg), count >= 0 else {
                logger.error("failNextApplies needs a whole number 0 or more")
                reply()
                return
            }
            controller.failNextApplies(count)
            reply()
        case "state": reply()
        case "quit":
            controller.receive(.quitRequested)
            reply()
            NSApp.terminate(nil)
        default:
            logger.error("unknown debug command: \(command, privacy: .public)")
            reply()
        }
    }

    private func sendReply(id: String, extra: [String: String] = [:]) {
        guard var values = controller?.debugSnapshot else { return }
        values["id"] = id
        values.merge(extra) { _, new in new }
        center.postNotificationName(replyName, object: nil, userInfo: values, deliverImmediately: true)
    }
}
#endif
