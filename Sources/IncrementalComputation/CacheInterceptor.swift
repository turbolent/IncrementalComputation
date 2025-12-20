/// An interceptor that caches query results (memoization).
/// Returns cached values on subsequent fetches of the same query.
public actor CacheInterceptor: QueryInterceptor {
    private var cache: [AnyHashable: Any] = [:]

    public init() {}

    public func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) async throws -> Any? {
        return self.cache[query]
    }

    public func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    ) async {
        self.cache[query] = value
    }

    /// Clears all cached values.
    public func clear() {
        self.cache.removeAll()
    }

    /// Clears a specific cached value.
    public func clear(query: AnyHashable) {
        self.cache.removeValue(forKey: query)
    }

    /// Checks if a query is cached.
    public func isCached(query: AnyHashable) -> Bool {
        return self.cache[query] != nil
    }

    /// Number of cached queries.
    public var count: Int {
        return self.cache.count
    }
}
