import AppKit
import Dispatch
import OSLog
import SMHCore
import ApplicationServices
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private static let menuBarAgentID = "com.apple.MenuBarAgent"
    private let logger = Logger(subsystem: "dev.yili.smh", category: "controller")
    private let store = SettingsStore(store: UserDefaultsStore(defaults: .standard))
    /// Holds automatic saves while unreadable settings could not be copied aside (set at launch).
    private lazy var writer = SettingsWriter(store: store, holdAutomaticSaves: false)
    private let engine = HidingEngine(shim: SMHMenuBarShim())
    private let popoverModel = PopoverModel()
    private lazy var status = StatusItemController(model: popoverModel)
    private let scanner = MenuBarScanner()
    private var trustTimer: Timer?
    private var firstLaunch = false
    private var settingsNote = ""
    private(set) var settings = Settings()
    private(set) var state: BarState = .expanded
    /// The user's pause (saved in settings) plus the automatic pause while a competing hider runs.
    private var pause = PauseState(user: false)
    private var launched = false
    private var revealTimer: Timer?
    private var appChangeTimer: Timer?
    private var retryTimer: Timer?
    private var retryBackoff = RetryBackoff()
    private var agentRestart = ProcessRestartDetector()
    private var agentPollTimer: Timer?
    private var agentReapplyTimer: Timer?
    /// Wake and display changes come in bursts; they force one apply 0.5 s after the last one,
    /// and at most 2 s after the first one.
    private var systemDebounce = BurstDebounce()
    private var systemChangeTimer: Timer?
    private var scans = ScanSequence()
    private var scanCompletions: [() -> Void] = []
    /// Spots the Accessibility grant, and whether the user opened the popover while untrusted.
    private var trustWatch = TrustWatch(trusted: false)
    private var openingAutomatically = false
    private var settingsLineShown = false
    private var runningAppsObservation: NSKeyValueObservation?
    private var signalSources: [DispatchSourceSignal] = []
    #if DEBUG
    private var debugChannel: DebugChannel?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let recovered = SettingsRecovery.load(store: store, backup: Self.backUpSettings)
        settings = recovered.settings
        writer = SettingsWriter(store: store, holdAutomaticSaves: recovered.holdAutomaticSaves, backup: Self.backUpSettings)
        pause = PauseState(user: settings.paused)
        firstLaunch = recovered.firstLaunch
        settingsNote = recovered.note
        if !settingsNote.isEmpty {
            if let error = recovered.backupError {
                logger.error("settings corrupt and could not be copied (\(error, privacy: .public)); left as they are, using defaults in memory until the user changes a setting: \(self.settingsNote, privacy: .public)")
                popoverModel.settingsResetLine = PopoverText.settingsLeft(backupError: error)
            } else {
                logger.error("settings corrupt, reset to defaults: \(self.settingsNote, privacy: .public)")
                if let url = recovered.backupURL {
                    logger.error("saved the unreadable settings to \(url.path, privacy: .public)")
                }
                popoverModel.settingsResetLine = PopoverText.settingsReset(backupError: nil)
            }
        }
        if !recovered.droppedNeverHide.isEmpty {
            logger.notice("removed ids SMH never hides from the hidden set: \(recovered.droppedNeverHide.joined(separator: ","), privacy: .public)")
        }
        status.onEvent = { [weak self] event in
            self?.receive(event)
        }
        status.onOpen = { [weak self] in self?.popoverOpened() }
        status.onClose = { [weak self] in self?.popoverClosed() }
        status.onQuit = { [weak self] in self?.quit() }
        popoverModel.toggleApp = { [weak self] id in self?.toggleApp(id) }
        popoverModel.setRevealSeconds = { [weak self] seconds in self?.setRevealSeconds(seconds) }
        popoverModel.setPaused = { [weak self] paused in self?.setPaused(paused) {} }
        popoverModel.setLaunchAtLogin = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
        popoverModel.openAccessibilitySettings = { [weak self] in self?.openAccessibilitySettings() }
        popoverModel.quit = { [weak self] in self?.quit() }
        syncPopover()
        updateCompetitors()
        popoverModel.trusted = AXIsProcessTrusted()
        trustWatch = TrustWatch(trusted: popoverModel.trusted)
        // Launch and terminate notifications skip agent (LSUIElement) apps, which most menu bar apps are.
        // Observing runningApplications sees every app.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { [weak self] _, change in
            let appChange = RunningAppsChange(old: (change.oldValue ?? []).map(\.bundleIdentifier),
                                              new: (change.newValue ?? []).map(\.bundleIdentifier))
            Task { @MainActor in self?.runningAppsChanged(appChange) }
        }
        watchMenuBarAgent()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemChanged), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        installSignalHandlers()
        #if DEBUG
        debugChannel = DebugChannel(controller: self)
        #endif
        launched = true
        receive(.launched(shimAvailable: shimAvailableAtLaunch(),
                          inApplications: Bundle.main.bundlePath.hasPrefix("/Applications/"), now: Date()))
        scanApps()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        if firstLaunch { DispatchQueue.main.async { [weak self] in self?.openPopoverAutomatically() } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        receive(.quitRequested)
        for timer in [revealTimer, appChangeTimer, retryTimer, agentPollTimer, agentReapplyTimer, systemChangeTimer, trustTimer] {
            timer?.invalidate()
        }
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        signalSources.forEach { $0.cancel() }
    }

    private func runningAppsChanged(_ change: RunningAppsChange) {
        updateCompetitors()
        checkMenuBarAgent()
        if change.isEmpty { return }
        logger.info("running apps changed: \(change.launched.count) launched, \(change.terminated.count) terminated")
        appChangeTimer?.invalidate()
        // Common modes, so the debounce still fires while a menu (the Hide Again After menu) is tracking.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.receive(.runningAppsChanged)
                self?.scanApps()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        appChangeTimer = timer
    }

    /// Wake and display changes: the system may have dropped the assertion, so apply again even if the list is unchanged.
    /// A burst of them forces one apply, 0.5 s after the last one, or 2 s after the first one if the burst goes on.
    @objc private func systemChanged(_ notification: Notification) {
        logger.info("system change: \(notification.name.rawValue, privacy: .public); forcing apply after 0.5 s without more changes (2 s at most)")
        updateCompetitors()
        if let delay = systemDebounce.event(now: ProcessInfo.processInfo.systemUptime) {
            scheduleSystemChangeTimer(after: delay)
        }
    }

    private func scheduleSystemChangeTimer(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemChangeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        systemChangeTimer = timer
    }

    private func systemChangeTimerFired() {
        systemChangeTimer = nil
        switch systemDebounce.timerFired(now: ProcessInfo.processInfo.systemUptime) {
        case .act:
            logger.info("system changes settled; forcing apply")
            receive(.systemChanged)
            scanApps()
        case .wait(let delay):
            scheduleSystemChangeTimer(after: delay)
        case .idle:
            break
        }
    }

    /// MenuBarAgent shows up in NSWorkspace.runningApplications on macOS 27.0.1 (26A434), so the
    /// running-apps observation catches its restarts. If it is missing, SMH polls every 2 s instead.
    private func watchMenuBarAgent() {
        let pid = Self.menuBarAgentPID()
        _ = agentRestart.observe(pid: pid)
        let inWorkspace = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.menuBarAgentID }
        if inWorkspace {
            logger.info("MenuBarAgent watch: runningApplications observation (pid \(pid ?? -1))")
            return
        }
        logger.notice("MenuBarAgent watch: not in runningApplications; polling every 2 s")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuBarAgent() }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentPollTimer = timer
    }

    private func checkMenuBarAgent() {
        let pid = Self.menuBarAgentPID()
        guard agentRestart.observe(pid: pid) else { return }
        logger.notice("MenuBarAgent restarted (new pid \(pid ?? -1)); forcing apply in 1 s")
        // Give the new MenuBarAgent a moment to accept assertions; a failed apply would flash every icon.
        agentReapplyTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(.systemChanged) }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentReapplyTimer = timer
    }

    private static func menuBarAgentPID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentID).first?.processIdentifier
    }

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
        let context = BarContext(revealSeconds: settings.revealSeconds, paused: pause.effective,
                                 hiddenIsEmpty: settings.hidden.isEmpty)
        let (next, actions) = BarStateMachine.reduce(state, event, context)
        if next != state { logger.info("state: \(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public)") }
        state = next
        status.render(state: state, hiddenCount: settings.hidden.count, paused: pause.effective)
        syncPopover()
        var waitingForApply = false
        for action in actions {
            logger.info("action: \(String(describing: action), privacy: .public)")
            switch action {
            case .applyAllowList, .reapplyAllowList:
                waitingForApply = true
                applyAllowList(force: action == .reapplyAllowList, completion: completion)
            case .release:
                engine.release()
            case .scheduleRevealTimer(let until):
                scheduleRevealTimer(until: until)
            case .cancelRevealTimer:
                revealTimer?.invalidate()
                revealTimer = nil
            case .showWarning(let reason):
                logger.error("warning: \(StatusItemController.warningText(reason), privacy: .public)")
                status.render(state: .unavailable(reason), hiddenCount: settings.hidden.count, paused: pause.effective)
            }
        }
        updateRetryTimer()
        if !waitingForApply { completion?() }
    }

    private func applyAllowList(force: Bool, completion: (() -> Void)?) {
        let list = AllowList.compute(
            runningBundleIDs: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier),
            hidden: settings.hidden, ownBundleID: Bundle.main.bundleIdentifier!)
        engine.apply(list: list, force: force) { [weak self] error in
            if let error = error as NSError? {
                if !(error.domain == "SMHShim" && error.code == 2) {
                    self?.logger.error("apply failed: \(error.localizedDescription, privacy: .public)")
                    self?.receive(.applyFailed(error.localizedDescription))
                }
            } else {
                self?.retryBackoff.reset()
            }
            completion?()
        }
    }

    /// While an apply has failed and there is something to hide, retry after 2, 5, 15, 60 s, then every 60 s.
    private func updateRetryTimer() {
        guard RetryBackoff.shouldRetry(state: state, paused: pause.effective, hiddenIsEmpty: settings.hidden.isEmpty) else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        let delay = retryBackoff.nextDelay()
        logger.notice("apply failed; retrying in \(delay) s")
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryTimer = nil
                self?.receive(.retryApply)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// A relative timer runs on monotonic time. If the wall clock moved back meanwhile, the
    /// event carries the deadline, so the reveal still ends on time.
    private func scheduleRevealTimer(until: Date) {
        revealTimer?.invalidate()
        let delay = RevealTimer.delay(until: until, now: Date())
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                let due = ProcessInfo.processInfo.systemUptime >= deadline - 0.05
                self?.receive(.revealTimerFired(now: RevealTimer.eventNow(wallNow: Date(), until: until, monotonicDue: due)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Copies unreadable settings into the backup folder, at launch and when a user change retries it.
    private static func backUpSettings(_ data: Data) throws -> URL {
        try SettingsBackup.write(data, to: try SettingsRecovery.backupFolder(), now: Date())
    }

    /// Saves a user change. When saves were held, the change first retried the copy of the
    /// unreadable settings; this logs the result and updates the popover's settings line.
    private func saveUserChange() {
        let result = writer.saveUserChange(settings)
        switch result {
        case .saved:
            return
        case .copiedThenSaved(let url):
            logger.error("saved the unreadable settings to \(url.path, privacy: .public) on retry; the user's change replaced them")
        case .savedWithoutCopy(let error):
            logger.error("the unreadable settings were replaced by the user's change without a copy; the copy failed again: \(error, privacy: .public)")
        }
        let line = result.settingsLine(current: popoverModel.settingsResetLine)
        if line != popoverModel.settingsResetLine {
            popoverModel.settingsResetLine = line
            // The open popover shows the new line now, so it closes with this popover.
            if line != nil && status.isOpen { settingsLineShown = true }
        }
    }

    func setHidden(_ hidden: Set<String>, completion: @escaping () -> Void) {
        settings.hidden = hidden
        saveUserChange()
        syncPopover()
        receive(.hiddenSetChanged, completion: completion)
    }

    func toggleApp(_ id: String, completion: @escaping () -> Void = {}) {
        var updated = settings.hidden
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        setHidden(updated, completion: completion)
    }

    func setRevealSeconds(_ seconds: Double) {
        settings.revealSeconds = seconds
        saveUserChange()
        syncPopover()
    }

    func setPaused(_ paused: Bool, completion: @escaping () -> Void) {
        settings.paused = paused
        saveUserChange()
        _ = pause.setUser(paused)
        syncPopover()
        receive(.pauseToggled(now: Date()), completion: completion)
    }

    func togglePause() { setPaused(!settings.paused) {} }

    #if DEBUG
    /// Debug command `failNextApplies`: the next `count` applies fail before they reach the shim.
    func failNextApplies(_ count: Int) {
        logger.notice("debug: the next \(count) applies will fail")
        engine.failNextApplies(count)
    }
    #endif

    func openPopover() { status.openPopover() }
    func closePopover() { status.closePopover() }

    private func openPopoverAutomatically() {
        openingAutomatically = true
        status.openPopover()
        openingAutomatically = false
    }

    /// Only the newest scan's result is used, and `scanning` ends only when the newest one finishes.
    /// Completions of older scans run when the newest finishes.
    func scanApps(completion: (() -> Void)? = nil) {
        let number = scans.start()
        popoverModel.scanning = true
        if let completion { scanCompletions.append(completion) }
        scanner.scan { [weak self] apps in
            guard let self else { return }
            guard self.scans.finish(number) else {
                self.logger.info("ignored the result of older scan \(number)")
                return
            }
            self.popoverModel.trusted = apps != nil
            self.popoverModel.scanning = false
            self.popoverModel.running = Self.runningBundleIDs()
            if let apps {
                self.popoverModel.apps = apps
                // Save only when a hidden app's name changed, so opening the popover never writes settings.
                var names = self.settings.names
                for app in apps where self.settings.hidden.contains(app.bundleID) {
                    names[app.bundleID] = app.name
                }
                if names != self.settings.names {
                    self.settings.names = names
                    if !self.writer.saveAutomatic(self.settings) {
                        self.logger.notice("app names not saved: the unreadable settings are kept until a setting changes")
                    }
                    self.popoverModel.names = names
                }
            }
            self.status.updatePopoverSize()
            let done = self.scanCompletions
            self.scanCompletions = []
            done.forEach { $0() }
        }
    }

    private func popoverOpened() {
        popoverModel.trusted = AXIsProcessTrusted()
        if !popoverModel.trusted && !openingAutomatically {
            trustWatch.openedWhileUntrusted(now: ProcessInfo.processInfo.systemUptime)
        }
        if popoverModel.settingsResetLine != nil { settingsLineShown = true }
        popoverModel.loginError = nil
        popoverModel.launchAtLogin = SMAppService.mainApp.status == .enabled
        scanApps()
    }

    /// The corrupt-settings line shows until the popover that showed it closes.
    private func popoverClosed() {
        if settingsLineShown {
            popoverModel.settingsResetLine = nil
            settingsLineShown = false
        }
    }

    /// The grant is judged from TrustWatch's own last value, which only this check updates,
    /// so a scan or popover open that already set `popoverModel.trusted` cannot hide it.
    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        if let reopen = trustWatch.check(trusted: trusted, now: ProcessInfo.processInfo.systemUptime) {
            popoverModel.trusted = true
            logger.info("Accessibility granted; rescanning; reopen popover: \(reopen)")
            scanApps { [weak self] in
                guard let self, reopen else { return }
                self.status.closePopover()
                self.openPopoverAutomatically()
            }
        } else if trusted && !popoverModel.trusted {
            popoverModel.trusted = true
            scanApps()
        } else if !trusted { popoverModel.trusted = false }
    }

    private func openAccessibilitySettings() {
        // The user acted in the popover while untrusted, so reopen it once access is granted.
        trustWatch.openedWhileUntrusted(now: ProcessInfo.processInfo.systemUptime)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            popoverModel.launchAtLogin = SMAppService.mainApp.status == .enabled
            popoverModel.loginError = nil
        } catch {
            popoverModel.launchAtLogin = SMAppService.mainApp.status == .enabled
            popoverModel.loginError = error.localizedDescription
        }
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// A running competitor pauses SMH (release, expanded); its quit resumes SMH unless the user paused.
    private func updateCompetitors() {
        let competitors = ConflictDetector.detect(
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            })
        if competitors != popoverModel.competitors { popoverModel.competitors = competitors }
        if pause.competitorsChanged(running: !competitors.isEmpty) {
            if competitors.isEmpty {
                logger.notice("competing hider quit; resuming")
            } else {
                logger.notice("competing hider running: \(competitors.map(\.bundleID).joined(separator: ","), privacy: .public); pausing")
            }
            popoverModel.pausedForConflict = pause.forConflict
            if launched { receive(.pauseToggled(now: Date())) }
        }
    }

    private func shimAvailableAtLaunch() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SMH_DEBUG_FORCE_SHIM_MISSING"] == "1" { return false }
        #endif
        return SMHMenuBarShim.isAvailable()
    }

    private func syncPopover() {
        popoverModel.running = Self.runningBundleIDs()
        popoverModel.hidden = settings.hidden
        popoverModel.names = settings.names
        popoverModel.revealSeconds = settings.revealSeconds
        popoverModel.paused = settings.paused
        popoverModel.pausedForConflict = pause.forConflict
        popoverModel.state = state
        status.updatePopoverSize()
    }

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
                "allowCount": String(engine.allowCount), "applied": engine.isApplied ? "yes" : "no",
                "applyCount": String(engine.applyCount),
                "conflict": popoverModel.competitors.map(\.bundleID).joined(separator: ","),
                "settingsNote": settingsNote,
                "popover": status.isOpen ? "open" : "closed", "trusted": AXIsProcessTrusted() ? "yes" : "no"]
    }

    var scanFound: String {
        guard popoverModel.trusted else { return "untrusted" }
        return popoverModel.apps.map(\.bundleID).sorted().joined(separator: ",")
    }
}
