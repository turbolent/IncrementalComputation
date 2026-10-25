import Testing
import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct QueryContinuationTests {
    enum Outcome: Equatable {
        case value(Int)
        case expectedFailure
        case cancelled
        case repeatedCall
        case unexpectedFailure
    }

    // Deliberately misuse next and catch its errors so both attempts can be inspected.
    actor RepeatingInterceptor: MemoizingInterceptor {
        let concurrent: Bool

        let rejectionGate: TestGate?

        private(set) var outcomes: [Outcome] = []

        init(concurrent: Bool = false, rejectionGate: TestGate? = nil) {
            self.concurrent = concurrent
            self.rejectionGate = rejectionGate
        }

        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            if concurrent {
                async let first = attempt(next)
                async let second = attempt(next)
                outcomes = await [first, second]
            } else {
                let first = await attempt(next)
                let second = await attempt(next)
                outcomes = [first, second]
            }
            return 0
        }

        private func attempt(_ next: QueryContinuation) async -> Outcome {
            do {
                return .value(try await next() as! Int)
            } catch QueryContinuationError.alreadyCalled {
                if let rejectionGate {
                    await rejectionGate.wait()
                }
                return .repeatedCall
            } catch is TestFailure {
                return .expectedFailure
            } catch is CancellationError {
                return .cancelled
            } catch {
                Issue.record("Unexpected continuation failure: \(error)")
                return .unexpectedFailure
            }
        }
    }

    @Test(
        "A continuation stays consumed after success or failure",
        arguments: [false, true]
    )
    func sequentialCalls(firstThrows: Bool) async throws {
        let state = GraphState()
        await state.fail("number", firstThrows)
        let interceptor = RepeatingInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: interceptor)
        )
        // New fetches of the same query each receive a fresh continuation.
        for expectedCount in 1...2 {
            #expect(try await engine.fetch(Input(state: state), with: .root) == 0)
            #expect(await state.count("input:number") == expectedCount)
            #expect(await interceptor.outcomes == [
                firstThrows ? .expectedFailure : .value(2), .repeatedCall
            ])
        }
    }

    @Test("Concurrent calls reject the second while the first is still executing")
    func concurrentCalls() async throws {
        let state = GraphState()
        let executionGate = TestGate()
        let rejectionGate = TestGate()
        await state.gate("number", executionGate)
        let interceptor = RepeatingInterceptor(
            concurrent: true,
            rejectionGate: rejectionGate
        )
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: interceptor)
        )
        let task = Task {
            try await engine.fetch(Input(state: state), with: .root)
        }
        await executionGate.waitForArrivals()
        await rejectionGate.waitForArrivals()
        #expect(await state.count("input:number") == 1)
        await executionGate.release()
        await rejectionGate.release()
        #expect(try await task.value == 0)
        let outcomes = await interceptor.outcomes
        #expect(outcomes.count == 2)
        #expect(outcomes.contains(.value(2)))
        #expect(outcomes.contains(.repeatedCall))
    }

    struct CancellableInput: Query {
        let state: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            let value = try await state.read("number")
            try Task.checkCancellation()
            return value
        }
    }

    @Test("Cancellation does not permit a second continuation call")
    func cancelledCall() async throws {
        let state = GraphState()
        let gate = TestGate()
        await state.gate("number", gate)
        let interceptor = RepeatingInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: interceptor)
        )
        let task = Task {
            try await engine.fetch(CancellableInput(state: state), with: .root)
        }
        await gate.waitForArrivals()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await interceptor.outcomes == [.cancelled, .repeatedCall])
        #expect(await state.count("input:number") == 1)
    }

    actor DoubleForwarder: DeduplicatingInterceptor {
        func intercept(
            query: AnyQuery,
            context: ExecutionContext,
            engine: any QueryEngine,
            next: QueryContinuation
        ) async throws -> any Sendable {
            _ = try await next()
            return try await next()
        }
    }

    @Test("An uncaught repeated-call error prevents publication and completes evaluation")
    func repeatedCallCleanup() async throws {
        let state = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
                .deduplicating(with: DoubleForwarder())
        )
        let input = Input(state: state)
        for expectedCount in 1...2 {
            await #expect(throws: QueryContinuationError.alreadyCalled) {
                try await engine.fetch(input, with: .root)
            }
            // A failed fetch must not leave the value from its first next call cached.
            #expect(await state.count("input:number") == expectedCount)
        }
        try await incremental.update(invalidating: [AnyQuery(input)]) {}
    }
}
