# IncrementalComputation for Swift

A simple incremental computation library using composable interceptors.

## Installation

Add IncrementalComputation to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/turbolent/IncrementalComputation.git",
        branch: "main"
    )
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

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> User {
        // Fetch from database, API, etc.
        return User(id: id, name: "User \(id)")
    }
}

struct GetPosts: Query {
    typealias Value = [Post]
    let userId: Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> [Post] {
        // Can depend on other queries - context is passed through
        let user = try await engine.fetch(GetUser(id: userId), with: context)
        return [Post(author: user.name, title: "Hello")]
    }
}
```

### 2. Create a ComposedEngine with Interceptors

```swift
// Basic engine - no interceptors
let basic = ComposedEngine(interceptorChain: InterceptorChain())

// With memoization (caching)
let cached = ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: CacheInterceptor())
)

// With cycle detection
let safe = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(CycleInterceptor())
)

// Full incremental engine: cycle detection + caching + reverse deps
let incremental = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(CycleInterceptor())
        .memoizing(with: CacheInterceptor())
        .observing(ReverseDepsInterceptor())
)

// Fetch queries - pass .root context for top-level calls
let user = try await incremental.fetch(GetUser(id: 1), with: .root)
```

## API Reference

### `Query`

A query identifies a value and defines how to compute it.

```swift
protocol Query: Hashable, Sendable {
    associatedtype Value: Sendable

    static func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Value
}
```

`valuesEqual` defaults to `==` for `Equatable` results of the same concrete type and `false` otherwise.
`RedGreenInterceptor` uses it to decide whether dependent queries must execute again.
Override it when results need a custom comparison; see [Query.swift](Sources/IncrementalComputation/Query.swift).

**Important**: Always pass the `context` parameter to nested `fetch` calls to maintain the execution chain.

### `QueryEngine`

An engine executes queries.

```swift
protocol QueryEngine: Actor {
    func fetch<Q: Query>(
        _ query: Q,
        with context: ExecutionContext
    ) async throws -> Q.Value
}
```

### `ExecutionContext`

Tracks the current query execution chain for cycle detection and dependency tracking.
Each fetch also has an invocation identity, distinct even for concurrent fetches of the same query.
Internal validation reads do not create new dependency edges.
See [ExecutionContext.swift](Sources/IncrementalComputation/ExecutionContext.swift) for the context fields and validation rules.

Custom engines create each fetch's context with `child(for:fetchOrder:)` before calling hooks or `compute`.
Reserve a strictly increasing fetch number in the engine before the first suspension.
Custom memoizers can use `validatingDependencies()` when replaying old dependencies; computations triggered by validation still record their own reads.

```swift
// Top-level calls use .root
let result = try await engine.fetch(MyQuery(), with: .root)

// Nested calls pass the context through
func compute<E: QueryEngine>(
    with engine: E,
    context: ExecutionContext
) async throws -> Value {
    let dep = try await engine.fetch(Dependency(), with: context)
    return process(dep)
}
```

To cancel a long-running computation graph, wrap the fetch in a `Task`
and use `Task.checkCancellation()` inside long-running queries:

```swift
let task = Task {
    try await engine.fetch(MyQuery(), with: .root)
}

task.cancel()

struct MyQuery: Query {
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        while true {
            try Task.checkCancellation()
            // do work
        }
    }
}
```

### `ComposedEngine`

A composable engine that uses interceptors to provide different behaviors:

```swift
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(CycleInterceptor())
        .memoizing(with: CacheInterceptor())
        .observing(ReverseDepsInterceptor())
)
```

Construction does not throw: the typed chain rejects unsupported interceptor combinations at compile time.
See [interceptor ordering](#interceptor-ordering).

## Interceptors

### `QueryInterceptor`

Protocol for interceptors that can modify query execution.
Interceptors must be actors to provide thread-safe access.
Conform to `MemoizingInterceptor` or `DeduplicatingInterceptor` to install one in a chain.

```swift
public protocol QueryInterceptor: Actor {
    func beginEvaluation(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws

    func intercept(
        query: AnyQuery,
        context: ExecutionContext,
        engine: any QueryEngine,
        next: QueryContinuation
    ) async throws -> any Sendable

    func didResolve(
        query: AnyQuery,
        result: QueryResult,
        context: ExecutionContext
    ) async

    func endEvaluation(context: ExecutionContext) async
}
```

`intercept` wraps resolution: return a value or call `next()` at most once.
The engine rejects repeated calls with `QueryContinuationError.alreadyCalled`.
The default around hook calls `next`; the other hooks do nothing.
`beginEvaluation` and `endEvaluation` let interceptors coordinate updates across the full fetch lifecycle.
`didResolve` delivers the final result so memoizers commit before deduplicators release waiters.
Nested queries belong in `intercept` or an observer's `willFetch`; the other hooks handle metadata and coordination.

### `QueryObserver`

Conform to `QueryObserver` for observation without changing resolution.
Its `beginEvaluation(query:context:)` hook records every attempt, including rejected admissions.
Its `willFetch(query:context:)` hook observes admitted fetches, including cache hits.
`AnyQuery` is a type-erased query used for cache keys, dependency records, and interceptor hooks.
It preserves query identity, fetching, and result comparison; supply an engine when fetching it.
`QueryResult` contains the fetched value or error.
See [ComposedEngine.swift](Sources/IncrementalComputation/ComposedEngine.swift) for callback order and cleanup rules.

### `CacheInterceptor`

Caches query results (memoization):

```swift
let cache = CacheInterceptor()
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: cache)
)

_ = try await engine.fetch(MyQuery(), with: .root)
_ = try await engine.fetch(MyQuery(), with: .root)  // Returns cached result

let isCached = await cache.isCached(query: MyQuery())  // true
let count = await cache.count   // 1
await cache.clear()  // Clear all cached values
```

### `CycleInterceptor`

Detects cyclic dependencies and throws `CyclicDependencyError`:

```swift
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(CycleInterceptor())
)

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
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: cache)
        .observing(reverseDeps)
)

_ = try await engine.fetch(CellD(), with: .root)  // D depends on B, C; B, C depend on A

// Find all queries that depend on A
let dependents = await reverseDeps.dependents(of: CellA())
// Returns: {B, C, D}

// Invalidate A and all its dependents
let invalidated = await reverseDeps.invalidate(query: CellA())
for query in invalidated {
    await cache.clear(query: query)
}
```

Dependency tracking includes cache hits, whether the observer is added before or after the cache.
Keep evaluations idle while changing external data and clearing affected cache entries.
The reverse-dependency graph is conservative: old edges can cause extra invalidations.

### `TrackingInterceptor`

Records admitted query fetches, including cache hits and validation reads (useful for debugging/testing):

```swift
let tracker = TrackingInterceptor()
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(tracker)
)

_ = try await engine.fetch(CellD(), with: .root)

await tracker.count  // Number of unique queries fetched
await tracker.wasFetched(query: CellA())  // true
await tracker.reset()  // Clear tracking
```

### `InFlightInterceptor`

Deduplicates concurrent fetches of the same query.
When multiple tasks fetch the same query simultaneously,
only the first performs the computation while others wait for and share the result:

```swift
let inFlight = InFlightInterceptor()
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .deduplicating(with: inFlight)
)

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
// Add memoization first, then wrap it with deduplication.
ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: CacheInterceptor())
        .deduplicating(with: InFlightInterceptor())
)
```

Only the producer reaches memoization; waiting callers share its result or error.
Cancelling a waiter leaves the producer running.
Producer failure or cancellation releases all waiters.
The wait graph detects cycles between concurrent producers.

**Note:** InFlightInterceptor only deduplicates _concurrent_ fetches.
Sequential fetches of the same query will compute independently.
Use `CacheInterceptor` for persistent memoization across sequential calls.

### `RedGreenInterceptor`

Caches query results across external updates by validating their dependencies.
When recomputation returns an equal result, **backdating** preserves `changedAt` while advancing `verifiedAt`.
Dependent queries can then return their cached values without executing their bodies.
Callers fetch normally; the interceptor makes this decision automatically.

```swift
let redGreen = RedGreenInterceptor()
let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: redGreen)
        .deduplicating(with: InFlightInterceptor())
)

try await redGreen.update(invalidating: [AnyQuery(sourceQuery)]) {
    await sourceStore.setNumber(4)
}
```

Declare every externally changed query and use a separate red-green instance per engine.
Updates require an idle engine and at least one key; fetches are rejected while the mutation runs.
Even a throwing mutation invalidates its declared keys because it may have changed external state.

See [RedGreenInterceptor.swift](Sources/IncrementalComputation/RedGreenInterceptor.swift) for the update contract and [the memoization example](Examples/Memoization/main.swift) for backdating and value-based keys with execution counts.

### Custom Interceptors

Create an observer by implementing `QueryObserver` as an actor:

```swift
actor LoggingInterceptor: QueryObserver {

    func willFetch(
        query: AnyQuery,
        context: ExecutionContext
    ) async throws {
        print("Fetching: \(query)")
    }
}

let engine = ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(LoggingInterceptor())
        .memoizing(with: CacheInterceptor())
)
```

### Interceptor Ordering

Build chains from the inside out: each memoizing or deduplicating interceptor wraps the existing chain.
Add at most one memoizer, followed by at most one deduplicator.
Observers can be added anywhere.

```swift
ComposedEngine(
    interceptorChain: InterceptorChain()
        .observing(CycleInterceptor())
        .memoizing(with: CacheInterceptor())
        .observing(ReverseDepsInterceptor())
        .deduplicating(with: InFlightInterceptor())
)
```

- Every `beginEvaluation` runs before observation, first for interceptors, then for plain observers.
  These hooks record query metadata and coordinate activity even if admission fails or the caller is cancelled.
  Observation and resolution run only when every admission succeeds.
- Every observer's `willFetch` runs before resolution, including on cache hits.
- `intercept` runs from the outermost interceptor inward when `next()` is called.
- Every interceptor's `didResolve` receives the final result from innermost to outermost, including rejected attempts.
  Memoizers commit before deduplicators release waiting callers.
- Every interceptor's `endEvaluation` runs from outermost to innermost after result delivery.
  The inner memoizer keeps its update guard active throughout outer cleanup.

Custom resolution interceptors conform to `MemoizingInterceptor` or `DeduplicatingInterceptor` and follow the same composition rules.
See [QueryInterceptor.swift](Sources/IncrementalComputation/QueryInterceptor.swift), [QueryObserver.swift](Sources/IncrementalComputation/QueryObserver.swift), and [InterceptorChain.swift](Sources/IncrementalComputation/InterceptorChain.swift) for hook contracts and composition rules.

## Example: Spreadsheet

```swift
struct CellA: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return 10
    }
}

struct CellB: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
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
        let b = try await engine.fetch(CellB(), with: context)
        let c = try await engine.fetch(CellC(), with: context)
        return b + c
    }
}

// Without memoization: CellA computed twice
let basic = ComposedEngine(interceptorChain: InterceptorChain())
let result1 = try await basic.fetch(CellD(), with: .root)  // 70

// With memoization: CellA computed once
let cached = ComposedEngine(
    interceptorChain: InterceptorChain()
        .memoizing(with: CacheInterceptor())
)
let result2 = try await cached.fetch(CellD(), with: .root)  // 70
```

## Running Tests and Examples

Run the test suite:

```bash
swift test -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete
```

Run the spreadsheet example:

```bash
swift run SpreadsheetExample
```

Run the [backdating and value-key examples](Examples/Memoization/main.swift):

```bash
swift run MemoizationExample red-green
swift run MemoizationExample value-keys
```

## License

This library is released under the MIT license.
See [LICENSE](LICENSE) for details.
