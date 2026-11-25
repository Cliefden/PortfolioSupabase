# Changelog

## 0.1.1

Additive only: every 0.1.0 call compiles unchanged. Gaps found while adopting
the package in Sextant.

### Added

- `PortfolioSupabase.makeClient(…)` takes `db: SupabaseClientOptions.DatabaseOptions`
  (schema, row encoder/decoder), `session: URLSession` and
  `logger: (any SupabaseLogger)?`, all defaulted to the SDK's values.
- `PortfolioSupabase.clientOptions(storage:redirectToURL:storageKey:flowType:headers:db:session:logger:)`
  returns the `SupabaseClientOptions` `makeClient` builds.
- Token-only session migration for hand-rolled GoTrue clients (Otta, Svamp,
  Sextant): `LegacyTokenSessionStore` (Keychain account/service/access group,
  pluggable decoder, `KeychainBackend` for tests), `LegacyTokenSession`, and the
  single-flight `actor LegacyTokenSessionMigrator`, which redeems the old refresh
  token once via `client.auth.refreshSession(refreshToken:)`. The legacy item is
  deleted on success, server rejection, an undecodable item or an existing SDK
  session, and kept on network/server failure or a locked Keychain.
- `AppleSignInFormButton`: Sign in with Apple as a plain `Button` with a
  `Label` (or any label), for native `Form` rows. Runs through SwiftUI's
  `AuthorizationController`. Titles in `AppleSignInFormTitle`
  (`signIn`, `continueWithApple`, `signUp`).
- `AppleSignInFlow.makeRequest()`, `.signIn(using: AuthorizationController)` and
  `.credential(fromAppleID:)` to drive the nonce flow from any control.
- German, French and Spanish translations of every package string (machine
  translations, `needs_review`).

### Fixed

- `AuthFailure.isAuthRejection` now recognizes older self-hosted GoTrue's
  refresh-token rejection without an `error_code`: any 400–403 on
  `/token?grant_type=refresh_token`, and a bare `400 {"error":"invalid_grant"}`
  that isn't the password grant's credentials error. 429, 5xx and transport
  errors are still not rejections.

## 0.1.0

Initial release.
