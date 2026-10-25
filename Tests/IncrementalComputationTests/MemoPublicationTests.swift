import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct MemoPublicationTests {
    actor DuplicateStore: Hashable {
        /// Holds the first computation until the second has also started.
        let first = TestGate()

        /// Holds the second computation until the first fetch has committed.
        let second = TestGate()

        /// Number of query bodies entered, including failed duplicate fetches.
        private(set) var executions = 0

        nonisolated static func == (lhs: DuplicateStore, rhs: DuplicateStore) -> Bool {
            lhs === rhs
        }

        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        func read() async -> Int {
            executions += 1
            switch executions {
            case 1:
                await first.wait()
            case 2:
                await second.wait()
            default:
                break
            }
            return 2
        }
    }

    struct DuplicateQuery: Query {
        /// Supplies a fixed value through separately controlled executions.
        let store: DuplicateStore

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await store.read()
        }
    }

    actor RejectSecondResolution: DeduplicatingInterceptor {
        /// Holds the second fetch after its inner resolution has returned.
        let rejection = TestGate()

        /// Assigns each invocation its role before its first suspension.
        private var attempts = 0

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            attempts += 1
            let attempt = attempts
            let value = try await next()
            if attempt == 2 {
                await rejection.wait()
                try Task.checkCancellation()
                throw TestFailure.expected
            }
            return value
        }
    }

    @Test(
        "A failed duplicate preserves a memo committed by another invocation",
        arguments: [false, true]
    )
    func failedDuplicatePreservesCommittedMemo(cancel: Bool) async throws {
        let store = DuplicateStore()
        let query = DuplicateQuery(store: store)
        let incremental = RedGreenInterceptor()
        let rejecting = RejectSecondResolution()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: rejecting)
        )

        let first = Task {
            try await engine.fetch(query, with: .root)
        }
        await store.first.waitForArrivals()
        let second = Task {
            try await engine.fetch(query, with: .root)
        }
        await store.second.waitForArrivals()

        // Both executions began without a memo, but only the first fetch succeeds.
        await store.first.release()
        #expect(try await first.value == 2)
        await store.second.release()
        await rejecting.rejection.waitForArrivals()
        if cancel {
            second.cancel()
        }
        await rejecting.rejection.release()

        if cancel {
            await #expect(throws: CancellationError.self) {
                try await second.value
            }
        } else {
            await #expect(throws: TestFailure.self) {
                try await second.value
            }
        }

        // The successful first result remains cached after its duplicate fails.
        #expect(await incremental.memoRevisions(for: AnyQuery(query))?.verifiedAt == 1)
        #expect(try await engine.fetch(query, with: .root) == 2)
        #expect(await store.executions == 2)
        try await incremental.update(invalidating: [AnyQuery(query)]) {}
    }
}
