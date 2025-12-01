import XCTest
import IncrementalComputation

final class TrackingInterceptorTests: XCTestCase {

    func testTracking() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(interceptors: [CacheInterceptor(), tracker])

        _ = try await engine.fetch(DerivedQuery())

        XCTAssertTrue(tracker.wasFetched(key: AnyHashable(DerivedQuery())))
        XCTAssertTrue(tracker.wasFetched(key: AnyHashable(BaseQuery())))
        XCTAssertEqual(tracker.count, 2)
    }

}
