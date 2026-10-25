import Testing
import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct AdmissionDependencyTests {
    enum AdmissionFailure: Error, Equatable {
        case memoizer
        case deduplicator
    }

    actor EventLog {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    actor RejectingDeduplicator: DeduplicatingInterceptor {
        let key: AnyQuery

        let log: EventLog?

        private var rejecting = true

        init(key: AnyQuery, log: EventLog? = nil) {
            self.key = key
            self.log = log
        }

        func allow() {
            rejecting = false
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            if let log {
                await log.record("deduplicator.begin")
            }
            if rejecting && query == key {
                throw AdmissionFailure.deduplicator
            }
        }

        func endEvaluation(context: ExecutionContext) async {
            if let log {
                await log.record("deduplicator.end")
            }
        }
    }

    struct AdmissionFallback: Query {
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("admissionParent")
            do {
                return try await engine.fetch(Input(state: state), with: context)
            } catch AdmissionFailure.deduplicator {
                return -1
            }
        }
    }

    @Test("Red-green retains caught admission failures until the parent can recover")
    func redGreenRecovery() async throws {
        let state = GraphState()
        let input = Input(state: state)
        let parent = AdmissionFallback(state: state)
        let rejecting = RejectingDeduplicator(key: AnyQuery(input))
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: rejecting)
        )

        #expect(try await engine.fetch(parent, with: .root) == -1)
        #expect(try await engine.fetch(parent, with: .root) == -1)
        #expect(await state.count("admissionParent") == 1)
        #expect(await state.count("input:number") == 0)

        for (index, value) in [4, 5].enumerated() {
            try await incremental.update(invalidating: [AnyQuery(input)]) {
                await state.set("number", value)
                await rejecting.allow()
            }
            // Recovery must still execute the parent when the child is already cached.
            #expect(try await engine.fetch(input, with: .root) == value)
            #expect(try await engine.fetch(parent, with: .root) == value)
            #expect(try await engine.fetch(parent, with: .root) == value)
            #expect(await state.count("admissionParent") == index + 2)
            #expect(await state.count("input:number") == index + 1)
        }

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 5)
        }
        #expect(try await engine.fetch(parent, with: .root) == 5)
        #expect(await state.count("input:number") == 3)
        #expect(await state.count("admissionParent") == 3)
    }

    @Test(
        "Plain cache invalidation follows caught admission failures in either observer order",
        arguments: [false, true]
    )
    func plainCacheRecovery(reverseFirst: Bool) async throws {
        let state = GraphState()
        let input = Input(state: state)
        let parent = AdmissionFallback(state: state)
        let rejecting = RejectingDeduplicator(key: AnyQuery(input))
        let cache = CacheInterceptor()
        let reverse = ReverseDepsInterceptor()
        let chain = reverseFirst
            ? InterceptorChain()
                .observing(reverse)
                .memoizing(with: cache)
                .deduplicating(with: rejecting)
            : InterceptorChain()
                .memoizing(with: cache)
                .deduplicating(with: rejecting)
                .observing(reverse)
        let engine = ComposedEngine(interceptorChain: chain)

        #expect(try await engine.fetch(parent, with: .root) == -1)
        #expect(try await engine.fetch(parent, with: .root) == -1)
        #expect(await state.count("admissionParent") == 1)
        #expect(await state.count("input:number") == 0)
        #expect(await reverse.directDependents(of: input) == [AnyQuery(parent)])

        for (index, value) in [4, 5, 6].enumerated() {
            await state.set("number", value)
            await rejecting.allow()
            let invalidated = await reverse.invalidate(query: input)
            #expect(invalidated == [AnyQuery(input), AnyQuery(parent)])
            for key in invalidated {
                await cache.clear(query: key)
            }
            // Reading a cached child must restore the edge removed by invalidation.
            #expect(try await engine.fetch(input, with: .root) == value)
            #expect(try await engine.fetch(parent, with: .root) == value)
            #expect(try await engine.fetch(parent, with: .root) == value)
            #expect(await reverse.directDependents(of: input) == [AnyQuery(parent)])
            #expect(await state.count("admissionParent") == index + 2)
            #expect(await state.count("input:number") == index + 1)
        }
    }

    actor RejectingMemoizer: MemoizingInterceptor {
        let log: EventLog

        init(log: EventLog) {
            self.log = log
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async throws {
            await log.record("memoizer.begin")
            throw AdmissionFailure.memoizer
        }

        func endEvaluation(context: ExecutionContext) async {
            await log.record("memoizer.end")
        }
    }

    actor LifecycleObserver: QueryObserver {
        let log: EventLog

        init(log: EventLog) {
            self.log = log
        }

        func beginEvaluation(
            query: AnyQuery,
            context: ExecutionContext
        ) async {
            await log.record("observer.begin")
        }

        func willFetch(
            query: AnyQuery,
            context: ExecutionContext
        ) async {
            await log.record("observer.will")
        }
    }

    @Test("Admission retains the first failure and balances every evaluation hook")
    func firstAdmissionError() async throws {
        let state = GraphState()
        let input = Input(state: state)
        let log = EventLog()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: RejectingMemoizer(log: log))
                .deduplicating(with: RejectingDeduplicator(key: AnyQuery(input), log: log))
                .observing(LifecycleObserver(log: log))
        )

        await #expect(throws: AdmissionFailure.memoizer) {
            try await engine.fetch(input, with: .root)
        }
        let events = await log.events
        #expect(events.count == 5)
        #expect(Set(events) == [
            "memoizer.begin", "memoizer.end",
            "deduplicator.begin", "deduplicator.end",
            "observer.begin"
        ])
        #expect(await state.count("input:number") == 0)
    }

    actor ChildTaskSlot: Hashable {
        private let registered = TestGate()

        private let beforeFetch = TestGate()

        private var task: Task<Int, any Error>?

        nonisolated static func == (lhs: ChildTaskSlot, rhs: ChildTaskSlot) -> Bool {
            lhs === rhs
        }

        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        func install(_ task: Task<Int, any Error>) async {
            self.task = task
            await registered.release()
        }

        func waitBeforeFetch() async {
            await beforeFetch.wait()
        }

        func cancelBeforeFetch() async {
            await registered.wait()
            task?.cancel()
            await beforeFetch.release()
        }
    }

    struct CancellationFallback: Query {
        let state: GraphState

        let slot: ChildTaskSlot

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("cancellationParent")
            let child = Task {
                await slot.waitBeforeFetch()
                return try await engine.fetch(Input(state: state), with: context)
            }
            await slot.install(child)
            do {
                return try await child.value
            } catch is CancellationError {
                return -1
            }
        }
    }

    @Test("A caught pre-cancelled child read forces parent execution in the next revision")
    func cancelledBeforeAdmission() async throws {
        let state = GraphState()
        let slot = ChildTaskSlot()
        let input = Input(state: state)
        let parent = CancellationFallback(state: state, slot: slot)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )

        let first = Task {
            try await engine.fetch(parent, with: .root)
        }
        // Cancel only the independent child task, before it reaches engine.fetch.
        await slot.cancelBeforeFetch()
        #expect(try await first.value == -1)
        #expect(await state.count("cancellationParent") == 1)
        #expect(await state.count("input:number") == 0)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await state.set("number", 4)
        }
        #expect(try await engine.fetch(parent, with: .root) == 4)
        #expect(await state.count("cancellationParent") == 2)
        #expect(await state.count("input:number") == 1)
    }
}
