import Foundation
import Supabase

/// PostgREST's default `max-rows`. A page larger than the server's cap comes
/// back truncated, so keep `pageSize` at or below it.
public let postgrestDefaultMaxRows = 1000

/// Fetches every row by calling `fetchPage(from, to)` (inclusive range, as
/// `.range(from:to:)` takes) until the rows run out (Stokked Wholesale
/// `fetchAllRows`, Nassau `AdminService.fetchAllPages`).
///
/// The query needs a stable `.order(...)` on a unique column, or rows can be
/// skipped or repeated between pages.
///
/// - Parameters:
///   - pageSize: rows per request. Must not exceed the server's `max-rows`
///     when `stopOnShortPage` is `true`.
///   - stopOnShortPage: stop as soon as a page has fewer than `pageSize`
///     rows (Nassau; saves a request). Pass `false` to stop only on an empty
///     page (Stokked), which is correct even if the server caps pages below
///     `pageSize`.
///   - maxPages: safety cap on requests; `nil` for no cap.
public func fetchAllPages<T>(
    pageSize: Int = postgrestDefaultMaxRows,
    stopOnShortPage: Bool = true,
    maxPages: Int? = nil,
    _ fetchPage: (_ from: Int, _ to: Int) async throws -> [T]
) async throws -> [T] {
    precondition(pageSize > 0, "pageSize must be positive")
    var all: [T] = []
    var offset = 0
    var pages = 0
    while maxPages.map({ pages < $0 }) ?? true {
        try Task.checkCancellation()
        let page = try await fetchPage(offset, offset + pageSize - 1)
        pages += 1
        all.append(contentsOf: page)
        if page.isEmpty { break }
        if stopOnShortPage, page.count < pageSize { break }
        // Advance by what came back, so a server cap below pageSize doesn't
        // skip rows.
        offset += page.count
    }
    return all
}

/// ``fetchAllPages(pageSize:stopOnShortPage:maxPages:_:)`` for a PostgREST
/// query: return the ranged builder and this executes and decodes it.
///
/// ```swift
/// let users: [Profile] = try await fetchAllRows { from, to in
///     client.from("profiles").select().order("id").range(from: from, to: to)
/// }
/// ```
public func fetchAllRows<T: Decodable & Sendable>(
    pageSize: Int = postgrestDefaultMaxRows,
    stopOnShortPage: Bool = true,
    maxPages: Int? = nil,
    _ query: (_ from: Int, _ to: Int) throws -> PostgrestTransformBuilder
) async throws -> [T] {
    try await fetchAllPages(pageSize: pageSize, stopOnShortPage: stopOnShortPage, maxPages: maxPages) { from, to in
        let rows: [T] = try await query(from, to).execute().value
        return rows
    }
}
