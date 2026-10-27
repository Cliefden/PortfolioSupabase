import Foundation

extension LocalizedStringResource {
    /// A string owned by PortfolioSupabase, looked up in the package's own
    /// `Localizable.xcstrings` (`Bundle.module`) rather than the app's main
    /// bundle, so validation and error copy is translated without every app
    /// carrying the same keys. Same pattern as PortfolioKit.
    static func portfolioSupabase(
        _ keyAndValue: String.LocalizationValue,
        comment: StaticString? = nil
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            keyAndValue,
            bundle: .atURL(Bundle.module.bundleURL),
            comment: comment
        )
    }
}
