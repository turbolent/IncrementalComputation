/// An interceptor that tracks reverse dependencies.
/// When query A depends on B, this records that B has A as a reverse dependency.
/// This enables efficient invalidation: "what queries need recomputing if X changes?"
public final class ReverseDepsInterceptor: QueryInterceptor {
    /// Reverse dependency graph: dependency -> set of dependents
    /// If reverseDeps[B] contains A, it means A depends on B.
    private var reverseDeps: [AnyHashable: Set<AnyHashable>] = [:]

    /// Internal stack tracking queries currently being computed.
    private var stack: [AnyHashable] = []

    public init() {}

    public func willFetch(key: AnyHashable) throws -> Any? {
        // If we're inside another computation, record the reverse dependency
        if let parent = stack.last {
            // parent depends on key, so key -> parent is a reverse dependency
            reverseDeps[key, default: []].insert(parent)
        }
        // Push this query onto the stack
        stack.append(key)
        return nil
    }

    public func didCompute(key: AnyHashable, value: Any) {
        // Pop from stack when computation completes
        stack.removeLast()
    }

    /// Returns all queries that transitively depend on the given query.
    /// This is useful for invalidation: when `query` changes, all returned queries
    /// need to be recomputed.
    public func dependents(of key: AnyHashable) -> Set<AnyHashable> {
        var result = Set<AnyHashable>()
        var queue = [key]
        var visited = Set<AnyHashable>()

        while let current = queue.popLast() {
            guard !visited.contains(current) else {
                continue
            }
            visited.insert(current)

            if let deps = reverseDeps[current] {
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
    public func invalidate(key: AnyHashable) -> Set<AnyHashable> {
        var invalidated = Set<AnyHashable>()
        var queue = [key]

        while let current = queue.popLast() {
            guard !invalidated.contains(current) else {
                continue
            }
            invalidated.insert(current)

            // Remove from reverse deps and queue dependents
            if let dependents = reverseDeps.removeValue(forKey: current) {
                queue.append(contentsOf: dependents)
            }
        }

        return invalidated
    }

    /// Gets the direct reverse dependencies of a query (non-transitive).
    public func directDependents(of key: AnyHashable) -> Set<AnyHashable> {
        return reverseDeps[key] ?? []
    }

    /// Returns the current reverse dependency graph (for debugging).
    public var allReverseDependencies: [AnyHashable: Set<AnyHashable>] {
        return reverseDeps
    }

    /// Clears all reverse dependency information.
    public func clear() {
        reverseDeps.removeAll()
        stack.removeAll()
    }
}
