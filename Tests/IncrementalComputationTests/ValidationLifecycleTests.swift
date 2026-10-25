import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct ValidationLifecycleTests {
    actor ValidationLog: QueryObserver {
        private(set) var keys: [AnyQuery] = []
        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) {
            if context.isValidationRead {
                keys.append(query)
            }
        }
    }

    struct ParallelPair: Query {
        let state: GraphState

        let gate: TestGate
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            async let first = engine.fetch(Input(state: state), with: context)
            // Wait for the first read to start, then finish the second before releasing it.
            await gate.waitForArrivals()
            let second = try await engine.fetch(Input(state: state, name: "right"), with: context)
            await gate.release()
            return try await first + second
        }
    }

    @Test("Dependency validation follows read start order, not completion order")
    func parallelReadOrder() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let incremental = RedGreenInterceptor()
        let log = ValidationLog()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(log)
                .memoizing(with: incremental)
        )
        let pair = ParallelPair(state: state, gate: gate)
        #expect(try await engine.fetch(pair, with: .root) == 9)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(pair, with: .root) == 11)
        #expect(await log.keys == [AnyQuery(Input(state: state))])
    }

    actor DelayingObserver: QueryObserver {
        let key: AnyQuery

        let gate: TestGate

        init(key: AnyQuery, gate: TestGate) {
            self.key = key
            self.gate = gate
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async {
            if query == key {
                await gate.wait()
            }
        }
    }

    @Test("Suspending observers cannot reorder dependency reads")
    func observationReadOrder() async throws {
        let state = GraphState()
        let gate = TestGate()
        let input = Input(state: state)
        let incremental = RedGreenInterceptor()
        let log = ValidationLog()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(DelayingObserver(key: AnyQuery(input), gate: gate))
                .observing(log)
                .memoizing(with: incremental)
        )
        let pair = ParallelPair(state: state, gate: gate)
        // The first fetch suspends in observation while the second completes.
        // Validation must keep start order.
        #expect(try await engine.fetch(pair, with: .root) == 9)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(pair, with: .root) == 11)
        #expect(await log.keys == [AnyQuery(input)])
    }

    actor DelayingMemoizer: MemoizingInterceptor {
        let incremental: RedGreenInterceptor

        let key: AnyQuery

        let gate: TestGate

        init(
            incremental: RedGreenInterceptor,
            key: AnyQuery,
            gate: TestGate
        ) {
            self.incremental = incremental
            self.key = key
            self.gate = gate
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            if query == key {
                await gate.wait()
            }
            try await incremental.beginEvaluation(query: query, context: context)
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            try await incremental.intercept(
                query: query,
                context: context,
                engine: engine,
                next: next
            )
        }

        func didResolve(
            query: AnyQuery,
            result: QueryResult,
            context: ExecutionContext
        ) async {
            await incremental.didResolve(
                query: query,
                result: result,
                context: context
            )
        }

        func endEvaluation(context: ExecutionContext) async {
            await incremental.endEvaluation(context: context)
        }
    }

    @Test("Suspending admission cannot reorder dependency reads")
    func admissionReadOrder() async throws {
        let state = GraphState()
        let gate = TestGate()
        let input = Input(state: state)
        let incremental = RedGreenInterceptor()
        let log = ValidationLog()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: DelayingMemoizer(
                    incremental: incremental,
                    key: AnyQuery(input),
                    gate: gate
                ))
                .observing(log)
        )
        let pair = ParallelPair(state: state, gate: gate)
        // The second read reaches red-green first while the first waits in admission.
        #expect(try await engine.fetch(pair, with: .root) == 9)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(pair, with: .root) == 11)
        #expect(await log.keys == [AnyQuery(input)])
    }

    @Test("Cancelling validation preserves the old unverified parent")
    func cancelledValidation() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let report = Report(state: state)
        _ = try await engine.fetch(report, with: .root)
        let gate = TestGate()
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 3)
            await state.gate("number", gate)
        }
        let task = Task {
            try await engine.fetch(report, with: .root)
        }
        await gate.waitForArrivals()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await incremental.memoRevisions(for: AnyQuery(report))?.verifiedAt == 1)
        #expect(await state.count("report") == 1)
        #expect(try await engine.fetch(report, with: .root) == "odd")
    }

    actor FailingObserver: QueryObserver {
        let key: AnyQuery

        private var enabled = true
        init(_ key: AnyQuery) {
            self.key = key
        }
        func disable() {
            enabled = false
        }
        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) throws {
            if enabled && query == key {
                throw TestFailure.expected
            }
        }
    }

    @Test("Observation failures remain dependencies")
    func caughtObservationFailure() async throws {
        let state = GraphState()
        let input = Input(state: state)
        let observer = FailingObserver(AnyQuery(input))
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(observer)
                .memoizing(with: incremental)
        )
        let fallback = Fallback(state: state)
        #expect(try await engine.fetch(fallback, with: .root) == -1)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await observer.disable()
        }
        #expect(try await engine.fetch(fallback, with: .root) == 2)
    }

    @Test("Stored replay requests do not retain their engine")
    func engineLifetime() async throws {
        let incremental = RedGreenInterceptor()
        weak var releasedEngine: ComposedEngine?
        do {
            let engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .memoizing(with: incremental)
            )
            releasedEngine = engine
            _ = try await engine.fetch(IncC(), with: .root)
        }
        #expect(releasedEngine == nil)
        #expect(await incremental.memoRevisions(for: AnyQuery(IncC())) != nil)
    }
}
