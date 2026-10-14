import Foundation

public enum AllowList {
    /// M0 on macOS 27 build 26A434 found that allowing all system items kept the clock, Wi-Fi, and Control Center clickable.
    public static let systemItems: [Int] = Array(0...255)

    /// These Apple processes draw the clock, Control Center, and other system extras; hiding them would hide system controls.
    public static let neverHide: Set<String> = [
        "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.Spotlight", "com.apple.MenuBarAgent"
    ]

    public static func compute(runningBundleIDs: [String?], hidden: Set<String>, ownBundleID: String) -> [String] {
        var allowed = Set(runningBundleIDs.compactMap { $0 }.filter { !$0.isEmpty && (!hidden.contains($0) || neverHide.contains($0)) })
        allowed.insert(ownBundleID)
        return allowed.sorted()
    }
}
