import Foundation

/// The Supabase URL and anon key an app talks to, plus the checks every app
/// ran before building a client (Stokked/Jeroboam `AppEnvironment`).
///
/// Values usually come from Info.plist keys filled by an xcconfig, with a
/// committed `Secrets.swift` value as fallback:
///
/// ```swift
/// let env = SupabaseEnvironment.fromInfoPlist(
///     fallbackURL: Secrets.supabaseURL,
///     fallbackAnonKey: Secrets.supabaseAnonKey,
///     allowedHostSuffixes: [".crawik.com", ".supabase.co"]
/// )
/// ```
public struct SupabaseEnvironment: Sendable, Equatable {
    /// Info.plist key for the project URL.
    public static let defaultURLKey = "SUPABASE_URL"
    /// Info.plist key for the anon (publishable) key.
    public static let defaultAnonKeyKey = "SUPABASE_ANON_KEY"

    /// Substrings that mark a value as a template placeholder, including an
    /// unexpanded xcconfig variable (`$(SUPABASE_URL)`).
    static let placeholderMarkers = ["YOUR_SUPABASE", "<your-project-ref>", "<your-anon-key>", "$("]
    /// Prefixes that mark a placeholder (ThenCam's `REPLACE_ME`).
    static let placeholderPrefixes = ["REPLACE"]

    public var urlString: String
    public var anonKey: String
    /// Host suffixes the URL must match, e.g. `[".crawik.com", ".supabase.co"]`.
    /// A suffix with a leading dot also accepts the bare domain. `nil` accepts
    /// any https host (Jeroboam's rule for self-hosted stacks).
    public var allowedHostSuffixes: [String]?

    public init(url: String, anonKey: String, allowedHostSuffixes: [String]? = nil) {
        self.urlString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowedHostSuffixes = allowedHostSuffixes
    }

    /// Reads the URL and key from `bundle`'s Info.plist, falling back to the
    /// given values when a key is missing, empty or still a placeholder.
    public static func fromInfoPlist(
        bundle: Bundle = .main,
        urlKey: String = defaultURLKey,
        anonKeyKey: String = defaultAnonKeyKey,
        fallbackURL: String,
        fallbackAnonKey: String,
        allowedHostSuffixes: [String]? = nil
    ) -> SupabaseEnvironment {
        fromInfoDictionary(
            bundle.infoDictionary,
            urlKey: urlKey,
            anonKeyKey: anonKeyKey,
            fallbackURL: fallbackURL,
            fallbackAnonKey: fallbackAnonKey,
            allowedHostSuffixes: allowedHostSuffixes
        )
    }

    /// Same as ``fromInfoPlist(bundle:urlKey:anonKeyKey:fallbackURL:fallbackAnonKey:allowedHostSuffixes:)``
    /// for an explicit dictionary (tests, extensions with their own plist).
    public static func fromInfoDictionary(
        _ info: [String: Any]?,
        urlKey: String = defaultURLKey,
        anonKeyKey: String = defaultAnonKeyKey,
        fallbackURL: String,
        fallbackAnonKey: String,
        allowedHostSuffixes: [String]? = nil
    ) -> SupabaseEnvironment {
        func usable(_ key: String) -> String? {
            guard let raw = info?[key] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !isPlaceholder(value) else { return nil }
            return value
        }
        return SupabaseEnvironment(
            url: usable(urlKey) ?? fallbackURL,
            anonKey: usable(anonKeyKey) ?? fallbackAnonKey,
            allowedHostSuffixes: allowedHostSuffixes
        )
    }

    static func isPlaceholder(_ value: String) -> Bool {
        placeholderMarkers.contains { value.contains($0) }
            || placeholderPrefixes.contains { value.hasPrefix($0) }
    }

    /// The parsed URL, or `nil` when it isn't a valid https URL with a host.
    public var url: URL? {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    /// `true` when the URL and key are real values and the host is allowed.
    public var isConfigured: Bool { configurationError == nil }

    /// Why the environment can't be used, or `nil` when it can.
    public var configurationError: SupabaseConfigurationError? {
        if urlString.isEmpty || Self.isPlaceholder(urlString) { return .missingURL }
        if anonKey.isEmpty || Self.isPlaceholder(anonKey) { return .missingAnonKey }
        guard let url else { return .invalidURL }
        if let suffixes = allowedHostSuffixes, !Self.host(url.host ?? "", matchesAnyOf: suffixes) {
            return .hostNotAllowed
        }
        return nil
    }

    /// Exact host or subdomain match, never a substring match (so
    /// `https://evil.com/?x=supabase.co` and `evilsupabase.co` are rejected).
    static func host(_ host: String, matchesAnyOf suffixes: [String]) -> Bool {
        let host = host.lowercased()
        return suffixes.contains { rawSuffix in
            let suffix = rawSuffix.lowercased()
            if suffix.hasPrefix(".") {
                return host == String(suffix.dropFirst()) || host.hasSuffix(suffix)
            }
            return host == suffix || host.hasSuffix("." + suffix)
        }
    }
}

/// Why a ``SupabaseEnvironment`` isn't usable. The descriptions are user-facing
/// ("contact the developer"); log the case itself for diagnostics.
public enum SupabaseConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case missingURL
    case missingAnonKey
    case invalidURL
    case hostNotAllowed

    public var localizedResource: LocalizedStringResource {
        switch self {
        case .missingURL:
            .portfolioSupabase("The server address is not configured. Please contact the developer.")
        case .missingAnonKey:
            .portfolioSupabase("The server key is not configured. Please contact the developer.")
        case .invalidURL, .hostNotAllowed:
            .portfolioSupabase("The server address is invalid. Please contact the developer.")
        }
    }

    public var errorDescription: String? { String(localized: localizedResource) }
}
