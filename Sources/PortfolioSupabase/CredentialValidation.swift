import Foundation

/// Password rules. The default (8–72 characters, no composition rule) is
/// what Stokked, Jeroboam and Nassau enforced; 72 is GoTrue's bcrypt limit.
/// Keep it in step with the server's `GOTRUE_PASSWORD_MIN_LENGTH` /
/// `PASSWORD_REQUIRED_CHARACTERS`.
public struct PasswordPolicy: Sendable, Equatable {
    public var minimumLength: Int
    public var maximumLength: Int
    /// Require at least one letter and one digit.
    public var requiresLetterAndDigit: Bool

    public init(minimumLength: Int = 8, maximumLength: Int = 72, requiresLetterAndDigit: Bool = false) {
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.requiresLetterAndDigit = requiresLetterAndDigit
    }

    public static let standard = PasswordPolicy()
}

/// One unmet password rule, for live hints under a form (Nassau
/// `PasswordRuleHints`).
public enum PasswordRule: Sendable, Equatable, Hashable {
    case minimumLength(Int)
    case maximumLength(Int)
    case letterAndDigit
    case matchesConfirmation

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .minimumLength(let n): .portfolioSupabase("Password must be at least \(n) characters")
        case .maximumLength(let n): .portfolioSupabase("Password can be at most \(n) characters")
        case .letterAndDigit: .portfolioSupabase("Password must contain a letter and a number")
        case .matchesConfirmation: .portfolioSupabase("Passwords do not match")
        }
    }

    public var message: String { String(localized: localizedResource) }
}

public enum CredentialValidationError: Error, LocalizedError, Equatable, Sendable {
    case emptyEmail
    case invalidEmail
    case passwordTooShort(minimum: Int)
    case passwordTooLong(maximum: Int)
    case passwordNeedsLetterAndDigit
    case passwordMismatch
    case emptyDisplayName
    case displayNameTooLong(maximum: Int)

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .emptyEmail: .portfolioSupabase("Enter your email address")
        case .invalidEmail: .portfolioSupabase("Please enter a valid email address")
        case .passwordTooShort(let n): PasswordRule.minimumLength(n).localizedResource
        case .passwordTooLong(let n): PasswordRule.maximumLength(n).localizedResource
        case .passwordNeedsLetterAndDigit: PasswordRule.letterAndDigit.localizedResource
        case .passwordMismatch: PasswordRule.matchesConfirmation.localizedResource
        case .emptyDisplayName: .portfolioSupabase("Enter your name")
        case .displayNameTooLong(let n): .portfolioSupabase("Name can be at most \(n) characters")
        }
    }

    public var errorDescription: String? { String(localized: localizedResource) }
}

/// Email, password and display-name validation, unifying Stokked and
/// Jeroboam `Validation` (auth part) and Nassau `PasswordPolicy`. App-specific
/// field rules (item names, invite codes) stay in the apps.
public enum CredentialValidation {
    /// Same pattern Stokked and Jeroboam used. Deliberately simple: the server
    /// is the real check (GoTrue answers `email_address_invalid`).
    public static let emailPattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#

    public static let defaultDisplayNameMaxLength = 100

    /// Trimmed and lowercased, the form to send to the server.
    public static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isValidEmail(_ email: String) -> Bool {
        if case .success = self.email(email) { return true }
        return false
    }

    /// Validates and normalizes an email.
    public static func email(_ email: String) -> Result<String, CredentialValidationError> {
        let normalized = normalizedEmail(email)
        guard !normalized.isEmpty else { return .failure(.emptyEmail) }
        guard normalized.range(of: emailPattern, options: .regularExpression) != nil,
              !normalized.contains("..") else {
            return .failure(.invalidEmail)
        }
        return .success(normalized)
    }

    /// Validates a password against `policy` (not trimmed: spaces count).
    public static func password(_ password: String, policy: PasswordPolicy = .standard) -> Result<String, CredentialValidationError> {
        if password.count < policy.minimumLength { return .failure(.passwordTooShort(minimum: policy.minimumLength)) }
        if password.count > policy.maximumLength { return .failure(.passwordTooLong(maximum: policy.maximumLength)) }
        if policy.requiresLetterAndDigit, !hasLetterAndDigit(password) { return .failure(.passwordNeedsLetterAndDigit) }
        return .success(password)
    }

    public static func confirmPassword(_ password: String, confirmation: String) -> Result<String, CredentialValidationError> {
        password == confirmation ? .success(password) : .failure(.passwordMismatch)
    }

    /// Policy and confirmation together, as a sign-up or reset form needs.
    public static func newPassword(
        _ password: String,
        confirmation: String,
        policy: PasswordPolicy = .standard
    ) -> Result<String, CredentialValidationError> {
        self.password(password, policy: policy).flatMap { confirmPassword($0, confirmation: confirmation) }
    }

    /// `true` when the password meets the policy and matches (Nassau
    /// `PasswordPolicy.isValid`).
    public static func isValidNewPassword(_ password: String, confirmation: String, policy: PasswordPolicy = .standard) -> Bool {
        if case .success = newPassword(password, confirmation: confirmation, policy: policy) { return true }
        return false
    }

    /// Every rule `password` doesn't meet yet, for live form hints. The
    /// confirmation rule only appears once something has been typed there.
    public static func unmetRules(
        password: String,
        confirmation: String,
        policy: PasswordPolicy = .standard
    ) -> [PasswordRule] {
        var rules: [PasswordRule] = []
        if password.count < policy.minimumLength { rules.append(.minimumLength(policy.minimumLength)) }
        if password.count > policy.maximumLength { rules.append(.maximumLength(policy.maximumLength)) }
        if policy.requiresLetterAndDigit, !hasLetterAndDigit(password) { rules.append(.letterAndDigit) }
        if !confirmation.isEmpty, password != confirmation { rules.append(.matchesConfirmation) }
        return rules
    }

    /// Validates and trims a display name.
    public static func displayName(
        _ name: String,
        maximumLength: Int = defaultDisplayNameMaxLength
    ) -> Result<String, CredentialValidationError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyDisplayName) }
        guard trimmed.count <= maximumLength else { return .failure(.displayNameTooLong(maximum: maximumLength)) }
        return .success(trimmed)
    }

    static func hasLetterAndDigit(_ s: String) -> Bool {
        s.contains(where: \.isLetter) && s.contains(where: \.isNumber)
    }
}
