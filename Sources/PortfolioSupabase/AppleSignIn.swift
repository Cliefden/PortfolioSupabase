import CryptoKit
import Foundation
import Security
import Supabase

/// Nonce helpers for Sign in with Apple → `signInWithIdToken` (Stokked).
/// Put ``sha256(_:)`` of the raw nonce on the Apple request, and send the raw
/// nonce to Supabase.
public enum AppleSignInNonce {
    /// 64 characters, so `byte % 64` has no modulo bias.
    static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    /// A cryptographically random URL-safe string.
    public static func random(length: Int = 32) -> String {
        precondition(length > 0, "Nonce length must be positive")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // Practically unreachable; fall back to the system CSPRNG rather
            // than crash the sign-in flow.
            var generator = SystemRandomNumberGenerator()
            return String((0..<length).map { _ in charset[Int(generator.next() % UInt64(charset.count))] })
        }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    /// Lowercase hex SHA-256, the form Apple expects in `request.nonce`.
    public static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// What a completed Sign in with Apple hands back, ready for Supabase.
public struct AppleSignInCredential: Sendable, Equatable {
    /// Apple's identity token (JWT) as a string.
    public var idToken: String
    /// The raw nonce whose hash was on the request.
    public var nonce: String
    /// Only present on the user's very first authorization.
    public var fullName: PersonNameComponents?
    public var email: String?
    /// One-time code (expires in minutes). Forward it to a server that trades
    /// it for a refresh token if you revoke on account deletion (Stokked's
    /// `apple-auth` edge function).
    public var authorizationCode: String?
    /// Apple's stable user identifier.
    public var userIdentifier: String

    public init(
        idToken: String,
        nonce: String,
        fullName: PersonNameComponents? = nil,
        email: String? = nil,
        authorizationCode: String? = nil,
        userIdentifier: String
    ) {
        self.idToken = idToken
        self.nonce = nonce
        self.fullName = fullName
        self.email = email
        self.authorizationCode = authorizationCode
        self.userIdentifier = userIdentifier
    }

    /// The name Apple returned, formatted and validated as a display name,
    /// or `nil`. Store it (user metadata / profile row) on first sign-in,
    /// because Apple never sends it again.
    public var displayName: String? {
        AppleSignIn.displayName(from: fullName)
    }
}

public enum AppleSignIn {
    /// Formats a name from Apple into a valid display name, or `nil`.
    public static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        guard case .success(let name) = CredentialValidation.displayName(formatted) else { return nil }
        return name
    }

    /// Whether `user` has an Apple identity linked (Stokked
    /// `AppleTokenService.currentUserUsesApple`). Use it to decide whether to
    /// revoke Apple tokens on account deletion.
    public static func userUsesApple(_ user: User) -> Bool {
        if user.identities?.contains(where: { $0.provider == "apple" }) == true {
            return true
        }
        if case .array(let providers)? = user.appMetadata["providers"] {
            return providers.contains(.string("apple"))
        }
        return user.appMetadata["provider"] == .string("apple")
    }
}

extension AuthClient {
    /// Exchanges an Apple identity token for a Supabase session (GoTrue's
    /// Apple provider). `nonce` is the raw nonce. The server's Apple client ID
    /// must be the app's bundle ID.
    @discardableResult
    public func signInWithApple(idToken: String, nonce: String) async throws -> Session {
        try await signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    /// Same, from an ``AppleSignInCredential``.
    @discardableResult
    public func signInWithApple(_ credential: AppleSignInCredential) async throws -> Session {
        try await signInWithApple(idToken: credential.idToken, nonce: credential.nonce)
    }
}

public enum AppleSignInError: Error, LocalizedError, Equatable, Sendable {
    /// Apple returned no identity token, or no request nonce was pending.
    case incompleteCredential
    /// Apple's sheet failed for another reason (message included).
    case failed(String)

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .incompleteCredential:
            .portfolioSupabase("Could not sign in with Apple. Please try again.")
        case .failed(let message):
            .portfolioSupabase("Could not sign in with Apple: \(message)")
        }
    }

    public var errorDescription: String? { String(localized: localizedResource) }
}
