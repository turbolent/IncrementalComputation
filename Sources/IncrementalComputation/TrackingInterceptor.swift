/// An interceptor that tracks which queries are fetched.
/// Useful for debugging and testing to see what queries were executed.
public actor TrackingInterceptor: QueryInterceptor {

    public private(set) var fetchedQueries: Set<AnyHashable> = []

    public init() {}

    public func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) async throws -> Any? {
        self.fetchedQueries.insert(query)
        return nil
    }

    public func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    ) async {
        // No-op
    }

    /// Checks if a specific query was fetched.
    public func wasFetched(query: AnyHashable) -> Bool {
        return self.fetchedQueries.contains(query)
    }

    /// Returns the count of fetched queries.
    public var count: Int {
        return self.fetchedQueries.count
    }

    /// Resets tracking.
    public func reset() {
        self.fetchedQueries.removeAll()
    }
}
