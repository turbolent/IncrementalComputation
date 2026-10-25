import IncrementalComputation

// MARK: - Query Definitions

/// Each cell defines a query and its result type.

struct CellA: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        print("Fetching A")
        return 10
    }
}

struct CellB: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        print("Fetching B")
        let a = try await engine.fetch(CellA(), with: context)
        return a + 20
    }
}

struct CellC: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        print("Fetching C")
        let a = try await engine.fetch(CellA(), with: context)
        return a + 30
    }
}

struct CellD: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        print("Fetching D")
        let b = try await engine.fetch(CellB(), with: context)
        let c = try await engine.fetch(CellC(), with: context)
        return b + c
    }
}

// MARK: - Main

@main
struct SpreadsheetExample {
    static func main() async throws {
        // Without memoization, A's body executes for each fetch.
        print("=== Running without memoization ===")
        let basicEngine = ComposedEngine(interceptorChain: InterceptorChain())
        let result1 = try await basicEngine.fetch(CellD(), with: .root)
        print("Result: D = \(result1)")
        print()

        // With memoization, A's body executes once.
        print("=== Running with memoization ===")
        let memoEngine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
        )
        let result2 = try await memoEngine.fetch(CellD(), with: .root)
        print("Result: D = \(result2)")
        print()

        // Track which queries are fetched.
        print("=== Running with tracking ===")
        let tracker = TrackingInterceptor()
        let trackingEngine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(tracker)
        )
        let result3 = try await trackingEngine.fetch(CellD(), with: .root)
        print("Result: D = \(result3)")
        print("Fetched \(await tracker.count) unique queries")
        print()

        // Combine cycle detection, memoization, and reverse-dependency tracking.
        print("=== Running with full incremental engine ===")
        let cache = CacheInterceptor()
        let incrementalEngine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .observing(CycleInterceptor())
                .memoizing(with: cache)
                .observing(ReverseDepsInterceptor())
        )
        let result4 = try await incrementalEngine.fetch(CellD(), with: .root)
        print("Result: D = \(result4)")
        print("Cached \(await cache.count) queries")
    }
}
