/// Detects cyclic dependencies within an execution chain.
/// Throws `CyclicDependencyError` if a query depends on itself, directly or transitively.
/// Checks each invocation's execution context to keep concurrent chains separate.
public actor CycleInterceptor: QueryObserver {

    public init() {
    }

    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {

        // Reject recursion before observation hooks can fetch this query again.
        if context.ancestors.contains(query) {
            throw CyclicDependencyError()
        }
    }
}

/// Error thrown when a cyclic dependency is detected.
public struct CyclicDependencyError: Error, CustomStringConvertible, Sendable {

    /// The message shown when a dependency cycle prevents evaluation.
    public var description: String {
        return "Cyclic dependency detected"
    }
}
