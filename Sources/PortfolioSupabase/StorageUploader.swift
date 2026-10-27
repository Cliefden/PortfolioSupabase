import Foundation
import Supabase

/// Storage object paths. Per-user folders use the **lowercased** UUID because
/// storage policies compare `(storage.foldername(name))[1]` with
/// `auth.uid()::text`, which is lowercase, while Swift's `uuidString` is
/// uppercase. Jeroboam shipped that mismatch and every upload was rejected
/// (fixed server-side in its migration 00023).
public enum StoragePath {
    /// `"<lowercased-uuid>"`.
    public static func userFolder(_ userId: UUID) -> String {
        userId.uuidString.lowercased()
    }

    /// `"<lowercased-uuid>/a/b.jpg"`. Empty components and stray slashes are
    /// dropped. Components are used verbatim otherwise (UUID components you
    /// pass are *not* lowercased; use ``component(_:)`` for those).
    public static func forUser(_ userId: UUID, _ components: String...) -> String {
        join([userFolder(userId)] + components)
    }

    /// A UUID as a path component, lowercased like the user folder.
    public static func component(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func join(_ components: [String]) -> String {
        components
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: true) }
            .map(String.init)
            .joined(separator: "/")
    }
}

/// When and how often to retry.
public struct RetryPolicy: Sendable {
    /// Retries after the first attempt (so `2` means up to 3 attempts).
    public var retries: Int
    /// Delay before the first retry; doubles each time.
    public var baseDelay: Duration
    public var isRetryable: @Sendable (any Error) -> Bool

    public init(retries: Int = 2, baseDelay: Duration = .seconds(1), isRetryable: @escaping @Sendable (any Error) -> Bool = RetryPolicy.isTransientUploadError) {
        self.retries = max(0, retries)
        self.baseDelay = baseDelay
        self.isRetryable = isRetryable
    }

    /// Network failures and 408/429/5xx from Storage. Never auth or
    /// validation errors (retrying can't fix those).
    public static let isTransientUploadError: @Sendable (any Error) -> Bool = { error in
        if error is CancellationError { return false }
        if AuthFailure.isTransient(error) { return true }
        if let storageError = error as? StorageError, let status = storageError.statusCode {
            return ["408", "429", "500", "502", "503", "504"].contains(status)
        }
        return false
    }

    func delay(beforeRetry retry: Int) -> Duration {
        baseDelay * (1 << min(retry - 1, 16))
    }

    /// Runs `operation`, retrying per the policy. Internal `sleep` is
    /// injectable for tests.
    func run<T: Sendable>(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var retry = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard retry < retries, isRetryable(error) else { throw error }
                retry += 1
                try await sleep(delay(beforeRetry: retry))
            }
        }
    }
}

/// Uploads with retry, and signed URLs (Carpe Vitem `StorageService`).
public struct StorageUploader: Sendable {
    public let client: SupabaseClient
    public var baseDelay: Duration

    public init(client: SupabaseClient, baseDelay: Duration = .seconds(1)) {
        self.client = client
        self.baseDelay = baseDelay
    }

    /// Uploads JPEG data and returns the object path.
    ///
    /// - Parameters:
    ///   - path: object path inside the bucket; build per-user paths with
    ///     ``StoragePath/forUser(_:_:)``.
    ///   - upsert: overwrite an existing object (needs an UPDATE policy).
    ///   - retries: retries after the first attempt on transient failures.
    @discardableResult
    public func uploadJPEG(
        data: Data,
        bucket: String,
        path: String,
        upsert: Bool = true,
        retries: Int = 2
    ) async throws -> String {
        try await upload(data: data, bucket: bucket, path: path, contentType: "image/jpeg", upsert: upsert, retries: retries)
    }

    /// Uploads any data and returns the object path.
    @discardableResult
    public func upload(
        data: Data,
        bucket: String,
        path: String,
        contentType: String,
        upsert: Bool = true,
        cacheControl: String = "3600",
        retries: Int = 2
    ) async throws -> String {
        let client = client
        let policy = RetryPolicy(retries: retries, baseDelay: baseDelay)
        return try await policy.run {
            _ = try await client.storage
                .from(bucket)
                .upload(path, data: data, options: FileOptions(cacheControl: cacheControl, contentType: contentType, upsert: upsert))
            return path
        }
    }

    /// A time-limited URL for an object in a private bucket.
    public func signedURL(bucket: String, path: String, expiresIn seconds: Int = 3600) async throws -> URL {
        try await client.storage.from(bucket).createSignedURL(path: path, expiresIn: seconds)
    }

    /// Removes objects; an empty list is a no-op.
    public func remove(bucket: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await client.storage.from(bucket).remove(paths: paths)
    }
}
