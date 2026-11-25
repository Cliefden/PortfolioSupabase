import Foundation
import Security
import Supabase

/// The tokens a hand-rolled GoTrue client kept (Otta, Svamp, Sextant before
/// supabase-swift). Only ``refreshToken`` is needed to migrate.
public struct LegacyTokenSession: Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String
    public var userID: String?
    public var expiresAt: Date?
    public var isAnonymous: Bool?

    public init(
        accessToken: String? = nil,
        refreshToken: String,
        userID: String? = nil,
        expiresAt: Date? = nil,
        isAnonymous: Bool? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.expiresAt = expiresAt
        self.isAnonymous = isAnonymous
    }
}

/// Reads and deletes the one Keychain item a hand-rolled client stored its
/// session in. It never writes: the session moves into the SDK's storage
/// through ``LegacyTokenSessionMigrator``.
///
/// The hand-rolled clients wrote a generic password by **account only**, with
/// no service attribute, so leave `service` `nil` for them (a query without a
/// service matches the item whatever its service):
///
/// ```swift
/// LegacyTokenSessionStore(account: "sextant.supabase.session")   // Sextant ≤ 1.1 (12)
/// LegacyTokenSessionStore(account: "supabase.session.v1")        // Otta, Svamp
/// ```
public struct LegacyTokenSessionStore: Sendable {
    /// Turns the item's data into a session. Throwing (or returning a
    /// session with an empty refresh token) marks the item as corrupt.
    public typealias Decoder = @Sendable (Data) throws -> LegacyTokenSession

    public enum ReadResult: Equatable, Sendable {
        case none
        case session(LegacyTokenSession)
        /// An item exists but couldn't be decoded.
        case corrupt
        /// The Keychain refused the read (e.g. `errSecInteractionNotAllowed`
        /// while locked before first unlock).
        case unreadable(OSStatus)
    }

    public let account: String
    public let service: String?
    public let accessGroup: String?
    let backend: any KeychainBackend
    let decode: Decoder

    public init(
        account: String,
        service: String? = nil,
        accessGroup: String? = nil,
        backend: any KeychainBackend = SystemKeychain(),
        decode: @escaping Decoder = LegacyTokenSessionStore.defaultJSONDecoder
    ) {
        self.account = account
        self.service = service
        self.accessGroup = accessGroup
        self.backend = backend
        self.decode = decode
    }

    /// Decodes what the hand-rolled clients wrote with a plain `JSONEncoder()`:
    /// `{"accessToken", "refreshToken", "userID" | "userId", "expiresAt",
    /// "isAnonymous"}`, `expiresAt` in the default date strategy (seconds since
    /// 2001-01-01). Only `refreshToken` is required. Snake-case keys
    /// (`refresh_token`, `user_id`, …) are accepted too.
    public static let defaultJSONDecoder: Decoder = { data in
        try JSONDecoder().decode(LenientTokenSession.self, from: data).session
    }

    var itemQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        if let service { query[kSecAttrService as String] = service }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read() -> ReadResult {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data, let session = try? decode(data), !session.refreshToken.isEmpty else {
                return .corrupt
            }
            return .session(session)
        case errSecItemNotFound:
            return .none
        default:
            return .unreadable(status)
        }
    }

    /// `true` when an item exists in any state, including unreadable. Use it
    /// as the launch-time "signed in" hint while a migration is pending.
    public var hasItem: Bool {
        if case .none = read() { return false }
        return true
    }

    public func delete() {
        _ = backend.delete(itemQuery)
    }
}

/// `Codable` shape behind ``LegacyTokenSessionStore/defaultJSONDecoder``.
struct LenientTokenSession: Decodable {
    let session: LegacyTokenSession

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func first<T: Decodable>(_ type: T.Type, _ keys: String...) throws -> T? {
            for key in keys.map(Key.init) where c.contains(key) {
                if let value = try c.decodeIfPresent(T.self, forKey: key) { return value }
            }
            return nil
        }
        guard let refreshToken = try first(String.self, "refreshToken", "refresh_token") else {
            throw DecodingError.keyNotFound(
                Key("refreshToken"),
                .init(codingPath: c.codingPath, debugDescription: "No refresh token")
            )
        }
        session = LegacyTokenSession(
            accessToken: try first(String.self, "accessToken", "access_token"),
            refreshToken: refreshToken,
            userID: try first(String.self, "userID", "userId", "user_id"),
            expiresAt: try? first(Date.self, "expiresAt", "expires_at"),
            isAnonymous: try? first(Bool.self, "isAnonymous", "is_anonymous")
        )
    }
}

/// What a ``LegacyTokenSessionMigrator`` run did.
public enum LegacyTokenSessionMigrationOutcome: Sendable {
    /// No legacy item: fresh install, or already migrated.
    case nothingToMigrate
    /// The SDK now holds the session for this user; the legacy item is gone.
    case migrated(userID: UUID)
    /// The SDK already had a session (e.g. the user signed in again); the
    /// stale legacy item was removed without a network call.
    case alreadyMigrated
    /// The server rejected the legacy refresh token: the session was dead
    /// anyway. Item removed; the user is signed out.
    case rejected(any Error)
    /// The legacy item can't be decoded. Item removed.
    case corrupt
    /// Couldn't finish now (offline, 5xx, Keychain locked). Item kept; the
    /// next ``LegacyTokenSessionMigrator/migrateIfNeeded()`` retries.
    case deferred(any Error)

    public var isDeferred: Bool {
        if case .deferred = self { return true }
        return false
    }
}

/// One-time move of a token-only session (see ``LegacyTokenSessionStore``)
/// into supabase-swift.
///
/// The legacy item has tokens but not the SDK's `Session` (with its `User`),
/// so instead of forging one, the legacy refresh token is redeemed once with
/// `client.auth.refreshSession(refreshToken:)`. The SDK stores the new
/// session in its own storage and emits `.tokenRefreshed`.
///
/// The legacy item is deleted only when that succeeded, or when it can never
/// succeed: the server rejected the token (``AuthFailure/isAuthRejection(_:)``),
/// the item is undecodable, or the SDK already holds a session. A network or
/// server failure, or a locked Keychain, keeps it for the next attempt, so
/// keep showing the user as signed in while ``hasPendingSession`` is `true`.
///
/// Calls are single-flight: concurrent callers share one refresh, because a
/// refresh token is single-use and a second, parallel redemption would be
/// rejected as reused.
///
/// ```swift
/// let migrator = LegacyTokenSessionMigrator(
///     store: LegacyTokenSessionStore(account: "supabase.session.v1"),
///     client: Backend.client
/// )
/// let signedIn = client.auth.currentSession != nil || migrator.hasPendingSession   // launch hint
/// Task { await migrator.migrateIfNeeded() }                                        // launch, and before sync
/// ```
public actor LegacyTokenSessionMigrator {
    public let store: LegacyTokenSessionStore
    private let hasSDKSession: @Sendable () -> Bool
    private let redeem: @Sendable (String) async throws -> UUID
    private var running: Task<LegacyTokenSessionMigrationOutcome, Never>?
    private var finished = false

    /// Production: redeems through `client.auth`.
    public init(store: LegacyTokenSessionStore, client: SupabaseClient) {
        let auth = client.auth
        self.init(
            store: store,
            hasSDKSession: { auth.currentSession != nil },
            redeem: { try await auth.refreshSession(refreshToken: $0).user.id }
        )
    }

    /// Injectable steps, for tests and for apps that redeem differently.
    /// - Parameters:
    ///   - hasSDKSession: whether the SDK storage already holds a session.
    ///   - redeem: trades the legacy refresh token for an SDK session and
    ///     returns its user id.
    public init(
        store: LegacyTokenSessionStore,
        hasSDKSession: @escaping @Sendable () -> Bool,
        redeem: @escaping @Sendable (String) async throws -> UUID
    ) {
        self.store = store
        self.hasSDKSession = hasSDKSession
        self.redeem = redeem
    }

    /// `true` while a legacy item exists (whatever its state). Reads the
    /// Keychain, so call it at launch rather than in a view body.
    public nonisolated var hasPendingSession: Bool { store.hasItem }

    /// Runs the migration, or joins the one in flight. After a final outcome
    /// later calls return ``LegacyTokenSessionMigrationOutcome/nothingToMigrate``
    /// without touching the Keychain.
    @discardableResult
    public func migrateIfNeeded() async -> LegacyTokenSessionMigrationOutcome {
        if finished { return .nothingToMigrate }
        if let running { return await running.value }
        let task = Task { [store, hasSDKSession, redeem] in
            await Self.run(store: store, hasSDKSession: hasSDKSession(), redeem: redeem)
        }
        running = task
        let outcome = await task.value
        running = nil
        if !outcome.isDeferred { finished = true }
        return outcome
    }

    /// Drops the legacy item without redeeming it: after a fresh sign-in or
    /// a sign-out, which supersede it.
    public func discard() {
        store.delete()
        finished = true
    }

    /// One attempt, without single-flight.
    static func run(
        store: LegacyTokenSessionStore,
        hasSDKSession: Bool,
        redeem: (String) async throws -> UUID
    ) async -> LegacyTokenSessionMigrationOutcome {
        let legacy: LegacyTokenSession
        switch store.read() {
        case .none:
            return .nothingToMigrate
        case .unreadable(let status):
            return .deferred(KeychainAuthStorageError.unableToRetrieve(status))
        case .corrupt:
            store.delete()
            return .corrupt
        case .session(let session):
            legacy = session
        }

        if hasSDKSession {
            store.delete()
            return .alreadyMigrated
        }

        do {
            let userID = try await redeem(legacy.refreshToken)
            store.delete()
            return .migrated(userID: userID)
        } catch {
            if AuthFailure.isAuthRejection(error) {
                store.delete()
                return .rejected(error)
            }
            return .deferred(error)
        }
    }
}
