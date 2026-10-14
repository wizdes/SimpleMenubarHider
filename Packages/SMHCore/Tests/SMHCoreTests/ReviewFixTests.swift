import Foundation
import Testing
@testable import SMHCore

// Tests for the M4 review fixes. Each test names the review item it covers.

private let start = Date(timeIntervalSince1970: 1_000)
private let due = start.addingTimeInterval(10)
private let active = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: false)
private let paused = BarContext(revealSeconds: 10, paused: true, hiddenIsEmpty: false)
private let empty = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: true)
private let failed = BarState.unavailable(.applyFailed("oops"))
private let shimMissing = BarState.unavailable(.shimMissing("MenuBarClientCore"))
private let notInApps = BarState.unavailable(.notInApplications)

// Item 3: wake, display change and MenuBarAgent restart force a real apply while collapsed.
@Test(arguments: [
    Transition("collapsed, system changed", .collapsed, .systemChanged, active, .collapsed, [.reapplyAllowList]),
    Transition("expanded, system changed", .expanded, .systemChanged, active, .expanded, []),
    Transition("revealing, system changed", .revealing(until: due), .systemChanged, active, .revealing(until: due), []),
    Transition("failed, system changed", failed, .systemChanged, active, failed, []),
    Transition("collapsed, apps changed stays a plain apply", .collapsed, .runningAppsChanged, active, .collapsed, [.applyAllowList]),
])
func systemChangesForceApply(_ row: Transition) { row.check() }

@Test func agentRestartDetector() {
    var detector = ProcessRestartDetector()
    #expect(detector.observe(pid: 100) == false, "the first pid is the baseline")
    #expect(detector.observe(pid: 100) == false, "same pid")
    #expect(detector.observe(pid: 200) == true, "a new pid is a restart")
    #expect(detector.observe(pid: nil) == false, "gone is not yet a restart")
    #expect(detector.observe(pid: nil) == false, "still gone")
    #expect(detector.observe(pid: 300) == true, "back with a new pid")
    var late = ProcessRestartDetector()
    #expect(late.observe(pid: nil) == false, "not running at launch")
    #expect(late.observe(pid: 50) == true, "it started after SMH, so SMH must apply again")
}

// Item 4: recovery from applyFailed.
@Test(arguments: [
    Transition("failed, retry, active", failed, .retryApply, active, .collapsed, [.applyAllowList]),
    Transition("failed, retry, paused", failed, .retryApply, paused, .expanded, []),
    Transition("failed, retry, hidden empty", failed, .retryApply, empty, .expanded, []),
    Transition("failed, resume", failed, .pauseToggled(now: start), active, .collapsed, [.applyAllowList]),
    Transition("failed, pause on", failed, .pauseToggled(now: start), paused, .expanded, []),
    Transition("failed, row toggled", failed, .hiddenSetChanged, active, .collapsed, [.applyAllowList]),
    Transition("failed, last row unticked", failed, .hiddenSetChanged, empty, .expanded, []),
    Transition("collapsed, retry ignored", .collapsed, .retryApply, active, .collapsed, []),
    Transition("expanded, retry ignored", .expanded, .retryApply, active, .expanded, []),
    Transition("revealing, retry ignored", .revealing(until: due), .retryApply, active, .revealing(until: due), []),
    Transition("retry fails again", .collapsed, .applyFailed("again"), active, .unavailable(.applyFailed("again")), [.release, .showWarning(.applyFailed("again"))]),
])
func applyFailedRecovers(_ row: Transition) { row.check() }

@Test(arguments: [shimMissing, notInApps])
func terminalReasonsStayTerminal(_ state: BarState) {
    for event in [BarEvent.retryApply, .pauseToggled(now: start), .hiddenSetChanged, .systemChanged, .runningAppsChanged] {
        #expect(BarStateMachine.reduce(state, event, active) == (state, []), "\(event)")
        #expect(BarStateMachine.reduce(state, event, paused) == (state, []), "\(event) paused")
    }
}

@Test func retryBackoffSchedule() {
    var backoff = RetryBackoff()
    #expect((0..<7).map { _ in backoff.nextDelay() } == [2, 5, 15, 60, 60, 60, 60])
    backoff.reset()
    #expect(backoff.nextDelay() == 2, "a success starts the schedule over")
}

@Test func retryOnlyWhileFailedAndWanted() {
    #expect(RetryBackoff.shouldRetry(state: failed, paused: false, hiddenIsEmpty: false))
    #expect(!RetryBackoff.shouldRetry(state: failed, paused: true, hiddenIsEmpty: false))
    #expect(!RetryBackoff.shouldRetry(state: failed, paused: false, hiddenIsEmpty: true))
    #expect(!RetryBackoff.shouldRetry(state: shimMissing, paused: false, hiddenIsEmpty: false))
    #expect(!RetryBackoff.shouldRetry(state: notInApps, paused: false, hiddenIsEmpty: false))
    #expect(!RetryBackoff.shouldRetry(state: .collapsed, paused: false, hiddenIsEmpty: false))
}

// Item 5: SMH pauses itself while a competing hider runs.
@Test func conflictPause() {
    var pause = PauseState(user: false)
    #expect(pause.effective == false)
    #expect(pause.competitorsChanged(running: true) == true, "a competitor starts: SMH pauses")
    #expect(pause.effective && pause.forConflict)
    #expect(pause.competitorsChanged(running: true) == false, "no change while it keeps running")
    #expect(pause.competitorsChanged(running: false) == true, "it quits: SMH resumes")
    #expect(pause.effective == false)

    var manual = PauseState(user: true)
    #expect(manual.competitorsChanged(running: true) == false, "already paused by the user")
    #expect(manual.competitorsChanged(running: false) == false, "the user's pause stays")
    #expect(manual.effective == true)

    var both = PauseState(user: false)
    _ = both.competitorsChanged(running: true)
    #expect(both.setUser(true) == false, "pausing during a conflict changes nothing visible")
    #expect(both.competitorsChanged(running: false) == false, "the competitor quits, the user's pause holds")
    #expect(both.setUser(false) == true, "resume hides again")
    #expect(both.effective == false)

    var resumeDuringConflict = PauseState(user: true)
    _ = resumeDuringConflict.competitorsChanged(running: true)
    #expect(resumeDuringConflict.setUser(false) == false, "resume while the competitor runs keeps SMH paused")
    #expect(resumeDuringConflict.effective == true)
}

// Item 9: neverHide ids saved in the hidden set are dropped on load.
@Test func neverHideIdsAreDropped() {
    let saved = Settings(hidden: ["com.apple.controlcenter", "dev.example.app", "com.apple.MenuBarAgent"])
    let (clean, dropped) = saved.removingNeverHide()
    #expect(clean.hidden == ["dev.example.app"])
    #expect(dropped == ["com.apple.MenuBarAgent", "com.apple.controlcenter"])
    #expect(Settings(hidden: ["dev.example.app"]).removingNeverHide().dropped.isEmpty)
}

// Item 10: a reveal timer that fires before the deadline (the wall clock moved back) schedules again.
@Test(arguments: [
    Transition("revealing, clock moved back", .revealing(until: due), .revealTimerFired(now: start), active, .revealing(until: due), [.scheduleRevealTimer(at: due)]),
    Transition("revealing, on time", .revealing(until: due), .revealTimerFired(now: due), active, .collapsed, [.applyAllowList]),
])
func revealTimerEarly(_ row: Transition) { row.check() }

@Test func revealTimerDelays() {
    #expect(RevealTimer.delay(until: due, now: start) == 10)
    #expect(RevealTimer.delay(until: due, now: due) == 0.5, "never less than 0.5 s")
    #expect(RevealTimer.delay(until: start, now: due) == 0.5, "a past deadline still waits 0.5 s")
    #expect(RevealTimer.eventNow(wallNow: start, until: due, monotonicDue: true) == due,
            "the monotonic deadline passed, so the wall clock moving back does not hold the reveal")
    #expect(RevealTimer.eventNow(wallNow: due.addingTimeInterval(3), until: due, monotonicDue: true) == due.addingTimeInterval(3))
    #expect(RevealTimer.eventNow(wallNow: start, until: due, monotonicDue: false) == start, "early fire keeps the real time")
}

// Item 11: missing optional keys are not corrupt; hidden stays required; bad bytes get a backup.
@Test func settingsDecodeMissingOptionalKeys() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"hidden":["app"]}"#.utf8))
    #expect(settings == Settings(hidden: ["app"]))
    let store = InMemoryStore()
    store.set(Data(#"{"hidden":["app"],"paused":true}"#.utf8), forKey: SettingsStore.key)
    #expect(SettingsStore(store: store).load() == .loaded(Settings(hidden: ["app"], paused: true)))
}

@Test func settingsWithoutHiddenAreCorrupt() {
    let store = InMemoryStore()
    store.set(Data(#"{"revealSeconds":10,"paused":false,"schemaVersion":1}"#.utf8), forKey: SettingsStore.key)
    guard case .corrupt = SettingsStore(store: store).load() else {
        Issue.record("hidden is required")
        return
    }
    #expect(SettingsStore(store: store).storedData() == Data(#"{"revealSeconds":10,"paused":false,"schemaVersion":1}"#.utf8))
}

@Test func corruptSettingsBackup() throws {
    let when = Date(timeIntervalSince1970: 1_792_005_330) // 2026-10-14 19:15:30 UTC
    #expect(SettingsBackup.fileName(for: when) == "settings-corrupt-20261014T191530Z.json")
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        .appendingPathComponent("smh-backup-\(UUID().uuidString)").appendingPathComponent("Simple Menubar Hider")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let url = try SettingsBackup.write(Data("bad json".utf8), to: folder, now: when)
    #expect(url.lastPathComponent == "settings-corrupt-20261014T191530Z.json")
    #expect(try Data(contentsOf: url) == Data("bad json".utf8), "the backup holds the exact bad bytes")
    let second = try SettingsBackup.write(Data("other".utf8), to: folder, now: when)
    #expect(second != url, "a second backup in the same second does not overwrite the first")
    #expect(try Data(contentsOf: url) == Data("bad json".utf8))
}

// Item 12: the store writes to the defaults object it is given.
@Test func userDefaultsStoreUsesGivenDefaults() throws {
    let name = "dev.yili.smh.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(store: UserDefaultsStore(defaults: defaults))
    store.save(Settings(hidden: ["app"]))
    #expect(defaults.data(forKey: SettingsStore.key) != nil)
    #expect(store.load() == .loaded(Settings(hidden: ["app"])))
}

// Item 13: only the newest scan's result counts.
@Test func scanSequence() {
    var scans = ScanSequence()
    #expect(scans.scanning == false)
    let first = scans.start()
    let second = scans.start()
    #expect(scans.scanning)
    #expect(scans.finish(first) == false, "an older scan's result is ignored")
    #expect(scans.scanning, "still scanning until the newest finishes")
    #expect(scans.finish(second) == true)
    #expect(scans.scanning == false)
    let third = scans.start()
    #expect(scans.finish(third) == true)
    #expect(scans.finish(second) == false, "a late duplicate is ignored")
}
