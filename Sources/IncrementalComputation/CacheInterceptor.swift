import Foundation

/// Caches query results for later fetches of the same key.
/// Cached values remain until explicitly cleared.
/// Publishes a computed value only after the complete fetch succeeds.
/// When external data changes, use `ReverseDepsInterceptor` to find affected queries:
///
/// ```swift
/// for query in await dependencies.invalidate(query: changedQuery) {
///     await cache.clear(query: query)
/// }
/// ```
///
/// Keep evaluations idle while changing external data and invalidating this cache.
/// For coordinated updates and automatic dependency validation, use `RedGreenInterceptor`.
public actor CacheInterceptor: MemoizingInterceptor {
    /// Successful results by query key, retained until explicitly cleared.
    private var cache: [AnyQuery: any Sendable] = [:]

    /// Inner results awaiting the full chain's outcome, kept separate for concurrent invocations.
    private var pending: [UUID: any Sendable] = [:]

    public init() {
    }

    public func intercept(
        query: AnyQuery,
        context: ExecutionContext,
        engine: any QueryEngine,
        next: QueryContinuation
    ) async throws -> any Sendable {
        if let value = cache[query] {
            return value
        }
        let value = try await next()
        try Task.checkCancellation()
        pending[context.invocationID!] = value
        return value
    }

    public func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async {
        guard let value = pending.removeValue(forKey: context.invocationID!),
              case .success = result else {
            return
        }
        // Cache the inner value so outer transformations run once on each fetch.
        cache[query] = value
    }

    /// Clears all cached values.
    public func clear() {
        self.cache.removeAll()
    }

    /// Removes the query's cached value.
    public func clear(query: AnyQuery) {
        self.cache.removeValue(forKey: query)
    }

    /// Removes the query's cached value.
    public func clear<Q: Query>(query: Q) {
        self.clear(query: AnyQuery(query))
    }

    /// Returns whether the cache contains this query.
    public func isCached(query: AnyQuery) -> Bool {
        return self.cache[query] != nil
    }

    /// Returns whether the cache contains this query.
    public func isCached<Q: Query>(query: Q) -> Bool {
        self.isCached(query: AnyQuery(query))
    }

    /// Number of cached queries.
    public var count: Int {
        return self.cache.count
    }
}
