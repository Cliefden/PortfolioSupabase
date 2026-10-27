import Foundation
import Supabase

/// Classifies errors from any Supabase sub-client.
///
/// The rule every app converged on: only a definite rejection of the
/// credentials (expired/invalid JWT, revoked refresh token) means the session
/// is dead. A network failure proves nothing, and signing a user out over a
/// dropped packet defeats offline-first apps.
public enum AuthFailure {
    /// PostgREST codes for a rejected JWT: PGRST301 (v11 "JWT expired", v12
    /// "JWT could not be decoded"), PGRST302 (anonymous role disabled) and
    /// PGRST303 (v12 "JWT claims validation failed", i.e. expired).
    static let postgrestJWTCodes: Set<String> = ["PGRST301", "PGRST302", "PGRST303"]

    /// GoTrue error codes that mean the session or refresh token is dead.
    /// `invalid_grant` is what older GoTrue versions send for a bad refresh
    /// token (self-hosted stacks lag behind).
    static let authRejectionCodes: Set<String> = [
        "bad_jwt", "invalid_jwt", "no_authorization",
        "session_not_found", "session_expired",
        "refresh_token_not_found", "refresh_token_already_used",
        "invalid_grant",
    ]

    /// Message fragments for errors that arrive untyped or without a code.
    static let rejectionMessageFragments = [
        "jwt expired", "invalid jwt", "jwt could not be decoded", "invalid refresh token",
        "refresh token not found", "refresh_token_not_found", "invalid_grant",
    ]

    /// `true` when `error` means the server rejected the access or refresh
    /// token, so refreshing (or signing in again) is the fix.
    public static func isAuthRejection(_ error: any Error) -> Bool {
        if error is URLError || error is CancellationError { return false }

        if let authError = error as? AuthError {
            if case .sessionMissing = authError { return true }
            if case .api(let message, let code, _, let response) = authError {
                if authRejectionCodes.contains(code.rawValue) { return true }
                if response.statusCode == 401 { return true }
                return containsRejectionFragment(message)
            }
            return false
        }

        if let postgrestError = error as? PostgrestError {
            if let code = postgrestError.code, postgrestJWTCodes.contains(code.uppercased()) { return true }
            return containsRejectionFragment(postgrestError.message)
        }

        if let functionsError = error as? FunctionsError {
            if case .httpError(let code, _) = functionsError { return code == 401 }
            return false
        }

        if let storageError = error as? StorageError {
            if storageError.statusCode == "401" { return true }
            return containsRejectionFragment(storageError.message)
                || containsRejectionFragment(storageError.error ?? "")
        }

        return containsRejectionFragment(String(describing: error))
    }

    /// `true` for transient transport failures worth retrying (offline,
    /// timeout, connection lost, DNS).
    public static func isTransient(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return transientURLErrorCodes.contains(URLError.Code(rawValue: nsError.code))
    }

    static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .networkConnectionLost,
        .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
        .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    static func containsRejectionFragment(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return rejectionMessageFragments.contains { lowered.contains($0) }
    }
}
