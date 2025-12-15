import XCTest
import IncrementalComputation

final class ReverseDepsInterceptorTests: XCTestCase {

    func testReverseDependencyTracking() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                reverseDeps
            ]
        )

        _ = try await engine.fetch(IncC(), with: .root)

        // Check that dependencies were tracked
        let dependentsOfA = reverseDeps.dependents(of: AnyHashable(IncA()))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncB())))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncC())))
    }

    func testInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                cache,
                reverseDeps
            ]
        )

        let result1 = try await engine.fetch(IncC(), with: .root)
        XCTAssertEqual(result1, 111)

        let aCached = cache.isCached(query: AnyHashable(IncA()))
        let bCached = cache.isCached(query: AnyHashable(IncB()))
        let cCached = cache.isCached(query: AnyHashable(IncC()))
        XCTAssertTrue(aCached)
        XCTAssertTrue(bCached)
        XCTAssertTrue(cCached)

        // Invalidate A - should also invalidate B and C
        let invalidated = reverseDeps.invalidate(query: AnyHashable(IncA()))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncA())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncB())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncC())))

        // Clear invalidated entries from cache
        for query in invalidated {
            cache.clear(query: query)
        }

        let aNotCached = cache.isCached(query: AnyHashable(IncA()))
        let bNotCached = cache.isCached(query: AnyHashable(IncB()))
        let cNotCached = cache.isCached(query: AnyHashable(IncC()))
        XCTAssertFalse(aNotCached)
        XCTAssertFalse(bNotCached)
        XCTAssertFalse(cNotCached)
    }

    func testPartialInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                cache,
                reverseDeps
            ]
        )

        _ = try await engine.fetch(IncC(), with: .root)

        // Invalidate B - should also invalidate C but NOT A
        let invalidated = reverseDeps.invalidate(query: AnyHashable(IncB()))
        XCTAssertFalse(invalidated.contains(AnyHashable(IncA())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncB())))
        XCTAssertTrue(invalidated.contains(AnyHashable(IncC())))

        // A should still be cached
        let aStillCached = cache.isCached(query: AnyHashable(IncA()))
        XCTAssertTrue(aStillCached)
    }
}
