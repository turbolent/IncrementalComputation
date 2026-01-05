import HashTreeCollections

/// Context passed through query execution chains.
public struct ExecutionContext {

    public static let root = ExecutionContext(
        queries: TreeSet(),
        parentQuery: nil
    )

    /// Persistent set of all queries in the current execution chain.
    /// Used for fast cycle checks without walking a linked list.
    public let queries: TreeSet<AnyHashable>

    /// The most recent query in the chain (the immediate parent for child work).
    /// Used for O(1) reverse-dependency tracking without iterating the set.
    public let parentQuery: AnyHashable?

    public init(
        queries: TreeSet<AnyHashable>,
        parentQuery: AnyHashable?
    ) {
        self.queries = queries
        self.parentQuery = parentQuery
    }

    /// Checks if the given query is already in the execution chain
    public func contains(_ query: AnyHashable) -> Bool {
        return self.queries.contains(query)
    }

    /// Create a child context for a nested query
    public func child(for query: AnyHashable) -> ExecutionContext {
        var updated = self.queries
        updated.insert(query)
        return ExecutionContext(
            queries: updated,
            parentQuery: query
        )
    }
}
