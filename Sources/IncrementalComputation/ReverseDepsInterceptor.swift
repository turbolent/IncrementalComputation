/// Tracks reverse dependencies to identify queries affected by a change.
/// When query A fetches B, records A as a dependent of B, including on cache hits.
/// Use these records to invalidate cached queries when an input changes.
/// Tracking works before or after memoization because it runs for every attempted fetch.
/// The graph is conservative: old edges can cause extra invalidations.
/// `RedGreenInterceptor` instead replaces each memo's dependencies after successful execution.
public actor ReverseDepsInterceptor: QueryObserver {

    /// Reverse dependency graph: dependency -> set of dependents.
    /// If `reverseDeps[B]` contains A, then A depends on B.
    public private(set) var reverseDeps: [AnyQuery: Set<AnyQuery>] = [:]

    public init() {
    }

    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
        // Record the immediate caller for computation reads.
        // Admission can fail before observation; a caught failure is still a dependency.
        // Validation reads check existing dependencies; they do not add new ones.
        if !context.isValidationRead, let parent = context.callerQuery {
            self.reverseDeps[query, default: []].insert(parent)
        }
    }

    /// Returns all queries that transitively depend on the given query.
    /// When `query` changes, invalidate the returned queries' cached results.
    public func dependents(of query: AnyQuery) -> Set<AnyQuery> {
        var result = Set<AnyQuery>()
        var queue = [query]
        var visited = Set<AnyQuery>()

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

    /// Returns all queries that transitively depend on the given query.
    public func dependents<Q: Query>(of query: Q) -> Set<AnyQuery> {
        self.dependents(of: AnyQuery(query))
    }

    /// Returns the query and its transitive dependents, removing their graph entries.
    /// Use the returned keys to clear their cached results.
    @discardableResult
    public func invalidate(query: AnyQuery) -> Set<AnyQuery> {
        var invalidated = Set<AnyQuery>()
        var queue = [query]

        while let current = queue.popLast() {
            guard !invalidated.contains(current) else {
                continue
            }
            invalidated.insert(current)

            // Remove this query's graph entry and visit its dependents.
            if let dependents = self.reverseDeps.removeValue(forKey: current) {
                queue.append(contentsOf: dependents)
            }
        }

        return invalidated
    }

    /// Returns the query and its transitive dependents, removing their graph entries.
    /// Use the returned keys to clear their cached results.
    @discardableResult
    public func invalidate<Q: Query>(query: Q) -> Set<AnyQuery> {
        self.invalidate(query: AnyQuery(query))
    }

    /// Returns the query's direct dependents.
    public func directDependents(of query: AnyQuery) -> Set<AnyQuery> {
        return self.reverseDeps[query] ?? []
    }

    /// Returns the query's direct dependents.
    public func directDependents<Q: Query>(of query: Q) -> Set<AnyQuery> {
        self.directDependents(of: AnyQuery(query))
    }

    /// Returns the current reverse dependency graph for debugging.
    public var allReverseDependencies: [AnyQuery: Set<AnyQuery>] {
        return self.reverseDeps
    }

    /// Clears all reverse dependency information.
    public func clear() {
        self.reverseDeps.removeAll()
    }
}
