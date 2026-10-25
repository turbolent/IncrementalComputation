import Testing
import IncrementalComputation

struct ReverseDepsInterceptorTests {

    @Test("Reverse Dependency Tracking")
    func testReverseDependencyTracking() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(reverseDeps)
        )

        _ = try await engine.fetch(IncC(), with: .root)

        // Check the recorded dependencies.
        let dependentsOfA = await reverseDeps.dependents(of: AnyQuery(IncA()))
        #expect(dependentsOfA.contains(AnyQuery(IncB())))
        #expect(dependentsOfA.contains(AnyQuery(IncC())))
    }

    @Test("Invalidation")
    func testInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .observing(reverseDeps)
        )

        let result1 = try await engine.fetch(IncC(), with: .root)
        #expect(result1 == 111)

        let aCached = await cache.isCached(query: AnyQuery(IncA()))
        let bCached = await cache.isCached(query: AnyQuery(IncB()))
        let cCached = await cache.isCached(query: AnyQuery(IncC()))
        #expect(aCached)
        #expect(bCached)
        #expect(cCached)

        // Invalidating A also invalidates B and C.
        let invalidated = await reverseDeps.invalidate(query: AnyQuery(IncA()))
        #expect(invalidated.contains(AnyQuery(IncA())))
        #expect(invalidated.contains(AnyQuery(IncB())))
        #expect(invalidated.contains(AnyQuery(IncC())))

        // Clear the invalidated cache entries.
        for query in invalidated {
            await cache.clear(query: query)
        }

        let aNotCached = await cache.isCached(query: AnyQuery(IncA()))
        let bNotCached = await cache.isCached(query: AnyQuery(IncB()))
        let cNotCached = await cache.isCached(query: AnyQuery(IncC()))
        #expect(!(aNotCached))
        #expect(!(bNotCached))
        #expect(!(cNotCached))
    }

    @Test("Partial Invalidation")
    func testPartialInvalidation() async throws {
        let cache = CacheInterceptor()
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .observing(reverseDeps)
        )

        _ = try await engine.fetch(IncC(), with: .root)

        // Invalidating B also invalidates C; A remains cached.
        let invalidated = await reverseDeps.invalidate(query: AnyQuery(IncB()))
        #expect(!(invalidated.contains(AnyQuery(IncA()))))
        #expect(invalidated.contains(AnyQuery(IncB())))
        #expect(invalidated.contains(AnyQuery(IncC())))

        // A's cached result remains valid.
        let aStillCached = await cache.isCached(query: AnyQuery(IncA()))
        #expect(aStillCached)
    }

    @Test("Convenience Overloads Match Query Key Variants")
    func testConvenienceOverloadsMatchAnyQueryVariants() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(reverseDeps)
        )

        _ = try await engine.fetch(IncC(), with: .root)

        let dependentsViaTyped = await reverseDeps.dependents(of: IncA())
        let dependentsViaKey = await reverseDeps.dependents(of: AnyQuery(IncA()))
        #expect(dependentsViaTyped == dependentsViaKey)

        let directViaTyped = await reverseDeps.directDependents(of: IncA())
        let directViaKey = await reverseDeps.directDependents(of: AnyQuery(IncA()))
        #expect(directViaTyped == directViaKey)

        let invalidatedViaTyped = await reverseDeps.invalidate(query: IncA())

        let reverseDeps2 = ReverseDepsInterceptor()
        let engine2 = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(reverseDeps2)
        )
        _ = try await engine2.fetch(IncC(), with: .root)
        let invalidatedViaKey = await reverseDeps2.invalidate(query: AnyQuery(IncA()))

        #expect(invalidatedViaTyped == invalidatedViaKey)
    }
}
