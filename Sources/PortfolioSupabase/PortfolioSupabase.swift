import Foundation
import Supabase

/// Namespace for the client factory and small SDK-level helpers.
public enum PortfolioSupabase {
    /// Host of the non-functional client returned while unconfigured.
    public static let unconfiguredURL = URL(string: "https://invalid.supabase.co")!

    /// Builds the client every SDK app built by hand, with the shared auth
    /// options: `autoRefreshToken: true` and
    /// `emitLocalSessionAsInitialSession: true` (the stored session is emitted
    /// at once as `.initialSession`, even if expired; check
    /// `session.isExpired`. ``SessionObserver`` does).
    ///
    /// When `environment` isn't configured this returns ``makeUnconfiguredClient()``
    /// instead of crashing, so the UI can show
    /// `environment.configurationError`. Check `environment.isConfigured`
    /// before relying on the client.
    ///
    /// - Parameters:
    ///   - storage: where the session lives. Typically
    ///     `#if DEBUG UserDefaultsAuthStorage() #else KeychainAuthStorage(service:) #endif`.
    ///   - redirectToURL: default redirect for magic link / OAuth / recovery
    ///     flows (e.g. `celiador://auth-callback`).
    ///   - storageKey: leave `nil` to keep the SDK default, or existing
    ///     sessions are not found after adopting.
    ///   - flowType: PKCE by default. Use `.implicit` only for flows whose
    ///     emailed link must be redeemable on another device (see README).
    ///   - headers: extra global headers.
    ///   - db: PostgREST options: schema and the JSON coders for rows (e.g.
    ///     an app's own date format). Defaults to the SDK's.
    ///   - session: the `URLSession` every sub-client uses (custom timeouts,
    ///     or a `URLProtocol` stub in tests). Defaults to `.shared`, as the SDK.
    ///   - logger: the SDK logger, passed to every sub-client.
    public static func makeClient(
        environment: SupabaseEnvironment,
        storage: any AuthLocalStorage,
        redirectToURL: URL? = nil,
        storageKey: String? = nil,
        flowType: AuthFlowType = AuthClient.Configuration.defaultFlowType,
        headers: [String: String] = [:],
        db: SupabaseClientOptions.DatabaseOptions = .init(),
        session: URLSession = .shared,
        logger: (any SupabaseLogger)? = nil
    ) -> SupabaseClient {
        guard environment.isConfigured, let url = environment.url else {
            return makeUnconfiguredClient()
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: environment.anonKey,
            options: clientOptions(
                storage: storage,
                redirectToURL: redirectToURL,
                storageKey: storageKey,
                flowType: flowType,
                headers: headers,
                db: db,
                session: session,
                logger: logger
            )
        )
    }

    /// The full `SupabaseClientOptions` ``makeClient(environment:storage:redirectToURL:storageKey:flowType:headers:db:session:logger:)``
    /// builds: the shared auth options plus the given db and global options.
    /// For apps that construct `SupabaseClient` themselves.
    public static func clientOptions(
        storage: any AuthLocalStorage,
        redirectToURL: URL? = nil,
        storageKey: String? = nil,
        flowType: AuthFlowType = AuthClient.Configuration.defaultFlowType,
        headers: [String: String] = [:],
        db: SupabaseClientOptions.DatabaseOptions = .init(),
        session: URLSession = .shared,
        logger: (any SupabaseLogger)? = nil
    ) -> SupabaseClientOptions {
        SupabaseClientOptions(
            db: db,
            auth: authOptions(
                storage: storage,
                redirectToURL: redirectToURL,
                storageKey: storageKey,
                flowType: flowType
            ),
            global: SupabaseClientOptions.GlobalOptions(headers: headers, session: session, logger: logger)
        )
    }

    /// The shared `AuthOptions`, for apps that need to build
    /// `SupabaseClientOptions` themselves (e.g. custom db schema).
    public static func authOptions(
        storage: any AuthLocalStorage,
        redirectToURL: URL? = nil,
        storageKey: String? = nil,
        flowType: AuthFlowType = AuthClient.Configuration.defaultFlowType
    ) -> SupabaseClientOptions.AuthOptions {
        SupabaseClientOptions.AuthOptions(
            storage: storage,
            redirectToURL: redirectToURL,
            storageKey: storageKey,
            flowType: flowType,
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: true
        )
    }

    /// A client pointed at an invalid host with in-memory storage. Every call
    /// fails (as a network error), nothing touches the keychain, and nothing
    /// crashes. Used by ``makeClient(environment:storage:redirectToURL:storageKey:flowType:headers:db:session:logger:)``
    /// when the environment is unconfigured.
    public static func makeUnconfiguredClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: unconfiguredURL,
            supabaseKey: "invalid-key",
            options: SupabaseClientOptions(
                auth: authOptions(storage: InMemoryAuthStorage())
            )
        )
    }

    /// Signs out, treating a failed server call as success when the local
    /// session is gone anyway (Stokked `AuthService.signOut`).
    ///
    /// supabase-swift removes the local session before calling `/logout`, so
    /// a network failure there still leaves the device signed out. This only
    /// throws if a session is still stored afterwards.
    public static func signOut(client: SupabaseClient, scope: SignOutScope = .global) async throws {
        do {
            try await client.auth.signOut(scope: scope)
        } catch {
            if client.auth.currentSession != nil {
                // Last resort: drop the local session without the network.
                try? await client.auth.signOut(scope: .local)
                if client.auth.currentSession != nil { throw error }
            }
        }
    }
}
