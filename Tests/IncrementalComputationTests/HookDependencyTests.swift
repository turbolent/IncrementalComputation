import Foundation
import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct HookDependencyTests {
    struct Parent: Query {
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("hookParent")
            return 17
        }
    }

    actor ReadingObserver: QueryObserver {
        let state: GraphState

        private weak var engine: ComposedEngine?

        init(state: GraphState) {
            self.state = state
        }

        func attach(_ engine: ComposedEngine) {
            self.engine = engine
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            guard query == AnyQuery(Parent(state: state)),
                  let engine else {
                return
            }
            _ = try await engine.fetch(Input(state: state), with: context)
        }
    }

    @Test(
        "Observer reads remain dependencies in either registration order",
        arguments: [false, true]
    )
    func observerDependencies(observerFirst: Bool) async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let observer = ReadingObserver(state: state)
        let chain = observerFirst
            ? InterceptorChain().observing(observer).memoizing(with: incremental)
            : InterceptorChain().memoizing(with: incremental).observing(observer)
        let engine = ComposedEngine(interceptorChain: chain)
        await observer.attach(engine)
        let parent = Parent(state: state)
        let input = Input(state: state)

        // The body reads no queries; its only dependency comes from the observer.
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("hookParent") == 1)
        #expect(await state.count("input:number") == 1)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("hookParent") == 2)
        #expect(await state.count("input:number") == 2)

        // Equal input values skip the body without losing the observer's old edge.
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("hookParent") == 2)
        #expect(await state.count("input:number") == 3)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 5)
        }
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("hookParent") == 3)
        #expect(await state.count("input:number") == 4)
        let revisions = await incremental.memoRevisions(for: AnyQuery(parent))
        #expect(revisions?.changedAt == 1)
        #expect(revisions?.verifiedAt == 4)
    }

    actor ReadingDeduplicator: DeduplicatingInterceptor {
        let state: GraphState

        init(state: GraphState) {
            self.state = state
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            let value = try await next()
            if query == AnyQuery(Parent(state: state)) {
                _ = try await engine.fetch(Input(state: state), with: context)
            }
            return value
        }
    }

    @Test("Outer resolution reads are finalized before ending evaluation")
    func outerResolutionDependencies() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: ReadingDeduplicator(state: state))
        )
        let parent = Parent(state: state)
        #expect(try await engine.fetch(parent, with: .root) == 17)
        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(parent, with: .root) == 17)
        #expect(await state.count("hookParent") == 2)
        #expect(await state.count("input:number") == 2)
    }

    actor ReadingNestedCalls: DeduplicatingInterceptor {
        /// Supplies the additional dependency and records query executions.
        let state: GraphState

        init(state: GraphState) {
            self.state = state
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            let value = try await next()
            if query == AnyQuery(Parent(state: state)), context.callerQuery != nil {
                _ = try await engine.fetch(Input(state: state), with: context)
            }
            return value
        }
    }

    struct Consumer: Query {
        /// Records executions and identifies the shared parent query.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("hookConsumer")
            return try await engine.fetch(Parent(state: state), with: context)
        }
    }

    @Test("Memo hits retain dependencies first read by an outer hook")
    func freshOuterDependency() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: ReadingNestedCalls(state: state))
        )

        // Root reads return 17 without the hook's extra dependency.
        #expect(try await engine.fetch(Parent(state: state), with: .root) == 17)
        #expect(await state.count("input:number") == 0)
        // A nested memo hit also returns 17, but now records the hook's input read.
        #expect(try await engine.fetch(Consumer(state: state), with: .root) == 17)
        #expect(await state.count("hookParent") == 1)
        #expect(await state.count("input:number") == 1)

        try await incremental.update(invalidating: [AnyQuery(Input(state: state))]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(Consumer(state: state), with: .root) == 17)
        #expect(await state.count("hookParent") == 2)
        #expect(await state.count("hookConsumer") == 1)
        #expect(await state.count("input:number") == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(Parent(state: state)))?.changedAt == 1)
    }

    actor LifecycleObserver: QueryObserver {
        private(set) var begun: Set<UUID> = []

        private(set) var observations = 0

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) {
            begun.insert(context.invocationID!)
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) {
            observations += 1
        }
    }

    @Test(
        "Updates reject observation and release rejected-attempt bookkeeping",
        arguments: [false, true]
    )
    func rejectedUpdateAttempt(observerFirst: Bool) async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let observer = LifecycleObserver()
        let chain = observerFirst
            ? InterceptorChain().observing(observer).memoizing(with: incremental)
            : InterceptorChain().memoizing(with: incremental).observing(observer)
        let engine = ComposedEngine(interceptorChain: chain)
        let input = Input(state: state)
        let gate = TestGate()
        let update = Task {
            try await incremental.update(invalidating: [AnyQuery(input)]) {
                await gate.wait()
                await state.set("number", 4)
            }
        }
        await gate.waitForArrivals()

        await #expect(throws: RevisionUpdateError.updateInProgress) {
            try await engine.fetch(input, with: .root)
        }
        #expect(await observer.begun.count == 1)
        #expect(await observer.observations == 0)
        #expect(await state.count("input:number") == 0)

        await gate.release()
        try await update.value
        // A leaked admission would reject this next update as evaluationsActive.
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 5)
        }
        #expect(try await engine.fetch(input, with: .root) == 5)
        #expect(await observer.begun.count == 2)
        #expect(await observer.observations == 1)
        #expect(await incremental.revision == 3)
    }
}
