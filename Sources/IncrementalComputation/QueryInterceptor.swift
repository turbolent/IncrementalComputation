/// The final value or error delivered after resolution.
public typealias QueryResult = Result<any Sendable, any Error>

/// Continues resolution through the remaining interceptors and query computation.
/// Engine-supplied continuations are nonescaping and may be called at most once.
/// A second call throws `QueryContinuationError.alreadyCalled`, even if the first failed.
public typealias QueryContinuation = @Sendable () async throws -> any Sendable

/// An error in how an interceptor uses its continuation.
public enum QueryContinuationError: Error, Equatable {
    case alreadyCalled
}

/// Controls query resolution and observes its lifecycle.
/// Adopt `MemoizingInterceptor` or `DeduplicatingInterceptor` to install one in a chain.
/// Use `QueryObserver` to observe fetches without changing resolution.
/// Lifecycle hooks default to no-ops; the around hook calls `next`.
/// Custom wrappers must forward the lifecycle hooks used by their wrapped interceptor.
/// Fetch nested queries only during `intercept` or a `QueryObserver`'s `willFetch`.
public protocol QueryInterceptor: Actor {
    /// Registers an attempted fetch before observation or resolution.
    /// Runs even if another admission fails or the caller is cancelled.
    /// Use only metadata and coordination state here; an external update may be running.
    /// - Parameters:
    ///   - query: The type-erased, replayable query
    ///   - context: The execution context for this query invocation
    /// - Throws: Rejects evaluation before observation or resolution.
    ///   The engine still calls every admission hook, then `didResolve` and `endEvaluation`.
    func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws

    /// Wraps query resolution, allowing caching, validation, or shared computation.
    /// Call `next` at most once, or supply a value of the query's result type.
    /// The engine rejects repeated calls before entering the remaining chain.
    /// Fetch dependencies with the supplied context and await them before returning.
    /// - Parameters:
    ///   - query: The type-erased, replayable query
    ///   - context: The execution context for this query invocation
    ///   - engine: The engine to use when replaying dependencies
    ///   - next: Resolves through the remaining interceptors, then computes if needed
    /// - Returns: The computed or cached value for the query
    /// - Throws: An error from resolution or from this interceptor
    func intercept(
        query: AnyQuery,
        context: ExecutionContext,
        engine: any QueryEngine,
        next: QueryContinuation
    ) async throws -> any Sendable

    /// Commits an attempted fetch's final result, from innermost interceptor to outermost.
    /// Memoizers commit before deduplicators release waiting callers.
    /// Runs on cache hits, rejected admission, errors, and cancellation.
    /// The result is fixed before this phase; later cancellation does not change it.
    /// Must tolerate admission that threw before registering activity.
    /// Use only metadata and coordination state here; do not fetch queries.
    /// - Parameters:
    ///   - query: The query passed to `beginEvaluation`
    ///   - result: The fetched value or the error that prevented resolution
    ///   - context: The context passed to `beginEvaluation`
    func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async

    /// Releases evaluation state after every interceptor has received the final result.
    /// Runs from outermost interceptor to innermost, including after rejected admission.
    /// This keeps the inner memoizer's update guard active throughout outer cleanup.
    /// Must tolerate admission that threw before registering activity.
    /// Use only metadata and coordination state here; do not fetch queries.
    /// - Parameter context: The context passed to `beginEvaluation`
    func endEvaluation(context: ExecutionContext) async
}

extension QueryInterceptor {
    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
    }

    public func intercept(
        query: AnyQuery,
        context: ExecutionContext,
        engine: any QueryEngine,
        next: QueryContinuation
    ) async throws -> any Sendable {
        try await next()
    }

    public func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async {
    }

    public func endEvaluation(context: ExecutionContext) async {
    }
}

/// Caches completed query results for a chain.
/// Add it before deduplication so only the producer reaches its resolution hook.
/// Only one memoizing interceptor may be installed.
public protocol MemoizingInterceptor: QueryInterceptor {}

/// Shares active resolutions without caching completed calls.
/// Must release waiters on every outcome, keep waiter cancellation from cancelling
/// the producer, and prevent wait cycles.
/// Only one such interceptor may be installed.
public protocol DeduplicatingInterceptor: QueryInterceptor {}
