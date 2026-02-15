/// Protocol for query execution interceptors.
public protocol QueryInterceptor: Actor {

    /// Called before fetching a query.
    /// - Parameters:
    ///   - query: The type-erased query
    ///   - context: The execution context for this query chain
    /// - Returns: A cached value if available, or nil to continue with computation
    /// - Throws: Can throw (e.g., CyclicDependencyError for cycle detection)
    func willFetch(
        query: QueryKey,
        context: ExecutionContext
    ) async throws -> (any Sendable)?

    /// Called after a query value has been computed.
    /// - Parameters:
    ///   - query: The type-erased query
    ///   - value: The computed value
    ///   - context: The execution context for this query chain
    func didCompute(
        query: QueryKey,
        value: any Sendable,
        context: ExecutionContext
    ) async
}
