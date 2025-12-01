import IncrementalComputation

// MARK: - Query Definitions

/// Each cell is its own query type with its specific return type.

struct CellA: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        print("Fetching A")
        return 10
    }
}

struct CellB: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        print("Fetching B")
        let a = try await engine.fetch(CellA())
        return a + 20
    }
}

struct CellC: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        print("Fetching C")
        let a = try await engine.fetch(CellA())
        return a + 30
    }
}

struct CellD: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        print("Fetching D")
        let b = try await engine.fetch(CellB())
        let c = try await engine.fetch(CellC())
        return b + c
    }
}

// MARK: - Main

@main
struct SpreadsheetExample {
    static func main() async throws {
        // Run without memoization - A will be fetched multiple times
        print("=== Running without memoization ===")
        let basicEngine = ComposedEngine(interceptors: [])
        let result1 = try await basicEngine.fetch(CellD())
        print("Result: D = \(result1)")
        print()

        // Run with memoization - A will only be fetched once
        print("=== Running with memoization ===")
        let memoEngine = ComposedEngine(interceptors: [CacheInterceptor()])
        let result2 = try await memoEngine.fetch(CellD())
        print("Result: D = \(result2)")
        print()

        // Run with tracking
        print("=== Running with tracking ===")
        let tracker = TrackingInterceptor()
        let trackingEngine = ComposedEngine(interceptors: [tracker])
        let result3 = try await trackingEngine.fetch(CellD())
        print("Result: D = \(result3)")
        print("Fetched \(tracker.count) unique queries")
        print()

        // Run with full incremental engine (cycle detection + memoization + reverse deps)
        print("=== Running with full incremental engine ===")
        let cache = CacheInterceptor()
        let incrementalEngine = ComposedEngine(interceptors: [
            CycleInterceptor(),
            cache,
            ReverseDepsInterceptor()
        ])
        let result4 = try await incrementalEngine.fetch(CellD())
        print("Result: D = \(result4)")
        print("Cached \(cache.count) queries")
    }
}
