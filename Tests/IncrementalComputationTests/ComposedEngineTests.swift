import XCTest
import IncrementalComputation

final class ComposedEngineTests: XCTestCase {

    // MARK: - Basic Tests

    func testBasicComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(BaseQuery(), with: .root)
        XCTAssertEqual(result, 10)
    }

    func testDerivedComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(DerivedQuery(), with: .root)
        XCTAssertEqual(result, 15)
    }

    // MARK: - Full Incremental Engine Tests

    func testIncrementalEngineBasic() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor(),
                cache,
                ReverseDepsInterceptor()
            ]
        )

        let result1 = try await engine.fetch(IncC(), with: .root)
        XCTAssertEqual(result1, 111)

        // Second fetch uses cache
        let result2 = try await engine.fetch(IncC(), with: .root)
        XCTAssertEqual(result2, 111)

        // Verify caching worked: A, B, C all cached
        XCTAssertEqual(cache.count, 3)
        XCTAssert(cache.isCached(query: AnyHashable(IncA())))
        XCTAssert(cache.isCached(query: AnyHashable(IncB())))
        XCTAssert(cache.isCached(query: AnyHashable(IncC())))
    }

    func testIncrementalEngineWithCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor(),
                CacheInterceptor(),
                ReverseDepsInterceptor()
            ]
        )

        do {
            _ = try await engine.fetch(CyclicQueryA(), with: .root)
            XCTFail("Expected CyclicDependencyError")
        } catch is CyclicDependencyError {
            // Expected
        } catch {
            XCTFail("Expected CyclicDependencyError, got \(error)")
        }
    }
}
