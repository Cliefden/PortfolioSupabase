import Foundation
import Supabase
import Testing
@testable import PortfolioSupabase

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ s: String) { lock.withLock { steps.append(s) } }
    var all: [String] { lock.withLock { steps } }
}

private func steps(
    _ log: StepLog,
    refreshFails: (any Error)? = nil,
    deleteFails: (any Error)? = nil,
    signOutFails: Bool = false
) -> AccountDeletionSteps {
    AccountDeletionSteps(
        refreshSession: {
            log.add("refresh")
            if let refreshFails { throw refreshFails }
        },
        delete: {
            log.add("delete")
            if let deleteFails { throw deleteFails }
        },
        signOut: {
            log.add("signOut")
            if signOutFails { throw URLError(.notConnectedToInternet) }
        },
        signOutLocally: { log.add("signOutLocal") }
    )
}

@Suite struct AccountDeletionTests {
    @Test func happyPathOrder() async throws {
        let log = StepLog()
        try await AccountDeletion.run(steps: steps(log), cleanup: { log.add("cleanup") })
        #expect(log.all == ["refresh", "cleanup", "delete", "signOut"])
    }

    @Test func refreshFailureStopsBeforeAnythingDestructive() async {
        let log = StepLog()
        await #expect(throws: AccountDeletionError.self) {
            try await AccountDeletion.run(steps: steps(log, refreshFails: URLError(.notConnectedToInternet)), cleanup: { log.add("cleanup") })
        }
        #expect(log.all == ["refresh"])
    }

    @Test func deletionFailureDoesNotSignOut() async {
        let log = StepLog()
        do {
            try await AccountDeletion.run(steps: steps(log, deleteFails: try postgrestError(code: "23503", message: "fk")), cleanup: nil)
            Issue.record("expected a throw")
        } catch let error as AccountDeletionError {
            guard case .deletionFailed = error else { Issue.record("wrong case"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(log.all == ["refresh", "delete"])
    }

    @Test func failedNetworkSignOutFallsBackToLocal() async throws {
        let log = StepLog()
        try await AccountDeletion.run(steps: steps(log, signOutFails: true), cleanup: nil)
        #expect(log.all == ["refresh", "delete", "signOut", "signOutLocal"])
    }

    @Test func strategiesCompare() {
        #expect(AccountDeletionStrategy.rpc("delete_user_account") == .rpc("delete_user_account", params: [:]))
        #expect(AccountDeletionStrategy.edgeFunction("delete-account", body: ["confirm": true])
            != .edgeFunction("delete-account"))
    }

    @Test func errorMessages() {
        let offline = AccountDeletionError.sessionUnavailable(underlying: URLError(.notConnectedToInternet))
        let dead = AccountDeletionError.sessionUnavailable(underlying: AuthError.sessionMissing)
        #expect(offline.errorDescription != dead.errorDescription)
        #expect(AccountDeletionError.deletionFailed(underlying: URLError(.timedOut)).errorDescription?.isEmpty == false)
    }
}

// MARK: - Localization (Bundle.module string catalog)

private func resolve(_ resource: LocalizedStringResource, _ locale: String) -> String {
    var r = resource
    r.locale = Locale(identifier: locale)
    return String(localized: r)
}

@Suite struct LocalizationTests {
    @Test func englishSource() {
        #expect(resolve(AuthErrorKind.invalidCredentials.localizedResource, "en") == "Incorrect email or password.")
        #expect(resolve(PasswordRule.minimumLength(8).localizedResource, "en") == "Password must be at least 8 characters")
    }

    @Test func swedish() {
        #expect(resolve(AuthErrorKind.invalidCredentials.localizedResource, "sv") == "Fel e-postadress eller lösenord.")
        #expect(resolve(PasswordRule.matchesConfirmation.localizedResource, "sv") == "Lösenorden matchar inte")
        #expect(resolve(CredentialValidationError.invalidEmail.localizedResource, "sv") == "Ange en giltig e-postadress")
    }

    @Test func swedishInterpolation() {
        #expect(resolve(PasswordRule.minimumLength(10).localizedResource, "sv") == "Lösenordet måste vara minst 10 tecken")
        #expect(resolve(CredentialValidationError.displayNameTooLong(maximum: 50).localizedResource, "sv") == "Namnet får vara högst 50 tecken")
        #expect(resolve(AppleSignInError.failed("boom").localizedResource, "sv") == "Det gick inte att logga in med Apple: boom")
    }

    @Test func everyKindIsTranslatedToSwedish() {
        for kind in AuthErrorKind.allCases {
            #expect(resolve(kind.localizedResource, "sv") != resolve(kind.localizedResource, "en"), "\(kind)")
        }
        for error in [SupabaseConfigurationError.missingURL, .missingAnonKey, .invalidURL] {
            #expect(resolve(error.localizedResource, "sv") != resolve(error.localizedResource, "en"))
        }
    }
}
