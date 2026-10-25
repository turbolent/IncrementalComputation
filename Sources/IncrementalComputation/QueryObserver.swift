/// Records fetch attempts and observes admitted fetches without changing resolution.
/// Use `beginEvaluation` to record attempted reads, including rejected admissions.
/// Use `willFetch` for work that requires successful admission.
/// Both hooks default to no-ops and receive the query's child context, as does `compute`.
public protocol QueryObserver: Actor {
    /// Records an attempted fetch after interceptor admission.
    /// Runs even if another admission fails or the caller is cancelled.
    /// Use only metadata here; an external update may be running.
    /// All admission hooks run before the engine reports the first error.
    func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws

    /// Observes an admitted fetch before resolution, including cache hits.
    /// Runs in observer registration order after every admission hook succeeds.
    /// All observers run before the engine reports the first observation error.
    /// Queries fetched with the supplied context count as dependencies.
    /// Await those fetches before returning.
    func willFetch(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws
}

extension QueryObserver {
    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
    }

    public func willFetch(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
    }
}
