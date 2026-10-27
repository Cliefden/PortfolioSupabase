import Foundation
import Supabase
import Testing
@testable import PortfolioSupabase

func apiError(_ code: String, status: Int = 400, message: String = "x") -> AuthError {
    .api(
        message: message,
        errorCode: ErrorCode(code),
        underlyingData: Data(),
        underlyingResponse: HTTPURLResponse(url: URL(string: "https://a.crawik.com/auth/v1/token")!, statusCode: status, httpVersion: nil, headerFields: nil)!
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
