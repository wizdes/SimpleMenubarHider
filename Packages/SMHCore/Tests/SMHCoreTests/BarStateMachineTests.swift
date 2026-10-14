import Foundation
import Testing
@testable import SMHCore

private let start = Date(timeIntervalSince1970: 1_000)
private let due = start.addingTimeInterval(10)
private let held = Date.distantFuture
private let warning = Reason.shimMissing("MenuBarClientCore")

private let active = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: false)
private let paused = BarContext(revealSeconds: 10, paused: true, hiddenIsEmpty: false)
private let empty = BarContext(revealSeconds: 10, paused: false, hiddenIsEmpty: true)
private let pausedEmpty = BarContext(revealSeconds: 10, paused: true, hiddenIsEmpty: true)
private let failed = BarState.unavailable(.applyFailed("oops"))

private func launch(shim: Bool = true, inApps: Bool = true) -> BarEvent {
    .launched(shimAvailable: shim, inApplications: inApps, now: start)
}

/// One row of the transition table: start state, event and context, then the expected result.
struct Transition: Sendable, CustomTestStringConvertible {
    let name: String
    let state: BarState
    let event: BarEvent
    let context: BarContext
    let next: BarState
    let actions: [BarAction]

    init(_ name: String, _ state: BarState, _ event: BarEvent, _ context: BarContext, _ next: BarState, _ actions: [BarAction]) {
        (self.name, self.state, self.event, self.context, self.next, self.actions) = (name, state, event, context, next, actions)
    }

    var testDescription: String { name }

    func check() {
        let result = BarStateMachine.reduce(state, event, context)
        #expect(result.0 == next, "\(name): state")
        #expect(result.1 == actions, "\(name): actions")
    }
}

// Bug 1: ticking the first app while expanded must hide it.
@Test(arguments: [
    Transition("expanded, app ticked, active", .expanded, .hiddenSetChanged, active, .collapsed, [.applyAllowList]),
    Transition("expanded, set changed, paused", .expanded, .hiddenSetChanged, paused, .expanded, []),
    Transition("expanded, set changed, hidden empty", .expanded, .hiddenSetChanged, empty, .expanded, []),
    Transition("collapsed, set changed, active", .collapsed, .hiddenSetChanged, active, .collapsed, [.applyAllowList]),
    Transition("collapsed, set cleared", .collapsed, .hiddenSetChanged, empty, .expanded, [.release]),
    Transition("collapsed, set changed while paused", .collapsed, .hiddenSetChanged, paused, .expanded, [.release]),
])
func hiddenSetChanges(_ row: Transition) { row.check() }

// Bug 2: a reveal must not re-hide after the set is cleared or pause is on.
@Test(arguments: [
    Transition("revealing, timer due, hidden empty", .revealing(until: due), .revealTimerFired(now: due), empty, .expanded, []),
    Transition("revealing, timer due, paused", .revealing(until: due), .revealTimerFired(now: due), paused, .expanded, []),
    Transition("revealing, timer due, active", .revealing(until: due), .revealTimerFired(now: due), active, .collapsed, [.applyAllowList]),
    // M4 review item 10: an early fire (the wall clock moved back) schedules the timer again.
    Transition("revealing, timer early", .revealing(until: due), .revealTimerFired(now: start), active, .revealing(until: due), [.scheduleRevealTimer(at: due)]),
    Transition("revealing, set cleared", .revealing(until: due), .hiddenSetChanged, empty, .expanded, [.cancelRevealTimer]),
    Transition("revealing, set changed, active", .revealing(until: due), .hiddenSetChanged, active, .revealing(until: due), []),
])
func revealAfterClearOrPause(_ row: Transition) { row.check() }

// Bug 3 and bug 5: launch releases a held assertion when it should not hide.
@Test(arguments: [
    Transition("expanded, launch, active", .expanded, launch(), active, .collapsed, [.applyAllowList]),
    Transition("expanded, launch, paused", .expanded, launch(), paused, .expanded, []),
    Transition("expanded, launch, hidden empty", .expanded, launch(), empty, .expanded, []),
    Transition("collapsed, relaunch, active", .collapsed, launch(), active, .collapsed, [.applyAllowList]),
    Transition("collapsed, relaunch, paused", .collapsed, launch(), paused, .expanded, [.release]),
    Transition("collapsed, relaunch, hidden empty", .collapsed, launch(), empty, .expanded, [.release]),
    Transition("revealing, relaunch, paused", .revealing(until: due), launch(), paused, .expanded, [.cancelRevealTimer, .release]),
    Transition("revealing, relaunch, hidden empty", .revealing(until: due), launch(), empty, .expanded, [.cancelRevealTimer, .release]),
    Transition("revealing, relaunch, active", .revealing(until: due), launch(), active, .collapsed, [.cancelRevealTimer, .applyAllowList]),
    Transition("unavailable, launch, active", failed, launch(), active, .collapsed, [.applyAllowList]),
    Transition("unavailable, launch, paused", failed, launch(), paused, .expanded, []),
    Transition("expanded, launch, shim missing", .expanded, launch(shim: false), active, .unavailable(warning), [.showWarning(warning)]),
    Transition("collapsed, launch, shim missing", .collapsed, launch(shim: false), active, .unavailable(warning), [.release, .showWarning(warning)]),
    Transition("revealing, launch, shim missing", .revealing(until: due), launch(shim: false), active, .unavailable(warning), [.cancelRevealTimer, .release, .showWarning(warning)]),
    Transition("collapsed, launch, outside Applications", .collapsed, launch(inApps: false), active, .unavailable(.notInApplications), [.release, .showWarning(.notInApplications)]),
    Transition("unavailable, launch, shim missing", failed, launch(shim: false), active, .unavailable(warning), [.showWarning(warning)]),
])
func launches(_ row: Transition) { row.check() }

// Bug 4: context.paused is the new value after the toggle.
@Test(arguments: [
    Transition("collapsed, pause on", .collapsed, .pauseToggled(now: start), paused, .expanded, [.release]),
    Transition("revealing, pause on", .revealing(until: due), .pauseToggled(now: start), paused, .expanded, [.cancelRevealTimer, .release]),
    Transition("expanded, pause on", .expanded, .pauseToggled(now: start), paused, .expanded, []),
    Transition("expanded, pause on, hidden empty", .expanded, .pauseToggled(now: start), pausedEmpty, .expanded, []),
    Transition("expanded, pause off", .expanded, .pauseToggled(now: start), active, .collapsed, [.applyAllowList]),
    Transition("expanded, pause off, hidden empty", .expanded, .pauseToggled(now: start), empty, .expanded, []),
    Transition("collapsed, pause off", .collapsed, .pauseToggled(now: start), active, .collapsed, [.applyAllowList]),
    // M4 review item 4: a failed apply recovers, so pausing settles to expanded (nothing is applied).
    Transition("unavailable, pause on", failed, .pauseToggled(now: start), paused, .expanded, []),
])
func pauseToggles(_ row: Transition) { row.check() }

// Existing rules: reveal clicks, timers, menus and running apps.
@Test(arguments: [
    Transition("collapsed, reveal click", .collapsed, .revealClicked(now: start), active, .revealing(until: due), [.release, .scheduleRevealTimer(at: due)]),
    Transition("revealing, reveal click hides early", .revealing(until: due), .revealClicked(now: start), active, .collapsed, [.cancelRevealTimer, .applyAllowList]),
    Transition("expanded, reveal click", .expanded, .revealClicked(now: start), active, .expanded, []),
    Transition("collapsed, stale timer", .collapsed, .revealTimerFired(now: due), active, .collapsed, []),
    Transition("expanded, stale timer", .expanded, .revealTimerFired(now: due), active, .expanded, []),
    Transition("revealing, menu opened", .revealing(until: due), .menuOpened, active, .revealing(until: held), [.cancelRevealTimer]),
    Transition("menu held, timer fired", .revealing(until: held), .revealTimerFired(now: due), active, .revealing(until: held), []),
    Transition("menu held, timer fired, hidden empty", .revealing(until: held), .revealTimerFired(now: due), empty, .revealing(until: held), []),
    Transition("menu held, menu closed", .revealing(until: held), .menuClosed(now: due), active, .revealing(until: due.addingTimeInterval(10)), [.scheduleRevealTimer(at: due.addingTimeInterval(10))]),
    Transition("revealing, menu closed without open", .revealing(until: due), .menuClosed(now: start), active, .revealing(until: due), []),
    Transition("collapsed, menu opened", .collapsed, .menuOpened, active, .collapsed, []),
    Transition("collapsed, menu closed", .collapsed, .menuClosed(now: start), active, .collapsed, []),
    Transition("collapsed, apps changed", .collapsed, .runningAppsChanged, active, .collapsed, [.applyAllowList]),
    Transition("expanded, apps changed", .expanded, .runningAppsChanged, active, .expanded, []),
    Transition("revealing, apps changed", .revealing(until: due), .runningAppsChanged, active, .revealing(until: due), []),
])
func revealAndMenuRules(_ row: Transition) { row.check() }

@Test(arguments: [
    Transition("expanded, apply failed", .expanded, .applyFailed("oops"), active, failed, [.release, .showWarning(.applyFailed("oops"))]),
    Transition("collapsed, apply failed", .collapsed, .applyFailed("oops"), active, failed, [.release, .showWarning(.applyFailed("oops"))]),
    Transition("revealing, apply failed", .revealing(until: due), .applyFailed("oops"), active, failed, [.cancelRevealTimer, .release, .showWarning(.applyFailed("oops"))]),
    Transition("unavailable, apply failed again", failed, .applyFailed("again"), active, failed, []),
])
func applyFailures(_ row: Transition) { row.check() }

@Test(arguments: [
    Transition("expanded, quit", .expanded, .quitRequested, active, .expanded, [.release]),
    Transition("collapsed, quit", .collapsed, .quitRequested, active, .collapsed, [.release]),
    Transition("revealing, quit", .revealing(until: due), .quitRequested, active, .revealing(until: due), [.cancelRevealTimer, .release]),
    Transition("unavailable, quit", failed, .quitRequested, active, failed, [.release]),
])
func quits(_ row: Transition) { row.check() }

// Bug 5: unavailable ignores every event except launch and quit.
// M4 review item 4: a failed apply now also recovers on Resume and on a row toggle
// (see applyFailedRecovers in ReviewFixTests.swift); the two terminal reasons still ignore both.
@Test(arguments: [
    BarEvent.revealClicked(now: start), .revealTimerFired(now: due), .menuOpened, .menuClosed(now: start),
    .runningAppsChanged, .hiddenSetChanged, .pauseToggled(now: start),
])
func unavailableIgnoresOtherEvents(_ event: BarEvent) {
    for terminal in [BarState.unavailable(warning), .unavailable(.notInApplications)] {
        #expect(BarStateMachine.reduce(terminal, event, active) == (terminal, []))
    }
    if event == .hiddenSetChanged || event == .pauseToggled(now: start) { return }
    #expect(BarStateMachine.reduce(failed, event, active) == (failed, []))
}

@Test func firstRunTickHides() {
    let launched = BarStateMachine.reduce(.expanded, launch(), empty)
    #expect(launched == (.expanded, []))
    #expect(BarStateMachine.reduce(launched.0, .hiddenSetChanged, active) == (.collapsed, [.applyAllowList]))
}

@Test func clearedDuringRevealStaysShown() {
    let revealed = BarStateMachine.reduce(.collapsed, .revealClicked(now: start), active)
    let cleared = BarStateMachine.reduce(revealed.0, .hiddenSetChanged, empty)
    #expect(cleared == (.expanded, [.cancelRevealTimer]))
    // A timer that fires after the cancel is ignored.
    #expect(BarStateMachine.reduce(cleared.0, .revealTimerFired(now: due), empty) == (.expanded, []))
}
