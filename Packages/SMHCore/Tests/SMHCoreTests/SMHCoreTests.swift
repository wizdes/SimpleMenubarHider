import Foundation
import Testing
@testable import SMHCore

@Test func allowListEmptyAndProtected() {
    #expect(AllowList.compute(runningBundleIDs: [], hidden: [], ownBundleID: "self") == ["self"])
    #expect(AllowList.systemItems == Array(0...255))
    #expect(AllowList.neverHide == ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.MenuBarAgent"])
}

@Test func allowListFiltersAndSorts() {
    let result = AllowList.compute(
        runningBundleIDs: [nil, "", "z", "z", "hidden", "com.apple.Spotlight", "a"],
        hidden: ["hidden", "self", "com.apple.Spotlight", "absent"], ownBundleID: "self")
    #expect(result == ["a", "com.apple.Spotlight", "self", "z"])
}

@Test func allowListEverythingHidden() {
    let protected = AllowList.neverHide
    let result = AllowList.compute(runningBundleIDs: Array(protected) + ["self", "other"], hidden: protected.union(["self", "other"]), ownBundleID: "self")
    #expect(Set(result) == protected.union(["self"]))
    #expect(result == result.sorted())
}

@Test func settingsDefaultsAndClamp() {
    #expect(Settings().hidden.isEmpty)
    #expect(Settings().revealSeconds == 10)
    #expect(Settings().paused == false)
    #expect(Settings().schemaVersion == 1)
    #expect(Settings(revealSeconds: 1).revealSeconds == 3)
    #expect(Settings(revealSeconds: 999).revealSeconds == 120)
    var value = Settings()
    value.revealSeconds = .nan
    #expect(value.revealSeconds == 10)
}

@Test func settingsStoreMissingRoundTripAndCorrupt() {
    let memory = InMemoryStore()
    let store = SettingsStore(store: memory)
    #expect(store.load() == .missing)
    #expect(store.load().settings == Settings())
    let settings = Settings(hidden: ["app"], revealSeconds: 15, paused: true)
    store.save(settings)
    #expect(store.load() == .loaded(settings))
    memory.set(Data("bad json".utf8), forKey: SettingsStore.key)
    let result = store.load()
    guard case .corrupt(let fallback, let reason) = result else {
        Issue.record("Expected corrupt settings")
        return
    }
    #expect(fallback == Settings())
    #expect(!reason.isEmpty)
}

@Test func settingsDecodeClamp() throws {
    let data = Data(#"{"hidden":[],"revealSeconds":999,"paused":false,"schemaVersion":1}"#.utf8)
    #expect(try JSONDecoder().decode(Settings.self, from: data).revealSeconds == 120)
}

private let now = Date(timeIntervalSince1970: 1_000)
private let active = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: false)

@Test func launchChecks() {
    #expect(BarStateMachine.reduce(.expanded, .launched(shimAvailable: false, inApplications: true, now: now), active) == (.unavailable(.shimMissing("MenuBarClientCore")), [.showWarning(.shimMissing("MenuBarClientCore"))]))
    #expect(BarStateMachine.reduce(.expanded, .launched(shimAvailable: true, inApplications: false, now: now), active) == (.unavailable(.notInApplications), [.showWarning(.notInApplications)]))
    #expect(BarStateMachine.reduce(.expanded, .launched(shimAvailable: true, inApplications: true, now: now), active) == (.collapsed, [.applyAllowList]))
    #expect(BarStateMachine.reduce(.expanded, .launched(shimAvailable: true, inApplications: true, now: now), BarContext(revealSeconds: 10, paused: true, hiddenIsEmpty: false)) == (.expanded, []))
    #expect(BarStateMachine.reduce(.expanded, .launched(shimAvailable: true, inApplications: true, now: now), BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: true)) == (.expanded, []))
}

@Test func revealClickAndEarlyCollapse() {
    let until = now.addingTimeInterval(10)
    #expect(BarStateMachine.reduce(.collapsed, .revealClicked(now: now), active) == (.revealing(until: until), [.release, .scheduleRevealTimer(at: until)]))
    #expect(BarStateMachine.reduce(.revealing(until: until), .revealClicked(now: now), active) == (.collapsed, [.cancelRevealTimer, .applyAllowList]))
    #expect(BarStateMachine.reduce(.expanded, .revealClicked(now: now), active) == (.expanded, []))
}

@Test func revealTimerChecks() {
    let until = now.addingTimeInterval(10)
    #expect(BarStateMachine.reduce(.revealing(until: until), .revealTimerFired(now: now), active) == (.revealing(until: until), []))
    #expect(BarStateMachine.reduce(.revealing(until: until), .revealTimerFired(now: until), active) == (.collapsed, [.applyAllowList]))
    #expect(BarStateMachine.reduce(.collapsed, .revealTimerFired(now: until), active) == (.collapsed, []))
}

@Test func menuPausesReveal() {
    let until = now.addingTimeInterval(10)
    let opened = BarStateMachine.reduce(.revealing(until: until), .menuOpened, active)
    #expect(opened.1 == [.cancelRevealTimer])
    #expect(BarStateMachine.reduce(opened.0, .revealTimerFired(now: until), active).0 == opened.0)
    let closed = BarStateMachine.reduce(opened.0, .menuClosed(now: until), active)
    #expect(closed == (.revealing(until: until.addingTimeInterval(10)), [.scheduleRevealTimer(at: until.addingTimeInterval(10))]))
    #expect(BarStateMachine.reduce(.collapsed, .menuOpened, active) == (.collapsed, []))
}

@Test func appAndHiddenChanges() {
    #expect(BarStateMachine.reduce(.collapsed, .runningAppsChanged, active) == (.collapsed, [.applyAllowList]))
    #expect(BarStateMachine.reduce(.collapsed, .hiddenSetChanged, active) == (.collapsed, [.applyAllowList]))
    let empty = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: true)
    #expect(BarStateMachine.reduce(.collapsed, .hiddenSetChanged, empty) == (.expanded, [.release]))
    #expect(BarStateMachine.reduce(.expanded, .runningAppsChanged, active) == (.expanded, []))
    #expect(BarStateMachine.reduce(.revealing(until: now), .hiddenSetChanged, active) == (.revealing(until: now), []))
}

@Test func pauseTransitions() {
    #expect(BarStateMachine.reduce(.collapsed, .pauseToggled(now: now), active) == (.expanded, [.release]))
    #expect(BarStateMachine.reduce(.revealing(until: now), .pauseToggled(now: now), active) == (.expanded, [.cancelRevealTimer, .release]))
    #expect(BarStateMachine.reduce(.expanded, .pauseToggled(now: now), active) == (.collapsed, [.applyAllowList]))
    let empty = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: true)
    #expect(BarStateMachine.reduce(.expanded, .pauseToggled(now: now), empty) == (.expanded, []))
}

@Test func failureQuitAndUnavailable() {
    let failure = BarStateMachine.reduce(.collapsed, .applyFailed("oops"), active)
    #expect(failure == (.unavailable(.applyFailed("oops")), [.release, .showWarning(.applyFailed("oops"))]))
    #expect(BarStateMachine.reduce(failure.0, .revealClicked(now: now), active) == (failure.0, []))
    #expect(BarStateMachine.reduce(failure.0, .quitRequested, active) == (failure.0, [.release]))
    #expect(BarStateMachine.reduce(.revealing(until: now), .quitRequested, active) == (.revealing(until: now), [.cancelRevealTimer, .release]))
    #expect(BarStateMachine.reduce(failure.0, .launched(shimAvailable: true, inApplications: true, now: now), active) == (.collapsed, [.applyAllowList]))
}

@Test func failedRelaunchReleasesActiveAssertion() {
    let result = BarStateMachine.reduce(.collapsed, .launched(shimAvailable: false, inApplications: true, now: now), active)
    #expect(result == (.unavailable(.shimMissing("MenuBarClientCore")), [.release, .showWarning(.shimMissing("MenuBarClientCore"))]))
}
