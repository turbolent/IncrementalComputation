import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct AbortedValidationTests {
    struct Child: Query {
        /// Supplies the input graph and records execution counts.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("abortedChild")
            return try await engine.fetch(Input(state: state), with: context)
        }
    }

    struct Parent: Query {
        /// Identifies the child and records enclosing body executions.
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("abortedParent")
            return try await engine.fetch(Child(state: state), with: context)
        }
    }

    actor FailingValidationObserver: QueryObserver {
        /// Identifies the dependency whose next validation will fail.
        let query: AnyQuery

        /// Holds one validation attempt while a separate invocation succeeds.
        private var nextGate: TestGate?

        init(query: AnyQuery) {
            self.query = query
        }

        func failNextValidation(at gate: TestGate) {
            nextGate = gate
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            guard query == self.query, context.isValidationRead, let gate = nextGate else {
                return
            }
            nextGate = nil
            await gate.wait()
            throw CancellationError()
        }
    }

    actor RecoveringInterceptor: DeduplicatingInterceptor {
        /// Identifies the query whose aborted validation produces a fallback.
        let query: AnyQuery

        init(query: AnyQuery) {
            self.query = query
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            guard query == self.query else {
                return try await next()
            }
            do {
                return try await next()
            } catch is CancellationError {
                return -1
            }
        }
    }

    @Test("An aborted validation cannot borrow a concurrent invocation's successful memo")
    func concurrentValidationRecovery() async throws {
        let state = GraphState()
        let child = Child(state: state)
        let parent = Parent(state: state)
        let incremental = RedGreenInterceptor()
        let observer = FailingValidationObserver(query: AnyQuery(Input(state: state)))
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(observer)
                .memoizing(with: incremental)
                .deduplicating(with: RecoveringInterceptor(query: AnyQuery(child)))
        )
        #expect(try await engine.fetch(child, with: .root) == 2)
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}

        let gate = TestGate()
        await observer.failNextValidation(at: gate)
        let fallback = Task {
            try await engine.fetch(parent, with: .root)
        }
        await gate.waitForArrivals()

        // A separate fetch verifies the child before the first validation fails.
        #expect(try await engine.fetch(child, with: .root) == 2)
        #expect(await incremental.memoRevisions(for: AnyQuery(child))?.verifiedAt == 2)
        await gate.release()
        #expect(try await fallback.value == -1)
        #expect(await state.count("abortedParent") == 1)

        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}

        // The parent's fallback needs a fresh read even though the child's memo is unchanged.
        #expect(try await engine.fetch(parent, with: .root) == 2)
        #expect(await state.count("abortedParent") == 2)
        #expect(await state.count("abortedChild") == 1)
        #expect(await state.count("input:number") == 1)

        // Once the parent records a reliable read, ordinary backdating works again.
        try await incremental.update(
            invalidating: [AnyQuery(Input(state: state, name: "unrelated"))]
        ) {}
        #expect(try await engine.fetch(parent, with: .root) == 2)
        #expect(await state.count("abortedParent") == 2)
    }

    actor CancellableStore: Hashable {
        /// Holds the first source's independent task until another source fetch succeeds.
        let gate = TestGate()

        /// The source operation that can be cancelled without cancelling its caller.
        private var child: Task<Int, any Error>?

        /// Number of source bodies entered.
        private(set) var executions = 0

        /// Number of parent bodies entered.
        private(set) var parentExecutions = 0

        nonisolated static func == (lhs: CancellableStore, rhs: CancellableStore) -> Bool {
            lhs === rhs
        }

        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        func recordParent() {
            parentExecutions += 1
        }

        func cancelChild() {
            child?.cancel()
        }

        func read() async throws -> Int {
            executions += 1
            guard executions == 1 else {
                return 2
            }
            let task = Task {
                await gate.wait()
                try Task.checkCancellation()
                return 2
            }
            child = task
            defer {
                child = nil
            }
            return try await task.value
        }
    }

    struct CancellableSource: Query {
        /// Supplies the source value through an independently cancellable operation.
        let store: CancellableStore

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            try await store.read()
        }
    }

    struct SourceParent: Query {
        /// Identifies the source and records enclosing body executions.
        let store: CancellableStore

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await store.recordParent()
            return try await engine.fetch(CancellableSource(store: store), with: context)
        }
    }

    @Test("An aborted computation cannot borrow a concurrent invocation's successful memo")
    func concurrentComputationRecovery() async throws {
        let store = CancellableStore()
        let source = CancellableSource(store: store)
        let parent = SourceParent(store: store)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: RecoveringInterceptor(query: AnyQuery(source)))
        )

        let fallback = Task {
            try await engine.fetch(parent, with: .root)
        }
        await store.gate.waitForArrivals()

        // A second execution commits while the first is still waiting on its source operation.
        #expect(try await engine.fetch(source, with: .root) == 2)
        await store.cancelChild()
        await store.gate.release()
        #expect(try await fallback.value == -1)
        #expect(await store.parentExecutions == 1)

        try await incremental.update(invalidating: [AnyQuery(IncA())]) {}

        // No nested query read failed, but the aborted computation still needs a retry.
        #expect(try await engine.fetch(parent, with: .root) == 2)
        #expect(await store.parentExecutions == 2)
        #expect(await store.executions == 2)

        try await incremental.update(invalidating: [AnyQuery(IncA())]) {}
        #expect(try await engine.fetch(parent, with: .root) == 2)
        #expect(await store.parentExecutions == 2)
    }
}
