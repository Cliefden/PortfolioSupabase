import Auth
import Foundation

/// UserDefaults-backed `AuthLocalStorage` (identical in Stokked, Jeroboam and
/// Carpe Vitem). Tokens are stored in plaintext, so use it for DEBUG builds
/// (no macOS keychain prompts during development) and as the legacy source of
/// a ``MigratingAuthStorage``.
///
/// Values live at `"\(key).\(sdkKey)"`. The default prefix matches the apps'
/// existing copies, so sessions already stored there are found.
public final class UserDefaultsAuthStorage: AuthLocalStorage, @unchecked Sendable {
    public static let defaultKey = "supabase.auth.session"

    public let key: String
    // UserDefaults is thread-safe; @unchecked only because older SDKs don't
    // mark it Sendable.
    private let defaults: UserDefaults

    public init(key: String = defaultKey, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    func fullKey(_ sdkKey: String) -> String { "\(key).\(sdkKey)" }

    public func store(key: String, value: Data) throws {
        defaults.set(value, forKey: fullKey(key))
    }

    public func retrieve(key: String) throws -> Data? {
        defaults.data(forKey: fullKey(key))
    }

    public func remove(key: String) throws {
        defaults.removeObject(forKey: fullKey(key))
    }
}

/// Reads from `primary`, and on a miss moves a value found in `legacy` into
/// `primary` (then deletes the legacy copy), so switching storage doesn't sign
/// anyone out. Writes go to `primary` and clear `legacy`. Generalizes Carpe
/// Vitem's `KeychainMigratingAuthStorage` and Stokked's
/// `KeychainAuthStorage.migrateFromUserDefaults()`.
///
/// ```swift
/// MigratingAuthStorage(
///     from: UserDefaultsAuthStorage(),
///     to: KeychainAuthStorage(service: "com.carpevitem.app.auth")
/// )
/// ```
public final class MigratingAuthStorage: AuthLocalStorage, Sendable {
    public let legacy: any AuthLocalStorage
    public let primary: any AuthLocalStorage

    public init(from legacy: any AuthLocalStorage, to primary: any AuthLocalStorage) {
        self.legacy = legacy
        self.primary = primary
    }

    public func store(key: String, value: Data) throws {
        try primary.store(key: key, value: value)
        try? legacy.remove(key: key)
    }

    public func retrieve(key: String) throws -> Data? {
        // A primary read error (e.g. keychain locked before first unlock) is
        // propagated rather than masked by a stale legacy value.
        if let value = try primary.retrieve(key: key) {
            return value
        }
        guard let legacyValue = try? legacy.retrieve(key: key) else { return nil }
        do {
            try primary.store(key: key, value: legacyValue)
            try? legacy.remove(key: key)
        } catch {
            // Keep the legacy copy so the next launch can try again; the
            // session is still returned, so the user stays signed in.
        }
        return legacyValue
    }

    public func remove(key: String) throws {
        try? legacy.remove(key: key)
        try primary.remove(key: key)
    }
}

/// Process-lifetime storage: previews, tests, and the unconfigured fallback
/// client (which must never touch the keychain).
public final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init(_ initial: [String: Data] = [:]) {
        values = initial
    }

    public func store(key: String, value: Data) throws {
        lock.withLock { values[key] = value }
    }

    public func retrieve(key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func remove(key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    public var keys: [String] {
        lock.withLock { Array(values.keys) }
    }
}
