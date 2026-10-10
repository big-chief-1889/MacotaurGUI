import Foundation

/// Where settings live. Live: UserDefaults (domain app.macotaur.miner).
/// Demo and snapshot: a MemoryStore, so nothing is ever written.
protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: String?, forKey key: String)
    func set(_ value: Data?, forKey key: String)
}

/// The only place Macotaur touches UserDefaults.
final class DefaultsStore: PreferenceStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    func set(_ value: Data?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// A read-only copy of every key Macotaur uses (for read-only snapshots).
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [:]
        for k in PreferenceKey.strings { if let v = defaults.string(forKey: k) { out[k] = v } }
        for k in PreferenceKey.json { if let v = defaults.data(forKey: k) { out[k] = v } }
        return out
    }
}

/// Settings kept in memory only.
final class MemoryStore: PreferenceStore {
    private var values: [String: Any]
    init(seed: [String: Any] = [:]) { values = seed }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func set(_ value: Data?, forKey key: String) { values[key] = value }
}

/// Keys from older versions that are no longer listed here stay in the
/// user's defaults untouched; nothing reads or writes them.
enum PreferenceKey {
    // Plain strings.
    static let preset = "preset", kryptexRegion = "kryptexRegion", customHost = "customHost", customPort = "customPort"
    static let customSeparator = "customSeparator", wallet = "wallet", worker = "worker", intensity = "intensity"
    /// Read once, to carry an older version's power mode over to `intensity`. Never written.
    static let oldPowerMode = "powerMode"
    // Stored as JSON.
    static let ui = "ui"

    static let strings = [preset, kryptexRegion, customHost, customPort, customSeparator, wallet, worker, intensity, oldPowerMode]
    static let json = [ui]
}

extension PreferenceStore {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    func encode<T: Encodable>(_ value: T, forKey key: String) {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        set(try? e.encode(value), forKey: key)
    }
}

/// What the dashboard remembers between launches.
struct UIState: Codable, Equatable {
    var activityExpanded = false

    init() {}
    // Tolerant decoding: a missing or unreadable field keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activityExpanded = (try? c.decode(Bool.self, forKey: .activityExpanded)) ?? false
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case mining, pool
    var id: Self { self }
}

enum UISurface: Hashable { case dashboard, settings }
