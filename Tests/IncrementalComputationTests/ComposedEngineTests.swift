import Testing
import IncrementalComputation

struct ComposedEngineTests {

    // MARK: - Basic Tests

    @Test("Basic Computation")
    func testBasicComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(BaseQuery(), with: .root)
        #expect(result == 10)
    }

    @Test("Derived Computation")
    func testDerivedComputation() async throws {
        let engine = ComposedEngine(interceptors: [])
        let result = try await engine.fetch(DerivedQuery(), with: .root)
        #expect(result == 15)
    }

    // MARK: - Full Incremental Engine Tests

    @Test("Incremental Engine Basic")
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
        #expect(result1 == 111)

        // Second fetch uses cache
        let result2 = try await engine.fetch(IncC(), with: .root)
        #expect(result2 == 111)

        // Verify caching worked: A, B, C all cached
        let cachedCount = await cache.count
        #expect(cachedCount == 3)

        let aCached = await cache.isCached(query: QueryKey(IncA()))
        #expect(aCached)

        let bCached = await cache.isCached(query: QueryKey(IncB()))
        #expect(bCached)

        let cCached = await cache.isCached(query: QueryKey(IncC()))
        #expect(cCached)
    }

    @Test("Incremental Engine With Cycle Detection")
    func testIncrementalEngineWithCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor(),
                CacheInterceptor(),
                ReverseDepsInterceptor()
            ]
        )

        await #expect(throws: CyclicDependencyError.self) {
            _ = try await engine.fetch(CyclicQueryA(), with: .root)
        }
    }
}
