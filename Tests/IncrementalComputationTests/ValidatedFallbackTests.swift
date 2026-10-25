import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct ValidatedFallbackTests {
    struct Constant: Query {
        /// Stores execution counts without affecting the result.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("constant")
            return 17
        }
    }

    struct Parent: Query {
        /// Identifies the input graph and records body executions.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("parent")
            return try await engine.fetch(Constant(state: state), with: context)
        }
    }

    actor CancellableOuterRead: DeduplicatingInterceptor {
        /// Identifies the query whose result includes the outer dependency.
        let state: GraphState

        /// The value returned when an independent child is cancelled.
        let fallbackValue: Int

        /// Pauses one child before fetching, allowing cancellation without cancelling its parent.
        private var nextGate: TestGate?

        /// The independently cancellable child currently awaited by the outer hook.
        private var child: Task<Int, any Error>?

        /// Final outer results, including a fallback returned during validation.
        private(set) var observed: [Int] = []

        init(state: GraphState, fallbackValue: Int = -1) {
            self.state = state
            self.fallbackValue = fallbackValue
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
            let value = try await next() as! Int
            guard query == AnyQuery(Constant(state: state)) else {
                return value
            }
            let gate = nextGate
            nextGate = nil
            let task = Task {
                if let gate {
                    await gate.wait()
                }
                return try await engine.fetch(Input(state: state), with: context)
            }
            child = task
            defer {
                child = nil
            }
            let result: Int
            do {
                result = value + (try await task.value)
            } catch is CancellationError {
                result = fallbackValue
            }
            observed.append(result)
            return result
        }
    }

    @Test("A caught outer child cancellation invalidates proof from reused inner dependencies")
    func cancelledOuterRead() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let outer = CancellableOuterRead(state: state)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: outer)
        )
        let parent = Parent(state: state)
        #expect(try await engine.fetch(parent, with: .root) == 19)
        #expect(await state.count("parent") == 1)
        #expect(await state.count("constant") == 1)

        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}
        let gate = TestGate()
        await outer.blockNextChild(at: gate)
        let validation = Task {
            try await engine.fetch(parent, with: .root)
        }
        // The inner value validates unchanged before the outer read is cancelled.
        await gate.waitForArrivals()
        await outer.cancelChild()
        await gate.release()

        // Validation sees -1, so the parent executes and performs its normal read again.
        #expect(try await validation.value == 19)
        #expect(await outer.observed == [19, -1, 19])
        #expect(await state.count("parent") == 2)
        #expect(await state.count("constant") == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(Constant(state: state)))?.changedAt == 2)

        // The child and its consumer retry until successful execution replaces the failed read.
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}
        #expect(try await engine.fetch(parent, with: .root) == 19)
        #expect(await state.count("constant") == 2)
        #expect(await state.count("parent") == 3)
    }

    @Test("Recovery within a revision cannot hide an earlier fallback from consumers")
    func recoveryBeforeNextRevision() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let outer = CancellableOuterRead(state: state)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: outer)
        )
        let source = Constant(state: state)
        let parent = Parent(state: state)
        #expect(try await engine.fetch(source, with: .root) == 19)
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}

        let gate = TestGate()
        await outer.blockNextChild(at: gate)
        let fallback = Task {
            try await engine.fetch(parent, with: .root)
        }
        await gate.waitForArrivals()
        await outer.cancelChild()
        await gate.release()
        #expect(try await fallback.value == -1)
        #expect(await state.count("parent") == 1)

        // A later memo hit recovers, while the consumer still holds the earlier fallback.
        #expect(try await engine.fetch(source, with: .root) == 19)
        #expect(await state.count("constant") == 1)
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}

        // The recovered child can backdate, but the consumer must retry its uncertain read.
        #expect(try await engine.fetch(parent, with: .root) == 19)
        #expect(await state.count("parent") == 2)
        #expect(await state.count("constant") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(source))?.changedAt == 2)
    }

    @Test("An equal fallback does not establish that its consumer is unchanged")
    func equalFallbackDuringValidation() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let outer = CancellableOuterRead(state: state, fallbackValue: 19)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: outer)
        )
        let parent = Parent(state: state)
        #expect(try await engine.fetch(parent, with: .root) == 19)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }

        let gate = TestGate()
        await outer.blockNextChild(at: gate)
        let validation = Task {
            try await engine.fetch(parent, with: .root)
        }
        await gate.waitForArrivals()
        await outer.cancelChild()
        await gate.release()

        // Validation receives the old value 19, but a failed read makes that proof uncertain.
        // Executing the consumer gives its ordinary read a chance to recover to 21.
        #expect(try await validation.value == 21)
        #expect(await outer.observed == [19, 19, 21])
        #expect(await state.count("parent") == 2)
        #expect(await state.count("constant") == 2)

        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}
        #expect(try await engine.fetch(parent, with: .root) == 21)
        #expect(await state.count("parent") == 3)
        #expect(await state.count("constant") == 3)
    }
}
