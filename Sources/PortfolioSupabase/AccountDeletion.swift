import Foundation
import Supabase

/// How the server deletes the account.
public enum AccountDeletionStrategy: Sendable, Equatable {
    /// A `SECURITY DEFINER` Postgres function that deletes the caller's data
    /// and `auth.users` row, keyed on `auth.uid()` (Jeroboam
    /// `delete_user_account`, Nassau `delete_current_user`, Stokked
    /// `delete_my_account`).
    case rpc(_ name: String, params: [String: AnyJSON] = [:])
    /// An edge function that deletes storage objects and the auth user with
    /// the service role (Carpe Vitem `delete-account`, body `["confirm": true]`).
    case edgeFunction(_ name: String, body: [String: AnyJSON] = [:])
}

public enum AccountDeletionError: Error, LocalizedError {
    /// The session couldn't be refreshed (offline, or already dead), so
    /// nothing was deleted.
    case sessionUnavailable(underlying: any Error)
    /// The server deletion failed; the account still exists.
    case deletionFailed(underlying: any Error)

    public var underlying: any Error {
        switch self {
        case .sessionUnavailable(let e), .deletionFailed(let e): e
        }
    }

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .sessionUnavailable:
            if AuthFailure.isTransient(underlying) {
                return .portfolioSupabase("Couldn't connect. Check your connection and try again.")
            }
            return .portfolioSupabase("Your session has expired. Sign in again, then delete your account.")
        case .deletionFailed:
            return .portfolioSupabase("Your account could not be deleted. Please try again.")
        }
    }

    public var errorDescription: String? { String(localized: localizedResource) }
}

/// The account-deletion sequence (Jeroboam `DeleteAccountView.performDeletion`
/// + Carpe Vitem `ExportService.deleteAccount`):
///
/// 1. Refresh the session, failing fast before anything destructive (offline,
///    dead session).
/// 2. Run the app's best-effort `cleanup` (Storage files SQL can't delete,
///    Apple token revocation). It must not throw; failures can't block
///    deletion (App Review 5.1.1(v)).
/// 3. Run the server strategy.
/// 4. Sign out. The user no longer exists, so a failed network sign-out falls
///    back to clearing the local session.
///
/// Plugs straight into PortfolioKit:
///
/// ```swift
/// DeleteAccountView(config: …) {
///     try await AccountDeletion.deleteAccount(client: client, strategy: .rpc("delete_user_account"))
/// }
/// ```
public enum AccountDeletion {
    public static func deleteAccount(
        client: SupabaseClient,
        strategy: AccountDeletionStrategy,
        cleanup: (@Sendable () async -> Void)? = nil
    ) async throws {
        try await run(
            steps: AccountDeletionSteps(
                refreshSession: { _ = try await client.auth.refreshSession() },
                delete: { try await perform(strategy, client: client) },
                signOut: { try await client.auth.signOut() },
                signOutLocally: { try await client.auth.signOut(scope: .local) }
            ),
            cleanup: cleanup
        )
    }

    static func perform(_ strategy: AccountDeletionStrategy, client: SupabaseClient) async throws {
        switch strategy {
        case .rpc(let name, let params):
            if params.isEmpty {
                try await client.rpc(name).execute()
            } else {
                try await client.rpc(name, params: params).execute()
            }
        case .edgeFunction(let name, let body):
            try await client.functions.invoke(
                name,
                options: FunctionInvokeOptions(method: .post, body: body)
            )
        }
    }

    /// The sequence over injectable steps (tests).
    static func run(steps: AccountDeletionSteps, cleanup: (@Sendable () async -> Void)?) async throws {
        do {
            try await steps.refreshSession()
        } catch {
            throw AccountDeletionError.sessionUnavailable(underlying: error)
        }

        await cleanup?()

        do {
            try await steps.delete()
        } catch {
            throw AccountDeletionError.deletionFailed(underlying: error)
        }

        do {
            try await steps.signOut()
        } catch {
            try? await steps.signOutLocally()
        }
    }
}

struct AccountDeletionSteps: Sendable {
    var refreshSession: @Sendable () async throws -> Void
    var delete: @Sendable () async throws -> Void
    var signOut: @Sendable () async throws -> Void
    var signOutLocally: @Sendable () async throws -> Void
}
