import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct AdmissionCycleTests {
    enum Protection: Sendable {
        case observer
        case inFlight
        case redGreen
    }

    struct ValueQuery: Query {
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await state.record("recursiveBody")
            return 1
        }
    }

    actor RecursingObserver: QueryObserver {
        let state: GraphState

        private weak var engine: ComposedEngine?

        private(set) var calls = 0

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
            calls += 1
            // Bound recursion so a missing admission guard fails without hanging the suite.
            guard calls < 5, let engine else {
                return
            }
            _ = try await engine.fetch(ValueQuery(state: state), with: context)
        }
    }

    @Test(
        "Cycle admission prevents recursive observation and retains the attempted edge",
        arguments: [Protection.observer, .inFlight, .redGreen]
    )
    func recursiveObservation(protection: Protection) async throws {
        let state = GraphState()
        let reader = RecursingObserver(state: state)
        let reverse = ReverseDepsInterceptor()
        let engine: ComposedEngine
        switch protection {
        case .observer:
            engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .observing(CycleInterceptor())
                    .observing(reverse)
                    .observing(reader)
            )
        case .inFlight:
            engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .deduplicating(with: InFlightInterceptor())
                    .observing(reverse)
                    .observing(reader)
            )
        case .redGreen:
            engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .memoizing(with: RedGreenInterceptor())
                    .observing(reverse)
                    .observing(reader)
            )
        }
        await reader.attach(engine)
        let query = ValueQuery(state: state)

        await #expect(throws: CyclicDependencyError.self) {
            try await engine.fetch(query, with: .root)
        }
        #expect(await reader.calls == 1)
        #expect(await state.count("recursiveBody") == 0)
        // Other admission observers still record the read rejected by the cycle guard.
        #expect(await reverse.directDependents(of: query) == [AnyQuery(query)])
    }
}
