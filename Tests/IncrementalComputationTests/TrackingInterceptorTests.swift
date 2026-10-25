import Testing
import IncrementalComputation

struct TrackingInterceptorTests {

    @Test("Tracking")
    func testTracking() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
                .observing(tracker)
        )

        _ = try await engine.fetch(DerivedQuery(), with: .root)

        let derivedWasFetched = await tracker.wasFetched(query: AnyQuery(DerivedQuery()))
        #expect(derivedWasFetched)

        let baseWasFetched = await tracker.wasFetched(query: AnyQuery(BaseQuery()))
        #expect(baseWasFetched)

        let count = await tracker.count
        #expect(count == 2)
    }

    @Test("Convenience Overload Matches Query Key Variant")
    func testConvenienceOverloadMatchesAnyQueryVariant() async throws {
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(tracker)
        )

        _ = try await engine.fetch(DerivedQuery(), with: .root)

        let typedDerived = await tracker.wasFetched(query: DerivedQuery())
        let keyDerived = await tracker.wasFetched(query: AnyQuery(DerivedQuery()))
        #expect(typedDerived == keyDerived)
        #expect(typedDerived)

        let typedBase = await tracker.wasFetched(query: BaseQuery())
        let keyBase = await tracker.wasFetched(query: AnyQuery(BaseQuery()))
        #expect(typedBase == keyBase)
        #expect(typedBase)
    }

}
