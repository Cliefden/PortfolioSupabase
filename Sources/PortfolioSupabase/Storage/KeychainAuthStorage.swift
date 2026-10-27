import Auth
import Foundation
import Security

/// When the stored session may be read. Mirrors `kSecAttrAccessible*`.
public enum KeychainAccessibility: Sendable, Equatable {
    case whenUnlocked
    case whenUnlockedThisDeviceOnly
    /// Readable after the first unlock since boot, so background refreshes,
    /// widgets and push handlers can use the session. Survives backups.
    case afterFirstUnlock
    /// Like ``afterFirstUnlock`` but never leaves the device (Stokked's
    /// choice, and the default).
    case afterFirstUnlockThisDeviceOnly

    var secValue: CFString {
        switch self {
        case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
        case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// The four `SecItem*` calls ``KeychainAuthStorage`` makes, behind a protocol
/// so tests can run against an in-memory keychain.
public protocol KeychainBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real keychain.
public struct SystemKeychain: KeychainBackend {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain-backed `AuthLocalStorage` (Stokked ≈ Nassau, unified).
///
/// `store` updates the existing item and only adds when there is none. The old
/// copies deleted first and then added, which leaves a window with no session
/// stored (a crash or a failed add there signs the user out) and can't change
/// an item's accessibility class in place. Update-then-add can.
///
/// Use one `service` per app, and keep the app's current value when adopting,
/// or existing users are signed out: Stokked `com.stefan.bernini.Stocked.auth`,
/// Nassau `com.stefan.bernini.nassau.auth`.
public final class KeychainAuthStorage: AuthLocalStorage, Sendable {
    public let service: String
    public let accessibility: KeychainAccessibility
    /// Shared keychain access group (for widgets/extensions), or `nil` for
    /// the app's default group.
    public let accessGroup: String?
    /// macOS only: use the data-protection keychain instead of the legacy
    /// file keychain (no access prompts). Needs a signed app with a
    /// keychain-access-groups entitlement; ignored on other platforms.
    public let usesDataProtectionKeychain: Bool
    let backend: any KeychainBackend

    public init(
        service: String,
        accessibility: KeychainAccessibility = .afterFirstUnlockThisDeviceOnly,
        accessGroup: String? = nil,
        usesDataProtectionKeychain: Bool = false,
        backend: any KeychainBackend = SystemKeychain()
    ) {
        self.service = service
        self.accessibility = accessibility
        self.accessGroup = accessGroup
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        self.backend = backend
    }

    /// Identifies one item. Never contains the value: a query with
    /// `kSecValueData` matches nothing, which is how a delete-with-value bug
    /// silently leaves the old item behind.
    func itemQuery(key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    public func store(key: String, value: Data) throws {
        let query = itemQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessibility.secValue,
        ]

        var status = backend.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = backend.add(query.merging(attributes) { _, new in new })
            // Another thread added it between our update and add.
            if status == errSecDuplicateItem {
                status = backend.update(query, attributes: attributes)
            }
        }
        guard status == errSecSuccess else {
            throw KeychainAuthStorageError.unableToStore(status)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        var query = itemQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = backend.copyMatching(query)
        switch status {
        case errSecSuccess: return data
        case errSecItemNotFound: return nil
        default: throw KeychainAuthStorageError.unableToRetrieve(status)
        }
    }

    public func remove(key: String) throws {
        let status = backend.delete(itemQuery(key: key))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAuthStorageError.unableToRemove(status)
        }
    }
}

public enum KeychainAuthStorageError: Error, LocalizedError, Equatable, Sendable {
    case unableToStore(OSStatus)
    case unableToRetrieve(OSStatus)
    case unableToRemove(OSStatus)

    public var status: OSStatus {
        switch self {
        case .unableToStore(let s), .unableToRetrieve(let s), .unableToRemove(let s): s
        }
    }

    /// Diagnostic text (not user-facing).
    public var errorDescription: String? {
        switch self {
        case .unableToStore(let s): "Unable to store in Keychain (status: \(s))"
        case .unableToRetrieve(let s): "Unable to retrieve from Keychain (status: \(s))"
        case .unableToRemove(let s): "Unable to remove from Keychain (status: \(s))"
        }
    }
}
