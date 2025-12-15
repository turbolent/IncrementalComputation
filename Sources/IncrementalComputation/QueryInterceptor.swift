/// Protocol for query execution interceptors.
/// Interceptors should be actors to provide thread-safe access to their state.
public protocol QueryInterceptor {

    /// Called before fetching a query.
    /// - Parameters:
    ///   - query: The type-erased query
    ///   - context: The execution context for this query chain
    /// - Returns: A cached value if available, or nil to continue with computation
    /// - Throws: Can throw (e.g., CyclicDependencyError for cycle detection)
    func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) throws -> Any?

    /// Called after a query value has been computed.
    /// - Parameters:
    ///   - query: The type-erased query
    ///   - value: The computed value
    ///   - context: The execution context for this query chain
    func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    )
}
