/// An interceptor that caches query results (memoization).
/// Returns cached values on subsequent fetches of the same query.
public final class CacheInterceptor: QueryInterceptor {
    private var cache: [AnyHashable: Any] = [:]

    public init() {}

    public func willFetch(key: AnyHashable) throws -> Any? {
        return cache[key]
    }

    public func didCompute(key: AnyHashable, value: Any) {
        cache[key] = value
    }

    /// Clears all cached values.
    public func clear() {
        cache.removeAll()
    }

    /// Clears a specific cached value.
    public func clear(key: AnyHashable) {
        cache.removeValue(forKey: key)
    }

    /// Checks if a query is cached.
    public func isCached(key: AnyHashable) -> Bool {
        return cache[key] != nil
    }

    /// Number of cached queries.
    public var count: Int {
        return cache.count
    }
}
