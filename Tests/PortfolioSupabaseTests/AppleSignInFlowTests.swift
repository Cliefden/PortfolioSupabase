#if canImport(AuthenticationServices) && canImport(SwiftUI)
import AuthenticationServices
import SwiftUI
import Testing
@testable import PortfolioSupabase

@MainActor
@Suite struct AppleSignInFlowTests {
    @Test func makeRequestCarriesTheHashedNonceAndScopes() throws {
        let flow = AppleSignInFlow(scopes: [.email])
        let request = flow.makeRequest()
        let nonce = try #require(flow.pendingNonce)
        #expect(request.nonce == AppleSignInNonce.sha256(nonce))
        #expect(request.requestedScopes == [.email])
    }

    @Test func eachRequestGetsAFreshNonce() throws {
        let flow = AppleSignInFlow()
        _ = flow.makeRequest()
        let first = try #require(flow.pendingNonce)
        _ = flow.makeRequest()
        #expect(flow.pendingNonce != first)
    }

    @Test func missingAppleIDCredentialIsIncomplete() {
        let flow = AppleSignInFlow()
        _ = flow.makeRequest()
        #expect(throws: AppleSignInError.incompleteCredential) {
            _ = try flow.credential(fromAppleID: nil)
        }
    }

    @Test func formButtonBuildsWithDefaultAndCustomLabels() {
        let flow = AppleSignInFlow()
        _ = AppleSignInFormButton(flow: flow) { _ in } onError: { _ in }
        _ = AppleSignInFormButton(AppleSignInFormTitle.continueWithApple, flow: flow) { _ in } onError: { _ in }
        _ = AppleSignInFormButton(flow: flow) { _ in } onError: { _ in } label: {
            Text("Custom")
        }
    }
}
#endif
