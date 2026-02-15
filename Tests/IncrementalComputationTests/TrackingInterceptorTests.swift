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

    func testConvenienceOverloadMatchesQueryKeyVariant() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(interceptors: [tracker])

        _ = try await engine.fetch(DerivedQuery(), with: .root)

        let typedDerived = await tracker.wasFetched(query: DerivedQuery())
        let keyDerived = await tracker.wasFetched(query: QueryKey(DerivedQuery()))
        XCTAssertEqual(typedDerived, keyDerived)
        XCTAssertTrue(typedDerived)

        let typedBase = await tracker.wasFetched(query: BaseQuery())
        let keyBase = await tracker.wasFetched(query: QueryKey(BaseQuery()))
        XCTAssertEqual(typedBase, keyBase)
        XCTAssertTrue(typedBase)
    }

}
