import Foundation
import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct InterceptorLifecycleTests {
    struct Mirror: Query {
        let state: GraphState

        let id: Int
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            try await engine.fetch(Input(state: state), with: context) + id
        }
    }

    @Test(
        "Cache-hit edges survive shared reads and repeated invalidation",
        arguments: [false, true]
    )
    func cachedReads(reverseFirst: Bool) async throws {
        let state = GraphState()
        let cache = CacheInterceptor()
        let reverse = ReverseDepsInterceptor()
        let chain = reverseFirst
            ? InterceptorChain().observing(reverse).memoizing(with: cache)
            : InterceptorChain().memoizing(with: cache).observing(reverse)
        let engine = ComposedEngine(interceptorChain: chain)
        let input = Input(state: state)
        for value in [2, 4, 5] {
            await state.set("number", value)
            for key in await reverse.invalidate(query: input) {
                await cache.clear(query: key)
            }
            _ = try await engine.fetch(input, with: .root)
            #expect(try await engine.fetch(Mirror(state: state, id: 1), with: .root) == value + 1)
            #expect(try await engine.fetch(Mirror(state: state, id: 2), with: .root) == value + 2)
            let dependents = await reverse.directDependents(of: input)
            #expect(dependents == [
                AnyQuery(Mirror(state: state, id: 1)),
                AnyQuery(Mirror(state: state, id: 2))
            ])
        }
    }

    actor Observer: QueryObserver {
        var starts: [UUID] = []

        let throwsOnStart: Bool
        init(throwsOnStart: Bool = false) {
            self.throwsOnStart = throwsOnStart
        }
        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) throws {
            starts.append(context.invocationID!)
            if throwsOnStart {
                throw TestFailure.expected
            }
        }
        var count: Int {
            starts.count
        }
    }

    @Test("Observers see cache hits and run after a throwing observation")
    func observations() async throws {
        let observer = Observer()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
                .observing(observer)
        )
        _ = try await engine.fetch(IncA(), with: .root)
        _ = try await engine.fetch(IncA(), with: .root)
        #expect(await observer.count == 2)

        let throwing = Observer(throwsOnStart: true)
        let after = Observer()
        let failingEngine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(throwing)
                .observing(after)
        )
        await #expect(throws: TestFailure.self) {
            try await failingEngine.fetch(IncA(), with: .root)
        }
        #expect(await throwing.count == 1)
        #expect(await after.count == 1)
    }

    actor CompletionGate: DeduplicatingInterceptor {
        let gate: TestGate
        init(_ gate: TestGate) {
            self.gate = gate
        }
        func endEvaluation(context: ExecutionContext) async {
            if context.callerQuery == nil {
                await gate.wait()
            }
        }
    }

    @Test("Revision admission spans all completion callbacks")
    func completionAdmission() async throws {
        let gate = TestGate()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: CompletionGate(gate))
        )
        let task = Task {
            try await engine.fetch(IncA(), with: .root)
        }
        await gate.waitForArrivals()
        await #expect(throws: RevisionUpdateError.evaluationsActive) {
            try await incremental.update(invalidating: [AnyQuery(IncA())]) {}
        }
        await gate.release()
        _ = try await task.value
        try await incremental.update(invalidating: [AnyQuery(IncA())]) {}
    }

    @Test("In-flight outside a warm cache completes sequential fetches")
    func outerFlightWithCache() async throws {
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
                .deduplicating(with: InFlightInterceptor())
        )
        for _ in 0..<3 {
            #expect(try await engine.fetch(IncA(), with: .root) == 1)
        }
    }

    @Test(
        "Producer errors and cancellation release every waiting fetch",
        arguments: [false, true]
    )
    func producerFailure(cancel: Bool) async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        await state.fail("number", !cancel)
        let flight = InFlightInterceptor()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: flight)
        )
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
        if cancel {
            first.cancel()
        }
        await gate.release()
        if cancel {
            await #expect(throws: CancellationError.self) {
                try await first.value
            }
            await #expect(throws: CancellationError.self) {
                try await second.value
            }
        } else {
            await #expect(throws: TestFailure.self) {
                try await first.value
            }
            await #expect(throws: TestFailure.self) {
                try await second.value
            }
        }
        #expect(await flight.waiterCount == 0)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.fail("number", false)
        }
        #expect(try await engine.fetch(Input(state: state), with: .root) == 2)
    }

    @Test("A waiting caller can cancel without cancelling the producer")
    func waiterCancellation() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let flight = InFlightInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .deduplicating(with: flight)
        )
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
        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        #expect(await flight.waiterCount == 0)
        await gate.release()
        #expect(try await first.value == 2)
        #expect(await state.count("input:number") == 1)
    }

    struct CrossCycle: Query {
        let id: Int

        let gate: TestGate
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.gate === rhs.gate
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(ObjectIdentifier(gate))
        }
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await gate.wait()
            return try await engine.fetch(CrossCycle(id: 1 - id, gate: gate), with: context)
        }
    }

    @Test("Concurrent roots detect cycles in their wait graph")
    func concurrentCycle() async throws {
        let gate = TestGate()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(CycleInterceptor())
                .memoizing(with: RedGreenInterceptor())
                .deduplicating(with: InFlightInterceptor())
        )
        let first = Task {
            try await engine.fetch(CrossCycle(id: 0, gate: gate), with: .root)
        }
        let second = Task {
            try await engine.fetch(CrossCycle(id: 1, gate: gate), with: .root)
        }
        await gate.waitForArrivals(2)
        await gate.release()
        await #expect(throws: CyclicDependencyError.self) {
            try await first.value
        }
        await #expect(throws: CyclicDependencyError.self) {
            try await second.value
        }
    }
}
