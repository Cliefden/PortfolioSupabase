import Foundation
import Security
import Supabase
import Testing
@testable import PortfolioSupabase

// Ported from Sextant's `SupabaseMigrationTests` (LegacySessionMigration).

/// What Sextant ≤ 1.1 (12) wrote: `JSONEncoder()` output, `userID`,
/// `expiresAt` in seconds since 2001-01-01.
private let sextantJSON = #"{"accessToken":"old-access","refreshToken":"old-refresh","userID":"0f8fad5b-d9cb-469f-a165-70867728950e","expiresAt":800000000}"#
/// What Otta and Svamp write (`UserSession`): `userId` plus `isAnonymous`.
private let ottaJSON = #"{"accessToken":"a","refreshToken":"r","userId":"u","expiresAt":800000000,"isAnonymous":true}"#
private let legacyAccount = "sextant.supabase.session"
private let userUUID = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!

/// The hand-rolled clients wrote by account only (no service), which the
/// fake keychain files under the empty service.
private func seedLegacy(_ keychain: FakeKeychain, _ json: String, account: String = legacyAccount) {
    keychain.seed(service: "", account: account, data: Data(json.utf8), accessible: kSecAttrAccessibleAfterFirstUnlock)
}

private func legacyStore(_ keychain: FakeKeychain, account: String = legacyAccount) -> LegacyTokenSessionStore {
    LegacyTokenSessionStore(account: account, backend: keychain)
}

/// A rejection of the refresh grant the way older self-hosted GoTrue sends
/// it: 400, OAuth2 body, no `error_code` (so `ErrorCode.unknown`).
private func bareInvalidGrant(description: String = "Refresh token revoked") -> AuthError {
    .api(
        message: description,
        errorCode: .unknown,
        underlyingData: Data(#"{"error":"invalid_grant","error_description":"\#(description)"}"#.utf8),
        underlyingResponse: HTTPURLResponse(
            url: URL(string: "https://a.crawik.com/auth/v1/token?grant_type=refresh_token")!,
            statusCode: 400, httpVersion: nil, headerFields: nil
        )!
    )
}

private func refreshGrantError(status: Int, code: String = "unknown") -> AuthError {
    .api(
        message: "x",
        errorCode: ErrorCode(code),
        underlyingData: Data(),
        underlyingResponse: HTTPURLResponse(
            url: URL(string: "https://a.crawik.com/auth/v1/token?grant_type=refresh_token")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
    )
}

private func run(
    _ keychain: FakeKeychain,
    hasSDKSession: Bool = false,
    redeem: (String) async throws -> UUID
) async -> LegacyTokenSessionMigrationOutcome {
    await LegacyTokenSessionMigrator.run(store: legacyStore(keychain), hasSDKSession: hasSDKSession, redeem: redeem)
}

@Suite struct LegacyTokenSessionStoreTests {
    @Test func readsTheExactSextantItem() {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let store = legacyStore(keychain)
        #expect(store.read() == .session(LegacyTokenSession(
            accessToken: "old-access", refreshToken: "old-refresh",
            userID: "0f8fad5b-d9cb-469f-a165-70867728950e",
            expiresAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )))
        #expect(store.hasItem)
    }

    @Test func readsOttaAndSvampItems() {
        let keychain = FakeKeychain()
        seedLegacy(keychain, ottaJSON, account: "supabase.session.v1")
        #expect(legacyStore(keychain, account: "supabase.session.v1").read() == .session(LegacyTokenSession(
            accessToken: "a", refreshToken: "r", userID: "u",
            expiresAt: Date(timeIntervalSinceReferenceDate: 800_000_000), isAnonymous: true
        )))
    }

    @Test func acceptsSnakeCaseAndOnlyNeedsTheRefreshToken() {
        let keychain = FakeKeychain()
        seedLegacy(keychain, #"{"refresh_token":"r","user_id":"u"}"#)
        #expect(legacyStore(keychain).read() == .session(LegacyTokenSession(refreshToken: "r", userID: "u")))
    }

    @Test func missingOrEmptyRefreshTokenIsCorrupt() {
        for json in ["not json", #"{"accessToken":"a"}"#, #"{"refreshToken":""}"#] {
            let keychain = FakeKeychain()
            seedLegacy(keychain, json)
            #expect(legacyStore(keychain).read() == .corrupt, "\(json)")
        }
    }

    @Test func customDecoder() {
        let keychain = FakeKeychain()
        keychain.seed(service: "com.app.legacy", account: "tokens", data: Data("r-token".utf8), accessible: kSecAttrAccessibleWhenUnlocked)
        let store = LegacyTokenSessionStore(account: "tokens", service: "com.app.legacy", backend: keychain) { data in
            LegacyTokenSession(refreshToken: String(decoding: data, as: UTF8.self))
        }
        #expect(store.read() == .session(LegacyTokenSession(refreshToken: "r-token")))
    }

    @Test func lockedKeychainIsUnreadable() {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        keychain.forcedStatus[.copy] = errSecInteractionNotAllowed
        #expect(legacyStore(keychain).read() == .unreadable(errSecInteractionNotAllowed))
    }

    @Test func queryHasNoServiceUnlessGiven() {
        let store = LegacyTokenSessionStore(account: "a", backend: FakeKeychain())
        #expect(store.itemQuery[kSecAttrService as String] == nil)
        #expect(store.itemQuery[kSecValueData as String] == nil)
        let scoped = LegacyTokenSessionStore(account: "a", service: "s", backend: FakeKeychain())
        #expect(scoped.itemQuery[kSecAttrService as String] as? String == "s")
    }
}

@Suite struct LegacyTokenSessionMigrationTests {
    @Test func successfulRefreshMigratesAndDeletesTheLegacyItem() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let redeemed = Box<String?>(nil)
        let outcome = await run(keychain) {
            redeemed.value = $0
            return userUUID
        }
        guard case .migrated(let userID) = outcome else { Issue.record("\(outcome)"); return }
        #expect(userID == userUUID)
        #expect(redeemed.value == "old-refresh")
        #expect(keychain.itemCount == 0)
    }

    @Test func networkFailureKeepsTheLegacyItem() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let outcome = await run(keychain) { _ in throw URLError(.notConnectedToInternet) }
        #expect(outcome.isDeferred)
        #expect(keychain.item(service: "", account: legacyAccount) != nil)
    }

    @Test func serverErrorAndRateLimitAreNotRejections() async {
        for error in [refreshGrantError(status: 500), refreshGrantError(status: 503), refreshGrantError(status: 429)] {
            let keychain = FakeKeychain()
            seedLegacy(keychain, sextantJSON)
            let outcome = await run(keychain) { _ in throw error }
            #expect(outcome.isDeferred, "\(error)")
            #expect(keychain.itemCount == 1)
        }
    }

    @Test func rejectedRefreshTokenDropsTheLegacyItem() async {
        let errors: [any Error] = [
            bareInvalidGrant(),
            refreshGrantError(status: 400),
            refreshGrantError(status: 403),
            apiError("refresh_token_not_found"),
            AuthError.sessionMissing,
        ]
        for error in errors {
            let keychain = FakeKeychain()
            seedLegacy(keychain, sextantJSON)
            let outcome = await run(keychain) { _ in throw error }
            guard case .rejected = outcome else { Issue.record("\(error) → \(outcome)"); continue }
            #expect(keychain.itemCount == 0)
        }
    }

    @Test func corruptItemIsDropped() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, "not json")
        let outcome = await run(keychain) { _ in Issue.record("must not refresh"); return userUUID }
        guard case .corrupt = outcome else { Issue.record("\(outcome)"); return }
        #expect(keychain.itemCount == 0)
    }

    @Test func existingSDKSessionWinsOverTheLegacyItem() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let outcome = await run(keychain, hasSDKSession: true) { _ in Issue.record("must not refresh"); return userUUID }
        guard case .alreadyMigrated = outcome else { Issue.record("\(outcome)"); return }
        #expect(keychain.itemCount == 0)
    }

    @Test func lockedKeychainDefersWithoutDeleting() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        keychain.forcedStatus[.copy] = errSecInteractionNotAllowed
        let outcome = await run(keychain) { _ in Issue.record("must not refresh"); return userUUID }
        guard case .deferred(let error) = outcome else { Issue.record("\(outcome)"); return }
        #expect(error as? KeychainAuthStorageError == .unableToRetrieve(errSecInteractionNotAllowed))
        #expect(!keychain.calls.contains(.delete))
        #expect(keychain.itemCount == 1)
    }

    @Test func nothingToMigrate() async {
        let outcome = await run(FakeKeychain()) { _ in Issue.record("must not refresh"); return userUUID }
        guard case .nothingToMigrate = outcome else { Issue.record("\(outcome)"); return }
    }
}

@Suite struct LegacyTokenSessionMigratorTests {
    @Test func concurrentCallersShareOneRefresh() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let calls = Box(0)
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), hasSDKSession: { false }) { _ in
            calls.value += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return userUUID
        }
        #expect(migrator.hasPendingSession)

        async let a = migrator.migrateIfNeeded()
        async let b = migrator.migrateIfNeeded()
        async let c = migrator.migrateIfNeeded()
        let outcomes = await [a, b, c]

        #expect(calls.value == 1)
        let migrated = outcomes.filter { if case .migrated = $0 { true } else { false } }
        #expect(!migrated.isEmpty)
        #expect(!migrator.hasPendingSession)
        // Finished: later calls don't touch the Keychain.
        let copies = keychain.calls.filter { $0 == .copy }.count
        guard case .nothingToMigrate = await migrator.migrateIfNeeded() else { Issue.record("expected nothingToMigrate"); return }
        #expect(keychain.calls.filter { $0 == .copy }.count == copies)
    }

    @Test func deferredRunIsRetriedOnTheNextCall() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let online = Box(false)
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), hasSDKSession: { false }) { _ in
            guard online.value else { throw URLError(.notConnectedToInternet) }
            return userUUID
        }
        #expect(await migrator.migrateIfNeeded().isDeferred)
        #expect(migrator.hasPendingSession)

        online.value = true
        guard case .migrated = await migrator.migrateIfNeeded() else { Issue.record("expected migrated"); return }
        #expect(!migrator.hasPendingSession)
    }

    @Test func discardDropsTheItem() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), hasSDKSession: { false }) { _ in
            Issue.record("must not refresh"); return userUUID
        }
        await migrator.discard()
        #expect(!migrator.hasPendingSession)
        guard case .nothingToMigrate = await migrator.migrateIfNeeded() else { Issue.record("expected nothingToMigrate"); return }
    }
}

// MARK: - End to end through supabase-swift

/// URLProtocol stub. Handlers are keyed by host so suites can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var request: URLRequest; var body: Data? }
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var captured: [String: [Captured]] = [:]

    /// A fresh host whose requests go to `handler` (`nil` from the handler,
    /// or no handler, fails the request as offline).
    static func register(_ handler: Handler? = nil) -> String {
        let host = "\(UUID().uuidString.lowercased()).stub.crawik.com"
        lock.withLock {
            handlers[host] = handler
            captured[host] = []
        }
        return host
    }

    static func requests(host: String) -> [Captured] {
        lock.withLock { captured[host] ?? [] }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.captured[host, default: []].append(Captured(request: request, body: body))
            return Self.handlers[host]
        }
        guard let (status, data) = handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func sessionJSON(userID: UUID, refreshToken: String = "new-refresh") -> Data {
    let expiresAt = Int(Date().timeIntervalSince1970) + 3600
    return Data("""
    {"access_token":"new-access","token_type":"bearer","expires_in":3600,"expires_at":\(expiresAt),
     "refresh_token":"\(refreshToken)",
     "user":{"id":"\(userID.uuidString.lowercased())","aud":"authenticated","role":"authenticated",
             "app_metadata":{"provider":"apple","providers":["apple"]},"user_metadata":{},
             "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}}
    """.utf8)
}

private let sdkService = "com.example.test.auth"
private let sdkStorageKey = "sb-test-auth-token"

private func makeStubClient(host: String, keychain: FakeKeychain) -> SupabaseClient {
    PortfolioSupabase.makeClient(
        environment: SupabaseEnvironment(url: "https://\(host)", anonKey: "anon-key"),
        storage: KeychainAuthStorage(service: sdkService, accessibility: .afterFirstUnlock, backend: keychain),
        storageKey: sdkStorageKey,
        session: StubURLProtocol.session()
    )
}

@Suite struct LegacyTokenSessionEndToEndTests {
    /// An upgrading user: the legacy refresh token is redeemed through the
    /// real SDK, the session lands in `KeychainAuthStorage`, the legacy item
    /// is deleted.
    @Test func upgradingUserStaysSignedIn() async throws {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let host = StubURLProtocol.register { request in
            request.url?.path == "/auth/v1/token" ? (200, sessionJSON(userID: userUUID)) : (404, Data())
        }
        let client = makeStubClient(host: host, keychain: keychain)
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), client: client)

        guard case .migrated(let userID) = await migrator.migrateIfNeeded() else { Issue.record("expected migrated"); return }
        #expect(userID == userUUID)

        let refresh = try #require(StubURLProtocol.requests(host: host).first { $0.request.url?.path == "/auth/v1/token" })
        #expect(refresh.request.httpMethod == "POST")
        #expect(refresh.request.url?.query?.contains("grant_type=refresh_token") == true)
        let body = try #require(refresh.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["refresh_token"] as? String == "old-refresh")

        #expect(keychain.item(service: "", account: legacyAccount) == nil)
        let stored = try #require(keychain.item(service: sdkService, account: sdkStorageKey))
        #expect(stored.accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(String(decoding: stored.data, as: UTF8.self).contains("new-refresh"))
        #expect(client.auth.currentSession?.refreshToken == "new-refresh")
    }

    @Test func offlineUpgradeKeepsTheLegacyItem() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let host = StubURLProtocol.register()
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), client: makeStubClient(host: host, keychain: keychain))

        #expect(await migrator.migrateIfNeeded().isDeferred)
        #expect(keychain.item(service: "", account: legacyAccount) != nil)
        #expect(migrator.hasPendingSession)
    }

    /// Older self-hosted GoTrue: bare `400 {"error":"invalid_grant"}` with a
    /// description that doesn't say "refresh token".
    @Test func rejectedLegacySessionIsDropped() async {
        for description in ["Invalid Refresh Token", "Session Expired"] {
            let keychain = FakeKeychain()
            seedLegacy(keychain, sextantJSON)
            let host = StubURLProtocol.register { _ in
                (400, Data(#"{"error":"invalid_grant","error_description":"\#(description)"}"#.utf8))
            }
            let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), client: makeStubClient(host: host, keychain: keychain))

            guard case .rejected = await migrator.migrateIfNeeded() else { Issue.record("expected rejected: \(description)"); continue }
            #expect(keychain.itemCount == 0)
        }
    }

    @Test func serverErrorDefers() async {
        let keychain = FakeKeychain()
        seedLegacy(keychain, sextantJSON)
        let host = StubURLProtocol.register { _ in (503, Data(#"{"message":"upstream unavailable"}"#.utf8)) }
        let migrator = LegacyTokenSessionMigrator(store: legacyStore(keychain), client: makeStubClient(host: host, keychain: keychain))

        #expect(await migrator.migrateIfNeeded().isDeferred)
        #expect(keychain.itemCount == 1)
    }
}

// MARK: - makeClient options

@Suite struct MakeClientOptionsTests {
    struct Row: Codable, Equatable { var when: Date }

    /// `db:` coders and `session:` reach PostgREST.
    @Test func databaseCodersAndSessionAreUsed() async throws {
        let host = StubURLProtocol.register { _ in (200, Data(#"[{"when":"stamp-42"}]"#.utf8)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode("stamp-\(Int(date.timeIntervalSince1970))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return Date(timeIntervalSince1970: Double(text.dropFirst(6)) ?? 0)
        }
        let client = PortfolioSupabase.makeClient(
            environment: SupabaseEnvironment(url: "https://\(host)", anonKey: "anon-key"),
            storage: InMemoryAuthStorage(),
            headers: ["X-App": "test"],
            db: .init(encoder: encoder, decoder: decoder),
            session: StubURLProtocol.session()
        )

        let rows: [Row] = try await client.from("rows").insert(Row(when: Date(timeIntervalSince1970: 7)), returning: .representation).execute().value
        #expect(rows == [Row(when: Date(timeIntervalSince1970: 42))])

        let captured = try #require(StubURLProtocol.requests(host: host).first)
        #expect(captured.request.value(forHTTPHeaderField: "X-App") == "test")
        let body = try #require(captured.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("stamp-7"))
    }

    @Test func clientOptionsCarryTheSharedAuthOptions() {
        let session = StubURLProtocol.session()
        let options = PortfolioSupabase.clientOptions(
            storage: InMemoryAuthStorage(), storageKey: "k", db: .init(schema: "app"), session: session
        )
        #expect(options.auth.autoRefreshToken)
        #expect(options.auth.emitLocalSessionAsInitialSession)
        #expect(options.auth.storageKey == "k")
        #expect(options.db.schema == "app")
        #expect(options.global.session === session)
    }
}
