import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct RedGreenInterceptorTests {
    @Test("Backdating skips consumers and advances verification")
    func backdating() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Input(state: state)
        let parity = Parity(state: state)
        let report = Report(state: state)
        #expect(try await engine.fetch(report, with: .root) == "even")
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(report, with: .root) == "even")
        #expect(await state.count("input:number") == 2)
        #expect(await state.count("parity") == 2)
        #expect(await state.count("report") == 1)
        let revisions = await incremental.memoRevisions(for: AnyQuery(parity))
        #expect(revisions?.changedAt == 1)
        #expect(revisions?.verifiedAt == 2)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 5)
        }
        #expect(try await engine.fetch(report, with: .root) == "odd")
        #expect(await state.count("report") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(parity))?.changedAt == 3)
    }

    @Test("Unrelated changes, skipped revisions, and direct invalidation")
    func revisions() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let report = Report(state: state)
        _ = try await engine.fetch(report, with: .root)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]) {}
        _ = try await engine.fetch(report, with: .root)
        #expect(await state.count("parity") == 1)
        #expect(await state.count("report") == 1)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 3)
        }
        try await incremental.update(invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]) {}
        #expect(try await engine.fetch(report, with: .root) == "odd")
        #expect(await state.count("report") == 2)

        try await incremental.update(invalidating: [AnyQuery(Parity(state: state))]) {}
        _ = try await engine.fetch(report, with: .root)
        #expect(await state.count("parity") == 3)
        #expect(await state.count("report") == 2)
    }

    @Test("Equal input writes backdate before running intermediate queries")
    func equalInput() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        _ = try await engine.fetch(Report(state: state), with: .root)
        let key = AnyQuery(Input(state: state))
        try await incremental.update(invalidating: [key, key]) {
            await state.set("number", 2)
        }
        _ = try await engine.fetch(Report(state: state), with: .root)
        #expect(await state.count("input:number") == 2)
        #expect(await state.count("parity") == 1)
        #expect(await state.count("report") == 1)
        #expect(await incremental.revision == 2)
    }

    @Test("An equal result replaces branch dependencies and avoids obsolete reads")
    func dynamicDependencies() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let reverse = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(reverse)
                .memoizing(with: incremental)
        )
        let branch = Branch(state: state)
        #expect(try await engine.fetch(branch, with: .root) == 7)
        try await incremental.update(invalidating: [
            AnyQuery(Input(state: state, name: "condition")),
            AnyQuery(Input(state: state, name: "left"))
        ]) {
            await state.set("condition", 0)
            await state.fail("left", true)
        }
        #expect(try await engine.fetch(branch, with: .root) == 7)
        #expect(await state.count("input:left") == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(branch))?.changedAt == 1)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state, name: "left"))]) {}
        _ = try await engine.fetch(branch, with: .root)
        #expect(await state.count("branch") == 2)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state, name: "right"))]) {
            await state.set("right", 9)
        }
        #expect(try await engine.fetch(branch, with: .root) == 9)
        #expect(await state.count("branch") == 3)
    }

    struct Opaque: Sendable {
        let number: Int
    }
    struct OpaqueQuery: Query {
        let state: GraphState
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Opaque {
            Opaque(number: try await engine.fetch(Input(state: state), with: context))
        }
    }
    struct OpaqueConsumer: Query {
        let state: GraphState
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("opaqueConsumer")
            return try await engine.fetch(OpaqueQuery(state: state), with: context).number
        }
    }
    struct CustomQuery: Query {
        let state: GraphState
        static func valuesEqual(_ lhs: Opaque, _ rhs: Opaque) -> Bool {
            lhs.number == rhs.number
        }
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Opaque {
            Opaque(number: try await engine.fetch(Input(state: state), with: context) % 2)
        }
    }
    struct CustomConsumer: Query {
        let state: GraphState
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("customConsumer")
            return try await engine.fetch(CustomQuery(state: state), with: context).number
        }
    }

    @Test("Default comparison is conservative and custom equality backdates")
    func comparisons() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        _ = try await engine.fetch(OpaqueConsumer(state: state), with: .root)
        _ = try await engine.fetch(CustomConsumer(state: state), with: .root)
        try await incremental.update(invalidating: [AnyQuery(OpaqueQuery(state: state))]) {}
        _ = try await engine.fetch(OpaqueConsumer(state: state), with: .root)
        #expect(await state.count("opaqueConsumer") == 2)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }
        _ = try await engine.fetch(CustomConsumer(state: state), with: .root)
        #expect(await state.count("customConsumer") == 1)
    }

    @Test("Dependency failures rerun catching parents; errors are not memoized")
    func failures() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Input(state: state)
        let fallback = Fallback(state: state)
        #expect(try await engine.fetch(fallback, with: .root) == 2)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.fail("number", true)
        }
        #expect(try await engine.fetch(fallback, with: .root) == -1)
        let count = await state.count("input:number")
        await #expect(throws: TestFailure.self) {
            try await engine.fetch(input, with: .root)
        }
        #expect(await state.count("input:number") == count + 1)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.fail("number", false)
        }
        #expect(try await engine.fetch(fallback, with: .root) == 2)
        #expect(await state.count("fallback") == 3)
    }

    @Test("Updates require idle evaluation and block new fetches")
    func updateAdmission() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Input(state: state)
        let task = Task {
            try await engine.fetch(input, with: .root)
        }
        await gate.waitForArrivals()
        await #expect(throws: RevisionUpdateError.evaluationsActive) {
            try await incremental.update(invalidating: [AnyQuery(input)]) {
                await state.record("mutation")
            }
        }
        #expect(await state.count("mutation") == 0)
        await gate.release()
        _ = try await task.value

        let updateGate = TestGate()
        let update = Task {
            try await incremental.update(invalidating: [AnyQuery(input)]) {
                await updateGate.wait()
                await state.set("number", 4)
            }
        }
        await updateGate.waitForArrivals()
        await #expect(throws: RevisionUpdateError.updateInProgress) {
            try await engine.fetch(input, with: .root)
        }
        await updateGate.release()
        try await update.value
        #expect(try await engine.fetch(input, with: .root) == 4)
        await #expect(throws: RevisionUpdateError.emptyInvalidation) {
            try await incremental.update(invalidating: []) {}
        }
    }

    @Test("A throwing update invalidates partially changed external data")
    func throwingUpdate() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Input(state: state)
        _ = try await engine.fetch(input, with: .root)
        await #expect(throws: TestFailure.self) {
            try await incremental.update(invalidating: [AnyQuery(input)]) {
                await state.set("number", 9)
                throw TestFailure.expected
            }
        }
        #expect(try await engine.fetch(input, with: .root) == 9)
        #expect(await incremental.revision == 2)
    }

    @Test("Cancellation publishes no memo and releases admission")
    func cancellation() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Input(state: state)
        let task = Task {
            try await engine.fetch(input, with: .root)
        }
        await gate.waitForArrivals()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await incremental.memoRevisions(for: AnyQuery(input)) == nil)
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 6)
        }
        #expect(try await engine.fetch(input, with: .root) == 6)
    }

    @Test("Validation does not add transitive reverse dependency edges")
    func validationReads() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let reverse = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .observing(reverse)
        )
        _ = try await engine.fetch(Report(state: state), with: .root)
        let before = await reverse.allReverseDependencies
        try await incremental.update(invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]) {}
        _ = try await engine.fetch(Report(state: state), with: .root)
        #expect(await reverse.allReverseDependencies == before)
        #expect(
            await reverse.directDependents(of: Input(state: state)) == [AnyQuery(Parity(state: state))]
        )
    }

    @Test("Concurrent duplicate frames preserve dependency lists", arguments: [false, true])
    func concurrentFrames(deduplicate: Bool) async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let incremental = RedGreenInterceptor()
        let flight = InFlightInterceptor()
        let chain = InterceptorChain().memoizing(with: incremental)
        let engine = deduplicate
            ? ComposedEngine(interceptorChain: chain.deduplicating(with: flight))
            : ComposedEngine(interceptorChain: chain)
        let first = Task {
            try await engine.fetch(Report(state: state), with: .root)
        }
        await gate.waitForArrivals()
        let second = Task {
            try await engine.fetch(Report(state: state), with: .root)
        }
        if deduplicate {
            while await flight.waiterCount == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        } else {
            await gate.waitForArrivals(2)
        }
        await gate.release()
        #expect(try await first.value == "even")
        #expect(try await second.value == "even")
        #expect(await state.count("report") == (deduplicate ? 1 : 2))
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 5)
        }
        #expect(try await engine.fetch(Report(state: state), with: .root) == "odd")
    }

    @Test("Value-based keys memoize reports while the wrapper still executes")
    func valueKeys() async throws {
        let state = GraphState()
        let cache = CacheInterceptor()
        let reverse = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .observing(reverse)
        )
        let workflow = ValueWorkflow(state: state)
        _ = try await engine.fetch(workflow, with: .root)
        await state.set("number", 4)
        for key in await reverse.invalidate(query: Input(state: state)) {
            await cache.clear(query: key)
        }
        _ = try await engine.fetch(workflow, with: .root)
        #expect(await state.count("workflow") == 2)
        #expect(await state.count("parity") == 2)
        #expect(await state.count("valueReport") == 1)
    }
}
