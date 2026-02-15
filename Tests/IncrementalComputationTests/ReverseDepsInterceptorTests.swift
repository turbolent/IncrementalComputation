import Testing
import IncrementalComputation

struct ReverseDepsInterceptorTests {

    @Test("Reverse Dependency Tracking")
    func testReverseDependencyTracking() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptors: [
                reverseDeps
            ]
        )

        _ = try await engine.fetch(IncC(), with: .root)

        // Check that dependencies were tracked
        let dependentsOfA = await reverseDeps.dependents(of: QueryKey(IncA()))
        #expect(dependentsOfA.contains(QueryKey(IncB())))
        #expect(dependentsOfA.contains(QueryKey(IncC())))
    }

    @Test("Invalidation")
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
        #expect(result1 == 111)

        let aCached = await cache.isCached(query: QueryKey(IncA()))
        let bCached = await cache.isCached(query: QueryKey(IncB()))
        let cCached = await cache.isCached(query: QueryKey(IncC()))
        #expect(aCached)
        #expect(bCached)
        #expect(cCached)

        // Invalidate A - should also invalidate B and C
        let invalidated = await reverseDeps.invalidate(query: QueryKey(IncA()))
        #expect(invalidated.contains(QueryKey(IncA())))
        #expect(invalidated.contains(QueryKey(IncB())))
        #expect(invalidated.contains(QueryKey(IncC())))

        // Clear invalidated entries from cache
        for query in invalidated {
            await cache.clear(query: query)
        }

        let aNotCached = await cache.isCached(query: QueryKey(IncA()))
        let bNotCached = await cache.isCached(query: QueryKey(IncB()))
        let cNotCached = await cache.isCached(query: QueryKey(IncC()))
        #expect(!(aNotCached))
        #expect(!(bNotCached))
        #expect(!(cNotCached))
    }

    @Test("Partial Invalidation")
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
        let invalidated = await reverseDeps.invalidate(query: QueryKey(IncB()))
        #expect(!(invalidated.contains(QueryKey(IncA()))))
        #expect(invalidated.contains(QueryKey(IncB())))
        #expect(invalidated.contains(QueryKey(IncC())))

        // A should still be cached
        let aStillCached = await cache.isCached(query: QueryKey(IncA()))
        #expect(aStillCached)
    }

    @Test("Convenience Overloads Match Query Key Variants")
    func testConvenienceOverloadsMatchQueryKeyVariants() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [reverseDeps])

        _ = try await engine.fetch(IncC(), with: .root)

        let dependentsViaTyped = await reverseDeps.dependents(of: IncA())
        let dependentsViaKey = await reverseDeps.dependents(of: QueryKey(IncA()))
        #expect(dependentsViaTyped == dependentsViaKey)

        let directViaTyped = await reverseDeps.directDependents(of: IncA())
        let directViaKey = await reverseDeps.directDependents(of: QueryKey(IncA()))
        #expect(directViaTyped == directViaKey)

        let invalidatedViaTyped = await reverseDeps.invalidate(query: IncA())

        let reverseDeps2 = ReverseDepsInterceptor()
        let engine2 = ComposedEngine(interceptors: [reverseDeps2])
        _ = try await engine2.fetch(IncC(), with: .root)
        let invalidatedViaKey = await reverseDeps2.invalidate(query: QueryKey(IncA()))

        #expect(invalidatedViaTyped == invalidatedViaKey)
    }
}
