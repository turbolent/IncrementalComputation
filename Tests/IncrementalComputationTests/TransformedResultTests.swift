import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct TransformedResultTests {
    struct Constant: Query {
        /// Records body executions and supplies the outer hook's input.
        let state: GraphState

        /// Holds the body while another caller joins its flight.
        var gate: TestGate? = nil

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("constant")
            if let gate {
                await gate.wait()
            }
            return 17
        }
    }

    struct Consumer: Query {
        /// The query whose final, transformed result this consumer observes.
        let source: Constant

        /// Separates consumers that share the same source.
        var id = 0

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await source.state.record("consumer:\(id)")
            return try await engine.fetch(source, with: context)
        }
    }

    actor AddingInput: DeduplicatingInterceptor {
        /// Identifies the query whose result receives the extra input.
        let source: Constant

        /// Shares resolution when testing a wrapper around the built-in deduplicator.
        let flight: InFlightInterceptor?

        init(source: Constant, flight: InFlightInterceptor? = nil) {
            self.source = source
            self.flight = flight
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            try await flight?.beginEvaluation(query: query, context: context)
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            let value: any Sendable
            if let flight {
                value = try await flight.intercept(
                    query: query,
                    context: context,
                    engine: engine,
                    next: next
                )
            } else {
                value = try await next()
            }
            guard query == AnyQuery(source) else {
                return value
            }
            let input = try await engine.fetch(Input(state: source.state), with: context)
            return (value as! Int) + input
        }

        func didResolve(
            query: AnyQuery,
            result: QueryResult,
            context: ExecutionContext
        ) async {
            await flight?.didResolve(query: query, result: result, context: context)
        }

        func endEvaluation(context: ExecutionContext) async {
            await flight?.endEvaluation(context: context)
        }
    }

    @Test(
        "Backdating compares the final result without applying a transformation twice",
        arguments: [false, true]
    )
    func finalResultBackdating(deduplicate: Bool) async throws {
        let state = GraphState()
        let source = Constant(state: state)
        let consumer = Consumer(source: source)
        let input = Input(state: state)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: AddingInput(
                    source: source,
                    flight: deduplicate ? InFlightInterceptor() : nil
                ))
        )

        #expect(try await engine.fetch(consumer, with: .root) == 19)
        // A memo hit must return the inner 17 to the outer hook, which adds 2 once.
        #expect(try await engine.fetch(source, with: .root) == 19)
        #expect(try await engine.fetch(consumer, with: .root) == 19)
        #expect(await state.count("constant") == 1)
        #expect(await state.count("consumer:0") == 1)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        // The inner result is still 17, but consumers now observe 21.
        #expect(try await engine.fetch(consumer, with: .root) == 21)
        #expect(try await engine.fetch(source, with: .root) == 21)
        #expect(await state.count("constant") == 2)
        #expect(await state.count("consumer:0") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(source))?.changedAt == 2)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(consumer, with: .root) == 21)
        #expect(await state.count("constant") == 2)
        #expect(await state.count("consumer:0") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(source))?.verifiedAt == 3)
        #expect(await incremental.memoRevisions(for: AnyQuery(source))?.changedAt == 2)

        try await incremental.update(invalidating: [AnyQuery(source)]) {}
        #expect(try await engine.fetch(consumer, with: .root) == 21)
        #expect(await state.count("constant") == 3)
        #expect(await state.count("consumer:0") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(source))?.changedAt == 2)
    }

    @Test("Concurrent callers each transform the shared inner result once")
    func sharedTransformedResult() async throws {
        let state = GraphState()
        let gate = TestGate()
        let source = Constant(state: state, gate: gate)
        let firstConsumer = Consumer(source: source, id: 1)
        let secondConsumer = Consumer(source: source, id: 2)
        let incremental = RedGreenInterceptor()
        let flight = InFlightInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: AddingInput(source: source, flight: flight))
        )

        let first = Task {
            try await engine.fetch(firstConsumer, with: .root)
        }
        await gate.waitForArrivals()
        let second = Task {
            try await engine.fetch(secondConsumer, with: .root)
        }
        while await flight.waiterCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        await gate.release()
        #expect(try await first.value == 19)
        #expect(try await second.value == 19)
        #expect(await state.count("constant") == 1)
        #expect(await state.count("consumer:1") == 1)
        #expect(await state.count("consumer:2") == 1)
        #expect(await flight.waiterCount == 0)

        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(firstConsumer, with: .root) == 21)
        #expect(try await engine.fetch(secondConsumer, with: .root) == 21)
        #expect(await state.count("constant") == 2)
        #expect(await state.count("consumer:1") == 2)
        #expect(await state.count("consumer:2") == 2)
    }
}
