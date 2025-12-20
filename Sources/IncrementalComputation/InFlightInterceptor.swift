/// An interceptor that deduplicates concurrent fetches of the same query.
public actor InFlightInterceptor: QueryInterceptor {

    /// Represents an in-flight computation with waiting continuations
    private final class InFlightComputation {
        var continuations: [CheckedContinuation<Any, Error>] = []
    }

    /// Tracks queries currently being computed
    private var inFlightComputations: [AnyHashable: InFlightComputation] = [:]

    public init() {}

    public func willFetch(
        query: AnyHashable,
        context: ExecutionContext
    ) async throws -> Any? {

        // Check if query is already being computed
        if let inFlightComputation = self.inFlightComputations[query] {
            // Query is in-flight, register our continuation and wait
            return try await withCheckedThrowingContinuation { continuation in
                inFlightComputation.continuations.append(continuation)
            }
        }

        // Mark query as in-flight with empty continuations list
        self.inFlightComputations[query] = InFlightComputation()

        // Return nil to proceed with computation
        return nil
    }

    public func didCompute(
        query: AnyHashable,
        value: Any,
        context: ExecutionContext
    ) async {
        // Resume all waiting continuations with the computed value
        if let inFlightComputation = self.inFlightComputations.removeValue(forKey: query) {
            for continuation in inFlightComputation.continuations {
                continuation.resume(returning: value)
            }
        }
    }
}
