/// Context passed through query execution chains.
public final class ExecutionContext {

    public static let root = ExecutionContext(
        parent: nil,
        // Sentinel value for root context. Any value that is not a query
        query: AnyHashable(0)
    )

    public let parent: ExecutionContext?
    public let query: AnyHashable

    public init(
        parent: ExecutionContext?,
        query: AnyHashable
    ) {
        self.parent = parent
        self.query = query
    }

    /// Checks if the given query is already in the execution chain
    public func contains(_ query: AnyHashable) -> Bool {
        var current: ExecutionContext? = self
        while let context = current {
            if context.query == query {
                return true
            }
            current = context.parent
        }
        return false
    }

    /// Create a child context for a nested query
    public func child(for query: AnyHashable) -> ExecutionContext {
        return ExecutionContext(
            parent: self,
            query: query
        )
    }
}
