import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var hidden: Set<String>
    private var storedRevealSeconds: Double
    public var revealSeconds: Double {
        get { storedRevealSeconds }
        set { storedRevealSeconds = Self.clamp(newValue) }
    }
    public var paused: Bool
    public var schemaVersion: Int

    public init(hidden: Set<String> = [], revealSeconds: Double = 10, paused: Bool = false, schemaVersion: Int = 1) {
        self.hidden = hidden
        self.storedRevealSeconds = Self.clamp(revealSeconds)
        self.paused = paused
        self.schemaVersion = schemaVersion
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 10 }
        return min(120, max(3, value))
    }

    private enum CodingKeys: String, CodingKey { case hidden, revealSeconds, paused, schemaVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hidden: try values.decode(Set<String>.self, forKey: .hidden),
            revealSeconds: try values.decode(Double.self, forKey: .revealSeconds),
            paused: try values.decode(Bool.self, forKey: .paused),
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hidden, forKey: .hidden)
        try values.encode(revealSeconds, forKey: .revealSeconds)
        try values.encode(paused, forKey: .paused)
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

/// UserDefaults provides synchronized access to its values; the suite reference is fixed after init.
public final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}
