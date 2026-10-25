/// A query for a value and the computation that produces it.
public protocol Query: Hashable, Sendable {
    associatedtype Value: Sendable

    /// Returns whether dependent queries can treat these computed values as interchangeable.
    /// `RedGreenInterceptor` compares old and new results to decide whether dependents must execute.
    /// Defaults to `==` for `Equatable` values of the same concrete type and `false` otherwise.
    /// Override this method to define equality for red-green backdating.
    /// Return `true` only when replacing one value with the other cannot change a dependent result.
    /// Include observable source positions and diagnostics, or track them through separate queries.
    /// Results must behave as immutable snapshots; `Sendable` alone does not enforce this.
    static func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool

    /// Computes the value for this query.
    /// Use `engine.fetch()` to fetch dependent queries.
    /// - Parameters:
    ///   - engine: The engine used to fetch dependencies
    ///   - context: The current execution chain; pass it unchanged to dependent fetches
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Value
}

extension Query {
    public static func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        // Bridging can cast different result types to one Equatable type.
        // Keep concrete types distinct because dependents can observe them.
        guard type(of: lhs as Any) == type(of: rhs as Any) else {
            return false
        }
        // A generic query's conformance may know only that Value is Sendable.
        // Check the concrete value so that conformance can still use Equatable.
        guard let equatable = lhs as? any Equatable else {
            return false
        }

        // Open the existential as one concrete type so both operands can use ==.
        func compare<ComparedValue: Equatable>(_ lhs: ComparedValue) -> Bool {
            guard let rhs = rhs as? ComparedValue else {
                return false
            }
            return lhs == rhs
        }

        return compare(equatable)
    }
}
