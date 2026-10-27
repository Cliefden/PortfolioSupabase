#if canImport(AuthenticationServices) && canImport(SwiftUI)
import AuthenticationServices
import SwiftUI

/// Holds the pending nonce between Apple's request and completion callbacks
/// (the bit every app kept as `appleNonce` on its view model).
///
/// ```swift
/// @State private var apple = AppleSignInFlow()
///
/// SignInWithAppleButton(.continue) { apple.configure($0) } onCompletion: { result in
///     guard let credential = try? apple.credential(from: result) else { return }
///     Task { try await client.auth.signInWithApple(credential) }
/// }
/// ```
/// or just use ``AppleSignInButton``.
@MainActor
@Observable
public final class AppleSignInFlow {
    public var scopes: [ASAuthorization.Scope]
    @ObservationIgnored private(set) var pendingNonce: String?

    public init(scopes: [ASAuthorization.Scope] = [.fullName, .email]) {
        self.scopes = scopes
    }

    /// Generates a fresh nonce and puts its SHA-256 and the scopes on `request`.
    public func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.random()
        pendingNonce = nonce
        request.requestedScopes = scopes
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

    /// Turns Apple's completion into a credential. Returns `nil` when the user
    /// cancelled (not an error worth an alert). Consumes the pending nonce.
    public func credential(from result: Result<ASAuthorization, any Error>) throws -> AppleSignInCredential? {
        defer { pendingNonce = nil }
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return nil
            }
            throw AppleSignInError.failed(error.localizedDescription)
        case .success(let authorization):
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = apple.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = pendingNonce else {
                throw AppleSignInError.incompleteCredential
            }
            return AppleSignInCredential(
                idToken: idToken,
                nonce: nonce,
                fullName: apple.fullName,
                email: apple.email,
                authorizationCode: apple.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                userIdentifier: apple.user
            )
        }
    }
}

/// The portfolio's Sign in with Apple button: native button, black on light /
/// white on dark, 50 pt tall, 12 pt corners (Stokked's styling). Hands a
/// credential to `onCredential`; failures (not cancellation) go to `onError`.
public struct AppleSignInButton: View {
    private let label: SignInWithAppleButton.Label
    private let flow: AppleSignInFlow
    private let height: CGFloat
    private let cornerRadius: CGFloat
    private let onCredential: @MainActor (AppleSignInCredential) async -> Void
    private let onError: @MainActor (any Error) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        _ label: SignInWithAppleButton.Label = .continue,
        flow: AppleSignInFlow,
        height: CGFloat = 50,
        cornerRadius: CGFloat = 12,
        onCredential: @escaping @MainActor (AppleSignInCredential) async -> Void,
        onError: @escaping @MainActor (any Error) -> Void
    ) {
        self.label = label
        self.flow = flow
        self.height = height
        self.cornerRadius = cornerRadius
        self.onCredential = onCredential
        self.onError = onError
    }

    public var body: some View {
        SignInWithAppleButton(label) { request in
            flow.configure(request)
        } onCompletion: { result in
            do {
                guard let credential = try flow.credential(from: result) else { return }
                Task { await onCredential(credential) }
            } catch {
                onError(error)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
#endif
