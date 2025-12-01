/// An interceptor that tracks which queries are fetched.
/// Useful for debugging and testing to see what queries were executed.
public final class TrackingInterceptor: QueryInterceptor {
    private var fetchedQueries: Set<AnyHashable> = []

    public init() {}

    public func willFetch(key: AnyHashable) throws -> Any? {
        fetchedQueries.insert(key)
        return nil
    }

    public func didCompute(key: AnyHashable, value: Any) {
        // No action needed on completion
    }

    /// Returns all queries that have been fetched.
    public var fetched: Set<AnyHashable> {
        return fetchedQueries
    }

    /// Checks if a specific query was fetched.
    public func wasFetched(key: AnyHashable) -> Bool {
        return fetchedQueries.contains(key)
    }

    /// Returns the count of fetched queries.
    public var count: Int {
        return fetchedQueries.count
    }

    /// Resets tracking.
    public func reset() {
        fetchedQueries.removeAll()
    }
}
