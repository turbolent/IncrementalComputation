# IncrementalComputation for Swift

A simple incremental computation library using composable interceptors.

## Installation

Add IncrementalComputation to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/turbolent/IncrementalComputation.git")
]
```

## Quick Start

### 1. Define Queries

Each query is a struct that conforms to `Query`:

```swift
import IncrementalComputation

struct GetUser: Query {
    typealias Value = User

    let id: Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> User {
        // Fetch from database, API, etc.
        return User(id: id, name: "User \(id)")
    }
}

struct GetPosts: Query {
    typealias Value = [Post]
    let userId: Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> [Post] {
        // Can depend on other queries - context is passed through
        let user = try await engine.fetch(GetUser(id: userId), with: context)
        return [Post(author: user.name, title: "Hello")]
    }
}
```

### 2. Create a ComposedEngine with Interceptors

```swift
// Basic engine - no interceptors
let basic = ComposedEngine(interceptors: [])

// With memoization (caching)
let cached = ComposedEngine(interceptors: [CacheInterceptor()])

// With cycle detection
let safe = ComposedEngine(interceptors: [CycleInterceptor()])

// Full incremental engine: cycle detection + caching + reverse deps
let incremental = ComposedEngine(interceptors: [
    CycleInterceptor(),
    CacheInterceptor(),
    ReverseDepsInterceptor()
])

// Fetch queries - pass .root context for top-level calls
let user = try await incremental.fetch(GetUser(id: 1), with: .root)
```

## API Reference

### `Query`

A query defines a request for a value and how to compute it.

```swift
protocol Query: Hashable {
    associatedtype Value

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Value
}
```

**Important**: Always pass the `context` parameter to nested `fetch` calls to maintain the execution chain.

### `QueryEngine`

An engine executes queries.

```swift
protocol QueryEngine {
    func fetch<Q: Query>(_ query: Q, with context: ExecutionContext) async throws -> Q.Value
}
```

### `ExecutionContext`

Tracks the current query execution chain for cycle detection and dependency tracking.

```swift
// Top-level calls use .root
let result = try await engine.fetch(MyQuery(), with: .root)

// Nested calls pass the context through
func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Value {
    let dep = try await engine.fetch(Dependency(), with: context)
    return process(dep)
}
```

### `ComposedEngine`

A composable engine that uses interceptors to provide different behaviors:

```swift
let engine = ComposedEngine(interceptors: [
    CycleInterceptor(),
    CacheInterceptor(),
    ReverseDepsInterceptor()
])
```

**NOTE**: [Interceptor ordering matters!](#interceptor-ordering)

## Interceptors

### `QueryInterceptor`

Protocol for interceptors that can modify query execution.
Interceptors must be actors to provide thread-safe access.

```swift
protocol QueryInterceptor: Actor {

    /// Called before fetching a query.
    func willFetch(query: AnyHashable, context: ExecutionContext) async throws -> Any?

    /// Called after a query value has been computed.
    func didCompute(query: AnyHashable, value: Any, context: ExecutionContext) async
}
```

### `CacheInterceptor`

Caches query results (memoization):

```swift
let cache = CacheInterceptor()
let engine = ComposedEngine(interceptors: [cache])

_ = try await engine.fetch(MyQuery(), with: .root)
_ = try await engine.fetch(MyQuery(), with: .root)  // Returns cached result

let isCached = await cache.isCached(query: AnyHashable(MyQuery()))  // true
let count = await cache.count   // 1
await cache.clear()  // Clear all cached values
```

### `CycleInterceptor`

Detects cyclic dependencies and throws `CyclicDependencyError`:

```swift
let engine = ComposedEngine(interceptors: [CycleInterceptor()])

do {
    _ = try await engine.fetch(SelfReferentialQuery(), with: .root)
} catch is CyclicDependencyError {
    print("Cycle detected!")
}
```

### `ReverseDepsInterceptor`

Tracks reverse dependencies for invalidation:

```swift
let reverseDeps = ReverseDepsInterceptor()
let cache = CacheInterceptor()
let engine = ComposedEngine(interceptors: [cache, reverseDeps])

_ = try await engine.fetch(CellD(), with: .root)  // D depends on B, C; B, C depend on A

// Find all queries that depend on A
let dependents = await reverseDeps.dependents(of: AnyHashable(CellA()))
// Returns: {B, C, D}

// Invalidate A and all its dependents
let invalidated = await reverseDeps.invalidate(query: AnyHashable(CellA()))
for query in invalidated {
    await cache.clear(query: query)
}
```

### `TrackingInterceptor`

Records which queries were fetched (useful for debugging/testing):

```swift
let tracker = TrackingInterceptor()
let engine = ComposedEngine(interceptors: [tracker])

_ = try await engine.fetch(CellD(), with: .root)

await tracker.count  // Number of unique queries fetched
await tracker.wasFetched(query: AnyHashable(CellA()))  // true
await tracker.reset()  // Clear tracking
```

### `InFlightInterceptor`

Deduplicates concurrent fetches of the same query.
When multiple tasks fetch the same query simultaneously,
only the first performs the computation while others wait for and share the result:

```swift
let inFlight = InFlightInterceptor()
let engine = ComposedEngine(interceptors: [inFlight])

// Launch 5 concurrent fetches of the same expensive query
async let r1 = engine.fetch(ExpensiveQuery(), with: .root)
async let r2 = engine.fetch(ExpensiveQuery(), with: .root)
async let r3 = engine.fetch(ExpensiveQuery(), with: .root)
async let r4 = engine.fetch(ExpensiveQuery(), with: .root)
async let r5 = engine.fetch(ExpensiveQuery(), with: .root)

let results = try await (r1, r2, r3, r4, r5)
// ExpensiveQuery computed only once, all 5 calls get the same result
```

**Use Cases:**
- Expensive queries (database, API calls) that might be triggered multiple times concurrently
- Queries with shared dependencies that execute in parallel
- Preventing redundant work in highly concurrent scenarios

**Ordering with CacheInterceptor:**
```swift
// Option 1: Cache before InFlight (recommended)
// Cached values served immediately, only non-cached queries deduplicated
ComposedEngine(interceptors: [CacheInterceptor(), InFlightInterceptor()])

// Option 2: InFlight before Cache
// All concurrent fetches deduplicated first, then cached
ComposedEngine(interceptors: [InFlightInterceptor(), CacheInterceptor()])
```

**Note:** InFlightInterceptor only deduplicates _concurrent_ fetches.
Sequential fetches of the same query will compute independently.
Use `CacheInterceptor` for persistent memoization across sequential calls.

### Custom Interceptors

Create your own interceptor by implementing `QueryInterceptor` as an actor:

```swift
actor LoggingInterceptor: QueryInterceptor {

    func willFetch(query: AnyHashable, context: ExecutionContext) async throws -> Any? {
        print("Fetching: \(query)")
        return nil  // Continue with computation
    }

    func didCompute(query: AnyHashable, value: Any, context: ExecutionContext) async {
        print("Computed: \(query) = \(value)")
    }
}

let engine = ComposedEngine(interceptors: [
    LoggingInterceptor(),
    CacheInterceptor()
])
```

### Interceptor Ordering

**Interceptor order matters!** In `ComposedEngine`:
- `willFetch` is called in order until one returns a cached value (short-circuit)
- `didCompute` is called in reverse order, only after actual computation

**Recommended order:**
```swift
ComposedEngine(interceptors: [
    CycleInterceptor(),      // 1. Check for cycles first
    CacheInterceptor(),      // 2. Return cached value if available
    ReverseDepsInterceptor() // 3. Track dependencies (for non-cached fetches)
])
```

**Why this order:**
1. `CycleInterceptor` first - detect cycles before any other processing
2. `CacheInterceptor` second - return cached values early to avoid unnecessary work
3. `ReverseDepsInterceptor` last - manages internal tracking that requires matched `willFetch`/`didCompute` calls

With this order, cached queries won't have new dependencies recorded.
This is typically fine since dependencies are established during first computation and rebuilt after invalidation.


## Example: Spreadsheet

```swift
struct CellA: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
        return 10
    }
}

struct CellB: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
        let a = try await engine.fetch(CellA(), with: context)
        return a + 20
    }
}

struct CellC: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
        let a = try await engine.fetch(CellA(), with: context)
        return a + 30
    }
}

struct CellD: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E, context: ExecutionContext) async throws -> Int {
        let b = try await engine.fetch(CellB(), with: context)
        let c = try await engine.fetch(CellC(), with: context)
        return b + c
    }
}

// Without memoization: CellA computed twice
let basic = ComposedEngine(interceptors: [])
let result1 = try await basic.fetch(CellD(), with: .root)  // 70

// With memoization: CellA computed once
let cached = ComposedEngine(interceptors: [CacheInterceptor()])
let result2 = try await cached.fetch(CellD(), with: .root)  // 70
```

## Running Tests and Examples

Run the test suite:

```bash
swift test
```

Run the spreadsheet example:

```bash
swift run SpreadsheetExample
```

## License

This library is released under the MIT license. See [LICENSE](LICENSE) for details.
