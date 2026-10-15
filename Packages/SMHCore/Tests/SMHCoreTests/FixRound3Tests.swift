import Foundation
import Testing
@testable import SMHCore

// Tests for the M4 fix round 3. Each test names the item it covers.

private func ms(_ time: TimeInterval) -> TimeInterval { (time * 1000).rounded() / 1000 }

// Item 3: a steady stream of events, one every 0.3 s, never leaves a 0.5 s gap.
// The longest wait still forces one apply 2 s after the first event of each burst.
@Test func steadyStreamOfSystemChangesStillAppliesWithinTwoSeconds() {
    var debounce = BurstDebounce()
    var timerAt: TimeInterval?
    var acts: [TimeInterval] = []
    func fireTimers(until now: TimeInterval) {
        while let at = timerAt, at <= now {
            timerAt = nil
            switch debounce.timerFired(now: at) {
            case .act: acts.append(ms(at))
            case .wait(let delay): timerAt = at + delay
            case .idle: break
            }
        }
    }
    for index in 0..<14 {
        let now = 10 + Double(index) * 0.3
        fireTimers(until: now)
        if let delay = debounce.event(now: now) { timerAt = now + delay }
    }
    fireTimers(until: 100)
    #expect(BurstDebounce.longestWait == 2, "the longest wait is 2 s")
    #expect(acts == [12, 14.1], "one apply 2 s after the burst began (10 s), then 2 s after the next burst began (12.1 s)")
}

// Item 3: the timer waits for the earlier of 0.5 s after the last event and 2 s after the first.
@Test func longestWaitCutsTheTimerShort() {
    var debounce = BurstDebounce()
    #expect(debounce.event(now: 10) == 0.5, "the first event starts a 0.5 s timer")
    #expect(debounce.event(now: 11.8) == nil, "a timer is already waiting")
    if case .wait(let delay) = debounce.timerFired(now: 11.9) {
        #expect(ms(delay) == 0.1, "2 s after the first event comes before 0.5 s after the last one")
    } else {
        Issue.record("expected a wait of 0.1 s")
    }
    #expect(debounce.timerFired(now: 12) == .act, "2 s after the first event: apply")
    #expect(debounce.timerFired(now: 12.1) == .idle, "nothing more to do")
}
