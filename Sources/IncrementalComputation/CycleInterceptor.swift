/// An interceptor that detects cyclic dependencies.
/// Throws `CyclicDependencyError` if a query depends on itself (directly or transitively).
/// Uses the execution context to track the dependency chain per execution.
public actor CycleInterceptor: QueryInterceptor {

    public init() {}

    public func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) async throws -> Any? {

        // Check if this query is already in the execution chain
        if let parent = context.parent,
            parent.contains(query) {

            throw CyclicDependencyError()
        }

        return nil
    }

    public func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    ) {
        // No-op
    }
}

/// Error thrown when a cyclic dependency is detected.
public struct CyclicDependencyError: Error, CustomStringConvertible {

    public var description: String {
        return "Cyclic dependency detected"
    }
}
