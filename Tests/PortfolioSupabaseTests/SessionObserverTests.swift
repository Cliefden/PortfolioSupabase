import Foundation
import Supabase
import Testing
@testable import PortfolioSupabase

/// Builds an SDK `Session` by decoding JSON, which is stable across SDK
/// versions (the memberwise initializers are not).
func makeSession(userId: UUID = UUID(), expiresIn: TimeInterval = 3600) throws -> Session {
    let now = Date().timeIntervalSince1970
    let json = """
    {
      "access_token": "access",
      "token_type": "bearer",
      "expires_in": \(expiresIn),
      "expires_at": \(now + expiresIn),
      "refresh_token": "refresh",
      "user": {
        "id": "\(userId.uuidString.lowercased())",
        "aud": "authenticated",
        "app_metadata": {"provider": "email"},
        "user_metadata": {},
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z"
      }
    }
    """
    return try AuthClient.Configuration.jsonDecoder.decode(Session.self, from: Data(json.utf8))
}

/// Records what a stream emitted.
@MainActor
final class StreamRecorder {
    private(set) var values: [Bool] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Bool>) {
        task = Task { @MainActor [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    func cancel() { task?.cancel() }
}

/// Lets queued main-actor tasks run.
@MainActor
func drain() async {
    for _ in 0..<20 { await Task.yield() }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor
func makeObserver(
    refresh: @escaping @Sendable () async throws -> Session = { throw URLError(.notConnectedToInternet) },
    current: @escaping @Sendable () async throws -> Session = { throw URLError(.notConnectedToInternet) },
    guard userGuard: UserChangeGuard? = nil
) -> SessionObserver {
    SessionObserver(
        events: { AsyncStream { _ in } },
        refresh: refresh,
        currentSession: current,
        userChangeGuard: userGuard
    )
}

@MainActor
@Suite struct SessionObserverTests {
    @Test func streamWaitsForInitialSession() async throws {
        let observer = makeObserver()
        let recorder = StreamRecorder(observer.authStateStream())
        await drain()
        #expect(recorder.values.isEmpty, "no stale launch-time false")

        observer.handle(event: .initialSession, session: try makeSession())
        await drain()
        #expect(recorder.values == [true])
        #expect(observer.isAuthenticated)
        #expect(observer.hasResolvedInitialSession)
    }

    @Test func lateSubscriberGetsCurrentStateImmediately() async throws {
        let observer = makeObserver()
        observer.handle(event: .initialSession, session: nil)

        let recorder = StreamRecorder(observer.authStateStream())
        await drain()
        #expect(recorder.values == [false])
    }

    @Test func expiredInitialSessionIsSignedOut() async throws {
        let userGuard = UserChangeGuard(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let observer = makeObserver(guard: userGuard)
        let userId = UUID()
        observer.handle(event: .initialSession, session: try makeSession(userId: userId, expiresIn: -60))

        #expect(!observer.isAuthenticated)
        #expect(observer.currentUser == nil)
        // But the device's owner is recorded for the quarantine check.
        #expect(userGuard.lastUserId == userId)
    }

    @Test func emitsOnlyOnChanges() async throws {
        let observer = makeObserver()
        let recorder = StreamRecorder(observer.authStateStream())
        let session = try makeSession()

        observer.handle(event: .initialSession, session: nil)
        await drain()
        observer.handle(event: .signedIn, session: session)
        await drain()
        observer.handle(event: .tokenRefreshed, session: session)
        await drain()
        observer.handle(event: .signedOut, session: nil)
        await drain()

        #expect(recorder.values == [false, true, false])
    }

    @Test func waitForInitialSessionResumes() async throws {
        let observer = makeObserver()
        let resumed = Box(false)
        let waiter = Task { @MainActor in
            await observer.waitForInitialSession()
            resumed.value = true
        }
        await drain()
        #expect(!resumed.value)
        observer.handle(event: .initialSession, session: nil)
        await waiter.value
        #expect(resumed.value)
        // Already resolved: returns at once.
        await observer.waitForInitialSession()
    }

    @Test func userChangeGuardFiresOnlyForDifferentUser() async throws {
        let userGuard = UserChangeGuard(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let observer = makeObserver(guard: userGuard)
        var changes: [(UUID, UUID)] = []
        observer.onUserChanged = { previous, user in changes.append((previous, user.id)) }

        let alice = UUID(), bob = UUID()
        observer.handle(event: .initialSession, session: try makeSession(userId: alice))
        observer.handle(event: .tokenRefreshed, session: try makeSession(userId: alice))
        observer.handle(event: .signedOut, session: nil)
        observer.handle(event: .signedIn, session: try makeSession(userId: alice))
        #expect(changes.isEmpty)

        observer.handle(event: .signedOut, session: nil)
        observer.handle(event: .signedIn, session: try makeSession(userId: bob))
        #expect(changes.count == 1)
        #expect(changes.first?.0 == alice)
        #expect(changes.first?.1 == bob)
    }

    @Test func onEventSeesEveryEvent() async throws {
        let observer = makeObserver()
        var events: [AuthChangeEvent] = []
        observer.onEvent = { event, _ in events.append(event) }
        observer.handle(event: .initialSession, session: nil)
        observer.handle(event: .passwordRecovery, session: nil)
        #expect(events == [.initialSession, .passwordRecovery])
        #expect(observer.lastEvent == .passwordRecovery)
    }

    @Test func withSessionRefreshRetriesOnceAfterRefresh() async throws {
        let session = try makeSession()
        let refreshes = Counter()
        let observer = makeObserver(refresh: { refreshes.increment(); return session })
        observer.handle(event: .initialSession, session: session)

        var attempts = 0
        let result = try await observer.withSessionRefresh { () async throws -> String in
            attempts += 1
            if attempts == 1 { throw try postgrestError(code: "PGRST301", message: "JWT expired") }
            return "rows"
        }

        #expect(result == "rows")
        #expect(attempts == 2)
        #expect(refreshes.count == 1)
        #expect(observer.isAuthenticated)
    }

    @Test func withSessionRefreshPassesThroughNonAuthErrors() async throws {
        let refreshes = Counter()
        let observer = makeObserver(refresh: { refreshes.increment(); return try makeSession() })
        var attempts = 0
        await #expect(throws: URLError.self) {
            try await observer.withSessionRefresh { () async throws -> Int in
                attempts += 1
                throw URLError(.timedOut)
            }
        }
        #expect(attempts == 1)
        #expect(refreshes.count == 0)
    }

    @Test func rejectedRefreshExpiresSession() async throws {
        let observer = makeObserver(refresh: { throw apiError("refresh_token_not_found") })
        observer.handle(event: .initialSession, session: try makeSession())
        let recorder = StreamRecorder(observer.authStateStream())
        await drain()

        await #expect(throws: AuthError.self) {
            try await observer.withSessionRefresh { () async throws -> Int in
                throw FunctionsError.httpError(code: 401, data: Data())
            }
        }
        await drain()
        #expect(!observer.isAuthenticated)
        #expect(recorder.values == [true, false])
    }

    @Test func offlineRefreshKeepsSession() async throws {
        let observer = makeObserver(refresh: { throw URLError(.notConnectedToInternet) })
        observer.handle(event: .initialSession, session: try makeSession())

        await #expect(throws: URLError.self) {
            try await observer.withSessionRefresh { () async throws -> Int in
                throw FunctionsError.httpError(code: 401, data: Data())
            }
        }
        #expect(observer.isAuthenticated)
    }

    @Test func validateSession() async throws {
        let mode = Box(0)
        let session = try makeSession()
        let observer = makeObserver(current: {
            switch mode.value {
            case 0: return session
            case 1: throw URLError(.notConnectedToInternet)
            default: throw apiError("refresh_token_not_found")
            }
        })
        observer.handle(event: .initialSession, session: nil)

        #expect(await observer.validateSession())
        #expect(observer.isAuthenticated)

        mode.value = 1
        #expect(await observer.validateSession(), "offline keeps the session")
        #expect(observer.isAuthenticated)

        mode.value = 2
        #expect(await observer.validateSession() == false)
        #expect(!observer.isAuthenticated)
    }

    @Test func terminatedStreamsAreRemoved() async throws {
        let observer = makeObserver()
        let recorder = StreamRecorder(observer.authStateStream())
        await drain()
        #expect(observer.activeStreamCount == 1)
        recorder.cancel()
        await drain()
        #expect(observer.activeStreamCount == 0)
    }

    @Test func startConsumesInjectedEvents() async throws {
        let session = try makeSession()
        let (events, continuation) = AsyncStream<SessionObserver.AuthEvent>.makeStream()
        let observer = SessionObserver(
            events: { events },
            refresh: { session },
            currentSession: { session }
        )
        observer.start()
        observer.start() // idempotent
        continuation.yield((.initialSession, session))
        await observer.waitForInitialSession()
        #expect(observer.isAuthenticated)
        observer.stop()
    }
}

@Suite struct UserChangeGuardTests {
    @Test func recordsAndCompares() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let userGuard = UserChangeGuard(defaults: defaults)
        let a = UUID(), b = UUID()

        #expect(userGuard.recordSignIn(a) == nil)
        #expect(userGuard.recordSignIn(a) == nil)
        #expect(userGuard.recordSignIn(b) == a)
        #expect(userGuard.lastUserId == b)

        userGuard.recordIfMissing(a)
        #expect(userGuard.lastUserId == b, "never overwrites")

        userGuard.clear()
        userGuard.recordIfMissing(a)
        #expect(userGuard.lastUserId == a)
    }

    @Test func readsLegacyUppercaseIds() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = UUID()
        defaults.set(a.uuidString, forKey: "com.stocked.lastSignedInUserId")
        let userGuard = UserChangeGuard(key: "com.stocked.lastSignedInUserId", defaults: defaults)
        #expect(userGuard.recordSignIn(a) == nil)
    }
}
