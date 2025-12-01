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

    func compute<E: QueryEngine>(with engine: E) async throws -> User {
        // Fetch from database, API, etc.
        return User(id: id, name: "User \(id)")
    }
}

struct GetPosts: Query {
    typealias Value = [Post]
    let userId: Int

    func compute<E: QueryEngine>(with engine: E) async throws -> [Post] {
        // Can depend on other queries
        let user = try await engine.fetch(GetUser(id: userId))
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

let user = try await incremental.fetch(GetUser(id: 1))
```

## API Reference

### `Query`

A query defines a request for a value and how to compute it.

```swift
protocol Query: Hashable {
    associatedtype Value
    func compute<E: QueryEngine>(with engine: E) async throws -> Value
}
```

### `QueryEngine`

An engine executes queries.

```swift
protocol QueryEngine {
    func fetch<Q: Query>(_ query: Q) async throws -> Q.Value
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

Protocol for interceptors that can modify query execution:

```swift
protocol QueryInterceptor: AnyObject {
    func willFetch(key: AnyHashable) throws -> Any?
    func didCompute(key: AnyHashable, value: Any)
}
```

### `CacheInterceptor`

Caches query results (memoization):

```swift
let cache = CacheInterceptor()
let engine = ComposedEngine(interceptors: [cache])

_ = try await engine.fetch(MyQuery())
_ = try await engine.fetch(MyQuery())  // Returns cached result

cache.isCached(key: AnyHashable(MyQuery()))  // true
cache.count  // 1
cache.clear()  // Clear all cached values
```

### `CycleInterceptor`

Detects cyclic dependencies and throws `CyclicDependencyError`:

```swift
let engine = ComposedEngine(interceptors: [CycleInterceptor()])

do {
    _ = try await engine.fetch(SelfReferentialQuery())
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

_ = try await engine.fetch(CellD())  // D depends on B, C; B, C depend on A

// Find all queries that depend on A
let dependents = reverseDeps.dependents(of: AnyHashable(CellA()))
// Returns: {B, C, D}

// Invalidate A and all its dependents
let invalidated = reverseDeps.invalidate(key: AnyHashable(CellA()))
for key in invalidated {
    cache.clear(key: key)
}
```

### `TrackingInterceptor`

Records which queries were fetched (useful for debugging/testing):

```swift
let tracker = TrackingInterceptor()
let engine = ComposedEngine(interceptors: [tracker])

_ = try await engine.fetch(CellD())

tracker.count  // Number of unique queries fetched
tracker.wasFetched(key: AnyHashable(CellA()))  // true
tracker.reset()  // Clear tracking
```

### Custom Interceptors

Create your own interceptor by implementing `QueryInterceptor`:

```swift
class LoggingInterceptor: QueryInterceptor {
    func willFetch(key: AnyHashable) throws -> Any? {
        print("Fetching: \(key)")
        return nil  // Continue with computation
    }

    func didCompute(key: AnyHashable, value: Any) {
        print("Computed: \(key) = \(value)")
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
3. `ReverseDepsInterceptor` last - manages internal stack that requires matched `willFetch`/`didCompute` calls

**Note:** With this order, cached queries won't have new dependencies recorded.
This is typically fine since dependencies are established during first computation and rebuilt after invalidation.


## Example: Spreadsheet

```swift
struct CellA: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return 10
    }
}

struct CellB: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(CellA()) + 20
    }
}

struct CellC: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(CellA()) + 30
    }
}

struct CellD: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        let b = try await engine.fetch(CellB())
        let c = try await engine.fetch(CellC())
        return b + c
    }
}

// Without memoization: CellA computed twice
let basic = ComposedEngine(interceptors: [])
let result1 = try await basic.fetch(CellD())  // 70

// With memoization: CellA computed once
let cached = ComposedEngine(interceptors: [CacheInterceptor()])
let result2 = try await cached.fetch(CellD())  // 70
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
