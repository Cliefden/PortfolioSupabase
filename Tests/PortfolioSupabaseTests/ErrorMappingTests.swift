import Foundation
import Supabase
import Testing
@testable import PortfolioSupabase

func apiError(
    _ code: String,
    status: Int = 400,
    message: String = "x",
    url: String = "https://a.crawik.com/auth/v1/token"
) -> AuthError {
    .api(
        message: message,
        errorCode: ErrorCode(code),
        underlyingData: Data(),
        underlyingResponse: HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
}

func postgrestError(code: String?, message: String) throws -> PostgrestError {
    var object: [String: String] = ["message": message]
    if let code { object["code"] = code }
    return try JSONDecoder().decode(PostgrestError.self, from: JSONEncoder().encode(object))
}

@Suite struct AuthFailureTests {
    @Test func authRejections() throws {
        #expect(AuthFailure.isAuthRejection(AuthError.sessionMissing))
        #expect(AuthFailure.isAuthRejection(apiError("refresh_token_not_found")))
        #expect(AuthFailure.isAuthRejection(apiError("refresh_token_already_used")))
        #expect(AuthFailure.isAuthRejection(apiError("bad_jwt", status: 403)))
        #expect(AuthFailure.isAuthRejection(apiError("unknown", status: 401)))
        #expect(AuthFailure.isAuthRejection(apiError("unknown", message: "Invalid Refresh Token: Already Used")))
        #expect(AuthFailure.isAuthRejection(apiError("invalid_grant")))
        #expect(AuthFailure.isAuthRejection(try postgrestError(code: "PGRST301", message: "JWT expired")))
        #expect(AuthFailure.isAuthRejection(try postgrestError(code: "PGRST303", message: "JWT claims validation failed")))
        #expect(AuthFailure.isAuthRejection(try postgrestError(code: nil, message: "JWT expired")))
        #expect(AuthFailure.isAuthRejection(FunctionsError.httpError(code: 401, data: Data())))
        #expect(AuthFailure.isAuthRejection(StorageError(statusCode: "401", message: "Unauthorized")))
        #expect(AuthFailure.isAuthRejection(StorageError(statusCode: "400", message: "\"exp\" claim timestamp check failed", error: "jwt expired")))
    }

    @Test func notAuthRejections() throws {
        #expect(!AuthFailure.isAuthRejection(URLError(.notConnectedToInternet)))
        #expect(!AuthFailure.isAuthRejection(URLError(.timedOut)))
        #expect(!AuthFailure.isAuthRejection(CancellationError()))
        #expect(!AuthFailure.isAuthRejection(apiError("invalid_credentials")))
        #expect(!AuthFailure.isAuthRejection(apiError("otp_expired", status: 403)))
        #expect(!AuthFailure.isAuthRejection(try postgrestError(code: "42501", message: "permission denied for table x")))
        #expect(!AuthFailure.isAuthRejection(try postgrestError(code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned")))
        #expect(!AuthFailure.isAuthRejection(FunctionsError.httpError(code: 402, data: Data())))
        #expect(!AuthFailure.isAuthRejection(StorageError(statusCode: "403", message: "new row violates row-level security policy")))
    }

    /// Older self-hosted GoTrue: `400 {"error":"invalid_grant",…}` without an
    /// `error_code`, so the SDK reports `ErrorCode.unknown` and the
    /// description as message.
    @Test func bareInvalidGrantFromOlderGoTrue() {
        func bare(_ description: String, status: Int = 400, url: String) -> AuthError {
            .api(
                message: description,
                errorCode: .unknown,
                underlyingData: Data(#"{"error":"invalid_grant","error_description":"\#(description)"}"#.utf8),
                underlyingResponse: HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
        let refreshURL = "https://a.crawik.com/auth/v1/token?grant_type=refresh_token"
        let unknownURL = "https://a.crawik.com/auth/v1/token"
        let passwordURL = "https://a.crawik.com/auth/v1/token?grant_type=password"

        #expect(AuthFailure.isAuthRejection(bare("Session Expired", url: refreshURL)))
        #expect(AuthFailure.isAuthRejection(bare("Refresh token revoked", url: unknownURL)))
        // The password grant's invalid_grant is about credentials, not a session.
        #expect(!AuthFailure.isAuthRejection(bare("Invalid login credentials", url: passwordURL)))
        #expect(!AuthFailure.isAuthRejection(bare("Invalid login credentials", url: unknownURL)))
        #expect(!AuthFailure.isAuthRejection(bare("Email not confirmed", url: unknownURL)))
        #expect(!AuthFailure.isAuthRejection(bare("Something odd", url: passwordURL)))
    }

    /// Any 400–403 on the refresh grant means the refresh token is dead;
    /// 429 and 5xx do not.
    @Test func refreshGrantStatuses() {
        func refresh(_ status: Int) -> AuthError {
            apiError("unknown", status: status, message: "x", url: "https://a.crawik.com/auth/v1/token?grant_type=refresh_token")
        }
        for status in [400, 401, 403] {
            #expect(AuthFailure.isAuthRejection(refresh(status)), "\(status)")
        }
        for status in [404, 408, 422, 429, 500, 502, 503] {
            #expect(!AuthFailure.isAuthRejection(refresh(status)), "\(status)")
        }
        // A 400 on another endpoint stays a plain error.
        #expect(!AuthFailure.isAuthRejection(apiError("unknown", status: 400, message: "x", url: "https://a.crawik.com/auth/v1/user")))
        #expect(!AuthFailure.isAuthRejection(apiError("validation_failed", status: 400, message: "x", url: "https://a.crawik.com/auth/v1/token?grant_type=password")))
    }

    @Test func transient() {
        #expect(AuthFailure.isTransient(URLError(.networkConnectionLost)))
        #expect(AuthFailure.isTransient(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        #expect(!AuthFailure.isTransient(URLError(.badServerResponse)))
        #expect(!AuthFailure.isTransient(apiError("unknown", status: 500)))
    }
}

@Suite struct AuthErrorMessageTests {
    @Test func mapsErrorCodes() {
        let cases: [(String, AuthErrorKind)] = [
            ("invalid_credentials", .invalidCredentials),
            ("email_not_confirmed", .emailNotConfirmed),
            ("user_already_exists", .userAlreadyExists),
            ("email_exists", .userAlreadyExists),
            ("weak_password", .weakPassword),
            ("same_password", .samePassword),
            ("otp_expired", .invalidOrExpiredCode),
            ("over_email_send_rate_limit", .rateLimited),
            ("over_request_rate_limit", .rateLimited),
            ("email_address_invalid", .invalidEmail),
            ("validation_failed", .invalidEmail),
            ("signup_disabled", .signupDisabled),
            ("email_provider_disabled", .providerDisabled),
            ("anonymous_provider_disabled", .providerDisabled),
            ("refresh_token_not_found", .sessionExpired),
            ("session_not_found", .sessionExpired),
        ]
        for (code, kind) in cases {
            #expect(AuthErrorMessage.kind(for: apiError(code)) == kind, "\(code)")
        }
    }

    @Test func nonApiAuthErrors() {
        #expect(AuthErrorMessage.kind(for: AuthError.weakPassword(message: "weak", reasons: ["length"])) == .weakPassword)
        #expect(AuthErrorMessage.kind(for: AuthError.sessionMissing) == .sessionExpired)
    }

    @Test func fallsBackToStatusAndMessageForOldGoTrue() {
        #expect(AuthErrorMessage.kind(for: apiError("unknown", status: 429)) == .rateLimited)
        #expect(AuthErrorMessage.kind(for: apiError("unknown", message: "Invalid login credentials")) == .invalidCredentials)
        #expect(AuthErrorMessage.kind(for: apiError("unknown", message: "Email not confirmed")) == .emailNotConfirmed)
        #expect(AuthErrorMessage.kind(for: apiError("unknown", message: "User already registered")) == .userAlreadyExists)
        #expect(AuthErrorMessage.kind(for: apiError("unknown", status: 403, message: "Token has expired or is invalid")) == .invalidOrExpiredCode)
        #expect(AuthErrorMessage.kind(for: apiError("unknown", status: 500, message: "boom")) == .unknown)
    }

    @Test func transportAndOtherErrors() {
        #expect(AuthErrorMessage.kind(for: URLError(.notConnectedToInternet)) == .network)
        #expect(AuthErrorMessage.kind(for: URLError(.cancelled)) == .unknown)
        #expect(AuthErrorMessage.kind(for: CocoaError(.fileNoSuchFile)) == .unknown)
        #expect(AuthErrorMessage.kind(for: CredentialValidationError.invalidEmail) == .invalidEmail)
    }

    @Test func validationErrorsKeepTheirOwnMessage() {
        let message = AuthErrorMessage.from(CredentialValidationError.passwordTooShort(minimum: 10))
        #expect(message.contains("10"))
    }

    @Test func everyKindHasAMessage() {
        for kind in AuthErrorKind.allCases {
            #expect(!kind.message.isEmpty)
        }
    }
}
