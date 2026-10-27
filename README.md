# PortfolioSupabase

Shared helpers for the portfolio apps that use the official
[supabase-swift](https://github.com/supabase/supabase-swift) SDK. The portfolio
standardizes on the SDK (see `Celiador/_standard/SHARED_PACKAGES_SURVEY.md` §1.5).
This package holds the code each SDK app had copied. It does **not** wrap the SDK:
apps still call `client.auth`, `client.from(...)`, `client.storage` and so on.

- swift-tools 6.0 (Swift 6 language mode), iOS 17 / watchOS 10 / macOS 14 / visionOS 1
- Depends on `supabase-swift` `from: "2.40.0"` (product `Supabase`). Tested against **2.40.0 and 2.55.5**.
- Strings in `Resources/Localizable.xcstrings` (en + sv), resolved from `Bundle.module`, same pattern as PortfolioKit.

Depend on it by URL + version, like PortfolioKit (CI-safe in Xcode Cloud; use
`Add Local…` only for local development).

```swift
.package(url: "https://github.com/Cliefden/PortfolioSupabase.git", from: "0.1.0"),
// target:
.product(name: "PortfolioSupabase", package: "PortfolioSupabase"),
```

## API

| Area | Types |
|---|---|
| Configuration | `SupabaseEnvironment`, `SupabaseConfigurationError` |
| Auth storage | `KeychainAuthStorage`, `UserDefaultsAuthStorage`, `MigratingAuthStorage`, `InMemoryAuthStorage`, `KeychainBackend` / `SystemKeychain` |
| Client | `PortfolioSupabase.makeClient(environment:storage:…)`, `.authOptions(…)`, `.makeUnconfiguredClient()`, `.signOut(client:scope:)` |
| Session | `SessionObserver` (`@Observable @MainActor`), `UserChangeGuard`, `AuthFailure` |
| Sign in with Apple | `AppleSignInNonce`, `AuthClient.signInWithApple(idToken:nonce:)`, `AppleSignInCredential`, `AppleSignInFlow`, `AppleSignInButton`, `AppleSignIn.userUsesApple` |
| Validation & copy | `CredentialValidation`, `PasswordPolicy`, `PasswordRule`, `CredentialValidationError`, `AuthErrorMessage`, `AuthErrorKind` |
| Account deletion | `AccountDeletion.deleteAccount(client:strategy:cleanup:)`, `AccountDeletionStrategy`, `AccountDeletionError` |
| Storage | `StorageUploader`, `StoragePath`, `RetryPolicy` |
| Pagination | `fetchAllPages(pageSize:stopOnShortPage:maxPages:_:)`, `fetchAllRows(…)` |

### Environment + client

```swift
import PortfolioSupabase

enum Backend {
    static let environment = SupabaseEnvironment.fromInfoPlist(   // SUPABASE_URL / SUPABASE_ANON_KEY
        fallbackURL: Secrets.supabaseURL,
        fallbackAnonKey: Secrets.supabaseAnonKey,
        allowedHostSuffixes: [".crawik.com", ".supabase.co"]      // nil = any https host
    )

    static let storage: any AuthLocalStorage = {
        #if DEBUG
        UserDefaultsAuthStorage()                                  // no macOS keychain prompts
        #else
        MigratingAuthStorage(
            from: UserDefaultsAuthStorage(),                        // sessions from older builds
            to: KeychainAuthStorage(service: "com.example.app.auth")
        )
        #endif
    }()

    static let client = PortfolioSupabase.makeClient(environment: environment, storage: storage)
}

if let error = Backend.environment.configurationError { /* show error.localizedDescription */ }
```

`makeClient` sets `autoRefreshToken: true` and `emitLocalSessionAsInitialSession: true`.
When the environment is unconfigured it returns a non-functional client on
`https://invalid.supabase.co` with in-memory storage instead of crashing.

`SupabaseEnvironment` requires https, treats empty values, `YOUR_SUPABASE…`,
`<your-…>`, `REPLACE…` and unexpanded `$(VAR)` as missing, and matches the host
allowlist by exact host or subdomain only (never by substring).

### Auth storage

`KeychainAuthStorage(service:accessibility:accessGroup:usesDataProtectionKeychain:)`:

- **Update-then-add.** `store` updates the existing item and only adds when none
  exists. The old copies deleted first and then added, which leaves a moment with
  no session stored (a crash there signs the user out) and can't change the
  accessibility class in place. The item query never includes `kSecValueData`,
  because a query with the value matches nothing.
- The default accessibility is `.afterFirstUnlockThisDeviceOnly` (Stokked's).
  Existing items move to the configured class on the next write.
- It uses the same item layout as the SDK's own `KeychainLocalStorage`
  (generic password, `kSecAttrService` = service, `kSecAttrAccount` = key). So
  `KeychainAuthStorage(service: "x")` reads sessions an app stored with
  `KeychainLocalStorage(service: "x")`. The SDK default service is `supabase.gotrue.swift`.
- **Keep each app's current service string**, or existing users are signed out.

`MigratingAuthStorage(from:to:)` reads `primary` first. On a miss it copies a
legacy value into `primary` and deletes the legacy copy. If that copy fails, it
keeps the legacy value and still returns the session.

### SessionObserver

```swift
@State private var session = SessionObserver(client: Backend.client, userChangeGuard: UserChangeGuard())

// once, at launch
session.onUserChanged = { previousUserId, newUser in LocalStore.wipeAll() }   // runs before listeners are told
session.onEvent = { event, _ in if event == .signedOut { Caches.reset() } }
session.start()

// root view
.task { for await signedIn in session.authStateStream() { route(signedIn) } }
.onChange(of: scenePhase) { if $1 == .active { Task { await session.validateSession() } } }

// any call
let rows: [Item] = try await session.withSessionRefresh {
    try await Backend.client.from("items").select().execute().value
}
```

- `authStateStream()` follows Jeroboam's version. It registers synchronously and
  emits nothing until `.initialSession` resolves, so a signed-in user never sees
  the stale launch-time `false`. Later subscribers get the current value at once.
- An expired stored session (possible with `emitLocalSessionAsInitialSession`)
  counts as signed out.
- `withSessionRefresh` (Stokked) / `withFreshToken` (Contrarian): on an auth
  rejection it refreshes once and retries once. If the refresh is rejected, the
  session is marked expired and listeners get `false`. If the refresh fails on
  the network, the error is thrown and the user stays signed in.
- `AuthFailure.isAuthRejection` checks typed errors: `AuthError` codes and 401s,
  PostgREST `PGRST301/302/303`, `FunctionsError.httpError(401)` and Storage
  401 / "jwt expired". It falls back to message matching only for untyped errors.
  `URLError` is never a rejection.
- The SDK already coalesces concurrent refreshes of the same refresh token (in
  both 2.40 and 2.55), so this layer adds no single-flight logic of its own.
- `waitForInitialSession()` covers Nassau's `ensureAuthenticated` pattern.
- `UserChangeGuard(key:)` is Stokked's user-switch quarantine. Pass
  `key: "com.stocked.lastSignedInUserId"` to keep Stokked's stored id.

### Sign in with Apple

```swift
@State private var apple = AppleSignInFlow()          // scopes: [.fullName, .email]

AppleSignInButton(.continue, flow: apple) { credential in
    let session = try? await Backend.client.auth.signInWithApple(credential)
    if let name = credential.displayName { /* first sign-in only: store it */ }
    if let code = credential.authorizationCode { /* forward to apple-auth edge fn */ }
} onError: { error in
    message = error.localizedDescription                // cancellation is filtered out
}
```

`AppleSignInNonce.random(length:)` and `.sha256(_:)` keep Stokked's API.
`AppleSignIn.userUsesApple(user)` decides whether to revoke Apple tokens on
account deletion.

### Validation and error copy

```swift
switch CredentialValidation.email(emailField) { case .success(let email): …; case .failure(let e): e.localizedDescription }
CredentialValidation.newPassword(pw, confirmation: confirm)             // 8–72 chars + match
CredentialValidation.unmetRules(password: pw, confirmation: confirm)    // [PasswordRule] for live hints
CredentialValidation.displayName(name)                                  // trimmed, ≤ 100

do { try await client.auth.signIn(email: e, password: p) }
catch { message = AuthErrorMessage.from(error) }                        // localized, code-based
```

`AuthErrorMessage.kind(for:)` decides by `Auth.ErrorCode`: `invalid_credentials`,
`email_not_confirmed`, `user_already_exists`/`email_exists`, `weak_password`,
`same_password`, `otp_expired`, `over_*_rate_limit`, `email_address_invalid`,
`signup_disabled`, provider-disabled codes and session codes. It falls back to
HTTP 429 and message matching for older self-hosted GoTrue versions that send no code.
`URLError` maps to `.network`. These cover Nassau's `PasswordResetError` cases.

### Account deletion

```swift
DeleteAccountView(config: .init(deletedItems: […])) {          // PortfolioKit
    try await AccountDeletion.deleteAccount(
        client: Backend.client,
        strategy: .rpc("delete_user_account"),                  // or .edgeFunction("delete-account", body: ["confirm": true])
        cleanup: { await PhotoService.deleteAllForCurrentUser() } // best effort, cannot throw
    )
}
```

The steps run in this order:

1. Refresh the session. If that fails, it throws `AccountDeletionError.sessionUnavailable` and nothing is deleted.
2. Run `cleanup` (Storage files SQL can't reach, Apple token revocation).
3. Run the strategy. On failure it throws `.deletionFailed`, and the user stays signed in.
4. Sign out globally, falling back to `.local`.

### Storage

```swift
let uploader = StorageUploader(client: Backend.client)
let path = StoragePath.forUser(userId, StoragePath.component(entryId), "0.jpg")  // "<lowercase-uuid>/<lowercase-uuid>/0.jpg"
try await uploader.uploadJPEG(data: jpeg, bucket: "food_photos", path: path)     // upsert, 2 retries, 1s/2s backoff
let url = try await uploader.signedURL(bucket: "food_photos", path: path, expiresIn: 3600)
```

Per-user folders **must** use the lowercased UUID. Storage policies compare
`(storage.foldername(name))[1] = auth.uid()::text`, which is lowercase, while
Swift's `uuidString` is uppercase. Jeroboam shipped that mismatch and every
upload was rejected. Retries cover transient transport errors and Storage
408/429/5xx, never 4xx policy errors.

### Pagination

```swift
let all: [Profile] = try await fetchAllRows { from, to in
    client.from("profiles").select().order("id").range(from: from, to: to)
}
let rows = try await fetchAllPages(pageSize: 1000) { from, to in try await fetchPage(from, to) }
```

`stopOnShortPage: true` (the default, as in Nassau) saves a request.
`false` (as in Stokked) stops only on an empty page. That is correct even if
the server's `max-rows` is below `pageSize`. The offset always advances by the
number of rows returned. Order by a unique column.

## Per-app adoption map

Read-only survey as of 2026-10-27. Replace these files or blocks when you adopt
the package. What stays in each app is listed too.

### Stokked (`Stokked/Stocked`)

| File | Replace with | Keep in app |
|---|---|---|
| `Services/KeychainAuthStorage.swift` | `KeychainAuthStorage(service: "com.stefan.bernini.Stocked.auth")` (same default accessibility); `migrateFromUserDefaults()` becomes `MigratingAuthStorage(from: UserDefaultsAuthStorage(), to: keychain)` | – |
| `Services/SupabaseService.swift` | `UserDefaultsAuthStorage`, `client`/`createDummyClient` → `makeClient`; listener, `authStateStream` (incl. `terminatedContinuationIds`), `validateSession`, `refreshSession`, `withSessionRefresh`, `isAuthError` → `SessionObserver` / `AuthFailure`; user-switch quarantine → `UserChangeGuard(key: "com.stocked.lastSignedInUserId")` + `onUserChanged` | `hasStoredSession` launch hint, `didSignOutDeliberately`, the wipe body |
| `Configuration/Environment.swift` | `SupabaseEnvironment.fromInfoPlist(…, allowedHostSuffixes: [".supabase.co", ".crawik.com"])` | `developerConfigurationError` text |
| `Utilities/AppleSignInNonce.swift` | package `AppleSignInNonce` (same API) | – |
| `Utilities/Validation.swift` | `email`, `password`, `confirmPassword`, `displayName` and the matching `ValidationError` cases → `CredentialValidation` | item/list/family/store/category/notes/invite rules |
| `Services/AuthService.swift` | `signInWithApple` → `client.auth.signInWithApple(credential)` + `credential.displayName`; the sign-out fallback → `PortfolioSupabase.signOut(client:)`; `errorMessage = error.localizedDescription` → `AuthErrorMessage.from` | `resetPassword` (raw `/recover`, see the PKCE note below), `PasswordResetError`, local-state reset |
| `Services/AppleTokenService.swift` | `currentUserUsesApple` → `AppleSignIn.userUsesApple` | store/revoke edge-function calls |
| `Views/Auth/AppleSignInButton.swift` + `AuthViewModel.configureAppleRequest/handleAppleCompletion` | `AppleSignInButton(flow:)` / `AppleSignInFlow` | `AuthDivider` |
| `AccountService.deleteAccount` | `AccountDeletion.deleteAccount(strategy: .rpc("delete_my_account"), cleanup: { Apple revoke })` | the Stripe "still billable" abort check: run it **before** calling, because `cleanup` can't abort |
| `Wholesale/Services/AdminSupabaseService.fetchAllRows` | `fetchAllPages(stopOnShortPage: false)` | – |

### Nassau (`Nassau/Nassau`)

| File | Replace with | Keep in app |
|---|---|---|
| `Nassau/Config/SupabaseConfig.swift` | `KeychainAuthStorage(service: "com.stefan.bernini.nassau.auth", accessibility: .afterFirstUnlock)` (keep Nassau's class) + `makeClient(environment: SupabaseEnvironment(url:anonKey:), …)` | – |
| `Nassau/Services/AuthService.swift` | `PasswordResetError.from` → `AuthErrorMessage.kind(for:)` (same codes plus fallbacks); `waitForInitialSession` + continuations → `SessionObserver.waitForInitialSession()`; `deleteAccount` → `AccountDeletion(.rpc("delete_current_user"))`, then `signInAnonymously()` | anonymous-round logic, anonymous→permanent conversion (`auth.update(user:)` is already the SDK call), `restoresAnonymousSessionOnSignOut` (drive it from `onEvent`) |
| `Nassau/Views/Auth/AuthViews.swift` | `PasswordPolicy.isValidEmail/isValid` → `CredentialValidation.isValidEmail/isValidNewPassword` (the email check is stricter than `contains("@") && contains(".")`); `PasswordRuleHints` → render `unmetRules(...)` | the views |
| `NassauAdmin/Services/AdminService.fetchAllPages` | `fetchAllRows` | `exactCount`; `CourseService`'s parallel count-based fetch (different shape) |

Nassau's two `Package.resolved` files disagree (2.46 / 2.55). Align them when adopting.

### Jeroboam (`Jeroboam/Jeroboam/Jeroboam`)

| File | Replace with | Keep in app |
|---|---|---|
| `Services/SupabaseService.swift` | `UserDefaultsAuthStorage`, client/dummy → `makeClient`; the buffered `authStateStream` (the model for `SessionObserver`) → `SessionObserver`; `resetUserCaches` on `.signedOut` → `onEvent` | service resets |
| Release storage | it uses `KeychainLocalStorage()` (SDK default service `supabase.gotrue.swift`). The app was never released, so switch freely to `KeychainAuthStorage(service: "com.stefan.bernini.Jeroboam.auth")`. Otherwise use `KeychainAuthStorage(service: "supabase.gotrue.swift")` to keep sessions | – |
| `Configuration/Environment.swift` | `SupabaseEnvironment.fromInfoPlist(…)` with `allowedHostSuffixes: nil` (its CLAUDE.md: don't reintroduce a host check) | developer text |
| `Utilities/Validation.swift` | auth part → `CredentialValidation` | club/wine/notes/invite/rating rules |
| `Views/Profile/DeleteAccountView.swift` | PortfolioKit `DeleteAccountView` + `AccountDeletion(.rpc("delete_user_account"), cleanup: { DrinkingJournalService.deleteAllPhotosForCurrentUser })` | if the "photos removed but account not deleted" message is still wanted, catch `AccountDeletionError.deletionFailed` and add it |
| Journal / label photo uploads | `StorageUploader` + `StoragePath.forUser` (lowercase; 00023 made the policies case-insensitive server-side, so this keeps the client consistent too) | image prep |
| `DataExportService` paging | `fetchAllRows` | – |

### Carpe Vitem (`"Carpe Vitem"/swift/Carpe Diem/Shared`)

| File | Replace with | Keep in app |
|---|---|---|
| `Services/SupabaseService.swift` | `UserDefaultsAuthStorage` + `KeychainMigratingAuthStorage` → `MigratingAuthStorage(from: UserDefaultsAuthStorage(), to: KeychainAuthStorage(service: "com.carpevitem.app.auth", accessibility: .afterFirstUnlock))` (same items as the SDK storage it used); client (`preconditionFailure` on a bad URL) → `makeClient`; `authStateStream` (starts a new SDK listener per call) → `SessionObserver` | macOS `UserDefaults` choice |
| `Services/StorageService.swift` | `uploadPhoto` retry loop → `StorageUploader.uploadJPEG(retries: 2)`; `getSignedURL` → `signedURL`; paths → `StoragePath.forUser(userId, StoragePath.component(entryId), "\(n).jpg")` | `compressImage`, UIKit glue, `deletePhotosForEntry` listing |
| `Services/ExportService.deleteAccount` | `AccountDeletion(.edgeFunction("delete-account", body: ["confirm": true]))` (adds the refresh-first step) | – |

**Likely live bug:** `StorageService` builds paths with `userId.uuidString`
(uppercase), but the `food_photos` policies in `00028_food_photos_storage.sql`
compare against `auth.uid()::text` (lowercase), and no later migration lowercases
it. Every food-photo upload, read and delete is probably rejected by RLS: the
same bug as Jeroboam's before 00023. `StoragePath` fixes the client side. Existing
uppercase objects, if any, need a server-side rename or a `lower()` policy.

### ThenCam (`ThenCam/ThenCam`)

| File | Replace with | Keep in app |
|---|---|---|
| `Shared/Backend.swift` | `SupabaseClient(supabaseURL:supabaseKey:)` with SDK defaults (no `emitLocalSessionAsInitialSession`, default keychain) → `makeClient(environment: SupabaseEnvironment(url:anonKey:), storage: KeychainAuthStorage(service: "supabase.gotrue.swift", accessibility: .afterFirstUnlock))`, which keeps existing sessions; `isConfigured` → `environment.isConfigured` (`REPLACE…` is detected) | URL + key |
| `ThenCam/AccountStore.swift` | `observeAuth` → `SessionObserver` + `onEvent` (analytics identify/reset, entitlement refresh). This also fixes an expired initial session being treated as signed in once `emitLocalSessionAsInitialSession` is on. `authError = error.localizedDescription` → `AuthErrorMessage.from`; `signOut` → `PortfolioSupabase.signOut` | OTP `signInWithOTP` / `verifyOTP(type: .email)` (already SDK calls), entitlement query |

## Hand-rolled apps: migration path

These apps talk to GoTrue/PostgREST with their own URLSession code. Per the
survey recommendation, move each one to supabase-swift **when its auth is next
touched**, not as a big-bang change. The Otta keychain bug shows what maintaining
our own GoTrue client costs.

| App | Hand-rolled today | Switch to |
|---|---|---|
| **Otta** (`ios/Otta/Services/SupabaseClient.swift`, `AuthService.swift`, `SupabaseModels.swift`; `MacOttaAdmin` copy) | `actor SupabaseClient`, `/auth/v1/signup` + `/token`, own Apple sign-in, `SupabaseError` | `makeClient` + `KeychainAuthStorage`; `client.auth.signUp/signIn/signInWithApple(credential)`; `client.from(...)`; `AuthErrorMessage` instead of `SupabaseError` copy |
| **Sextant** (`Sextant/Services/SupabaseClient.swift`, `AuthService.swift`) / **Svamp** (`Svamp/Services/SupabaseClient.swift`) | copies of Otta's client | same as Otta; delete the copies |
| **Contrarian / Contria** (`ios/Sources/ContriaAPI.swift`, `AppState.swift`) | `authCall` for signup/token/refresh, anonymous `POST /signup`, conversion `PUT /user` + forced refresh, `withFreshToken` with single-flight refresh, engine calls with a bearer | `client.auth.signIn/signUp/signInAnonymously()`; conversion `client.auth.update(user: UserAttributes(email:password:))` then `refreshSession()` (clears `is_anonymous`); `SessionObserver.withSessionRefresh` (the SDK coalesces refreshes); engine → `client.functions.invoke("contria-engine", options:)` and map `FunctionsError.httpError(402/403/429)` as today. Keep the raw `/recover` call (PKCE note). The web app stays zero-SDK |
| **Ariman** (`ariman-ios/Sources/Networking/SupabaseService.swift`, `Session.swift`) | own `/auth/v1/token` + session persistence | `makeClient` + `KeychainAuthStorage` (or `MigratingAuthStorage` from its current store), `SessionObserver` |
| **Celiador iOS** (`celiador-ios/Shared/Api.swift`) | password sign-in, **magic link** (`POST /auth/v1/otp`), **GitHub OAuth** (`/auth/v1/authorize?provider=github`), the `celiador://auth-callback` handler, refresh coalescing, `importSession` | `makeClient(…, redirectToURL: URL(string: "celiador://auth-callback"))`. Magic link → `client.auth.signInWithOTP(email:redirectTo:shouldCreateUser:)`. GitHub → `client.auth.signInWithOAuth(provider: .github, redirectTo:)`, which runs `ASWebAuthenticationSession` itself (or `getOAuthSignInURL` + `launchFlow:` for custom presentation). Callback → `client.auth.session(from: url)` (or `client.auth.handle(url)` from `onOpenURL`). `importSession` → `client.auth.setSession(accessToken:refreshToken:)`. Daemon bearer → `try await client.auth.session.accessToken` (auto-refreshed). Refresh coalescing is built in |

**Celiador PKCE notes.** The SDK defaults to PKCE. The magic-link and OAuth
callbacks then carry `?code=…` instead of tokens in the fragment, and the code
can only be exchanged on the device that started the flow (the verifier is
stored locally). That matches Celiador's current "pending sign-in" same-device
assumption. `celiador://auth-callback` must be in GoTrue's
`ADDITIONAL_REDIRECT_URLS`. The daemon verifies the JWT with
`SUPABASE_JWT_SECRET` and is unaffected.

**PKCE and password recovery (Stokked, Contrarian).** Their emailed reset link
is redeemed by a **web** page, so they call `/auth/v1/recover` with raw
URLSession (implicit flow, tokens in the fragment). An SDK `resetPasswordForEmail`
on a PKCE client would produce a link that only the requesting device can
exchange. Keep the raw call, or build a separate `flowType: .implicit` client
just for recovery. Nassau's 6-digit-code recovery (`verifyOTP(type: .recovery)`)
works on the PKCE client as is.

## SDK version notes

- Tested against supabase-swift **2.40.0** (the declared floor) and **2.55.5**.
  The package avoids APIs that differ between them. For example, it skips the
  bulk `createSignedURLs`, whose `[URL]` overload is deprecated in 2.55, and
  never switches exhaustively over `AuthError` (2.55 added `refreshDiscarded`).
- **Recommend ≥ 2.55.3 in apps.** 2.55.3 ("discard a token refresh that outlived
  its session", #1374) stops a refresh that finishes after a sign-out or a user
  switch from committing the previous user's tokens. That is the same hazard
  `UserChangeGuard` defends against locally.
- `from: "2.40.0"` stays below 3.0. The SDK's `main` is preparing v3, which
  reworks `AuthError` and the session store. Error classification here pattern-matches
  `AuthError.api(…)` and will need an update for v3.
- `emitLocalSessionAsInitialSession` defaults to `false` in 2.x (it flips in
  v3). `makeClient` sets it to `true`, so the initial session can be expired,
  and `SessionObserver` checks `isExpired`.

## Development

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --package-path .
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme PortfolioSupabase -destination generic/platform=iOS build
```

Tests (Swift Testing, 87 tests) cover the pure parts: environment parsing and
host allowlist, keychain storage against an in-memory `KeychainBackend` (update-then-add,
accessibility migration, the add race, errors), UserDefaults and migrating
storage, validation, nonce, auth-failure and error-code mapping, the
`SessionObserver` buffering, refresh-retry and user-change logic (driven by
decoded `Session`s), the account-deletion order and fallbacks, retry/backoff,
storage paths, pagination, and en/sv lookups. Network paths (`makeClient`
against a live stack, real uploads) are not unit-tested.
