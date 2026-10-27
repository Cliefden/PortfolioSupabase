import Foundation
import Security
import Testing
@testable import PortfolioSupabase

/// In-memory stand-in for the keychain that follows `SecItem*` semantics
/// closely enough for ``KeychainAuthStorage``: items keyed by
/// class/service/account/access group, `add` fails on duplicates, `update`
/// fails when missing, and a query carrying `kSecValueData` matches nothing.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    struct Item: Equatable {
        var data: Data
        var accessible: String?
    }

    enum Call: Equatable { case copy, add, update, delete }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private(set) var calls: [Call] = []
    /// Force a status for the next call of a kind (simulate failures/races).
    var forcedStatus: [Call: OSStatus] = [:]

    private func id(_ query: [String: Any]) -> String? {
        if query[kSecValueData as String] != nil { return nil }
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        let group = query[kSecAttrAccessGroup as String] as? String ?? ""
        return "\(service)|\(account)|\(group)"
    }

    private func record(_ call: Call) -> OSStatus? {
        calls.append(call)
        return forcedStatus.removeValue(forKey: call)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            if let forced = record(.copy) { return (forced, nil) }
            guard let id = id(query), let item = items[id] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item.data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if let forced = record(.add) { return forced }
            var key = attributes
            let data = key.removeValue(forKey: kSecValueData as String) as? Data ?? Data()
            guard let id = id(key) else { return errSecParam }
            if items[id] != nil { return errSecDuplicateItem }
            items[id] = Item(data: data, accessible: (attributes[kSecAttrAccessible as String] as! CFString) as String)
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if let forced = record(.update) { return forced }
            guard let id = id(query), var item = items[id] else { return errSecItemNotFound }
            if let data = attributes[kSecValueData as String] as? Data { item.data = data }
            if let accessible = attributes[kSecAttrAccessible as String] {
                item.accessible = (accessible as! CFString) as String
            }
            items[id] = item
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if let forced = record(.delete) { return forced }
            guard let id = id(query), items.removeValue(forKey: id) != nil else { return errSecItemNotFound }
            return errSecSuccess
        }
    }

    func item(service: String, account: String, group: String = "") -> Item? {
        lock.withLock { items["\(service)|\(account)|\(group)"] }
    }

    func seed(service: String, account: String, data: Data, accessible: CFString) {
        lock.withLock {
            items["\(service)|\(account)|"] = Item(data: data, accessible: accessible as String)
        }
    }

    var itemCount: Int { lock.withLock { items.count } }
}

private let service = "com.example.test.auth"

@Suite struct KeychainAuthStorageTests {
    @Test func storeAddsWhenMissingThenRetrieves() throws {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)

        try storage.store(key: "session", value: Data("one".utf8))

        #expect(try storage.retrieve(key: "session") == Data("one".utf8))
        #expect(keychain.calls.prefix(2) == [.update, .add])
        #expect(keychain.item(service: service, account: "session")?.accessible
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func storeUpdatesInPlaceAndNeverDeletes() throws {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)

        try storage.store(key: "session", value: Data("one".utf8))
        try storage.store(key: "session", value: Data("two".utf8))

        #expect(try storage.retrieve(key: "session") == Data("two".utf8))
        #expect(keychain.itemCount == 1)
        #expect(!keychain.calls.contains(.delete))
        // Second store is a single update, no add.
        #expect(keychain.calls.filter { $0 == .add }.count == 1)
    }

    @Test func storeMigratesAccessibilityOfExistingItem() throws {
        let keychain = FakeKeychain()
        keychain.seed(service: service, account: "session", data: Data("old".utf8), accessible: kSecAttrAccessibleWhenUnlocked)
        let storage = KeychainAuthStorage(service: service, accessibility: .afterFirstUnlock, backend: keychain)

        try storage.store(key: "session", value: Data("new".utf8))

        #expect(keychain.item(service: service, account: "session")
            == .init(data: Data("new".utf8), accessible: kSecAttrAccessibleAfterFirstUnlock as String))
    }

    @Test func storeRecoversFromAddRace() throws {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)
        keychain.forcedStatus[.add] = errSecDuplicateItem
        // The racing writer's item, which the retry update should overwrite.
        keychain.seed(service: service, account: "session", data: Data("racer".utf8), accessible: kSecAttrAccessibleWhenUnlocked)
        keychain.forcedStatus[.update] = errSecItemNotFound

        try storage.store(key: "session", value: Data("mine".utf8))

        #expect(try storage.retrieve(key: "session") == Data("mine".utf8))
        #expect(keychain.calls.prefix(3) == [.update, .add, .update])
    }

    @Test func storeThrowsOnFailure() {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)
        keychain.forcedStatus[.update] = errSecInteractionNotAllowed

        #expect(throws: KeychainAuthStorageError.unableToStore(errSecInteractionNotAllowed)) {
            try storage.store(key: "session", value: Data("x".utf8))
        }
    }

    @Test func retrieveMissingIsNilAndOtherErrorsThrow() throws {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)
        #expect(try storage.retrieve(key: "nope") == nil)

        keychain.forcedStatus[.copy] = errSecInteractionNotAllowed
        #expect(throws: KeychainAuthStorageError.unableToRetrieve(errSecInteractionNotAllowed)) {
            _ = try storage.retrieve(key: "nope")
        }
    }

    @Test func removeIsIdempotent() throws {
        let keychain = FakeKeychain()
        let storage = KeychainAuthStorage(service: service, backend: keychain)
        try storage.store(key: "session", value: Data("x".utf8))

        try storage.remove(key: "session")
        try storage.remove(key: "session")

        #expect(try storage.retrieve(key: "session") == nil)
    }

    @Test func servicesAndGroupsAreIsolated() throws {
        let keychain = FakeKeychain()
        let a = KeychainAuthStorage(service: "a", backend: keychain)
        let b = KeychainAuthStorage(service: "b", backend: keychain)
        let shared = KeychainAuthStorage(service: "a", accessGroup: "TEAM.group", backend: keychain)

        try a.store(key: "k", value: Data("a".utf8))
        try b.store(key: "k", value: Data("b".utf8))
        try shared.store(key: "k", value: Data("g".utf8))

        #expect(try a.retrieve(key: "k") == Data("a".utf8))
        #expect(try b.retrieve(key: "k") == Data("b".utf8))
        #expect(try shared.retrieve(key: "k") == Data("g".utf8))
    }

    @Test func itemQueryNeverCarriesTheValue() {
        let storage = KeychainAuthStorage(service: service, backend: FakeKeychain())
        #expect(storage.itemQuery(key: "k")[kSecValueData as String] == nil)
    }
}

private func freshDefaults() -> UserDefaults {
    let suite = "PortfolioSupabaseTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Suite struct UserDefaultsAuthStorageTests {
    @Test func roundTripsUnderPrefixedKey() throws {
        let defaults = freshDefaults()
        let storage = UserDefaultsAuthStorage(defaults: defaults)

        try storage.store(key: "sb-x-auth-token", value: Data("s".utf8))

        #expect(defaults.data(forKey: "supabase.auth.session.sb-x-auth-token") == Data("s".utf8))
        #expect(try storage.retrieve(key: "sb-x-auth-token") == Data("s".utf8))
        try storage.remove(key: "sb-x-auth-token")
        #expect(try storage.retrieve(key: "sb-x-auth-token") == nil)
    }

    @Test func customPrefix() throws {
        let defaults = freshDefaults()
        let storage = UserDefaultsAuthStorage(key: "dev.auth", defaults: defaults)
        try storage.store(key: "k", value: Data("v".utf8))
        #expect(defaults.data(forKey: "dev.auth.k") == Data("v".utf8))
    }
}

@Suite struct MigratingAuthStorageTests {
    @Test func movesLegacyValueOnFirstRead() throws {
        let legacy = InMemoryAuthStorage(["k": Data("legacy".utf8)])
        let primary = InMemoryAuthStorage()
        let storage = MigratingAuthStorage(from: legacy, to: primary)

        #expect(try storage.retrieve(key: "k") == Data("legacy".utf8))
        #expect(try primary.retrieve(key: "k") == Data("legacy".utf8))
        #expect(try legacy.retrieve(key: "k") == nil)
    }

    @Test func primaryWinsOverLegacy() throws {
        let legacy = InMemoryAuthStorage(["k": Data("stale".utf8)])
        let primary = InMemoryAuthStorage(["k": Data("fresh".utf8)])
        let storage = MigratingAuthStorage(from: legacy, to: primary)

        #expect(try storage.retrieve(key: "k") == Data("fresh".utf8))
    }

    @Test func storeWritesPrimaryAndClearsLegacy() throws {
        let legacy = InMemoryAuthStorage(["k": Data("old".utf8)])
        let primary = InMemoryAuthStorage()
        let storage = MigratingAuthStorage(from: legacy, to: primary)

        try storage.store(key: "k", value: Data("new".utf8))

        #expect(try primary.retrieve(key: "k") == Data("new".utf8))
        #expect(try legacy.retrieve(key: "k") == nil)
    }

    @Test func removeClearsBoth() throws {
        let legacy = InMemoryAuthStorage(["k": Data("a".utf8)])
        let primary = InMemoryAuthStorage(["k": Data("b".utf8)])
        let storage = MigratingAuthStorage(from: legacy, to: primary)

        try storage.remove(key: "k")

        #expect(try storage.retrieve(key: "k") == nil)
        #expect(legacy.keys.isEmpty && primary.keys.isEmpty)
    }

    @Test func failedMigrationKeepsLegacyAndStillReturnsSession() throws {
        let keychain = FakeKeychain()
        keychain.forcedStatus[.update] = errSecInteractionNotAllowed
        let legacy = InMemoryAuthStorage(["k": Data("legacy".utf8)])
        let storage = MigratingAuthStorage(from: legacy, to: KeychainAuthStorage(service: service, backend: keychain))

        #expect(try storage.retrieve(key: "k") == Data("legacy".utf8))
        #expect(try legacy.retrieve(key: "k") == Data("legacy".utf8))
    }

    @Test func userDefaultsToKeychainEndToEnd() throws {
        let defaults = freshDefaults()
        let legacy = UserDefaultsAuthStorage(defaults: defaults)
        try legacy.store(key: "sb-auth", value: Data("session".utf8))
        let keychain = FakeKeychain()
        let storage = MigratingAuthStorage(from: legacy, to: KeychainAuthStorage(service: service, backend: keychain))

        #expect(try storage.retrieve(key: "sb-auth") == Data("session".utf8))
        #expect(keychain.item(service: service, account: "sb-auth")?.data == Data("session".utf8))
        #expect(defaults.data(forKey: "supabase.auth.session.sb-auth") == nil)
    }
}
