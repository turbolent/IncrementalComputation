/// Fetches query values through a chain of compatible interceptors.
/// The compiler checks compatibility when the chain is built.
/// Admission registers interceptors before plain observers.
/// Observation follows registration order; resolution starts with the outermost interceptor.
/// Interceptors commit results from innermost to outermost, then clean up in reverse order.
/// Actor isolation protects state while allowing suspended fetches to overlap.
///
/// Each fetch follows these phases:
/// 1. Call every interceptor's `beginEvaluation`, then every plain observer's.
///    Complete admission even when a hook throws; the first error prevents observation and resolution.
/// 2. Call every observer's `willFetch` in registration order.
///    Finish observation even when a hook throws, then report its first error without resolving.
/// 3. Resolve through the around hooks from outermost to innermost, then compute if needed.
/// 4. Fix the final result, then call every interceptor's `didResolve` from innermost to outermost.
///    Memoizers commit before deduplicators release waiters, including on cache hits and errors.
/// 5. Call every interceptor's `endEvaluation` from outermost to innermost.
///    Complete rejected attempts too, keeping update guards active through outer cleanup.
///
/// The evaluation hooks let interceptors coordinate external updates throughout each fetch.
public actor ComposedEngine: QueryEngine {
    /// The validated chain's observers and interceptors, fixed for this engine's lifetime.
    private let chain: ChainStorage

    /// Sequence counter assigning each fetch its start order within this engine.
    /// Incremented before any suspension and copied into `ExecutionContext.fetchOrder`.
    /// Hooks and parallel reads can finish out of order, so red-green sorts dependency
    /// reads by this number before storing them for validation.
    /// This lets validation stop at an earlier change before replaying an obsolete branch.
    /// The counter increases across revisions; it does not identify a revision or an array position.
    private var nextFetchOrder: UInt64 = 0

    /// Creates an engine from a chain whose composition the compiler has checked.
    /// - Parameter interceptorChain: The composed pipeline to use for every query fetch
    public init<Memoization, Deduplication>(
        interceptorChain: InterceptorChain<Memoization, Deduplication>
    ) {
        self.chain = interceptorChain.erased
    }

    /// Fetches a query using the supplied execution context.
    ///
    /// - Parameters:
    ///   - query: The query to fetch
    ///   - parentContext: The caller's execution context, or `.root` for a top-level fetch
    /// - Returns: The computed or cached value for the query
    /// - Throws: An error from observation, resolution, or cancellation
    public func fetch<Q: Query>(
        _ query: Q,
        with parentContext: ExecutionContext
    ) async throws -> Q.Value {
        let erasedQuery = AnyQuery(query)
        nextFetchOrder += 1
        let context = parentContext.child(
            for: erasedQuery,
            fetchOrder: nextFetchOrder
        )
        let result: QueryResult

        do {
            // Register every attempt, even if another admission fails or the caller is cancelled.
            // A parent can catch either error and cache its fallback value.
            let interceptorError = await notifyAll(chain.interceptors) { interceptor in
                try await interceptor.beginEvaluation(query: erasedQuery, context: context)
            }
            let observerError = await notifyAll(chain.observers) { observer in
                try await observer.beginEvaluation(query: erasedQuery, context: context)
            }
            if let error = interceptorError ?? observerError {
                throw error
            }
            try Task.checkCancellation()

            // Cache hits must not hide dependency reads from later observers.
            // Every observation runs, including when an earlier one throws.
            let observationError = await notifyAll(chain.observers) { observer in
                try await observer.willFetch(query: erasedQuery, context: context)
            }
            if let observationError {
                throw observationError
            }
            try Task.checkCancellation()

            // Compute with the child context if no around hook supplies a value.
            let value = try await resolve(
                query: erasedQuery,
                context: context,
                remaining: chain.interceptors[...]
            ) {
                try await query.compute(with: self, context: context)
            }
            try Task.checkCancellation()
            result = .success(value)
        } catch {
            result = .failure(error)
        }

        // The result is fixed before publication; later cancellation cannot retract it.
        // Commit the inner memo before the outer deduplicator releases waiting callers.
        for interceptor in chain.interceptors {
            await interceptor.didResolve(
                query: erasedQuery,
                result: result,
                context: context
            )
        }
        // Complete outer cleanup before releasing the inner memoizer's update guard.
        for interceptor in chain.interceptors.reversed() {
            await interceptor.endEvaluation(context: context)
        }
        return try result.get() as! Q.Value
    }

    /// Delivers a phase to every participant and returns its first error.
    private func notifyAll<Observer: Sendable>(
        _ observers: [Observer],
        body: @Sendable (Observer) async throws -> Void
    ) async -> (any Error)? {
        var firstError: (any Error)?
        for observer in observers {
            do {
                try await body(observer)
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    /// Removes the outermost interceptor and passes the remaining chain to its next call.
    private func resolve(
        query: AnyQuery,
        context: ExecutionContext,
        remaining: ArraySlice<any QueryInterceptor>,
        compute: QueryContinuation
    ) async throws -> any Sendable {
        guard let interceptor = remaining.last else {
            return try await compute()
        }
        let continuation = Continuation()
        return try await interceptor.intercept(
            query: query,
            context: context,
            engine: self
        ) {
            try await continuation.call {
                try await self.resolve(
                    query: query,
                    context: context,
                    remaining: remaining.dropLast(),
                    compute: compute
                )
            }
        }
    }

    /// Each around hook gets its own one-call guard.
    /// Claim before suspending so concurrent calls cannot both enter the remaining chain.
    private actor Continuation {
        /// Whether resolution has been claimed, including a call that later fails or is cancelled.
        private var called = false

        func call(_ body: QueryContinuation) async throws -> any Sendable {
            guard !called else {
                throw QueryContinuationError.alreadyCalled
            }
            called = true
            return try await body()
        }
    }
}
