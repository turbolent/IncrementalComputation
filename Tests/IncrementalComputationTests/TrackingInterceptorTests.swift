import XCTest
import IncrementalComputation

final class TrackingInterceptorTests: XCTestCase {

    func testTracking() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor(),
                tracker
            ]
        )

        _ = try await engine.fetch(DerivedQuery(), with: .root)

        let derivedWasFetched = await tracker.wasFetched(query: QueryKey(DerivedQuery()))
        XCTAssertTrue(derivedWasFetched)

        let baseWasFetched = await tracker.wasFetched(query: QueryKey(BaseQuery()))
        XCTAssertTrue(baseWasFetched)

        let count = await tracker.count
        XCTAssertEqual(count, 2)
    }

}
