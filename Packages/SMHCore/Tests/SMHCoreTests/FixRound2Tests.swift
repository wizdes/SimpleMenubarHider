import Foundation
import Testing
@testable import SMHCore

// Tests for the M4 fix round 2. Each test names the item it covers.

private func ms(_ step: BurstDebounce.Step) -> BurstDebounce.Step {
    if case .wait(let delay) = step { return .wait((delay * 1000).rounded() / 1000) }
    return step
}

// Item 9: a burst of wake and display-change events forces one apply, 0.5 s after the last event.
@Test func burstOfSystemChangesForcesOneApply() {
    var debounce = BurstDebounce()
    #expect(debounce.event(now: 10) == 0.5, "the first event starts a 0.5 s timer")
    #expect(debounce.event(now: 10.2) == nil, "a timer is already waiting")
    #expect(debounce.event(now: 10.4) == nil, "still waiting")
    #expect(ms(debounce.timerFired(now: 10.5)) == .wait(0.4), "the last event was 0.1 s ago, so wait 0.4 s more")
    #expect(debounce.timerFired(now: 10.9) == .act, "0.5 s after the last event: one forced apply")
    #expect(debounce.timerFired(now: 11) == .idle, "nothing more to do")
    #expect(debounce.event(now: 20) == 0.5, "a later event starts a new timer")
    #expect(debounce.timerFired(now: 20.5) == .act, "a single event acts after 0.5 s")
}
