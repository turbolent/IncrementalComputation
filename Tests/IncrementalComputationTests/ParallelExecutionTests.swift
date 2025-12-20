import XCTest
import IncrementalComputation

final class ParallelExecutionTests: XCTestCase {

    // MARK: - Parallel Independent Queries Tests

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

        XCTAssertEqual(results.0, 1)
        XCTAssertEqual(results.1, 2)
        XCTAssertEqual(results.2, 3)

        // Should complete in ~1s (parallel) not ~3s (serial)
        // Allow some overhead but verify it's closer to parallel than serial
        XCTAssertLessThan(elapsed, 1.5) // 1.5s threshold (generous for CI)
    }

    // MARK: - Parallel Queries with Shared Dependency Tests

    func testParallelQueriesWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                counter.count += 1
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

        XCTAssertEqual(results.0, 11)
        XCTAssertEqual(results.1, 12)

        // Should complete in ~1s (parallel) not ~2s (serial)
        // Allow some overhead but verify it's closer to parallel than serial
        XCTAssertLessThan(elapsed, 1.5) // 1.5s threshold (generous for CI)
    }

    // MARK: - Concurrent Cache Access Tests

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

        XCTAssertEqual(results.0, 10)
        XCTAssertEqual(results.1, 20)
        XCTAssertEqual(results.2, 30)
        XCTAssertEqual(results.3, 40)
        XCTAssertEqual(results.4, 10)
        XCTAssertEqual(results.5, 30)

        // Verify cache is in consistent state
        let count = await cache.count
        XCTAssertEqual(count, 4) // 1, 2, 3, 4
    }

    // MARK: - Parallel Execution with Reverse Deps Tests

    func testParallelExecutionWithReverseDeps() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(interceptors: [reverseDeps])

        // Fetch multiple queries concurrently that have dependencies
        async let r1 = engine.fetch(IncC(), with: .root)
        async let r2 = engine.fetch(IncB(), with: .root)

        let results = try await (r1, r2)

        XCTAssertEqual(results.0, 111)
        XCTAssertEqual(results.1, 11)

        // Verify reverse dependencies were tracked correctly
        let dependentsOfA = await reverseDeps.dependents(of: AnyHashable(IncA()))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncB())))
        XCTAssertTrue(dependentsOfA.contains(AnyHashable(IncC())))
    }

    // MARK: - No Deadlock on Cycles Tests

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
            XCTFail("Expected CyclicDependencyError for r1")
        } catch is CyclicDependencyError {
            // Expected
        }

        do {
            _ = try await r2
            XCTFail("Expected CyclicDependencyError for r2")
        } catch is CyclicDependencyError {
            // Expected
        }
    }

    // MARK: - InFlightInterceptor Tests

    func testInFlightInterceptorDeduplication() async throws {

        struct ExpensiveQuery: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                counter.count += 1
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
        XCTAssertEqual(results.0, 42)
        XCTAssertEqual(results.1, 42)
        XCTAssertEqual(results.2, 42)
        XCTAssertEqual(results.3, 42)
        XCTAssertEqual(results.4, 42)

        // Should only compute once
        XCTAssertEqual(counter.count, 1)

        // Should complete in ~0.5s (single computation) not ~2.5s (5 computations)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testInFlightInterceptorWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                counter.count += 1
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

        XCTAssertEqual(results.0, 101)
        XCTAssertEqual(results.1, 102)
        XCTAssertEqual(results.2, 103)

        // BaseQuery should only compute once (deduplication)
        XCTAssertEqual(counter.count, 1)

        // Should complete in ~0.5s (single BaseQuery computation) not ~1.5s (3 computations)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testInFlightInterceptorWithCache() async throws {

        struct Query1: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                counter.count += 1
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

        XCTAssertEqual(results1.0, 99)
        XCTAssertEqual(results1.1, 99)
        XCTAssertEqual(results1.2, 99)
        XCTAssertEqual(counter.count, 1)

        // Second batch: should use cache (no computation)
        async let r4 = engine.fetch(Query1(counter: counter), with: .root)
        async let r5 = engine.fetch(Query1(counter: counter), with: .root)

        let results2 = try await (r4, r5)

        XCTAssertEqual(results2.0, 99)
        XCTAssertEqual(results2.1, 99)
        // Counter should still be 1 (cached)
        XCTAssertEqual(counter.count, 1)
    }

    func testInFlightInterceptorSequentialFetches() async throws {

        struct Query2: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
                counter.count += 1
                return counter.count * 10
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

        XCTAssertEqual(result1, 10)
        XCTAssertEqual(result2, 20)
        XCTAssertEqual(result3, 30)
        XCTAssertEqual(counter.count, 3)
    }
}
