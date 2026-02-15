/// An interceptor that caches query results (memoization).
/// Returns cached values on subsequent fetches of the same query.
public actor CacheInterceptor: QueryInterceptor {
    private var cache: [QueryKey: any Sendable] = [:]

    public init() {}

    public func willFetch(
        query: QueryKey,
        context: ExecutionContext
    ) async throws -> (any Sendable)? {
        return self.cache[query]
    }

    public func didCompute(
        query: QueryKey,
        value: any Sendable,
        context: ExecutionContext
    ) async {
        self.cache[query] = value
    }

    /// Clears all cached values.
    public func clear() {
        self.cache.removeAll()
    }

    /// Clears a specific cached value.
    public func clear(query: QueryKey) {
        self.cache.removeValue(forKey: query)
    }

    /// Checks if a query is cached.
    public func isCached(query: QueryKey) -> Bool {
        return self.cache[query] != nil
    }

    /// Number of cached queries.
    public var count: Int {
        return self.cache.count
    }
}
