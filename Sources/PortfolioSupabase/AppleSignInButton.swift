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
            return try credential(fromAppleID: authorization.credential as? ASAuthorizationAppleIDCredential)
        }
    }

    /// A configured Apple ID request (fresh nonce, scopes), for apps that
    /// present it themselves. Pair it with ``credential(fromAppleID:)``.
    public func makeRequest() -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request)
        return request
    }

    /// Runs the whole flow with SwiftUI's `AuthorizationController` (from
    /// `@Environment(\.authorizationController)`), so any control can start
    /// it: a `Button` with a `Label` in a `Form`, a menu item, a toolbar
    /// button. Returns `nil` when the user cancelled.
    ///
    /// ```swift
    /// @Environment(\.authorizationController) private var authorizationController
    ///
    /// Button { Task {
    ///     guard let credential = try await apple.signIn(using: authorizationController) else { return }
    ///     try await client.auth.signInWithApple(credential)
    /// } } label: { Label("Sign in with Apple", systemImage: "apple.logo") }
    /// ```
    public func signIn(using controller: AuthorizationController) async throws -> AppleSignInCredential? {
        let request = makeRequest()
        // Held locally: another request started meanwhile replaces `pendingNonce`.
        let nonce = pendingNonce
        defer { if pendingNonce == nonce { pendingNonce = nil } }
        let result: ASAuthorizationResult
        do {
            result = try await controller.performRequest(request)
        } catch {
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return nil
            }
            throw AppleSignInError.failed(error.localizedDescription)
        }
        guard case .appleID(let apple) = result else {
            throw AppleSignInError.incompleteCredential
        }
        return try Self.credential(from: apple, nonce: nonce)
    }

    /// Turns an Apple ID credential obtained with a request from this flow
    /// into an ``AppleSignInCredential``. Does not consume the nonce.
    public func credential(fromAppleID apple: ASAuthorizationAppleIDCredential?) throws -> AppleSignInCredential {
        try Self.credential(from: apple, nonce: pendingNonce)
    }

    private static func credential(
        from apple: ASAuthorizationAppleIDCredential?,
        nonce: String?
    ) throws -> AppleSignInCredential {
        guard let apple,
              let tokenData = apple.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce else {
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

/// Sign in with Apple as an ordinary SwiftUI `Button` with any label, for a
/// native `Form`/`List` row (where the black/white ``AppleSignInButton`` looks
/// out of place) or any custom design. It drives the same nonce flow through
/// `AuthorizationController`, ignores cancellation, and disables itself while
/// a sign-in is running.
///
/// ```swift
/// Form {
///     Section {
///         AppleSignInFormButton(flow: apple) { credential in
///             try? await Backend.client.auth.signInWithApple(credential)
///         } onError: { message = $0.localizedDescription }
///     }
/// }
/// ```
///
/// The default label is `Label("Sign in with Apple", systemImage: "apple.logo")`,
/// localized by the package. Pass a `label` builder for anything else; keep
/// Apple's wording and logo (App Review guideline 4.8 / HIG).
public struct AppleSignInFormButton<Content: View>: View {
    private let flow: AppleSignInFlow
    private let onCredential: @MainActor (AppleSignInCredential) async -> Void
    private let onError: @MainActor (any Error) -> Void
    private let content: Content

    @Environment(\.authorizationController) private var authorizationController
    @State private var isRunning = false

    public init(
        flow: AppleSignInFlow,
        onCredential: @escaping @MainActor (AppleSignInCredential) async -> Void,
        onError: @escaping @MainActor (any Error) -> Void,
        @ViewBuilder label: () -> Content
    ) {
        self.flow = flow
        self.onCredential = onCredential
        self.onError = onError
        self.content = label()
    }

    public var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                defer { isRunning = false }
                do {
                    guard let credential = try await flow.signIn(using: authorizationController) else { return }
                    await onCredential(credential)
                } catch {
                    onError(error)
                }
            }
        } label: {
            content
        }
        .disabled(isRunning)
    }
}

extension AppleSignInFormButton where Content == Label<Text, Image> {
    /// The standard row: the Apple logo and a localized title.
    /// - Parameter title: ``AppleSignInFormTitle/signIn`` (default) or
    ///   ``AppleSignInFormTitle/continueWithApple`` or ``AppleSignInFormTitle/signUp``.
    public init(
        _ title: LocalizedStringResource = AppleSignInFormTitle.signIn,
        flow: AppleSignInFlow,
        onCredential: @escaping @MainActor (AppleSignInCredential) async -> Void,
        onError: @escaping @MainActor (any Error) -> Void
    ) {
        self.init(flow: flow, onCredential: onCredential, onError: onError) {
            Label { Text(title) } icon: { Image(systemName: "apple.logo") }
        }
    }
}

/// Localized titles for ``AppleSignInFormButton`` (Apple's approved wording).
public enum AppleSignInFormTitle {
    /// "Sign in with Apple"
    public static var signIn: LocalizedStringResource { .portfolioSupabase("Sign in with Apple") }
    /// "Continue with Apple"
    public static var continueWithApple: LocalizedStringResource { .portfolioSupabase("Continue with Apple") }
    /// "Sign up with Apple"
    public static var signUp: LocalizedStringResource { .portfolioSupabase("Sign up with Apple") }
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
