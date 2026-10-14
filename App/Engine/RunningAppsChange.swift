/// Bundle ids that started or stopped between two lists of running apps.
/// Key-value observation of `NSWorkspace.runningApplications` hands over either the
/// full old and new lists or only the inserted or removed apps; a set difference works for both.
struct RunningAppsChange: Equatable, Sendable {
    let launched: [String]
    let terminated: [String]

    var isEmpty: Bool { launched.isEmpty && terminated.isEmpty }

    init(old: [String?], new: [String?]) {
        let oldIDs = Set(old.compactMap { $0 })
        let newIDs = Set(new.compactMap { $0 })
        launched = newIDs.subtracting(oldIDs).sorted()
        terminated = oldIDs.subtracting(newIDs).sorted()
    }
}
