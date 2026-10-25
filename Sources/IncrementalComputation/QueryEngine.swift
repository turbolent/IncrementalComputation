/// Fetches query values.
public protocol QueryEngine: Actor {

    /// Fetches a query using the supplied execution context.
    func fetch<Q: Query>(
        _ query: Q,
        with context: ExecutionContext
    ) async throws -> Q.Value
}
