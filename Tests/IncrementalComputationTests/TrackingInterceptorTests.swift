import Testing
import IncrementalComputation

struct TrackingInterceptorTests {

    @Test("Tracking")
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
        #expect(derivedWasFetched)

        let baseWasFetched = await tracker.wasFetched(query: QueryKey(BaseQuery()))
        #expect(baseWasFetched)

        let count = await tracker.count
        #expect(count == 2)
    }

    @Test("Convenience Overload Matches Query Key Variant")
    func testConvenienceOverloadMatchesQueryKeyVariant() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(interceptors: [tracker])

        _ = try await engine.fetch(DerivedQuery(), with: .root)

        let typedDerived = await tracker.wasFetched(query: DerivedQuery())
        let keyDerived = await tracker.wasFetched(query: QueryKey(DerivedQuery()))
        #expect(typedDerived == keyDerived)
        #expect(typedDerived)

        let typedBase = await tracker.wasFetched(query: BaseQuery())
        let keyBase = await tracker.wasFetched(query: QueryKey(BaseQuery()))
        #expect(typedBase == keyBase)
        #expect(typedBase)
    }

}
