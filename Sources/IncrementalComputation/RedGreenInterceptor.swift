import Foundation

/// Reasons to reject an external update or a new evaluation.
public enum RevisionUpdateError: Error, Equatable {
    case emptyInvalidation
    case evaluationsActive
    case updateInProgress
}

/// Caches query results across external updates by validating their dependencies.
/// Use one instance per engine and declare every external change through `update`.
/// Queries must be deterministic within each revision.
/// Callers fetch queries normally; the interceptor decides which bodies must execute.
///
/// Each memo records when its value was last verified (`verifiedAt`) and last changed (`changedAt`).
/// When recomputation returns an equal value, `verifiedAt` advances and `changedAt` stays unchanged.
/// This is backdating: dependent queries can keep their cached results without executing again.
/// For `Number -> IsEven -> Report`, changing `2` to `4` recomputes `IsEven` but skips the report body.
/// Changing the input to `5` changes `IsEven`'s result, so the report executes too.
/// Source queries can backdate as well, stopping validation before their immediate consumers execute.
///
/// Validation checks dependencies in fetch-start order and stops at the first change.
/// Each successful execution replaces its dependency records, even when its result is equal.
/// This removes obsolete branch dependencies.
/// Dependency reads are finalized before another update can begin.
/// Failed or cancelled executions publish no new memo.
/// A subsequent fetch in a later revision reruns a parent that caught a failed dependency read.
/// Cancellation aborts validation.
///
/// Results must be immutable snapshots, and `Query.valuesEqual` must account for everything dependents observe.
/// A fetch that bypasses this interceptor can validate a memo only if its result compares equal.
/// Without a comparer, dependents of shared in-flight results may execute again in a later revision.
/// Old memos remain available for comparison; this interceptor does not evict them.
/// See `Examples/Memoization/main.swift` for executable backdating and value-based key examples.
public actor RedGreenInterceptor: MemoizingInterceptor {
    /// A dependency read, ordered by fetch start, including failures caught by its parent.
    private struct Read: Sendable {
        /// The dependency's identity and the query to replay during validation.
        let query: AnyQuery

        /// The engine's sequence number for this read, used to recover fetch-start order.
        let order: UInt64

        /// Whether a later revision must execute the parent rather than validate this read.
        /// Cleared only when the read succeeds with a memo verified in the current revision.
        /// A failed or unmemoized read cannot establish that its parent is unchanged.
        var requiresExecution = true
    }

    /// The last successful result and the dependencies that produced it.
    private struct Memo: Sendable {
        /// The inner result returned to outer interceptors on a cache hit.
        let value: any Sendable

        /// The final result seen by callers, used to compare executions for backdating.
        /// Outer interceptors may transform the inner result.
        let observedValue: any Sendable

        /// Latest revision in which the query was executed or its result validated.
        let verifiedAt: UInt64

        /// Latest revision in which execution produced a different result.
        let changedAt: UInt64

        /// Computation dependencies and later hook reads, in fetch-start order.
        let reads: [Read]

        /// Whether an explicit update requires execution even if dependencies are unchanged.
        /// Unfetched queries have no memo and already have to execute.
        var dirty = false

        /// Whether a failed or unmemoized read prevents validation of this result and its dependents.
        var requiresExecution: Bool {
            reads.contains { $0.requiresExecution }
        }
    }

    /// An inner result awaiting the full interceptor chain's outcome before publication.
    private enum Resolution {
        case computed(any Sendable)
        case validated(Memo)
    }

    /// Collects each invocation's reads separately, even for concurrent reads of one key.
    private struct Frame {
        /// This invocation's dependency reads, keyed by each child's invocation ID.
        /// Distinct IDs keep parallel reads of the same query separate.
        var reads: [UUID: Read] = [:]

        /// The result to publish only if the complete fetch succeeds.
        /// Waiting callers and outer short-circuits never enter this interceptor's resolution.
        var resolution: Resolution?

        /// Whether a validation replay failed or returned without a reliable memo.
        /// Kept separate from semantic reads so validation cannot add dependency edges.
        var validationFailed = false

        /// Collected reads sorted by fetch start, regardless of hook or completion order.
        var orderedReads: [Read] {
            reads.values.sorted { $0.order < $1.order }
        }
    }

    /// Cached values and validation records by query, including explicitly dirtied memos.
    private var memos: [AnyQuery: Memo] = [:]

    /// Dependency collection and pending results for each fetch attempt through completion.
    /// A nonempty dictionary prevents external updates.
    private var frames: [UUID: Frame] = [:]

    /// Whether an admitted external update is running and new evaluations must be rejected.
    private var updating = false

    /// Current revision, advanced once after each admitted update, even when its body throws.
    private(set) var revision: UInt64 = 1

    public init() {
    }

    /// Mutates external inputs while no evaluations are active.
    /// Rejects new evaluations until the body finishes, then advances the revision
    /// once and invalidates the declared queries.
    /// This also happens if the body throws,
    /// because the body may have changed some external state before failing.
    /// - Parameters:
    ///   - queries: At least one query whose external data may change; ignores duplicate keys
    ///   - body: The asynchronous mutation to perform after admission
    /// - Returns: The mutation body's result
    /// - Throws: `RevisionUpdateError` if admission fails, or `CancellationError` if
    ///   cancelled before admission.
    ///   Neither invokes the body.
    ///   Rethrows the body's
    ///   original error after invalidating the declared queries.
    ///
    /// Your code owns and mutates the external data:
    ///
    /// ```swift
    /// try await incremental.update(invalidating: [AnyQuery(sourceQuery)]) {
    ///     await sourceStore.setNumber(4)
    /// }
    /// ```
    ///
    /// The next fetch performs validation and computation; `update` does not evaluate queries.
    /// Declaring a derived query forces its body to execute too.
    /// Active evaluations, including completion callbacks, reject an update before its body runs.
    /// Fetches and nested updates during the body throw `RevisionUpdateError.updateInProgress`.
    /// Do not fetch through the engine from the mutation body.
    public func update<T: Sendable>(
        invalidating queries: [AnyQuery],
        body: @Sendable () async throws -> T
    ) async throws -> T {
        guard !queries.isEmpty else {
            throw RevisionUpdateError.emptyInvalidation
        }
        guard !updating else {
            throw RevisionUpdateError.updateInProgress
        }
        guard frames.isEmpty else {
            throw RevisionUpdateError.evaluationsActive
        }
        try Task.checkCancellation()
        updating = true
        defer {
            revision += 1
            for query in Set(queries) {
                memos[query]?.dirty = true
            }
            updating = false
        }
        return try await body()
    }

    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
        let id = context.invocationID!
        frames[id] = Frame()
        // Admission hooks may suspend, so these hooks can arrive out of order.
        // Keep the engine's fetch-start order and sort when publishing the memo.
        // Validation replays check old edges; they must not add new edges to the caller.
        if !context.isValidationRead, let parent = context.parentInvocationID {
            frames[parent]?.reads[id] = Read(
                query: query,
                order: context.fetchOrder
            )
        }
        guard !updating else {
            throw RevisionUpdateError.updateInProgress
        }
        // Register the read even if the caller catches this cycle error.
        guard !context.ancestors.contains(query) else {
            throw CyclicDependencyError()
        }
    }

    public func intercept(
        query: AnyQuery,
        context: ExecutionContext,
        engine: any QueryEngine,
        next: QueryContinuation
    ) async throws -> any Sendable {
        try Task.checkCancellation()
        let id = context.invocationID!
        let old = memos[query]
        if let old, old.verifiedAt == revision {
            frames[id]?.resolution = .validated(old)
            return old.value
        }

        // Explicitly dirtied queries must execute.
        // Otherwise validate old reads before deciding whether to execute the body.
        if let old, !old.dirty,
           try await dependenciesUnchanged(old, engine: engine, context: context) {
            try Task.checkCancellation()
            frames[id]?.resolution = .validated(old)
            return old.value
        }

        let value = try await next()
        try Task.checkCancellation()
        frames[id]?.resolution = .computed(value)
        return value
    }

    /// Stops at the first changed or failed dependency before visiting an obsolete branch.
    private func dependenciesUnchanged(
        _ memo: Memo,
        engine: any QueryEngine,
        context: ExecutionContext
    ) async throws -> Bool {
        for read in memo.reads {
            guard !read.requiresExecution else {
                return false
            }
            do {
                _ = try await read.query.fetch(
                    with: engine,
                    context: context.validatingDependencies()
                )
                try Task.checkCancellation()
            } catch {
                if error is CancellationError {
                    throw error
                }
                try Task.checkCancellation()
                // Execute the parent so its body can handle this dependency error.
                return false
            }
            // Compare against the parent's last verification, which may be several revisions old.
            // Backdating lets an equal result pass this check.
            guard frames[context.invocationID!]?.validationFailed == false,
                  let dependency = memos[read.query],
                  dependency.verifiedAt == revision,
                  !dependency.requiresExecution,
                  dependency.changedAt <= memo.verifiedAt else {
                return false
            }
        }
        return true
    }

    public func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async {
        let id = context.invocationID!
        guard case .success(let observedValue) = result, let frame = frames[id] else {
            // Failed reads retain requiresExecution, even when the parent catches the error.
            // Rerun that parent in a later revision so its body can handle the error again.
            if context.isValidationRead, let parent = context.parentInvocationID {
                frames[parent]?.validationFailed = true
            }
            return
        }
        if let resolution = frame.resolution {
            let value: any Sendable
            let changedAt: UInt64
            let reads: [Read]
            switch resolution {
            case .computed(let computed):
                value = computed
                changedAt = revisionOfChange(query, value: observedValue, previous: memos[query])
                // Replace dependencies even for an equal result: execution may switch branches.
                reads = frame.orderedReads
            case .validated(let old):
                value = old.value
                // Unchanged dependencies prove the result unchanged without comparing it again.
                // A fresh failed read can produce a different fallback in an outer hook.
                if frame.reads.values.contains(where: { $0.requiresExecution }) {
                    changedAt = revisionOfChange(query, value: observedValue, previous: old)
                } else {
                    changedAt = old.changedAt
                }
                // Keep the skipped computation's reads and any new reads from outer hooks.
                reads = mergingReads(old.reads, frame.orderedReads)
            }
            // Publish only after the entire chain succeeds.
            // Failed duplicates cannot overwrite another invocation's committed memo.
            memos[query] = Memo(
                value: value,
                observedValue: observedValue,
                verifiedAt: revision,
                changedAt: changedAt,
                reads: reads
            )
        }
        // A caught failure can return a fallback even when an earlier invocation committed a memo.
        // Propagate uncertainty through dependents so a later revision retries their bodies.
        guard let parent = context.parentInvocationID else {
            return
        }
        // A waiter or outer short-circuit must actually return the committed memo's value.
        // Without a comparer, retry its caller in a later revision instead of guessing.
        var reliable = false
        if let memo = memos[query],
           memo.verifiedAt == revision,
           !memo.requiresExecution,
           !frame.reads.values.contains(where: { $0.requiresExecution }) {
            reliable = frame.resolution != nil
                || (!frame.validationFailed && query.valuesEqual(memo.observedValue, observedValue))
        }
        if context.isValidationRead {
            if !reliable {
                frames[parent]?.validationFailed = true
            }
        } else if reliable {
            frames[parent]?.reads[id]?.requiresExecution = false
        }
    }

    /// Compares what callers observe, including outer transformations and caught failures.
    private func revisionOfChange(
        _ query: AnyQuery,
        value: any Sendable,
        previous: Memo?
    ) -> UInt64 {
        if let previous, query.valuesEqual(previous.observedValue, value) {
            return previous.changedAt
        }
        return revision
    }

    /// Combines cached computation reads with current hook reads without accumulating duplicates.
    private func mergingReads(_ previous: [Read], _ current: [Read]) -> [Read] {
        var reads: [AnyQuery: Read] = [:]
        for read in previous + current {
            if var existing = reads[read.query] {
                existing.requiresExecution = existing.requiresExecution || read.requiresExecution
                reads[read.query] = existing
            } else {
                reads[read.query] = read
            }
        }
        return reads.values.sorted { $0.order < $1.order }
    }

    public func endEvaluation(context: ExecutionContext) async {
        frames.removeValue(forKey: context.invocationID!)
    }

    // Internal diagnostics for tests; memo values and dependency records stay private.
    func memoRevisions(for key: AnyQuery) -> (verifiedAt: UInt64, changedAt: UInt64)? {
        guard let memo = memos[key] else {
            return nil
        }
        return (memo.verifiedAt, memo.changedAt)
    }
}
