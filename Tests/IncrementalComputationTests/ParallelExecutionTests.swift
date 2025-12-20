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
}
