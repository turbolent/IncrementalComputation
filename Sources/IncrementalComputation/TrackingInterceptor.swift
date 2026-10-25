/// Records keys of admitted fetches for debugging and tests.
/// Includes cache hits and validation reads, which may not execute query bodies.
public actor TrackingInterceptor: QueryObserver {

    /// Distinct queries observed since initialization or the last reset, including cache hits.
    public private(set) var fetchedQueries: Set<AnyQuery> = []

    public init() {
    }

    public func willFetch(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
        self.fetchedQueries.insert(query)
    }

    /// Returns whether this query was fetched.
    public func wasFetched(query: AnyQuery) -> Bool {
        return self.fetchedQueries.contains(query)
    }

    /// Returns whether this query was fetched.
    public func wasFetched<Q: Query>(query: Q) -> Bool {
        self.wasFetched(query: AnyQuery(query))
    }

    /// Number of distinct queries fetched.
    public var count: Int {
        return self.fetchedQueries.count
    }

    /// Clears the recorded query keys.
    public func reset() {
        self.fetchedQueries.removeAll()
    }
}
