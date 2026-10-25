import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct ShortCircuitFallbackTests {
    struct Child: Query {
        /// Counts computation independently of the interceptor's fallback.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("shortCircuitChild")
            return 17
        }
    }

    struct Parent: Query {
        /// Identifies the child and records enclosing body executions.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("shortCircuitParent")
            return try await engine.fetch(Child(state: state), with: context)
        }
    }

    actor ShortCircuitingOuterRead: DeduplicatingInterceptor {
        /// Identifies the query that may return a fallback before memoization.
        let state: GraphState

        /// Whether cancellation prevents the nested fetch from entering the engine at all.
        let checkCancellationBeforeFetch: Bool

        /// Pauses the next independent child before it enters the engine.
        private var nextGate: TestGate?

        /// The independently cancellable read currently awaited by the interceptor.
        private var child: Task<Int, any Error>?

        init(
            state: GraphState,
            checkCancellationBeforeFetch: Bool = false
        ) {
            self.state = state
            self.checkCancellationBeforeFetch = checkCancellationBeforeFetch
        }

        func blockNextChild(at gate: TestGate) {
            nextGate = gate
        }

        func cancelChild() {
            child?.cancel()
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            guard query == AnyQuery(Child(state: state)), let gate = nextGate else {
                return try await next()
            }
            nextGate = nil
            let task = Task {
                await gate.wait()
                if checkCancellationBeforeFetch {
                    try Task.checkCancellation()
                }
                return try await engine.fetch(Input(state: state), with: context)
            }
            child = task
            defer {
                child = nil
            }
            do {
                _ = try await task.value
            } catch is CancellationError {
                // The inner memoizer never receives this invocation's resolution.
                return -1
            }
            return try await next()
        }
    }

    @Test(
        "A short-circuit fallback cannot borrow proof from another invocation's memo",
        arguments: [false, true]
    )
    func cancelledReadBeforeResolution(checkBeforeFetch: Bool) async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let outer = ShortCircuitingOuterRead(
            state: state,
            checkCancellationBeforeFetch: checkBeforeFetch
        )
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: outer)
        )
        let child = Child(state: state)
        let parent = Parent(state: state)

        // An earlier successful fetch leaves a current memo for the same child key.
        #expect(try await engine.fetch(child, with: .root) == 17)
        let gate = TestGate()
        await outer.blockNextChild(at: gate)
        let fallback = Task {
            try await engine.fetch(parent, with: .root)
        }
        await gate.waitForArrivals()
        await outer.cancelChild()
        await gate.release()
        #expect(try await fallback.value == -1)
        #expect(await state.count("shortCircuitParent") == 1)
        #expect(await state.count("shortCircuitChild") == 1)

        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}

        // The fallback's failed read requires the parent to try its ordinary body again.
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("shortCircuitParent") == 2)
        #expect(await state.count("shortCircuitChild") == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(child))?.changedAt == 1)
    }

    @Test(
        "Validation cannot borrow a current memo after this invocation returns a fallback",
        arguments: [false, true]
    )
    func cancelledValidationBeforeResolution(checkBeforeFetch: Bool) async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let outer = ShortCircuitingOuterRead(
            state: state,
            checkCancellationBeforeFetch: checkBeforeFetch
        )
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: outer)
        )
        let child = Child(state: state)
        let parent = Parent(state: state)
        #expect(try await engine.fetch(parent, with: .root) == 17)
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}
        // Another invocation proves the child unchanged before parent validation starts.
        #expect(try await engine.fetch(child, with: .root) == 17)
        #expect(await incremental.memoRevisions(for: AnyQuery(child))?.verifiedAt == 2)

        let gate = TestGate()
        await outer.blockNextChild(at: gate)
        let validation = Task {
            try await engine.fetch(parent, with: .root)
        }
        await gate.waitForArrivals()
        await outer.cancelChild()
        await gate.release()

        // The replay returns -1 without reaching red-green, despite its earlier current memo.
        // Executing the parent retries the ordinary read and recovers to 17.
        #expect(try await validation.value == 17)
        #expect(await state.count("shortCircuitParent") == 2)
        #expect(await state.count("shortCircuitChild") == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(parent))?.changedAt == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(parent))?.verifiedAt == 2)
    }
}
