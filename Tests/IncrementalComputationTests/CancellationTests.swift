import Testing
import IncrementalComputation

struct CancellationTests {

    @Test("Task Cancellation Stops Long Running Query")
    func testTaskCancellationStopsLongRunningQuery() async {
        struct LongRunningQuery: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
            }
        }

        let engine = ComposedEngine(interceptors: [])

        let task = Task {
            try await engine.fetch(LongRunningQuery(), with: .root)
        }

        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
