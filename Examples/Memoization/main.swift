import IncrementalComputation

// Run either strategy with the same input sequence, 2 -> 4 -> 5:
//   swift run MemoizationExample red-green
//   swift run MemoizationExample value-keys
//
// Both strategies return the cached report when 2 changes to 4, since both numbers are even.
// Red-green backdates IsEven's equal result and skips Report's body automatically.
// Value-based keys let a plain cache find ReportByValue(even: true), but Workflow still executes.
// Changing the input to 5 executes the report in both strategies.
//
// Expected cumulative body execution counts:
// mode        input  source  parity  report  wrapper
// red-green       2       1       1       1        0
// red-green       4       2       2       1        0
// red-green       5       3       3       2        0
// value-keys      2       1       1       1        1
// value-keys      4       2       2       1        2
// value-keys      5       3       3       2        3
// These counters measure executions, not elapsed time.

/// Holds external input data and counters for the example.
/// Actor identity keeps query keys stable when the number changes.
actor Inputs: Hashable {
    var number = 2

    var counts: [String: Int] = [:]

    nonisolated static func == (lhs: Inputs, rhs: Inputs) -> Bool {
        lhs === rhs
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    func set(_ value: Int) {
        number = value
    }
    func record(_ name: String) {
        counts[name, default: 0] += 1
    }
    func summary() -> String {
        "source=\(counts["source", default: 0]), parity=\(counts["parity", default: 0]), report=\(counts["report", default: 0]), wrapper=\(counts["wrapper", default: 0])"
    }
}

struct Number: Query {
    let inputs: Inputs
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        await inputs.record("source")
        return await inputs.number
    }
}

struct IsEven: Query {
    let inputs: Inputs
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Bool {
        await inputs.record("parity")
        return try await engine.fetch(Number(inputs: inputs), with: context).isMultiple(of: 2)
    }
}

struct Report: Query {
    let inputs: Inputs
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await inputs.record("report")
        return try await engine.fetch(IsEven(inputs: inputs), with: context) ? "even" : "odd"
    }
}

/// Includes the intermediate Boolean in its key so a plain cache can match equal inputs.
/// Value-based keys must contain immutable data or an identity with sound equality.
/// Hashing and comparing large values have a cost; a bare hash cannot replace equality.
/// Different keys remain cached until cleared, so historical values can retain entries.
struct ReportByValue: Query {
    let inputs: Inputs

    let even: Bool
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await inputs.record("report")
        return even ? "even" : "odd"
    }
}

/// Executes after each invalidation to fetch the Boolean and construct the report's key.
/// This approach avoids executing a cached report but does not backdate the enclosing workflow.
struct Workflow: Query {
    let inputs: Inputs
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await inputs.record("wrapper")
        let even = try await engine.fetch(IsEven(inputs: inputs), with: context)
        return try await engine.fetch(ReportByValue(inputs: inputs, even: even), with: context)
    }
}

@main
struct MemoizationExample {
    static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "red-green"
        let inputs = Inputs()
        switch mode {
        case "red-green":
            let incremental = RedGreenInterceptor()
            let engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .memoizing(with: incremental)
                    .deduplicating(with: InFlightInterceptor())
            )
            for number in [2, 4, 5] {
                if number != 2 {
                    try await incremental.update(
                        invalidating: [AnyQuery(Number(inputs: inputs))]
                    ) {
                        await inputs.set(number)
                    }
                }
                let result = try await engine.fetch(Report(inputs: inputs), with: .root)
                print("\(number): \(result); \(await inputs.summary())")
            }
        case "value-keys":
            let cache = CacheInterceptor()
            let dependencies = ReverseDepsInterceptor()
            let engine = ComposedEngine(
                interceptorChain: InterceptorChain()
                    .memoizing(with: cache)
                    .observing(dependencies)
            )
            // Mutate inputs only between completed evaluations.
            for number in [2, 4, 5] {
                if number != 2 {
                    await inputs.set(number)
                    for key in await dependencies.invalidate(query: Number(inputs: inputs)) {
                        await cache.clear(query: key)
                    }
                }
                let result = try await engine.fetch(Workflow(inputs: inputs), with: .root)
                print("\(number): \(result); \(await inputs.summary())")
            }
        default:
            print("Usage: swift run MemoizationExample [red-green|value-keys]")
        }
    }
}
