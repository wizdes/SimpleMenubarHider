import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var hidden: Set<String>
    private var storedRevealSeconds: Double
    public var revealSeconds: Double {
        get { storedRevealSeconds }
        set { storedRevealSeconds = Self.clamp(newValue) }
    }
    public var paused: Bool
    public var names: [String: String]
    public var schemaVersion: Int

    public init(hidden: Set<String> = [], revealSeconds: Double = 10, paused: Bool = false,
                names: [String: String] = [:], schemaVersion: Int = 1) {
        self.hidden = hidden
        self.storedRevealSeconds = Self.clamp(revealSeconds)
        self.paused = paused
        self.names = names
        self.schemaVersion = schemaVersion
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 10 }
        return min(120, max(3, value))
    }

    private enum CodingKeys: String, CodingKey { case hidden, revealSeconds, paused, names, schemaVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Only `hidden` is required. A missing optional key takes its default instead of making
        // the whole file "corrupt"; a key that is present with the wrong type still fails.
        let defaults = Settings()
        self.init(
            hidden: try values.decode(Set<String>.self, forKey: .hidden),
            revealSeconds: try values.decodeIfPresent(Double.self, forKey: .revealSeconds) ?? defaults.revealSeconds,
            paused: try values.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused,
            names: try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:],
            schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        )
    }

    /// Drops ids SMH never hides. An older build could save them, and with no row to untick
    /// they would keep SMH collapsed for good.
    public func removingNeverHide() -> (settings: Settings, dropped: [String]) {
        var clean = self
        let dropped = hidden.intersection(AllowList.neverHide)
        clean.hidden.subtract(dropped)
        return (clean, dropped.sorted())
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hidden, forKey: .hidden)
        try values.encode(revealSeconds, forKey: .revealSeconds)
        try values.encode(paused, forKey: .paused)
        try values.encode(names, forKey: .names)
        try values.encode(schemaVersion, forKey: .schemaVersion)
    }
}

public protocol KeyValueStore: Sendable {
    func data(forKey: String) -> Data?
    func set(_ data: Data?, forKey: String)
}

public enum LoadResult: Equatable, Sendable {
    case loaded(Settings)
    case missing
    case corrupt(Settings, reason: String)

    public var settings: Settings {
        switch self {
        case .loaded(let settings), .corrupt(let settings, _): settings
        case .missing: Settings()
        }
    }
}

public final class SettingsStore: Sendable {
    public static let key = "SMHCore.settings"
    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    public func load() -> LoadResult {
        guard let data = store.data(forKey: Self.key) else { return .missing }
        do { return .loaded(try JSONDecoder().decode(Settings.self, from: data)) }
        catch { return .corrupt(Settings(), reason: String(describing: error)) }
    }

    /// The raw stored bytes, so corrupt settings can be copied aside before they are overwritten.
    public func storedData() -> Data? { store.data(forKey: Self.key) }

    public func save(_ settings: Settings) {
        do { store.set(try JSONEncoder().encode(settings), forKey: Self.key) }
        catch { assertionFailure("Failed to encode Settings: \(error)") }
    }
}

public final class InMemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}

/// UserDefaults provides synchronized access to its values; the defaults reference is fixed after init.
/// The app passes `UserDefaults.standard`, whose domain is the app's bundle id.
public final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}

/// Copies unreadable settings to a file before SMH replaces them with defaults.
public enum SettingsBackup {
    public static func fileName(for date: Date) -> String {
        "settings-corrupt-\(timestamp(date)).json"
    }

    /// Writes `data` into `folder` (created if needed) and returns the file. Never overwrites an older copy.
    public static func write(_ data: Data, to folder: URL, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(fileName(for: now))
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("settings-corrupt-\(timestamp(now))-\(counter).json")
            counter += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
