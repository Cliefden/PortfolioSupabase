import Foundation
import Observation
import Supabase

/// Observable auth state for SwiftUI, fed by `client.auth.authStateChanges`.
/// Replaces the `SupabaseService` auth half each SDK app forked.
///
/// - ``authStateStream()`` buffers like Jeroboam's: nothing is emitted until
///   the SDK has resolved the stored session, so a signed-in user never sees
///   the stale launch-time `false` (the landing-screen flash).
/// - ``withSessionRefresh(_:)`` retries an operation once after refreshing on
///   an auth rejection (Stokked `withSessionRefresh`, Contrarian
///   `withFreshToken`).
/// - An optional ``UserChangeGuard`` reports when a *different* user signs in
///   than the one whose data the device holds (Stokked's quarantine).
///
/// ```swift
/// let session = SessionObserver(client: client, userChangeGuard: UserChangeGuard())
/// session.onUserChanged = { _, _ in LocalStore.wipe() }
/// session.start()
/// ```
@Observable
@MainActor
public final class SessionObserver {
    public typealias AuthEvent = (event: AuthChangeEvent, session: Session?)

    /// The signed-in user, or `nil`.
    public private(set) var currentUser: User?
    /// `true` while a non-expired session is held.
    public private(set) var isAuthenticated = false
    /// `true` once the SDK has emitted `.initialSession` (or any later
    /// definite event). Before that, ``isAuthenticated`` is only the default.
    public private(set) var hasResolvedInitialSession = false
    /// The most recent SDK event, for apps that branch on it (e.g.
    /// `.passwordRecovery`).
    public private(set) var lastEvent: AuthChangeEvent?

    /// Detects a different user signing in. `nil` disables the check.
    @ObservationIgnored public var userChangeGuard: UserChangeGuard?
    /// Called (before stream listeners are notified, so before anything
    /// syncs) when a different user signs in than the guard's last user.
    /// Wipe the previous user's local data here.
    @ObservationIgnored public var onUserChanged: (@MainActor (_ previousUserId: UUID, _ newUser: User) -> Void)?
    /// Called after every handled event, for app-specific side effects
    /// (cache resets on `.signedOut`, analytics identify, …).
    @ObservationIgnored public var onEvent: (@MainActor (AuthChangeEvent, Session?) -> Void)?

    @ObservationIgnored private let events: @Sendable () async -> AsyncStream<AuthEvent>
    @ObservationIgnored private let refresher: @Sendable () async throws -> Session
    @ObservationIgnored private let sessionFetcher: @Sendable () async throws -> Session
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    @ObservationIgnored private var initialSessionWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init(client: SupabaseClient, userChangeGuard: UserChangeGuard? = nil) {
        self.init(
            events: {
                let source = client.auth.authStateChanges
                return AsyncStream { continuation in
                    let task = Task {
                        for await change in source {
                            continuation.yield((change.event, change.session))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            refresh: { try await client.auth.refreshSession() },
            currentSession: { try await client.auth.session },
            userChangeGuard: userChangeGuard
        )
    }

    /// Injectable initializer (tests, or a non-default auth source).
    public init(
        events: @escaping @Sendable () async -> AsyncStream<AuthEvent>,
        refresh: @escaping @Sendable () async throws -> Session,
        currentSession: @escaping @Sendable () async throws -> Session,
        userChangeGuard: UserChangeGuard? = nil
    ) {
        self.events = events
        self.refresher = refresh
        self.sessionFetcher = currentSession
        self.userChangeGuard = userChangeGuard
    }

    // MARK: - Listening

    /// Starts listening to auth events. Idempotent.
    public func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            guard let stream = await self?.events() else { return }
            for await (event, session) in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event: event, session: session)
            }
        }
    }

    /// Stops listening and finishes every stream handed out.
    public func stop() {
        listenTask?.cancel()
        listenTask = nil
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// Applies one SDK event. Internal so tests can drive it directly.
    func handle(event: AuthChangeEvent, session: Session?) {
        let wasAuthenticated = isAuthenticated
        lastEvent = event

        switch event {
        case .initialSession:
            if let session, !session.isExpired {
                setSignedIn(session.user)
            } else {
                setSignedOut()
                // An expired stored session still says whose data this device
                // holds; record it (never overwriting) so the guard can tell
                // if a different user signs in next.
                if let session { userChangeGuard?.recordIfMissing(session.user.id) }
            }
            resolveInitialSession()
        case .signedIn, .tokenRefreshed, .userUpdated:
            if let session { setSignedIn(session.user) } else { setSignedOut() }
            resolveInitialSession()
        case .signedOut:
            setSignedOut()
            resolveInitialSession()
        default:
            break
        }

        if isAuthenticated, let user = currentUser,
           let previous = userChangeGuard?.recordSignIn(user.id) {
            onUserChanged?(previous, user)
        }

        onEvent?(event, session)

        if wasAuthenticated != isAuthenticated || event == .initialSession {
            broadcast()
        }
    }

    private func setSignedIn(_ user: User) {
        currentUser = user
        isAuthenticated = true
    }

    private func setSignedOut() {
        currentUser = nil
        isAuthenticated = false
    }

    private func resolveInitialSession() {
        guard !hasResolvedInitialSession else { return }
        hasResolvedInitialSession = true
        let waiters = initialSessionWaiters
        initialSessionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func broadcast() {
        for continuation in continuations.values {
            continuation.yield(isAuthenticated)
        }
    }

    // MARK: - Streams

    /// Auth state as a stream. The first value is emitted only once the
    /// initial session has been resolved (immediately, if it already has);
    /// after that, on every change. Registered synchronously, so no event
    /// between creation and the first `for await` is missed.
    public func authStateStream() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        if hasResolvedInitialSession {
            continuation.yield(isAuthenticated)
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Suspends until the stored session (if any) has been resolved
    /// (Nassau `waitForInitialSession`). Safe to call any number of times.
    public func waitForInitialSession() async {
        if hasResolvedInitialSession { return }
        await withCheckedContinuation { continuation in
            if hasResolvedInitialSession {
                continuation.resume()
            } else {
                initialSessionWaiters.append(continuation)
            }
        }
    }

    var activeStreamCount: Int { continuations.count }

    // MARK: - Validation & refresh

    /// Validates the session, refreshing it if expired (call on every
    /// foreground). Returns `false` only when the server rejected the session;
    /// on a network failure the current state is kept and returned.
    @discardableResult
    public func validateSession() async -> Bool {
        do {
            let session = try await sessionFetcher()
            applyRefreshed(session)
            return true
        } catch {
            if AuthFailure.isAuthRejection(error) {
                expireSession()
                return false
            }
            return isAuthenticated
        }
    }

    /// Forces a token refresh. The SDK coalesces concurrent refreshes of the
    /// same refresh token, so parallel 401s share one request.
    public func refreshSession() async throws {
        let session = try await refresher()
        applyRefreshed(session)
    }

    /// Runs `operation`; if it fails with an auth rejection, refreshes the
    /// session once and retries. If the refresh itself is rejected the session
    /// is marked expired (listeners get `false`) and that error is thrown. A
    /// network failure during refresh is thrown without signing out.
    public func withSessionRefresh<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard AuthFailure.isAuthRejection(error) else { throw error }
            do {
                try await refreshSession()
            } catch {
                if AuthFailure.isAuthRejection(error) { expireSession() }
                throw error
            }
            return try await operation()
        }
    }

    private func applyRefreshed(_ session: Session) {
        let wasAuthenticated = isAuthenticated
        setSignedIn(session.user)
        if wasAuthenticated != isAuthenticated { broadcast() }
    }

    /// Marks the session dead locally and notifies listeners. The SDK
    /// normally follows with its own `.signedOut`.
    func expireSession() {
        let wasAuthenticated = isAuthenticated
        setSignedOut()
        if wasAuthenticated { broadcast() }
    }
}

/// Remembers which user's data this device holds, so a *different* user
/// signing in can be detected and the previous user's local data wiped first.
/// A session expiry keeps local data (the same user loses no offline edits);
/// without this, the next user would inherit it (Stokked's quarantine).
public final class UserChangeGuard: @unchecked Sendable {
    public static let defaultKey = "portfolio.supabase.lastSignedInUserId"

    public let key: String
    private let defaults: UserDefaults

    public init(key: String = defaultKey, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// The last recorded user, if any.
    public var lastUserId: UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// Records `userId` as the device's user. Returns the previous user's id
    /// when it was a different user, otherwise `nil`.
    @discardableResult
    public func recordSignIn(_ userId: UUID) -> UUID? {
        let previous = lastUserId
        defaults.set(userId.uuidString.lowercased(), forKey: key)
        guard let previous, previous != userId else { return nil }
        return previous
    }

    /// Records `userId` only if no user is recorded yet.
    public func recordIfMissing(_ userId: UUID) {
        guard lastUserId == nil else { return }
        defaults.set(userId.uuidString.lowercased(), forKey: key)
    }

    /// Forgets the recorded user (e.g. after a full local wipe).
    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
