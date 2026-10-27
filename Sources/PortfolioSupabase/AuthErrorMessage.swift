import Foundation
import Supabase

/// What went wrong with an auth call, in terms a user can act on.
public enum AuthErrorKind: Sendable, Equatable, CaseIterable {
    case invalidCredentials
    case emailNotConfirmed
    case userAlreadyExists
    case weakPassword
    case samePassword
    /// Wrong, used or expired email code / link.
    case invalidOrExpiredCode
    case rateLimited
    case invalidEmail
    case signupDisabled
    case providerDisabled
    case sessionExpired
    case network
    case unknown

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .invalidCredentials:
            .portfolioSupabase("Incorrect email or password.")
        case .emailNotConfirmed:
            .portfolioSupabase("Confirm your email address first. Check your inbox for the link.")
        case .userAlreadyExists:
            .portfolioSupabase("An account with this email already exists. Sign in instead.")
        case .weakPassword:
            .portfolioSupabase("That password is too weak. Choose a longer one or mix letters, numbers and symbols.")
        case .samePassword:
            .portfolioSupabase("Choose a password different from your current one.")
        case .invalidOrExpiredCode:
            .portfolioSupabase("That code is wrong or has expired. Check the email, or send a new code.")
        case .rateLimited:
            .portfolioSupabase("Too many attempts. Please wait a few minutes and try again.")
        case .invalidEmail:
            .portfolioSupabase("Please enter a valid email address")
        case .signupDisabled:
            .portfolioSupabase("New sign-ups are currently closed.")
        case .providerDisabled:
            .portfolioSupabase("This sign-in method isn't available right now.")
        case .sessionExpired:
            .portfolioSupabase("Your session has expired. Please sign in again.")
        case .network:
            .portfolioSupabase("Couldn't connect. Check your connection and try again.")
        case .unknown:
            .portfolioSupabase("Something went wrong. Please try again.")
        }
    }

    public var message: String { String(localized: localizedResource) }
}

/// Maps Supabase Auth / transport errors to localized user-facing text
/// (generalizes Nassau `PasswordResetError.from`). The server's own messages
/// are English and technical, so the error *code* decides; message matching is
/// only a fallback for older self-hosted GoTrue versions that send no code.
public enum AuthErrorMessage {
    public static func kind(for error: any Error) -> AuthErrorKind {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .unknown : .network
        }
        if AuthFailure.isTransient(error) { return .network }
        if let validation = error as? CredentialValidationError {
            switch validation {
            case .emptyEmail, .invalidEmail: return .invalidEmail
            case .passwordMismatch: return .unknown
            default: return .weakPassword
            }
        }
        guard let authError = error as? AuthError else { return .unknown }

        if case .weakPassword = authError { return .weakPassword }
        if case .sessionMissing = authError { return .sessionExpired }

        if let kind = kind(forCode: authError.errorCode.rawValue) { return kind }

        if case .api(let message, _, _, let response) = authError {
            if response.statusCode == 429 { return .rateLimited }
            if let kind = kind(forMessage: message) { return kind }
        }
        return .unknown
    }

    static func kind(forCode code: String) -> AuthErrorKind? {
        switch code {
        case "invalid_credentials": .invalidCredentials
        case "email_not_confirmed": .emailNotConfirmed
        case "user_already_exists", "email_exists": .userAlreadyExists
        case "weak_password": .weakPassword
        case "same_password": .samePassword
        case "otp_expired", "flow_state_expired", "flow_state_not_found", "bad_code_verifier": .invalidOrExpiredCode
        case "over_request_rate_limit", "over_email_send_rate_limit", "over_sms_send_rate_limit": .rateLimited
        case "email_address_invalid", "validation_failed": .invalidEmail
        case "signup_disabled": .signupDisabled
        case "email_provider_disabled", "provider_disabled", "anonymous_provider_disabled",
             "phone_provider_disabled", "otp_disabled", "oauth_provider_not_supported":
            .providerDisabled
        case "session_not_found", "session_expired", "refresh_token_not_found",
             "refresh_token_already_used", "bad_jwt", "invalid_jwt":
            .sessionExpired
        default: nil
        }
    }

    static func kind(forMessage message: String) -> AuthErrorKind? {
        let m = message.lowercased()
        if m.contains("invalid login credentials") { return .invalidCredentials }
        if m.contains("email not confirmed") { return .emailNotConfirmed }
        if m.contains("already registered") { return .userAlreadyExists }
        if m.contains("token has expired or is invalid") { return .invalidOrExpiredCode }
        if m.contains("rate limit") { return .rateLimited }
        if m.contains("signups not allowed") { return .signupDisabled }
        return nil
    }

    public static func resource(for error: any Error) -> LocalizedStringResource {
        if let validation = error as? CredentialValidationError { return validation.localizedResource }
        return kind(for: error).localizedResource
    }

    /// Localized text for `error`, ready for an alert or inline message.
    public static func from(_ error: any Error) -> String {
        String(localized: resource(for: error))
    }
}
