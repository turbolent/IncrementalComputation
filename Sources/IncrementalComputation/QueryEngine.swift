/// An engine executes queries.
public protocol QueryEngine {
    func fetch<Q: Query>(_ query: Q) async throws -> Q.Value
}
