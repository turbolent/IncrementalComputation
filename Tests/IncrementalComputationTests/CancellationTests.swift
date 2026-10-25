import Testing
import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct CancellationTests {

    @Test("Task Cancellation Stops Long Running Query")
    func testTaskCancellationStopsLongRunningQuery() async {
        struct LongRunningQuery: Query {
            typealias Value = Int

            /// Holds computation until the test cancels its task.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                await gate.wait()
                try Task.checkCancellation()
                return 1
            }
        }

        let engine = ComposedEngine(interceptorChain: InterceptorChain())
        let gate = TestGate()

        let task = Task {
            try await engine.fetch(LongRunningQuery(gate: gate), with: .root)
        }

        await gate.waitForArrivals()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
