/// Matches running menu bar hiders. Input names come from NSRunningApplication.localizedName.
struct RunningCompetitor: Equatable, Sendable {
    let bundleID: String
    let name: String
}

enum ConflictDetector {
    #if DEBUG
    /// Debug builds also treat the test fixture as a competitor, for scripts/adversarial.sh.
    static let bundleIDs: Set<String> = releaseBundleIDs.union(["dev.yili.smh.fixture.competitor"])
    #else
    static let bundleIDs: Set<String> = releaseBundleIDs
    #endif

    private static let releaseBundleIDs: Set<String> = [
        "com.stonerl.Thaw", "com.jordanbaird.Ice",
        "com.surteesstudios.Bartender", "com.surteesstudios.Bartender-setapp",
        "com.dwarvesv.minimalbar"
    ]

    static func detect(_ apps: [(String, String)]) -> [RunningCompetitor] {
        var matches: [String: String] = [:]
        for (id, name) in apps where bundleIDs.contains(id) {
            matches[id] = name
        }
        return matches.keys.sorted().map { RunningCompetitor(bundleID: $0, name: matches[$0]!) }
    }
}
