import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct InFlightLifecycleTests {
    struct Parent: Query {
        let gate: TestGate

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            try await engine.fetch(Child(gate: gate), with: context)
        }
    }

    struct Child: Query {
        let gate: TestGate

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            1
        }
    }

    struct ConcurrentRoot: Query {
        let gate: TestGate

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await gate.wait()
            return try await engine.fetch(Parent(gate: gate), with: context)
        }
    }

    actor ReentrantObserver: QueryObserver {
        let gate: TestGate

        private weak var engine: ComposedEngine?

        init(gate: TestGate) {
            self.gate = gate
        }

        func install(_ engine: ComposedEngine) {
            self.engine = engine
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            guard query == AnyQuery(Child(gate: gate)), let engine else {
                return
            }
            _ = try await engine.fetch(ConcurrentRoot(gate: gate), with: context)
        }
    }

    actor ReentrantMemoizer: MemoizingInterceptor {
        let duringAdmission: Bool

        let gate: TestGate

        private let cache = CacheInterceptor()

        private weak var engine: ComposedEngine?

        private(set) var caughtCycle = false

        init(duringAdmission: Bool, gate: TestGate) {
            self.duringAdmission = duringAdmission
            self.gate = gate
        }

        func install(_ engine: ComposedEngine) {
            self.engine = engine
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            try await cache.beginEvaluation(query: query, context: context)
            if duringAdmission {
                try await fetchRoot(context: context)
            }
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            try await cache.intercept(
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
            await cache.didResolve(query: query, result: result, context: context)
        }

        func endEvaluation(context: ExecutionContext) async {
            await cache.endEvaluation(context: context)
            guard !duringAdmission else {
                return
            }
            do {
                try await fetchRoot(context: context)
            } catch is CyclicDependencyError {
                caughtCycle = true
            } catch {
                Issue.record("Unexpected cleanup error: \(error)")
            }
        }

        private func fetchRoot(context: ExecutionContext) async throws {
            guard context.parentQuery == AnyQuery(Child(gate: gate)), let engine else {
                return
            }
            _ = try await engine.fetch(ConcurrentRoot(gate: gate), with: context)
        }
    }

    private func result<Q: Query>(
        of query: Q,
        with engine: ComposedEngine
    ) async -> Result<Q.Value, any Error> {
        do {
            return .success(try await engine.fetch(query, with: .root))
        } catch {
            return .failure(error)
        }
    }

    @Test("Wait cycles include reentrant observation")
    func reentrantCycle() async throws {
        let gate = TestGate()
        let flight = InFlightInterceptor()
        let observer = ReentrantObserver(gate: gate)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(observer)
                .deduplicating(with: flight)
        )
        await observer.install(engine)

        try await checkCycle(
            with: engine,
            gate: gate,
            flight: flight,
            parentFails: true
        )
    }

    @Test(
        "Wait cycles include reentrant admission and final cleanup hooks",
        arguments: [true, false]
    )
    func evaluationHookCycle(duringAdmission: Bool) async throws {
        let gate = TestGate()
        let flight = InFlightInterceptor()
        let memoizer = ReentrantMemoizer(duringAdmission: duringAdmission, gate: gate)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: memoizer)
                .deduplicating(with: flight)
        )
        await memoizer.install(engine)

        try await checkCycle(
            with: engine,
            gate: gate,
            flight: flight,
            parentFails: duringAdmission
        )
        #expect(await memoizer.caughtCycle == !duringAdmission)
    }

    @Test("Producer completion removes wait edges before resumed callers run")
    func completedWaitEdges() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let flight = InFlightInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain().deduplicating(with: flight)
        )
        let input = Input(state: state)

        async let producer = result(of: input, with: engine)
        await gate.waitForArrivals()
        async let parent = result(
            of: InterceptorLifecycleTests.Mirror(state: state, id: 1),
            with: engine
        )
        do {
            while await flight.waiterCount == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            await gate.release()
            throw error
        }

        await finishBeforeWaitersResume(flight, key: AnyQuery(input))
        await gate.release()
        let produced = await producer
        let parentResult = await parent
        #expect(try produced.get() == 2)
        #expect(try parentResult.get() == 3)
        #expect(await flight.waitGraphEdgeCount == 0)
    }

    private func finishBeforeWaitersResume(
        _ flight: isolated InFlightInterceptor,
        key: AnyQuery
    ) {
        #expect(flight.waitGraphEdgeCount == 2)
        // Both calls run in one actor turn, so waiter defers cannot hide stale edges.
        flight.finish(key: key, result: .success(2))
        #expect(flight.waiterCount == 0)
        #expect(flight.waitGraphEdgeCount == 0)
    }

    private func checkCycle(
        with engine: ComposedEngine,
        gate: TestGate,
        flight: InFlightInterceptor,
        parentFails: Bool
    ) async throws {
        async let concurrent = result(of: ConcurrentRoot(gate: gate), with: engine)
        await gate.waitForArrivals()
        async let parent = result(of: Parent(gate: gate), with: engine)

        // The child's hook joins the running root before that root fetches
        // the parent, closing Parent -> Child -> ConcurrentRoot -> Parent.
        do {
            while await flight.waiterCount == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        switch await concurrent {
        case .failure(let error):
            #expect(error is CyclicDependencyError)
        case .success:
            Issue.record("The concurrent root should reject the wait cycle")
        }
        switch await parent {
        case .failure(let error):
            #expect(parentFails)
            #expect(error is CyclicDependencyError)
        case .success(let value):
            #expect(!parentFails)
            #expect(value == 1)
        }
        #expect(await flight.waiterCount == 0)
    }
}
