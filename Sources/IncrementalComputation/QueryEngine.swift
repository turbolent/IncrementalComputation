/// An engine executes queries.
public protocol QueryEngine: Actor {

    /// Fetch a query with a specific execution context.
    func fetch<Q: Query>(
        _ query: Q,
        with context: ExecutionContext
    ) async throws -> Q.Value
}
