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

        XCTAssertTrue(tracker.wasFetched(query: AnyHashable(DerivedQuery())))
        XCTAssertTrue(tracker.wasFetched(query: AnyHashable(BaseQuery())))
        XCTAssertEqual(tracker.count, 2)
    }

}
