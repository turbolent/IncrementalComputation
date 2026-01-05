/// A composable query engine that uses interceptors to provide different behaviors.
/// Interceptors are executed in order for willFetch, and in reverse order for didCompute.
/// Thread-safe via actor isolation.
public actor ComposedEngine: QueryEngine {

    public let interceptors: [QueryInterceptor]

    /// Creates a composed engine with the given interceptors.
    /// - Parameter interceptors: The interceptors to use, executed in order.
    public init(interceptors: [QueryInterceptor]) {
        self.interceptors = interceptors
    }

    /// Fetch a query with a specific execution context.
    ///
    /// - Parameters:
    ///   - query: The query to fetch
    ///   - context: The execution context containing the current execution chain
    /// - Returns: The computed or cached value for the query
    ///
    public func fetch<Q: Query>(
        _ query: Q,
        with parentContext: ExecutionContext
    ) async throws -> Q.Value {

        let typeErasedQuery = AnyHashable(query)

        let childContext = parentContext.child(for: typeErasedQuery)

        // Notify all interceptors before computation

        for interceptor in self.interceptors {
            if let cached = try await interceptor.willFetch(
                query: typeErasedQuery,
                context: parentContext
            ) {
                return cached as! Q.Value
            }
        }

        // Execute the query computation with child context

        let value = try await query.compute(
            with: self,
            context: childContext
        )

        // Notify all interceptors after computation (in reverse order)

        for interceptor in self.interceptors.reversed() {
            await interceptor.didCompute(
                query: typeErasedQuery,
                value: value,
                context: childContext
            )
        }

        return value
    }
}
