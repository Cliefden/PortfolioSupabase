import Foundation
import Testing
@testable import PortfolioSupabase

private let key = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.sig"

@Suite struct SupabaseEnvironmentTests {
    @Test func prefersInfoPlistValues() {
        let env = SupabaseEnvironment.fromInfoDictionary(
            ["SUPABASE_URL": "https://api.app.crawik.com", "SUPABASE_ANON_KEY": key],
            fallbackURL: "https://fallback.crawik.com",
            fallbackAnonKey: "fallback"
        )
        #expect(env.urlString == "https://api.app.crawik.com")
        #expect(env.anonKey == key)
        #expect(env.isConfigured)
    }

    @Test func fallsBackOnMissingEmptyOrPlaceholderValues() {
        for info: [String: Any]? in [
            nil,
            [:],
            ["SUPABASE_URL": "", "SUPABASE_ANON_KEY": "  "],
            ["SUPABASE_URL": "$(SUPABASE_URL)", "SUPABASE_ANON_KEY": "$(SUPABASE_ANON_KEY)"],
            ["SUPABASE_URL": "https://<your-project-ref>.supabase.co", "SUPABASE_ANON_KEY": "<your-anon-key>"],
        ] {
            let env = SupabaseEnvironment.fromInfoDictionary(info, fallbackURL: "https://x.crawik.com", fallbackAnonKey: key)
            #expect(env.urlString == "https://x.crawik.com")
            #expect(env.anonKey == key)
        }
    }

    @Test func customKeys() {
        let env = SupabaseEnvironment.fromInfoDictionary(
            ["API_URL": "https://a.example.com", "API_KEY": key],
            urlKey: "API_URL",
            anonKeyKey: "API_KEY",
            fallbackURL: "",
            fallbackAnonKey: ""
        )
        #expect(env.isConfigured)
    }

    @Test func configurationErrors() {
        #expect(SupabaseEnvironment(url: "", anonKey: key).configurationError == .missingURL)
        #expect(SupabaseEnvironment(url: "https://YOUR_SUPABASE_URL", anonKey: key).configurationError == .missingURL)
        #expect(SupabaseEnvironment(url: "https://a.crawik.com", anonKey: "").configurationError == .missingAnonKey)
        #expect(SupabaseEnvironment(url: "https://a.crawik.com", anonKey: "REPLACE_ME").configurationError == .missingAnonKey)
        #expect(SupabaseEnvironment(url: "http://a.crawik.com", anonKey: key).configurationError == .invalidURL)
        #expect(SupabaseEnvironment(url: "not a url", anonKey: key).configurationError == .invalidURL)
    }

    @Test func anyHttpsHostWhenNoAllowlist() {
        #expect(SupabaseEnvironment(url: "https://api.thencam.com", anonKey: key).isConfigured)
    }

    @Test func hostAllowlistMatchesExactOrSubdomainOnly() {
        let suffixes = [".supabase.co", ".crawik.com"]
        func ok(_ url: String) -> Bool {
            SupabaseEnvironment(url: url, anonKey: key, allowedHostSuffixes: suffixes).isConfigured
        }
        #expect(ok("https://abc.supabase.co"))
        #expect(ok("https://nassau.crawik.com"))
        #expect(ok("https://crawik.com"))
        #expect(ok("https://API.Jeroboam.Crawik.com"))
        #expect(!ok("https://evil.com/?proxy=supabase.co"))
        #expect(!ok("https://evilsupabase.co"))
        #expect(!ok("https://crawik.com.evil.com"))
        #expect(SupabaseEnvironment(url: "https://evil.com", anonKey: key, allowedHostSuffixes: suffixes).configurationError == .hostNotAllowed)
    }

    @Test func suffixWithoutLeadingDot() {
        #expect(SupabaseEnvironment.host("api.thencam.com", matchesAnyOf: ["thencam.com"]))
        #expect(SupabaseEnvironment.host("thencam.com", matchesAnyOf: ["thencam.com"]))
        #expect(!SupabaseEnvironment.host("notthencam.com", matchesAnyOf: ["thencam.com"]))
    }

    @Test func trimsWhitespace() {
        let env = SupabaseEnvironment(url: " https://a.crawik.com\n", anonKey: " \(key) ")
        #expect(env.url?.absoluteString == "https://a.crawik.com")
        #expect(env.anonKey == key)
    }

    @Test func unconfiguredEnvironmentYieldsDummyClient() {
        let client = PortfolioSupabase.makeClient(
            environment: SupabaseEnvironment(url: "", anonKey: ""),
            storage: InMemoryAuthStorage()
        )
        #expect(client.auth.currentSession == nil)
        let configured = PortfolioSupabase.makeClient(
            environment: SupabaseEnvironment(url: "https://a.crawik.com", anonKey: key),
            storage: InMemoryAuthStorage()
        )
        #expect(configured.auth.currentSession == nil)
    }
}
