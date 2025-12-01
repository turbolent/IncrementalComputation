import XCTest
import IncrementalComputation

final class ComposedEngineTests: XCTestCase {

    // MARK: - Basic Tests

    func testBasicComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(BaseQuery())
        XCTAssertEqual(result, 10)
    }

    func testDerivedComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(DerivedQuery())
        XCTAssertEqual(result, 15)
    }

    // MARK: - Full Incremental Engine Tests

    func testIncrementalEngineBasic() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(interceptors: [
            CycleInterceptor(),
            cache,
            ReverseDepsInterceptor()
        ])

        let result1 = try await engine.fetch(IncC())
        XCTAssertEqual(result1, 111)

        // Second fetch uses cache
        let result2 = try await engine.fetch(IncC())
        XCTAssertEqual(result2, 111)

        // Verify caching worked
        XCTAssertEqual(cache.count, 3)  // A, B, C all cached
    }

    func testIncrementalEngineWithCycleDetection() async throws {
        let engine = ComposedEngine(interceptors: [
            CycleInterceptor(),
            CacheInterceptor(),
            ReverseDepsInterceptor()
        ])

        do {
            _ = try await engine.fetch(CyclicQueryA())
            XCTFail("Expected CyclicDependencyError")
        } catch is CyclicDependencyError {
            // Expected
        } catch {
            XCTFail("Expected CyclicDependencyError, got \(error)")
        }
    }
}
