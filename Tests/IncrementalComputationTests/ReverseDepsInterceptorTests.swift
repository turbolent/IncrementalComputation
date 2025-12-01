import XCTest
import IncrementalComputation

final class ReverseDepsInterceptorTests: XCTestCase {

    func testReverseDependencyTracking() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [
            reverseDeps
        ])

        _ = try await engine.fetch(IncC())

        // Check that dependencies were tracked
        let dependentsOfA = reverseDeps.dependents(of: AnyHashable(IncA()))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncB())))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncC())))
    }

    func testInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [
            cache,
            reverseDeps
        ])

        let result1 = try await engine.fetch(IncC())
        XCTAssertEqual(result1, 111)

        XCTAssertTrue(cache.isCached(key: AnyHashable(IncA())))
        XCTAssertTrue(cache.isCached(key: AnyHashable(IncB())))
        XCTAssertTrue(cache.isCached(key: AnyHashable(IncC())))

        // Invalidate A - should also invalidate B and C
        let invalidated = reverseDeps.invalidate(key: AnyHashable(IncA()))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncA())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncB())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncC())))

        // Clear invalidated entries from cache
        for key in invalidated {
            cache.clear(key: key)
        }

        XCTAssertFalse(cache.isCached(key: AnyHashable(IncA())))
        XCTAssertFalse(cache.isCached(key: AnyHashable(IncB())))
        XCTAssertFalse(cache.isCached(key: AnyHashable(IncC())))
    }

    func testPartialInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [
            cache,
            reverseDeps
        ])

        _ = try await engine.fetch(IncC())

        // Invalidate B - should also invalidate C but NOT A
        let invalidated = reverseDeps.invalidate(key: AnyHashable(IncB()))
        XCTAssertFalse(invalidated.contains(AnyHashable(IncA())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncB())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncC())))

        // A should still be cached
        XCTAssertTrue(cache.isCached(key: AnyHashable(IncA())))
    }
}
