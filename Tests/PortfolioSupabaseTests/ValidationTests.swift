import Foundation
import Testing
@testable import PortfolioSupabase

@Suite struct CredentialValidationTests {
    @Test func emailNormalizesAndValidates() {
        #expect(CredentialValidation.email("  Anna@Example.COM \n") == .success("anna@example.com"))
        #expect(CredentialValidation.email("a.b+tag@sub.example.se") == .success("a.b+tag@sub.example.se"))
        #expect(CredentialValidation.email("   ") == .failure(.emptyEmail))
        for bad in ["anna", "anna@", "@example.com", "anna@example", "anna@example.c", "an na@example.com", "anna@exa..mple.com"] {
            #expect(CredentialValidation.email(bad) == .failure(.invalidEmail), "\(bad)")
        }
        #expect(CredentialValidation.isValidEmail("x@y.io"))
        #expect(!CredentialValidation.isValidEmail("x@y"))
    }

    @Test func passwordPolicyLengths() {
        #expect(CredentialValidation.password("1234567") == .failure(.passwordTooShort(minimum: 8)))
        #expect(CredentialValidation.password("12345678") == .success("12345678"))
        #expect(CredentialValidation.password(String(repeating: "a", count: 73)) == .failure(.passwordTooLong(maximum: 72)))
        // Not trimmed: spaces count.
        #expect(CredentialValidation.password("  abcdef") == .success("  abcdef"))
    }

    @Test func passwordCompositionRule() {
        let policy = PasswordPolicy(minimumLength: 6, requiresLetterAndDigit: true)
        #expect(CredentialValidation.password("abcdefgh", policy: policy) == .failure(.passwordNeedsLetterAndDigit))
        #expect(CredentialValidation.password("12345678", policy: policy) == .failure(.passwordNeedsLetterAndDigit))
        #expect(CredentialValidation.password("abc123", policy: policy) == .success("abc123"))
    }

    @Test func confirmationAndNewPassword() {
        #expect(CredentialValidation.confirmPassword("abcdefgh", confirmation: "abcdefgh") == .success("abcdefgh"))
        #expect(CredentialValidation.confirmPassword("abcdefgh", confirmation: "abcdefgx") == .failure(.passwordMismatch))
        // Policy is checked before the match.
        #expect(CredentialValidation.newPassword("short", confirmation: "other") == .failure(.passwordTooShort(minimum: 8)))
        #expect(CredentialValidation.isValidNewPassword("abcdefgh", confirmation: "abcdefgh"))
        #expect(!CredentialValidation.isValidNewPassword("abcdefgh", confirmation: "abcdefg"))
    }

    @Test func unmetRulesForLiveHints() {
        #expect(CredentialValidation.unmetRules(password: "", confirmation: "") == [.minimumLength(8)])
        #expect(CredentialValidation.unmetRules(password: "abc", confirmation: "abd") == [.minimumLength(8), .matchesConfirmation])
        #expect(CredentialValidation.unmetRules(password: "abcdefgh", confirmation: "") == [])
        #expect(CredentialValidation.unmetRules(password: "abcdefgh", confirmation: "abcdefgh") == [])
        let strict = PasswordPolicy(requiresLetterAndDigit: true)
        #expect(CredentialValidation.unmetRules(password: "abcdefgh", confirmation: "", policy: strict) == [.letterAndDigit])
    }

    @Test func displayName() {
        #expect(CredentialValidation.displayName("  Anna Svensson ") == .success("Anna Svensson"))
        #expect(CredentialValidation.displayName(" \n ") == .failure(.emptyDisplayName))
        #expect(CredentialValidation.displayName(String(repeating: "x", count: 101)) == .failure(.displayNameTooLong(maximum: 100)))
        #expect(CredentialValidation.displayName("abcd", maximumLength: 3) == .failure(.displayNameTooLong(maximum: 3)))
    }

    @Test func appleDisplayName() {
        var name = PersonNameComponents()
        #expect(AppleSignIn.displayName(from: nil) == nil)
        #expect(AppleSignIn.displayName(from: name) == nil)
        name.givenName = "Anna"
        name.familyName = "Svensson"
        let formatted = AppleSignIn.displayName(from: name)
        #expect(formatted?.contains("Anna") == true)
        #expect(formatted?.contains("Svensson") == true)
    }
}

@Suite struct AppleSignInNonceTests {
    @Test func randomHasRequestedLengthAndCharset() {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        for length in [1, 16, 32, 64] {
            let nonce = AppleSignInNonce.random(length: length)
            #expect(nonce.count == length)
            #expect(nonce.allSatisfy(allowed.contains))
        }
        #expect(AppleSignInNonce.random().count == 32)
    }

    @Test func randomIsNotRepeated() {
        let nonces = Set((0..<200).map { _ in AppleSignInNonce.random() })
        #expect(nonces.count == 200)
    }

    @Test func sha256IsLowercaseHex() {
        // Known vectors.
        #expect(AppleSignInNonce.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(AppleSignInNonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func charsetHasNoModuloBias() {
        #expect(AppleSignInNonce.charset.count == 64)
        #expect(256 % AppleSignInNonce.charset.count == 0)
    }
}
