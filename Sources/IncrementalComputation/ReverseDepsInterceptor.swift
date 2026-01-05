/// An interceptor that tracks reverse dependencies.
/// When query A depends on B, this records that B has A as a reverse dependency.
/// This enables efficient invalidation: "what queries need recomputing if X changes?"
public actor ReverseDepsInterceptor: QueryInterceptor {

    /// Reverse dependency graph: dependency -> set of dependents.
    /// If reverseDeps[B] contains A, it means A depends on B.
    public private(set) var reverseDeps: [AnyHashable: Set<AnyHashable>] = [:]

    public init() {}

    public func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) async throws -> Any? {
        // If we're inside another query,
        // record the reverse dependency to the immediate parent query
        if let parent = context.parentQuery {
            self.reverseDeps[query, default: []].insert(parent)
        }
        return nil
    }

    public func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    ) async {
        // No-op
    }

    /// Returns all queries that transitively depend on the given query.
    /// This is useful for invalidation: when `query` changes,
    /// all returned queries need to be recomputed.
    public func dependents(of query: AnyHashable) -> Set<AnyHashable> {
        var result = Set<AnyHashable>()
        var queue = [query]
        var visited = Set<AnyHashable>()

        while let current = queue.popLast() {
            guard !visited.contains(current) else {
                continue
            }
            visited.insert(current)

            if let deps = self.reverseDeps[current] {
                for dep in deps {
                    result.insert(dep)
                    queue.append(dep)
                }
            }
        }

        return result
    }

    /// Invalidates a query and returns all queries that depend on it.
    /// Also removes the invalidated queries from the reverse dependency graph.
    @discardableResult
    public func invalidate(query: AnyHashable) -> Set<AnyHashable> {
        var invalidated = Set<AnyHashable>()
        var queue = [query]

        while let current = queue.popLast() {
            guard !invalidated.contains(current) else {
                continue
            }
            invalidated.insert(current)

            // Remove from reverse deps and queue dependents
            if let dependents = self.reverseDeps.removeValue(forKey: current) {
                queue.append(contentsOf: dependents)
            }
        }

        return invalidated
    }

    /// Gets the direct reverse dependencies of a query (non-transitive).
    public func directDependents(of query: AnyHashable) -> Set<AnyHashable> {
        return self.reverseDeps[query] ?? []
    }

    /// Returns the current reverse dependency graph (for debugging).
    public var allReverseDependencies: [AnyHashable: Set<AnyHashable>] {
        return self.reverseDeps
    }

    /// Clears all reverse dependency information.
    public func clear() {
        self.reverseDeps.removeAll()
    }
}
