import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct InterceptorChainTests {
    actor EventLog {
        private(set) var events: [String] = []
        func record(_ event: String) {
            events.append(event)
        }
        func clear() {
            events.removeAll()
        }
    }

    actor Observer: QueryObserver {
        let name: String

        let log: EventLog

        init(_ name: String, log: EventLog) {
            self.name = name
            self.log = log
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async {
            await log.record(name + ".start")
        }
    }

    // Custom interceptors receive their lifecycle hooks without adopting QueryObserver.
    actor LoggedMemoizer: MemoizingInterceptor {
        let log: EventLog

        let rejectsEvaluation: Bool

        /// Memoizes the producer's committed result.
        private let cache = CacheInterceptor()

        init(log: EventLog, rejectsEvaluation: Bool = false) {
            self.log = log
            self.rejectsEvaluation = rejectsEvaluation
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            await log.record("memo.begin")
            if rejectsEvaluation {
                throw TestFailure.expected
            }
            try await cache.beginEvaluation(query: query, context: context)
        }

        func didResolve(
            query: AnyQuery,
            result: QueryResult,
            context: ExecutionContext
        ) async {
            await log.record("memo.commit")
            await cache.didResolve(query: query, result: result, context: context)
        }

        func endEvaluation(context: ExecutionContext) async {
            await log.record("memo.end")
            await cache.endEvaluation(context: context)
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            await log.record("memo.resolve")
            return try await cache.intercept(
                query: query,
                context: context,
                engine: engine,
                next: next
            )
        }
    }

    actor LoggedDeduplicator: DeduplicatingInterceptor {
        let log: EventLog

        let rejectsEvaluation: Bool

        private let flight = InFlightInterceptor()

        init(log: EventLog, rejectsEvaluation: Bool = false) {
            self.log = log
            self.rejectsEvaluation = rejectsEvaluation
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            await log.record("flight.begin")
            if rejectsEvaluation {
                throw TestFailure.expected
            }
            try await flight.beginEvaluation(query: query, context: context)
        }

        func didResolve(
            query: AnyQuery,
            result: QueryResult,
            context: ExecutionContext
        ) async {
            await log.record("flight.commit")
            await flight.didResolve(query: query, result: result, context: context)
        }

        func endEvaluation(context: ExecutionContext) async {
            await log.record("flight.end")
            await flight.endEvaluation(context: context)
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            await log.record("flight.resolve")
            return try await flight.intercept(
                query: query,
                context: context,
                engine: engine,
                next: next
            )
        }
    }

    @Test("Registration controls observations; wrapping controls resolution")
    func lifecycleOrder() async throws {
        let log = EventLog()
        let state = GraphState()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(Observer("first", log: log))
                .memoizing(with: LoggedMemoizer(log: log))
                .observing(Observer("middle", log: log))
                .deduplicating(with: LoggedDeduplicator(log: log))
                .observing(Observer("last", log: log))
        )

        // The same lifecycle occurs on a cold fetch and on a memo hit.
        for _ in 0..<2 {
            await log.clear()
            #expect(try await engine.fetch(Input(state: state), with: .root) == 2)
            #expect(await log.events == [
                "memo.begin", "flight.begin",
                "first.start", "middle.start", "last.start",
                "flight.resolve", "memo.resolve",
                "memo.commit", "flight.commit",
                "flight.end", "memo.end"
            ])
        }
        #expect(await state.count("input:number") == 1)
    }

    @Test("Extending a chain leaves the original configuration intact")
    func independentConfigurations() async throws {
        let state = GraphState()
        let tracker = TrackingInterceptor()
        let base = InterceptorChain().observing(tracker)
        let cached = ComposedEngine(interceptorChain: base.memoizing(with: CacheInterceptor()))
        let uncached = ComposedEngine(interceptorChain: base)
        for engine in [cached, uncached] {
            _ = try await engine.fetch(Input(state: state), with: .root)
            _ = try await engine.fetch(Input(state: state), with: .root)
        }
        #expect(await state.count("input:number") == 3)
        #expect(await tracker.count == 1)
    }

    @Test("Deduplication wraps plain caching for concurrent reads and cache hits")
    func cacheOrdering() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let cache = CacheInterceptor()
        let flight = InFlightInterceptor()
        let chain = InterceptorChain()
            .memoizing(with: cache)
            .deduplicating(with: flight)
        let engine = ComposedEngine(interceptorChain: chain)
        let first = Task {
            try await engine.fetch(Input(state: state), with: .root)
        }
        await gate.waitForArrivals()
        let second = Task {
            try await engine.fetch(Input(state: state), with: .root)
        }
        while await flight.waiterCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        await gate.release()
        #expect(try await first.value == 2)
        #expect(try await second.value == 2)
        #expect(try await engine.fetch(Input(state: state), with: .root) == 2)
        #expect(await state.count("input:number") == 1)
    }

    actor StartGate: QueryObserver {
        let gate: TestGate
        init(_ gate: TestGate) {
            self.gate = gate
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async {
            await gate.wait()
        }
    }

    @Test("Red-green admission precedes observers registered before the interceptor")
    func admissionBeforeObservation() async throws {
        let state = GraphState()
        let gate = TestGate()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(StartGate(gate))
                .memoizing(with: incremental)
        )
        let task = Task {
            try await engine.fetch(Input(state: state), with: .root)
        }
        await gate.waitForArrivals()
        await #expect(throws: RevisionUpdateError.evaluationsActive) {
            try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
                await state.record("mutation")
            }
        }
        #expect(await state.count("mutation") == 0)
        await gate.release()
        #expect(try await task.value == 2)
    }

    @Test(
        "Throwing admission registers every attempt and skips observation",
        arguments: [false, true]
    )
    func rejectedAdmission(memoRejects: Bool) async throws {
        let log = EventLog()
        let state = GraphState()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(Observer("first", log: log))
                .memoizing(with: LoggedMemoizer(log: log, rejectsEvaluation: memoRejects))
                .deduplicating(with: LoggedDeduplicator(
                    log: log,
                    rejectsEvaluation: !memoRejects
                ))
        )
        await #expect(throws: TestFailure.self) {
            try await engine.fetch(Input(state: state), with: .root)
        }
        #expect(await state.count("input:number") == 0)
        #expect(await log.events == [
            "memo.begin", "flight.begin",
            "memo.commit", "flight.commit",
            "flight.end", "memo.end"
        ])
    }

    @Test("Evaluation cleanup follows observation failure")
    func observationFailureCleanup() async throws {
        let log = EventLog()
        let rejectingObserver = InterceptorLifecycleTests.Observer(throwsOnStart: true)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(rejectingObserver)
                .memoizing(with: LoggedMemoizer(log: log))
                .deduplicating(with: LoggedDeduplicator(log: log))
        )
        await #expect(throws: TestFailure.self) {
            try await engine.fetch(IncA(), with: .root)
        }
        #expect(await rejectingObserver.count == 1)
        #expect(await log.events == [
            "memo.begin", "flight.begin",
            "memo.commit", "flight.commit",
            "flight.end", "memo.end"
        ])
    }

    @Test(
        "Evaluation cleanup follows resolution failure and cancellation",
        arguments: [false, true]
    )
    func resolutionFailureCleanup(cancel: Bool) async throws {
        let log = EventLog()
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        await state.fail("number", !cancel)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(Observer("first", log: log))
                .memoizing(with: LoggedMemoizer(log: log))
                .deduplicating(with: LoggedDeduplicator(log: log))
        )
        let task = Task {
            try await engine.fetch(Input(state: state), with: .root)
        }
        await gate.waitForArrivals()
        if cancel {
            task.cancel()
        }
        await gate.release()
        if cancel {
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
        } else {
            await #expect(throws: TestFailure.self) {
                try await task.value
            }
        }
        #expect(await log.events == [
            "memo.begin", "flight.begin", "first.start",
            "flight.resolve", "memo.resolve",
            "memo.commit", "flight.commit",
            "flight.end", "memo.end"
        ])
    }
}
