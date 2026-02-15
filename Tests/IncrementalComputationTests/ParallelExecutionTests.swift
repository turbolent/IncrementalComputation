import Testing
import Foundation
import IncrementalComputation

struct ParallelExecutionTests {

    // MARK: - Parallel Independent Queries Tests

    @Test("Parallel Independent Queries")
    func testParallelIndependentQueries() async throws {

        struct QueryA: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                return 1
            }
        }

        struct QueryB: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                return 2
            }
        }

        struct QueryC: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                return 3
            }
        }

        let engine = ComposedEngine(interceptors: [])

        let startTime = Date()

        // Fetch all three queries concurrently
        async let a = engine.fetch(QueryA(), with: .root)
        async let b = engine.fetch(QueryB(), with: .root)
        async let c = engine.fetch(QueryC(), with: .root)

        let results = try await (a, b, c)

        let elapsed = Date().timeIntervalSince(startTime)

        #expect(results.0 == 1)
        #expect(results.1 == 2)
        #expect(results.2 == 3)

        // Should complete in ~1s (parallel) not ~3s (serial)
        // Allow some overhead but verify it's closer to parallel than serial
        #expect(elapsed < 1.5) // 1.5s threshold (generous for CI)
    }

    // MARK: - Parallel Queries with Shared Dependency Tests

    @Test("Parallel Queries With Shared Dependency")
    func testParallelQueriesWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                _ = await counter.increment()
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                return 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("BaseQuery")
            }

            static func == (lhs: BaseQuery, rhs: BaseQuery) -> Bool {
                return true
            }
        }

        struct DerivedA: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                let base = try await engine.fetch(BaseQuery(counter: counter), with: context)
                return base + 1
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedA")
            }

            static func == (lhs: DerivedA, rhs: DerivedA) -> Bool {
                return true
            }
        }

        struct DerivedB: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                let base = try await engine.fetch(BaseQuery(counter: counter), with: context)
                return base + 2
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedB")
            }

            static func == (lhs: DerivedB, rhs: DerivedB) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(interceptors: [])

        let counter = Counter()

        let startTime = Date()

        // Fetch DerivedA and DerivedB concurrently
        // Both depend on BaseQuery, which should only be computed once
        async let a = engine.fetch(DerivedA(counter: counter), with: .root)
        async let b = engine.fetch(DerivedB(counter: counter), with: .root)

        let results = try await (a, b)

        let elapsed = Date().timeIntervalSince(startTime)

        #expect(results.0 == 11)
        #expect(results.1 == 12)

        // Should complete in ~1s (parallel) not ~2s (serial)
        // Allow some overhead but verify it's closer to parallel than serial
        #expect(elapsed < 1.5) // 1.5s threshold (generous for CI)
    }

    // MARK: - Concurrent Cache Access Tests

    @Test("Concurrent Cache Access")
    func testConcurrentCacheAccess() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(interceptors: [cache])

        struct FastQuery: Query {
            let id: Int

            typealias Value = Int

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                return id * 10
            }
        }

        // Pre-populate cache with some queries
        _ = try await engine.fetch(FastQuery(id: 1), with: .root)
        _ = try await engine.fetch(FastQuery(id: 2), with: .root)

        // Now fetch mix of cached and non-cached queries concurrently
        async let r1 = engine.fetch(FastQuery(id: 1), with: .root) // cached
        async let r2 = engine.fetch(FastQuery(id: 2), with: .root) // cached
        async let r3 = engine.fetch(FastQuery(id: 3), with: .root) // not cached
        async let r4 = engine.fetch(FastQuery(id: 4), with: .root) // not cached
        async let r5 = engine.fetch(FastQuery(id: 1), with: .root) // cached
        async let r6 = engine.fetch(FastQuery(id: 3), with: .root) // might be cached by now

        let results = try await (r1, r2, r3, r4, r5, r6)

        #expect(results.0 == 10)
        #expect(results.1 == 20)
        #expect(results.2 == 30)
        #expect(results.3 == 40)
        #expect(results.4 == 10)
        #expect(results.5 == 30)

        // Verify cache is in consistent state
        let count = await cache.count
        #expect(count == 4) // 1, 2, 3, 4
    }

    // MARK: - Parallel Execution with Reverse Deps Tests

    @Test("Parallel Execution With Reverse Deps")
    func testParallelExecutionWithReverseDeps() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [reverseDeps])

        // Fetch multiple queries concurrently that have dependencies
        async let r1 = engine.fetch(IncC(), with: .root)
        async let r2 = engine.fetch(IncB(), with: .root)

        let results = try await (r1, r2)

        #expect(results.0 == 111)
        #expect(results.1 == 11)

        // Verify reverse dependencies were tracked correctly
        let dependentsOfA = await reverseDeps.dependents(of: QueryKey(IncA()))
        #expect(dependentsOfA.contains(QueryKey(IncB())))
        #expect(dependentsOfA.contains(QueryKey(IncC())))
    }

    // MARK: - No Deadlock on Cycles Tests

    @Test("No Cycle Deadlock In Parallel")
    func testNoCycleDeadlockInParallel() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )

        // Start multiple independent cyclic queries concurrently
        // Each should fail with CyclicDependencyError without deadlock
        async let r1 = engine.fetch(CyclicQueryA(), with: .root)
        async let r2 = engine.fetch(SelfReferentialQuery(), with: .root)

        do {
            _ = try await r1
            Issue.record("Expected CyclicDependencyError for r1")
        } catch is CyclicDependencyError {
            // Expected
        }

        do {
            _ = try await r2
            Issue.record("Expected CyclicDependencyError for r2")
        } catch is CyclicDependencyError {
            // Expected
        }
    }

    // MARK: - InFlightInterceptor Tests

    @Test("In Flight Interceptor Deduplication")
    func testInFlightInterceptorDeduplication() async throws {

        struct ExpensiveQuery: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                _ = await counter.increment()
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                return 42
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("ExpensiveQuery")
            }

            static func == (lhs: ExpensiveQuery, rhs: ExpensiveQuery) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                InFlightInterceptor()
            ]
        )

        let startTime = Date()

        // Launch 5 concurrent fetches of the same querys
        let counter = Counter()
        async let r1 = engine.fetch(ExpensiveQuery(counter: counter), with: .root)
        async let r2 = engine.fetch(ExpensiveQuery(counter: counter), with: .root)
        async let r3 = engine.fetch(ExpensiveQuery(counter: counter), with: .root)
        async let r4 = engine.fetch(ExpensiveQuery(counter: counter), with: .root)
        async let r5 = engine.fetch(ExpensiveQuery(counter: counter), with: .root)

        let results = try await (r1, r2, r3, r4, r5)

        let elapsed = Date().timeIntervalSince(startTime)

        // All fetches should return the same value
        #expect(results.0 == 42)
        #expect(results.1 == 42)
        #expect(results.2 == 42)
        #expect(results.3 == 42)
        #expect(results.4 == 42)

        // Should only compute once
        let count = await counter.value
        #expect(count == 1)

        // Should complete in ~0.5s (single computation) not ~2.5s (5 computations)
        #expect(elapsed < 1.0)
    }

    @Test("In Flight Interceptor With Shared Dependency")
    func testInFlightInterceptorWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                _ = await counter.increment()
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                return 100
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("BaseQuery")
            }

            static func == (lhs: BaseQuery, rhs: BaseQuery) -> Bool {
                return true
            }
        }

        struct DerivedQuery: Query {
            typealias Value = Int

            let id: Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                let base = try await engine.fetch(BaseQuery(counter: counter), with: context)
                return base + id
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedQuery")
                hasher.combine(id)
            }

            static func == (lhs: DerivedQuery, rhs: DerivedQuery) -> Bool {
                return lhs.id == rhs.id
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                InFlightInterceptor()
            ]
        )

        let startTime = Date()

        // Launch multiple derived queries concurrently that all depend on BaseQuery
        let counter = Counter()
        async let r1 = engine.fetch(DerivedQuery(id: 1, counter: counter), with: .root)
        async let r2 = engine.fetch(DerivedQuery(id: 2, counter: counter), with: .root)
        async let r3 = engine.fetch(DerivedQuery(id: 3, counter: counter), with: .root)

        let results = try await (r1, r2, r3)

        let elapsed = Date().timeIntervalSince(startTime)

        #expect(results.0 == 101)
        #expect(results.1 == 102)
        #expect(results.2 == 103)

        // BaseQuery should only compute once (deduplication)
        let count = await counter.value
        #expect(count == 1)

        // Should complete in ~0.5s (single BaseQuery computation) not ~1.5s (3 computations)
        #expect(elapsed < 1.0)
    }

    @Test("In Flight Interceptor With Cache")
    func testInFlightInterceptorWithCache() async throws {

        struct Query1: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                _ = await counter.increment()
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                return 99
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("Query1")
            }

            static func == (lhs: Query1, rhs: Query1) -> Bool {
                return true
            }
        }

        // Cache before InFlight: check cache first, then deduplicate
        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor(),
                InFlightInterceptor()
            ]
        )

        let counter = Counter()

        // First batch: concurrent fetches (should be deduplicated and cached)
        async let r1 = engine.fetch(Query1(counter: counter), with: .root)
        async let r2 = engine.fetch(Query1(counter: counter), with: .root)
        async let r3 = engine.fetch(Query1(counter: counter), with: .root)

        let results1 = try await (r1, r2, r3)

        #expect(results1.0 == 99)
        #expect(results1.1 == 99)
        #expect(results1.2 == 99)
        let countAfterFirstBatch = await counter.value
        #expect(countAfterFirstBatch == 1)

        // Second batch: should use cache (no computation)
        async let r4 = engine.fetch(Query1(counter: counter), with: .root)
        async let r5 = engine.fetch(Query1(counter: counter), with: .root)

        let results2 = try await (r4, r5)

        #expect(results2.0 == 99)
        #expect(results2.1 == 99)
        // Counter should still be 1 (cached)
        let countAfterSecondBatch = await counter.value
        #expect(countAfterSecondBatch == 1)
    }

    @Test("In Flight Interceptor Sequential Fetches")
    func testInFlightInterceptorSequentialFetches() async throws {

        struct Query2: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                let count = await counter.increment()
                return count * 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("Query2")
            }

            static func == (lhs: Query2, rhs: Query2) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                 InFlightInterceptor()
            ]
        )

        let counter = Counter()

        // Sequential fetches should NOT be deduplicated
        // (only concurrent ones are deduplicated)
        let result1 = try await engine.fetch(Query2(counter: counter), with: .root)
        let result2 = try await engine.fetch(Query2(counter: counter), with: .root)
        let result3 = try await engine.fetch(Query2(counter: counter), with: .root)

        #expect(result1 == 10)
        #expect(result2 == 20)
        #expect(result3 == 30)
        let count = await counter.value
        #expect(count == 3)
    }
}
