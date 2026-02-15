/// An interceptor that detects cyclic dependencies.
/// Throws `CyclicDependencyError` if a query depends on itself (directly or transitively).
/// Uses the execution context to track the dependency chain per execution.
public actor CycleInterceptor: QueryInterceptor {

    public init() {}

    public func willFetch(
        query: QueryKey,
        context: ExecutionContext
    ) async throws -> (any Sendable)? {

        // Check if this query is already in the execution chain
        if context.contains(query) {
            throw CyclicDependencyError()
        }

        return nil
    }

    public func didCompute(
        query: QueryKey,
        value: any Sendable,
        context: ExecutionContext
    ) {
        // No-op
    }
}

/// Error thrown when a cyclic dependency is detected.
public struct CyclicDependencyError: Error, CustomStringConvertible, Sendable {

    public var description: String {
        return "Cyclic dependency detected"
    }
}
