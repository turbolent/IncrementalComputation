/// A composable query engine that uses interceptors to provide different behaviors.
/// Interceptors are executed in order for willFetch, and in reverse order for didCompute.
/// Thread-safe via actor isolation.
public actor ComposedEngine: QueryEngine {
    private let interceptors: [QueryInterceptor]

    /// Creates a composed engine with the given interceptors.
    /// - Parameter interceptors: The interceptors to use, executed in order.
    public init(interceptors: [QueryInterceptor]) {
        self.interceptors = interceptors
    }

    public func fetch<Q: Query>(_ query: Q) async throws -> Q.Value {
        let key = AnyHashable(query)

        // Notify all interceptors before fetching
        for interceptor in interceptors {
            if let cached = try interceptor.willFetch(key: key) {
                return cached as! Q.Value
            }
        }

        // Compute the value
        let value = try await query.compute(with: self)

        // Notify all interceptors after fetching (in reverse order)
        for interceptor in interceptors.reversed() {
            interceptor.didCompute(key: key, value: value)
        }

        return value
    }
}
