import Foundation

/// A page of results from an endpoint that paginates by offset.
///
/// This is the older of Jira's two schemes and still what `/filter/search` and the reference
/// endpoints use.
public struct OffsetPage<Value: Sendable & Codable>: Sendable, Codable {
    public let values: [Value]
    public let startAt: Int
    public let maxResults: Int
    /// Absent on some endpoints, which is why it is optional rather than defaulted to zero —
    /// a missing total and a total of zero mean very different things to a UI.
    public let total: Int?
    public let isLast: Bool?

    public init(
        values: [Value],
        startAt: Int = 0,
        maxResults: Int = 0,
        total: Int? = nil,
        isLast: Bool? = nil
    ) {
        self.values = values
        self.startAt = startAt
        self.maxResults = maxResults
        self.total = total
        self.isLast = isLast
    }

    /// Whether another page exists.
    ///
    /// Jira sends `isLast` on some endpoints and only `total` on others, so both are consulted
    /// before falling back to the page being full — the least reliable signal, and the last resort.
    public var hasMore: Bool {
        if let isLast {
            return !isLast
        }
        if let total {
            return startAt + values.count < total
        }
        return !values.isEmpty && values.count >= maxResults
    }

    public var nextStartAt: Int {
        startAt + values.count
    }
}

/// A page from an endpoint that paginates by opaque cursor.
///
/// `/search/jql` replaced the offset scheme with this one and dropped `total` entirely; anything
/// wanting a count has to ask `/search/approximate-count` separately.
public struct TokenPage<Value: Sendable & Codable>: Sendable, Codable {
    public let values: [Value]
    public let nextPageToken: String?

    public init(values: [Value], nextPageToken: String? = nil) {
        self.values = values
        self.nextPageToken = nextPageToken
    }

    public var hasMore: Bool {
        nextPageToken != nil
    }
}

/// Where the next page starts, in whichever scheme the endpoint uses.
public enum PageCursor: Sendable, Hashable {
    case offset(Int)
    case token(String)
}

/// Walks every page of a paginated endpoint as a flat sequence of elements.
///
/// Lets callers write `for try await filter in service.allFilters()` without ever seeing a page
/// boundary, while keeping the fetching lazy — a UI that stops scrolling stops fetching.
public struct PagedSequence<Element: Sendable>: AsyncSequence, Sendable {
    /// Fetches one page starting at `cursor`; `nil` means the first page.
    public typealias Fetch = @Sendable (PageCursor?) async throws -> (elements: [Element], next: PageCursor?)

    private let fetch: Fetch
    private let pageLimit: Int

    /// - Parameter pageLimit: hard stop on how many pages will be requested. A server that keeps
    ///   handing back a cursor — through a bug or a filter matching everything — must not be able
    ///   to spin this loop forever.
    public init(pageLimit: Int = 200, fetch: @escaping Fetch) {
        self.pageLimit = pageLimit
        self.fetch = fetch
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(fetch: fetch, pageLimit: pageLimit)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let fetch: Fetch
        private let pageLimit: Int

        private var buffer: [Element] = []
        private var bufferIndex = 0
        private var cursor: PageCursor?
        private var pagesFetched = 0
        private var exhausted = false

        init(fetch: @escaping Fetch, pageLimit: Int) {
            self.fetch = fetch
            self.pageLimit = pageLimit
        }

        public mutating func next() async throws -> Element? {
            while true {
                if bufferIndex < buffer.count {
                    defer { bufferIndex += 1 }
                    return buffer[bufferIndex]
                }
                guard !exhausted, pagesFetched < pageLimit else {
                    return nil
                }

                try Task.checkCancellation()
                let page = try await fetch(cursor)
                pagesFetched += 1
                buffer = page.elements
                bufferIndex = 0
                cursor = page.next

                // An empty page with a cursor still pointing forward would loop indefinitely;
                // treat it as the end regardless of what the server claims.
                if page.next == nil || page.elements.isEmpty {
                    exhausted = true
                }
            }
        }
    }
}
