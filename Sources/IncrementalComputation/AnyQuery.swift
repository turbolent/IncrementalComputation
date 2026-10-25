/// A type-erased query that preserves identity, fetching, and result comparison.
/// Equality and hashing use the query's dynamic type and Hashable value.
/// Supply an engine when fetching; the wrapper stores only the query.
public struct AnyQuery: Hashable, Sendable {
    /// The wrapped query, retained for its identity, computation, and result comparison.
    private let raw: any Query

    /// Erases the concrete query type while preserving its operations.
    public init<Q: Query>(_ query: Q) {
        self.raw = query
    }

    public static func == (lhs: AnyQuery, rhs: AnyQuery) -> Bool {
        guard type(of: lhs.raw) == type(of: rhs.raw) else {
            return false
        }
        // Open the existential to compare values using their own Hashable conformance.
        func compare<Q: Query>(_ lhs: Q) -> Bool {
            guard let rhs = rhs.raw as? Q else {
                return false
            }
            return lhs == rhs
        }
        return compare(lhs.raw)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: self.raw)))
        hasher.combine(self.raw)
    }

    /// Fetches the query through the supplied engine's full lifecycle.
    /// Pass a caller context; the engine creates the fetched query's child context.
    public func fetch(
        with engine: any QueryEngine,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try await engine.fetch(raw, with: context)
    }

    /// Compares results with `Query.valuesEqual`, returning `false` for incompatible types.
    public func valuesEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        raw.valuesEqual(lhs, rhs)
    }
}

private extension Query {
    // The extension knows Value, so it can restore the erased result types directly.
    func valuesEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
        guard let lhs = lhs as? Value, let rhs = rhs as? Value else {
            return false
        }
        // Preserve comparison overrides when a class query is passed through a base type.
        return type(of: self).valuesEqual(lhs, rhs)
    }
}
