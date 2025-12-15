/// A query defines a request for a value and how to compute a value for the request.
public protocol Query: Hashable {
    associatedtype Value

    /// Computes the value for this query.
    /// Use `engine.fetch()` to fetch dependent queries.
    /// - Parameters:
    ///   - engine: The query engine to use for fetching dependencies
    ///   - context: The execution context containing the current execution chain
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Value
}
