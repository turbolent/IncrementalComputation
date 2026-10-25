import Testing
@testable import IncrementalComputation

@Suite(.timeLimit(.minutes(1)))
struct ParallelExecutionTests {

    // MARK: - Parallel Independent Queries Tests

    @Test("Parallel Independent Queries")
    func testParallelIndependentQueries() async throws {

        struct BlockingQuery: Query {
            typealias Value = Int

            /// Distinguishes the independent computations and their results.
            let id: Int

            /// Holds each computation until all three have started.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                await gate.wait()
                return id
            }
        }

        let engine = ComposedEngine(interceptorChain: InterceptorChain())

        let gate = TestGate()

        // Fetch all three queries concurrently.
        async let a = engine.fetch(BlockingQuery(id: 1, gate: gate), with: .root)
        async let b = engine.fetch(BlockingQuery(id: 2, gate: gate), with: .root)
        async let c = engine.fetch(BlockingQuery(id: 3, gate: gate), with: .root)

        // All three must enter their bodies before any can finish.
        await gate.waitForArrivals(3)
        await gate.release()
        let results = try await (a, b, c)

        #expect(results.0 == 1)
        #expect(results.1 == 2)
        #expect(results.2 == 3)
    }

    // MARK: - Parallel Queries with Shared Dependency Tests

    @Test("Parallel Queries With Shared Dependency")
    func testParallelQueriesWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int

            let counter: Counter

            /// Holds both dependency computations until they have started.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                await gate.wait()
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

            /// Passes the shared synchronization gate to the dependency.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let base = try await engine.fetch(
                    BaseQuery(counter: counter, gate: gate),
                    with: context
                )
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

            /// Passes the shared synchronization gate to the dependency.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let base = try await engine.fetch(
                    BaseQuery(counter: counter, gate: gate),
                    with: context
                )
                return base + 2
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedB")
            }

            static func == (lhs: DerivedB, rhs: DerivedB) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(interceptorChain: InterceptorChain())

        let counter = Counter()

        let gate = TestGate()

        // Fetch DerivedA and DerivedB concurrently.
        // Each computes BaseQuery because this engine has no cache or deduplication.
        async let a = engine.fetch(DerivedA(counter: counter, gate: gate), with: .root)
        async let b = engine.fetch(DerivedB(counter: counter, gate: gate), with: .root)

        // Both reads of the shared dependency must be active together.
        await gate.waitForArrivals(2)
        #expect(await counter.value == 2)
        await gate.release()
        let results = try await (a, b)

        #expect(results.0 == 11)
        #expect(results.1 == 12)
    }

    // MARK: - Concurrent Cache Access Tests

    @Test("Concurrent Cache Access")
    func testConcurrentCacheAccess() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
        )

        struct FastQuery: Query {
            let id: Int

            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                return id * 10
            }
        }

        // Cache two query results before starting concurrent fetches.
        _ = try await engine.fetch(FastQuery(id: 1), with: .root)
        _ = try await engine.fetch(FastQuery(id: 2), with: .root)

        // Fetch cached and uncached queries concurrently.
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

        // The cache must contain all four distinct queries.
        let count = await cache.count
        #expect(count == 4) // 1, 2, 3, 4
    }

    // MARK: - Parallel Execution with Reverse Deps Tests

    @Test("Parallel Execution With Reverse Deps")
    func testParallelExecutionWithReverseDeps() async throws {
        let reverseDeps = ReverseDepsInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(reverseDeps)
        )

        // Fetch queries with shared dependencies concurrently.
        async let r1 = engine.fetch(IncC(), with: .root)
        async let r2 = engine.fetch(IncB(), with: .root)

        let results = try await (r1, r2)

        #expect(results.0 == 111)
        #expect(results.1 == 11)

        // Both queries depend on A.
        let dependentsOfA = await reverseDeps.dependents(of: AnyQuery(IncA()))
        #expect(dependentsOfA.contains(AnyQuery(IncB())))
        #expect(dependentsOfA.contains(AnyQuery(IncC())))
    }

    // MARK: - No Deadlock on Cycles Tests

    @Test("No Cycle Deadlock In Parallel")
    func testNoCycleDeadlockInParallel() async throws {
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(CycleInterceptor())
        )

        // Start independent cyclic queries concurrently.
        // Each must throw CyclicDependencyError without deadlocking.
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

            /// Holds the producer until concurrent callers have joined.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                await gate.wait()
                return 42
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("ExpensiveQuery")
            }

            static func == (lhs: ExpensiveQuery, rhs: ExpensiveQuery) -> Bool {
                return true
            }
        }

        let flight = InFlightInterceptor()
        let gate = TestGate()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .deduplicating(with: flight)
        )

        // Launch five concurrent fetches of the same query.
        let counter = Counter()
        let query = ExpensiveQuery(counter: counter, gate: gate)
        async let r1 = engine.fetch(query, with: .root)
        async let r2 = engine.fetch(query, with: .root)
        async let r3 = engine.fetch(query, with: .root)
        async let r4 = engine.fetch(query, with: .root)
        async let r5 = engine.fetch(query, with: .root)

        await gate.waitForArrivals()
        try await waitForWaiters(4, in: flight, releasingOnFailure: gate)
        await gate.release()
        let results = try await (r1, r2, r3, r4, r5)

        // All fetches share the producer's result.
        #expect(results.0 == 42)
        #expect(results.1 == 42)
        #expect(results.2 == 42)
        #expect(results.3 == 42)
        #expect(results.4 == 42)

        // Deduplication executes the query body once.
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("In Flight Interceptor With Shared Dependency")
    func testInFlightInterceptorWithSharedDependency() async throws {

        struct BaseQuery: Query {
            typealias Value = Int

            let counter: Counter

            /// Holds the producer until concurrent callers have joined.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                await gate.wait()
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

            /// Holds the producer until concurrent callers have joined.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let base = try await engine.fetch(
                    BaseQuery(counter: counter, gate: gate),
                    with: context
                )
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

        let flight = InFlightInterceptor()
        let gate = TestGate()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .deduplicating(with: flight)
        )

        // Fetch three derived queries that share BaseQuery concurrently.
        let counter = Counter()
        async let r1 = engine.fetch(
            DerivedQuery(id: 1, counter: counter, gate: gate),
            with: .root
        )
        async let r2 = engine.fetch(
            DerivedQuery(id: 2, counter: counter, gate: gate),
            with: .root
        )
        async let r3 = engine.fetch(
            DerivedQuery(id: 3, counter: counter, gate: gate),
            with: .root
        )

        await gate.waitForArrivals()
        try await waitForWaiters(2, in: flight, releasingOnFailure: gate)
        await gate.release()
        let results = try await (r1, r2, r3)

        #expect(results.0 == 101)
        #expect(results.1 == 102)
        #expect(results.2 == 103)

        // Deduplication executes BaseQuery's body once.
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("In Flight Interceptor With Cache")
    func testInFlightInterceptorWithCache() async throws {

        struct Query1: Query {
            typealias Value = Int

            let counter: Counter

            /// Holds the producer until concurrent callers have joined.
            let gate: TestGate

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                await gate.wait()
                return 99
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("Query1")
            }

            static func == (lhs: Query1, rhs: Query1) -> Bool {
                return true
            }
        }

        // InFlight wraps the cache: only the producer resolves through memoization.
        let flight = InFlightInterceptor()
        let gate = TestGate()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
                .deduplicating(with: flight)
        )

        let counter = Counter()
        let query = Query1(counter: counter, gate: gate)

        // Deduplicate concurrent fetches and cache the result.
        async let r1 = engine.fetch(query, with: .root)
        async let r2 = engine.fetch(query, with: .root)
        async let r3 = engine.fetch(query, with: .root)

        await gate.waitForArrivals()
        try await waitForWaiters(2, in: flight, releasingOnFailure: gate)
        await gate.release()
        let results1 = try await (r1, r2, r3)

        #expect(results1.0 == 99)
        #expect(results1.1 == 99)
        #expect(results1.2 == 99)
        let countAfterFirstBatch = await counter.value
        #expect(countAfterFirstBatch == 1)

        // Later fetches return the memoized result without executing the body.
        async let r4 = engine.fetch(query, with: .root)
        async let r5 = engine.fetch(query, with: .root)

        let results2 = try await (r4, r5)

        #expect(results2.0 == 99)
        #expect(results2.1 == 99)
        // The body has still executed only once.
        let countAfterSecondBatch = await counter.value
        #expect(countAfterSecondBatch == 1)
    }

    @Test("In Flight Interceptor Sequential Fetches")
    func testInFlightInterceptorSequentialFetches() async throws {

        struct Query2: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
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
            interceptorChain: InterceptorChain()
                .deduplicating(with: InFlightInterceptor())
        )

        let counter = Counter()

        // Sequential fetches each execute because in-flight deduplication
        // retains no completed results.
        let result1 = try await engine.fetch(Query2(counter: counter), with: .root)
        let result2 = try await engine.fetch(Query2(counter: counter), with: .root)
        let result3 = try await engine.fetch(Query2(counter: counter), with: .root)

        #expect(result1 == 10)
        #expect(result2 == 20)
        #expect(result3 == 30)
        let count = await counter.value
        #expect(count == 3)
    }

    /// Waits until every expected caller has joined the held producer.
    private func waitForWaiters(
        _ count: Int,
        in interceptor: InFlightInterceptor,
        releasingOnFailure gate: TestGate
    ) async throws {
        do {
            while await interceptor.waiterCount < count {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            await gate.release()
            throw error
        }
    }
}
