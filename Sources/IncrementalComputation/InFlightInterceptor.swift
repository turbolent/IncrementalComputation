import Foundation
import HashTreeCollections

/// Deduplicates concurrent fetches of the same query.
/// Shares concurrent resolutions, including errors, without caching sequential calls.
/// Add it after memoization so it wraps the memoizing interceptor.
public actor InFlightInterceptor: DeduplicatingInterceptor {
    /// An in-flight computation and the continuations waiting for its result.
    private struct Flight {
        /// Invocation resolving this query on behalf of all waiting callers.
        let producer: UUID

        /// This interceptor's result, held until the full fetch has resolved.
        /// Share this value so outer wrappers apply their transformations once per caller.
        var result: QueryResult?

        /// Suspended callers by invocation ID, removed when resumed or cancelled.
        var waiters: [UUID: Waiter] = [:]
    }

    private struct Waiter {
        /// Ancestor invocations blocked by this caller, used to remove their wait edges.
        let ancestors: TreeSet<UUID>

        /// Resumes this caller with the producer's result or the caller's cancellation error.
        let continuation: CheckedContinuation<any Sendable, any Error>
    }

    /// Queries currently being resolved and the invocation producing each result.
    private var flights: [AnyQuery: Flight] = [:]

    /// Wait graph: blocked invocation -> invocations it awaits.
    /// Detects cycles between independent roots that execution ancestry alone cannot reveal.
    /// A caller joining a flight blocks all its ancestors until it completes.
    /// Connect those ancestors to the waiter, then the waiter to its producer.
    /// This includes observation and completion callbacks without tracking
    /// separate admission or completion events.
    private var waits: [UUID: Set<UUID>] = [:]

    public init() {
    }

    public func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
        // Reject recursion before an observation hook can fetch the same query again.
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
        // Also protect wrappers that delegate resolution directly.
        guard !context.ancestors.contains(query) else {
            throw CyclicDependencyError()
        }
        let id = context.invocationID!
        // Check whether another invocation is already resolving this query.
        if let existing = flights[query] {
            let producer = existing.producer
            for ancestor in context.ancestorInvocationIDs {
                waits[ancestor, default: []].insert(id)
            }
            defer {
                removeWaiterEdges(
                    id,
                    ancestors: context.ancestorInvocationIDs,
                    producer: producer
                )
            }
            // Reject an edge that would close a cycle before suspending its caller.
            guard !reaches(producer, target: id) else {
                throw CyclicDependencyError()
            }
            waits[id, default: []].insert(producer)
            // Register this caller's continuation and wait for the existing producer.
            // Cancelling this waiter must not cancel the producer or other waiters.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        removeWaiterEdges(
                            id,
                            ancestors: context.ancestorInvocationIDs,
                            producer: producer
                        )
                        continuation.resume(throwing: CancellationError())
                    } else {
                        flights[query]?.waiters[id] = Waiter(
                            ancestors: context.ancestorInvocationIDs,
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        key: query,
                        producer: producer,
                        waiter: id
                    )
                }
            }
        }

        // Register the producer before resolution can suspend.
        flights[query] = Flight(producer: id)
        do {
            let value = try await next()
            try Task.checkCancellation()
            flights[query]?.result = .success(value)
            return value
        } catch {
            flights[query]?.result = .failure(error)
            throw error
        }
    }

    public func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async {
        guard let flight = flights[query], flight.producer == context.invocationID else {
            return
        }
        // Inner memoizers have committed before waiting callers resume.
        // An outer failure rejects the producer and its waiters without publishing a memo.
        switch result {
        case .success:
            finish(key: query, result: flight.result ?? result)
        case .failure:
            finish(key: query, result: result)
        }
    }

    /// Removes the completed flight and resumes every waiter with its value or error.
    // Internal so tests can inspect cleanup before the resumed waiters run.
    func finish(key: AnyQuery, result: QueryResult) {
        guard let flight = flights.removeValue(forKey: key) else {
            return
        }
        for (id, waiter) in flight.waiters {
            // Resumed callers are runnable even before their intercept hooks return.
            // Remove their edges now so completion hooks cannot see a stale cycle.
            removeWaiterEdges(
                id,
                ancestors: waiter.ancestors,
                producer: flight.producer
            )
            waiter.continuation.resume(with: result)
        }
    }

    private func cancelWaiter(
        key: AnyQuery,
        producer: UUID,
        waiter: UUID
    ) {
        // A delayed cancellation must not affect a subsequent flight for the same key.
        guard flights[key]?.producer == producer else {
            return
        }
        guard let cancelled = flights[key]?.waiters.removeValue(forKey: waiter) else {
            return
        }
        removeWaiterEdges(
            waiter,
            ancestors: cancelled.ancestors,
            producer: producer
        )
        cancelled.continuation.resume(throwing: CancellationError())
    }

    private func removeWaiterEdges(
        _ id: UUID,
        ancestors: TreeSet<UUID>,
        producer: UUID
    ) {
        for ancestor in ancestors {
            removeWait(from: ancestor, to: id)
        }
        removeWait(from: id, to: producer)
    }

    private func removeWait(from: UUID, to: UUID) {
        waits[from]?.remove(to)
        if waits[from]?.isEmpty == true {
            waits.removeValue(forKey: from)
        }
    }

    private func reaches(_ start: UUID, target: UUID) -> Bool {
        var pending = [start]
        var visited: Set<UUID> = []
        while let current = pending.popLast() {
            if current == target {
                return true
            }
            if visited.insert(current).inserted, let next = waits[current] {
                pending.append(contentsOf: next)
            }
        }
        return false
    }

    /// Number of callers waiting across all flights.
    /// Lets tests wait for registration without relying on scheduler timing.
    var waiterCount: Int {
        flights.values.reduce(0) {
            $0 + $1.waiters.count
        }
    }

    /// Number of edges remaining in the wait graph.
    /// Tests inspect this in the same actor turn as completion, before waiter cleanup.
    var waitGraphEdgeCount: Int {
        waits.values.reduce(0) {
            $0 + $1.count
        }
    }
}
