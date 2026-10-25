import Testing
import IncrementalComputation

struct ComposedEngineTests {

    // MARK: - Basic Tests

    @Test("Basic Computation")
    func testBasicComputation() async throws {
        let engine = ComposedEngine(interceptorChain: InterceptorChain())
        let result = try await engine.fetch(BaseQuery(), with: .root)
        #expect(result == 10)
    }

    @Test("Derived Computation")
    func testDerivedComputation() async throws {
        let engine = ComposedEngine(interceptorChain: InterceptorChain())
        let result = try await engine.fetch(DerivedQuery(), with: .root)
        #expect(result == 15)
    }

    // MARK: - Full Incremental Engine Tests

    @Test("Incremental Engine Basic")
    func testIncrementalEngineBasic() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(CycleInterceptor())
                .memoizing(with: cache)
                .observing(ReverseDepsInterceptor())
        )

        let result1 = try await engine.fetch(IncC(), with: .root)
        #expect(result1 == 111)

        // The second fetch returns the memoized value.
        let result2 = try await engine.fetch(IncC(), with: .root)
        #expect(result2 == 111)

        // A, B, and C each have a cached result.
        let cachedCount = await cache.count
        #expect(cachedCount == 3)

        let aCached = await cache.isCached(query: AnyQuery(IncA()))
        #expect(aCached)

        let bCached = await cache.isCached(query: AnyQuery(IncB()))
        #expect(bCached)

        let cCached = await cache.isCached(query: AnyQuery(IncC()))
        #expect(cCached)
    }

    @Test("Incremental Engine With Cycle Detection")
    func testIncrementalEngineWithCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(CycleInterceptor())
                .memoizing(with: CacheInterceptor())
                .observing(ReverseDepsInterceptor())
        )

        await #expect(throws: CyclicDependencyError.self) {
            _ = try await engine.fetch(CyclicQueryA(), with: .root)
        }
    }
}
