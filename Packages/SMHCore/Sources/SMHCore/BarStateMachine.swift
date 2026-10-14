import Foundation

public enum Reason: Equatable, Sendable {
    case shimMissing(String), notInApplications, applyFailed(String)
}

public enum BarState: Equatable, Sendable {
    case expanded, collapsed, revealing(until: Date), unavailable(Reason)
}

public enum BarEvent: Equatable, Sendable {
    case launched(shimAvailable: Bool, inApplications: Bool, now: Date)
    case revealClicked(now: Date), revealTimerFired(now: Date)
    case menuOpened, menuClosed(now: Date)
    case runningAppsChanged, hiddenSetChanged
    case pauseToggled(now: Date), applyFailed(String), quitRequested
}

public enum BarAction: Equatable, Sendable {
    case applyAllowList, release, scheduleRevealTimer(at: Date), cancelRevealTimer, showWarning(Reason)
}

public struct BarContext: Sendable {
    public var revealSeconds: Double
    public var paused: Bool
    public var hiddenIsEmpty: Bool

    public init(revealSeconds: Double, paused: Bool, hiddenIsEmpty: Bool) {
        self.revealSeconds = revealSeconds
        self.paused = paused
        self.hiddenIsEmpty = hiddenIsEmpty
    }
}

public enum BarStateMachine {
    // The public state shape has no menu-open flag. A distant-future deadline means
    // a menu holds the reveal open; menuClosed replaces it with a new deadline.
    private static let menuHeldUntil = Date.distantFuture

    public static func reduce(_ state: BarState, _ event: BarEvent, _ context: BarContext) -> (BarState, [BarAction]) {
        if case .quitRequested = event {
            if case .revealing = state { return (state, [.cancelRevealTimer, .release]) }
            return (state, [.release])
        }

        if case .launched(let shimAvailable, let inApplications, _) = event {
            if !shimAvailable {
                let reason = Reason.shimMissing("MenuBarClientCore")
                return (.unavailable(reason), releaseActions(for: state) + [.showWarning(reason)])
            }
            if !inApplications {
                return (.unavailable(.notInApplications), releaseActions(for: state) + [.showWarning(.notInApplications)])
            }
            if context.paused || context.hiddenIsEmpty { return (.expanded, []) }
            return (.collapsed, [.applyAllowList])
        }

        if case .unavailable = state { return (state, []) }

        switch event {
        case .revealClicked(let now):
            switch state {
            case .collapsed:
                let until = now.addingTimeInterval(context.revealSeconds)
                return (.revealing(until: until), [.release, .scheduleRevealTimer(at: until)])
            case .revealing:
                return (.collapsed, [.cancelRevealTimer, .applyAllowList])
            default: return (state, [])
            }
        case .revealTimerFired(let now):
            if case .revealing(let until) = state, now >= until, until != menuHeldUntil {
                return (.collapsed, [.applyAllowList])
            }
            return (state, [])
        case .menuOpened:
            if case .revealing = state { return (.revealing(until: menuHeldUntil), [.cancelRevealTimer]) }
            return (state, [])
        case .menuClosed(let now):
            if case .revealing(let until) = state, until == menuHeldUntil {
                let newUntil = now.addingTimeInterval(context.revealSeconds)
                return (.revealing(until: newUntil), [.scheduleRevealTimer(at: newUntil)])
            }
            return (state, [])
        case .runningAppsChanged:
            if case .collapsed = state { return (state, [.applyAllowList]) }
            return (state, [])
        case .hiddenSetChanged:
            if case .collapsed = state {
                if context.hiddenIsEmpty { return (.expanded, [.release]) }
                return (state, [.applyAllowList])
            }
            return (state, [])
        case .pauseToggled:
            switch state {
            case .collapsed: return (.expanded, [.release])
            case .revealing: return (.expanded, [.cancelRevealTimer, .release])
            case .expanded where !context.hiddenIsEmpty: return (.collapsed, [.applyAllowList])
            default: return (state, [])
            }
        case .applyFailed(let message):
            let reason = Reason.applyFailed(message)
            let actions: [BarAction] = state.isRevealing ? [.cancelRevealTimer, .release, .showWarning(reason)] : [.release, .showWarning(reason)]
            return (.unavailable(reason), actions)
        case .launched, .quitRequested: return (state, [])
        }
    }

    private static func releaseActions(for state: BarState) -> [BarAction] {
        switch state {
        case .collapsed: [.release]
        case .revealing: [.cancelRevealTimer, .release]
        default: []
        }
    }
}

private extension BarState {
    var isRevealing: Bool {
        if case .revealing = self { true } else { false }
    }
}
