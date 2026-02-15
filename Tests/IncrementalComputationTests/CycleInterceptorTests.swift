import Testing
import IncrementalComputation

struct CycleInterceptorTests {

    @Test("Cycle Detection")
    func testCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )

        await #expect(throws: CyclicDependencyError.self) {
            _ = try await engine.fetch(CyclicQueryA(), with: .root)
        }
    }

    @Test("Self Referential Cycle Detection")
    func testSelfReferentialCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )

        await #expect(throws: CyclicDependencyError.self) {
            _ = try await engine.fetch(SelfReferentialQuery(), with: .root)
        }
    }

    @Test("No Cycle With Valid Query")
    func testNoCycleWithValidQuery() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )
        let result = try await engine.fetch(DerivedQuery(), with: .root)
        #expect(result == 15)
    }

}
