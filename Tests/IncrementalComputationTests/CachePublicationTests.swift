import Testing
import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct CachePublicationTests {
    actor OuterInterceptor: DeduplicatingInterceptor {
        /// Holds the first result after the cache has seen it.
        let gate: TestGate?

        /// Whether the gated call fails after the inner computation succeeds.
        let fail: Bool

        /// A transformation applied outside the cache on every successful fetch.
        let increment: Int

        /// Lets later calls proceed while the first result remains pending.
        private var first = true

        init(
            gate: TestGate? = nil,
            fail: Bool = false,
            increment: Int = 0
        ) {
            self.gate = gate
            self.fail = fail
            self.increment = increment
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            let value = try await next() as! Int
            if first, let gate {
                first = false
                await gate.wait()
                if fail {
                    throw TestFailure.expected
                }
            }
            return value + increment
        }
    }

    @Test(
        "Outer failure or cancellation discards an unpublished cache result",
        arguments: [false, true]
    )
    func failedPublication(cancel: Bool) async throws {
        let state = GraphState()
        let gate = TestGate()
        let cache = CacheInterceptor()
        let outer = OuterInterceptor(gate: gate, fail: !cancel)
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .deduplicating(with: outer)
        )
        let input = Input(state: state)
        let first = Task {
            try await engine.fetch(input, with: .root)
        }
        await gate.waitForArrivals()
        #expect(await state.count("input:number") == 1)
        #expect(!(await cache.isCached(query: input)))
        if cancel {
            first.cancel()
        }
        await gate.release()
        if cancel {
            await #expect(throws: CancellationError.self) {
                try await first.value
            }
        } else {
            await #expect(throws: TestFailure.self) {
                try await first.value
            }
        }
        #expect(!(await cache.isCached(query: input)))
        #expect(try await engine.fetch(input, with: .root) == 2)
        #expect(try await engine.fetch(input, with: .root) == 2)
        #expect(await state.count("input:number") == 2)
    }

    @Test("A failed duplicate leaves another invocation's committed cache entry intact")
    func concurrentPublication() async throws {
        let state = GraphState()
        let gate = TestGate()
        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .deduplicating(with: OuterInterceptor(gate: gate, fail: true))
        )
        let input = Input(state: state)
        let first = Task {
            try await engine.fetch(input, with: .root)
        }
        await gate.waitForArrivals()
        #expect(try await engine.fetch(input, with: .root) == 2)
        #expect(await cache.isCached(query: input))
        #expect(await state.count("input:number") == 2)
        await gate.release()
        await #expect(throws: TestFailure.self) {
            try await first.value
        }
        #expect(await cache.isCached(query: input))
        #expect(try await engine.fetch(input, with: .root) == 2)
        #expect(await state.count("input:number") == 2)
    }

    @Test("Plain caching preserves the inner value beneath an outer transformation")
    func transformedPublication() async throws {
        let state = GraphState()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
                .deduplicating(with: OuterInterceptor(increment: 1))
        )
        let input = Input(state: state)
        #expect(try await engine.fetch(input, with: .root) == 3)
        #expect(try await engine.fetch(input, with: .root) == 3)
        #expect(await state.count("input:number") == 1)
    }
}
