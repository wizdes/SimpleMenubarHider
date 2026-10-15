import Foundation

/// Waits between automatic retries after an apply failed: 2 s, 5 s, 15 s, 60 s, then every 60 s.
public struct RetryBackoff: Equatable, Sendable {
    public static let delays: [TimeInterval] = [2, 5, 15, 60]
    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return Self.delays[min(attempt, Self.delays.count - 1)]
    }

    /// A successful apply starts the schedule over.
    public mutating func reset() { attempt = 0 }

    /// Only a failed apply retries, and only while there is something to hide.
    /// A missing shim or a copy outside /Applications cannot fix itself, so those never retry.
    public static func shouldRetry(state: BarState, paused: Bool, hiddenIsEmpty: Bool) -> Bool {
        guard case .unavailable(.applyFailed) = state else { return false }
        return !paused && !hiddenIsEmpty
    }
}

/// The user's own pause plus the automatic pause while another menu bar hider runs.
public struct PauseState: Equatable, Sendable {
    public private(set) var user: Bool
    public private(set) var forConflict = false
    public var effective: Bool { user || forConflict }

    public init(user: Bool) { self.user = user }

    /// Returns true when the effective pause changed, so the bar must settle again.
    public mutating func competitorsChanged(running: Bool) -> Bool {
        let before = effective
        forConflict = running
        return effective != before
    }

    /// Returns true when the effective pause changed.
    public mutating func setUser(_ paused: Bool) -> Bool {
        let before = effective
        user = paused
        return effective != before
    }
}

/// Spots a restart of a process from its pid, such as MenuBarAgent.
public struct ProcessRestartDetector: Equatable, Sendable {
    private var observed = false
    private var lastPID: Int32?

    public init() {}

    /// Returns true when a pid appears that differs from the last one seen. The first call only records.
    public mutating func observe(pid: Int32?) -> Bool {
        defer { observed = true }
        guard let pid else { return false }
        let restarted = observed && pid != lastPID
        lastPID = pid
        return restarted
    }
}

/// Turns a burst of wake and display-change events into one forced apply, 0.5 s after the last event.
/// A steady stream that never pauses for 0.5 s still applies 2 s after the burst's first event.
/// Times are monotonic seconds (ProcessInfo.systemUptime).
public struct BurstDebounce: Equatable, Sendable {
    public static let delay: TimeInterval = 0.5
    public static let longestWait: TimeInterval = 2

    public enum Step: Equatable, Sendable {
        /// The burst is over: apply now.
        case act
        /// More events came: start the timer again with this delay.
        case wait(TimeInterval)
        /// No event is waiting.
        case idle
    }

    private var firstEvent: TimeInterval?
    private var lastEvent: TimeInterval?

    public init() {}

    /// Records an event. Returns the delay for a new timer, or nil when a timer is already waiting.
    public mutating func event(now: TimeInterval) -> TimeInterval? {
        let waiting = lastEvent != nil
        if !waiting { firstEvent = now }
        lastEvent = now
        return waiting ? nil : Self.delay
    }

    /// The timer fired.
    public mutating func timerFired(now: TimeInterval) -> Step {
        guard let lastEvent else { return .idle }
        let due = min(lastEvent + Self.delay, (firstEvent ?? lastEvent) + Self.longestWait)
        let remaining = due - now
        // 1 ms of slack, so a timer that fires a hair early does not wait again.
        if remaining > 0.001 { return .wait(remaining) }
        self.lastEvent = nil
        firstEvent = nil
        return .act
    }
}

/// Gives each scan a number, so a slow older scan cannot overwrite a newer result.
public struct ScanSequence: Equatable, Sendable {
    private var newest = 0
    private var newestFinished = true

    public init() {}

    public var scanning: Bool { !newestFinished }

    public mutating func start() -> Int {
        newest += 1
        newestFinished = false
        return newest
    }

    /// Returns true when this is the newest scan and its result should be used.
    public mutating func finish(_ number: Int) -> Bool {
        guard number == newest, !newestFinished else { return false }
        newestFinished = true
        return true
    }
}

/// Reveal timer math. The app schedules a relative (monotonic) timer, so a wall clock change cannot stretch it.
public enum RevealTimer {
    public static let minimumDelay: TimeInterval = 0.5

    public static func delay(until: Date, now: Date) -> TimeInterval {
        max(minimumDelay, until.timeIntervalSince(now))
    }

    /// The time to send with revealTimerFired. When the monotonic deadline passed but the wall clock
    /// moved back, the deadline itself is used, so the state machine re-hides instead of waiting.
    public static func eventNow(wallNow: Date, until: Date, monotonicDue: Bool) -> Date {
        monotonicDue ? max(wallNow, until) : wallNow
    }
}
