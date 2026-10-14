import AppKit
import Dispatch
import OSLog
import SMHCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.yili.smh", category: "controller")
    private let store = SettingsStore(store: UserDefaultsStore(suiteName: "dev.yili.smh"))
    private let engine = HidingEngine()
    private let status = StatusItemController()
    private(set) var settings = Settings()
    private(set) var state: BarState = .expanded
    private var revealTimer: Timer?
    private var appChangeTimer: Timer?
    private var runningAppsObservation: NSKeyValueObservation?
    private var signalSources: [DispatchSourceSignal] = []
    #if DEBUG
    private var debugChannel: DebugChannel?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch store.load() {
        case .loaded(let value): settings = value
        case .missing: settings = Settings()
        case .corrupt(let fallback, let reason):
            settings = fallback
            logger.error("settings corrupt: \(reason, privacy: .public)")
        }
        status.onEvent = { [weak self] event in
            if case .pauseToggled = event { self?.togglePause() }
            else { self?.receive(event) }
        }
        status.onQuit = { [weak self] in self?.quit() }
        // Launch and terminate notifications skip agent (LSUIElement) apps, which most menu bar apps are.
        // Observing runningApplications sees every app.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { [weak self] _, change in
            let appChange = RunningAppsChange(old: (change.oldValue ?? []).map(\.bundleIdentifier),
                                              new: (change.newValue ?? []).map(\.bundleIdentifier))
            Task { @MainActor in self?.runningAppsChanged(appChange) }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        installSignalHandlers()
        #if DEBUG
        debugChannel = DebugChannel(controller: self)
        #endif
        receive(.launched(shimAvailable: SMHMenuBarShim.isAvailable(),
                          inApplications: Bundle.main.bundlePath.hasPrefix("/Applications/"), now: Date()))
    }

    func applicationWillTerminate(_ notification: Notification) {
        receive(.quitRequested)
        revealTimer?.invalidate()
        appChangeTimer?.invalidate()
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        signalSources.forEach { $0.cancel() }
    }

    private func runningAppsChanged(_ change: RunningAppsChange) {
        if change.isEmpty { return }
        logger.info("running apps changed: \(change.launched.count) launched, \(change.terminated.count) terminated")
        appChangeTimer?.invalidate()
        appChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(.runningAppsChanged) }
        }
    }

    @objc private func workspaceChanged(_ notification: Notification) { receive(.runningAppsChanged) }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.quit() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func receive(_ event: BarEvent, completion: (() -> Void)? = nil) {
        logger.info("event: \(String(describing: event), privacy: .public)")
        let context = BarContext(revealSeconds: settings.revealSeconds, paused: settings.paused,
                                 hiddenIsEmpty: settings.hidden.isEmpty)
        let (next, actions) = BarStateMachine.reduce(state, event, context)
        if next != state { logger.info("state: \(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public)") }
        state = next
        status.render(state: state, hiddenCount: settings.hidden.count, paused: settings.paused)
        if actions.isEmpty { completion?(); return }
        var waitingForApply = false
        for action in actions {
            logger.info("action: \(String(describing: action), privacy: .public)")
            switch action {
            case .applyAllowList:
                waitingForApply = true
                let list = AllowList.compute(
                    runningBundleIDs: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier),
                    hidden: settings.hidden, ownBundleID: Bundle.main.bundleIdentifier!)
                engine.apply(list: list) { [weak self] error in
                    if let error = error as NSError?, !(error.domain == "SMHShim" && error.code == 2) {
                        self?.logger.error("apply failed: \(error.localizedDescription, privacy: .public)")
                        self?.receive(.applyFailed(error.localizedDescription))
                    }
                    completion?()
                }
            case .release:
                engine.release()
            case .scheduleRevealTimer(let date):
                revealTimer?.invalidate()
                revealTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.receive(.revealTimerFired(now: Date())) }
                }
                if let revealTimer { RunLoop.main.add(revealTimer, forMode: .common) }
            case .cancelRevealTimer:
                revealTimer?.invalidate()
                revealTimer = nil
            case .showWarning(let reason):
                logger.error("warning: \(StatusItemController.warningText(reason), privacy: .public)")
                status.render(state: .unavailable(reason), hiddenCount: settings.hidden.count, paused: settings.paused)
            }
        }
        if !waitingForApply { completion?() }
    }

    func setHidden(_ hidden: Set<String>, completion: @escaping () -> Void) {
        settings.hidden = hidden
        store.save(settings)
        receive(.hiddenSetChanged, completion: completion)
    }

    func setRevealSeconds(_ seconds: Double) {
        settings.revealSeconds = seconds
        store.save(settings)
    }

    func setPaused(_ paused: Bool, completion: @escaping () -> Void) {
        settings.paused = paused
        store.save(settings)
        receive(.pauseToggled(now: Date()), completion: completion)
    }

    func togglePause() { setPaused(!settings.paused) {} }

    func quit() {
        receive(.quitRequested)
        NSApp.terminate(nil)
    }

    var debugSnapshot: [String: String] {
        let stateString: String
        switch state {
        case .expanded: stateString = "expanded"
        case .collapsed: stateString = "collapsed"
        case .revealing: stateString = "revealing"
        case .unavailable(let reason): stateString = "unavailable:\(StatusItemController.warningText(reason))"
        }
        return ["state": stateString, "hidden": settings.hidden.sorted().joined(separator: ","),
                "allowCount": String(engine.allowCount), "applied": engine.isApplied ? "yes" : "no"]
    }
}
