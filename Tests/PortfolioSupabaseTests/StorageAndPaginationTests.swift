import Foundation
import Supabase
import Testing
@testable import PortfolioSupabase

@Suite struct StoragePathTests {
    let user = UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF")!

    @Test func userFolderIsLowercased() {
        #expect(StoragePath.userFolder(user) == "a1b2c3d4-e5f6-4711-8899-aabbccddeeff")
    }

    @Test func forUserJoinsAndCleansComponents() {
        #expect(StoragePath.forUser(user, "photo.jpg") == "a1b2c3d4-e5f6-4711-8899-aabbccddeeff/photo.jpg")
        #expect(StoragePath.forUser(user, "/entries/", "", "x/0.jpg") == "a1b2c3d4-e5f6-4711-8899-aabbccddeeff/entries/x/0.jpg")
        #expect(StoragePath.forUser(user) == "a1b2c3d4-e5f6-4711-8899-aabbccddeeff")
    }

    @Test func uuidComponentsCanBeLowercasedToo() {
        let entry = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        #expect(StoragePath.forUser(user, StoragePath.component(entry), "0.jpg")
            == "a1b2c3d4-e5f6-4711-8899-aabbccddeeff/00000000-0000-0000-0000-0000000000ab/0.jpg")
    }

    @Test func matchesAuthUidTextForm() {
        // auth.uid()::text is the lowercase canonical form.
        #expect(StoragePath.userFolder(user) == user.uuidString.lowercased())
        #expect(StoragePath.userFolder(user) != user.uuidString)
    }
}

/// Thread-safe counter for @Sendable closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var delays: [Duration] = []
    @discardableResult func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
    func recordDelay(_ d: Duration) { lock.withLock { delays.append(d) } }
    var recordedDelays: [Duration] { lock.withLock { delays } }
}

@Suite struct RetryPolicyTests {
    @Test func retriesTransientErrorsWithBackoff() async throws {
        let attempts = Counter()
        let sleeps = Counter()
        let policy = RetryPolicy(retries: 2, baseDelay: .seconds(1))

        let result = try await policy.run(sleep: { sleeps.recordDelay($0) }) {
            if attempts.increment() < 3 { throw URLError(.networkConnectionLost) }
            return "ok"
        }

        #expect(result == "ok")
        #expect(attempts.count == 3)
        #expect(sleeps.recordedDelays == [.seconds(1), .seconds(2)])
    }

    @Test func givesUpAfterRetries() async {
        let attempts = Counter()
        let policy = RetryPolicy(retries: 2, baseDelay: .zero)
        await #expect(throws: URLError.self) {
            try await policy.run(sleep: { _ in }) { () -> Int in
                attempts.increment()
                throw URLError(.timedOut)
            }
        }
        #expect(attempts.count == 3)
    }

    @Test func doesNotRetryPermanentErrors() async {
        let attempts = Counter()
        let policy = RetryPolicy(retries: 5, baseDelay: .zero)
        await #expect(throws: StorageError.self) {
            try await policy.run(sleep: { _ in }) { () -> Int in
                attempts.increment()
                throw StorageError(statusCode: "403", message: "new row violates row-level security policy")
            }
        }
        #expect(attempts.count == 1)
    }

    @Test func retryableClassification() {
        let isRetryable = RetryPolicy.isTransientUploadError
        #expect(isRetryable(URLError(.notConnectedToInternet)))
        #expect(isRetryable(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(isRetryable(StorageError(statusCode: "503", message: "unavailable")))
        #expect(!isRetryable(StorageError(statusCode: "400", message: "bad")))
        #expect(!isRetryable(URLError(.badURL)))
        #expect(!isRetryable(CancellationError()))
    }

    @Test func negativeRetriesClampToZero() {
        #expect(RetryPolicy(retries: -3).retries == 0)
    }
}

@Suite struct PaginationTests {
    /// A table of `total` rows served in pages capped at `serverCap`.
    final class FakeTable: @unchecked Sendable {
        let rows: [Int]
        let serverCap: Int
        private(set) var requests: [(Int, Int)] = []
        init(total: Int, serverCap: Int = 1000) {
            rows = Array(0..<total)
            self.serverCap = serverCap
        }
        func page(_ from: Int, _ to: Int) -> [Int] {
            requests.append((from, to))
            guard from < rows.count else { return [] }
            let end = min(to, rows.count - 1, from + serverCap - 1)
            return Array(rows[from...end])
        }
    }

    @Test func fetchesEverythingAcrossPages() async throws {
        let table = FakeTable(total: 2_345)
        let all = try await fetchAllPages(pageSize: 1000) { table.page($0, $1) }
        #expect(all == table.rows)
        #expect(table.requests.map(\.0) == [0, 1000, 2000])
        #expect(table.requests.map(\.1) == [999, 1999, 2999])
    }

    @Test func exactMultipleNeedsOneEmptyPage() async throws {
        let table = FakeTable(total: 2_000)
        let all = try await fetchAllPages(pageSize: 1000) { table.page($0, $1) }
        #expect(all.count == 2_000)
        #expect(table.requests.count == 3)
    }

    @Test func emptyTable() async throws {
        let table = FakeTable(total: 0)
        let all = try await fetchAllPages(pageSize: 50) { table.page($0, $1) }
        #expect(all.isEmpty)
        #expect(table.requests.count == 1)
    }

    @Test func stopOnEmptyOnlySurvivesServerCapBelowPageSize() async throws {
        // Server caps at 100 but we ask for 500: short-page stopping would
        // truncate; empty-page stopping must not.
        let table = FakeTable(total: 350, serverCap: 100)
        let truncated = try await fetchAllPages(pageSize: 500) { table.page($0, $1) }
        #expect(truncated.count == 100)

        let table2 = FakeTable(total: 350, serverCap: 100)
        let all = try await fetchAllPages(pageSize: 500, stopOnShortPage: false) { table2.page($0, $1) }
        #expect(all == table2.rows)
        #expect(table2.requests.map(\.0) == [0, 100, 200, 300, 350])
    }

    @Test func maxPagesCapsRequests() async throws {
        let table = FakeTable(total: 10_000)
        let some = try await fetchAllPages(pageSize: 100, maxPages: 3) { table.page($0, $1) }
        #expect(some.count == 300)
        #expect(table.requests.count == 3)
    }

    @Test func errorsPropagate() async {
        await #expect(throws: URLError.self) {
            let _: [Int] = try await fetchAllPages(pageSize: 10) { _, _ in throw URLError(.timedOut) }
        }
    }
}
