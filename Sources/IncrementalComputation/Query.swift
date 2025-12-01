/// A query defines a request for a value and how to compute a value for the request.
public protocol Query: Hashable {
    associatedtype Value

    /// Computes the value for this query.
    /// Use `engine.fetch()` to fetch dependent queries.
    func compute<E: QueryEngine>(with engine: E) async throws -> Value
}
