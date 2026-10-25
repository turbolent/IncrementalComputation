import Foundation
import Testing
@testable import IncrementalComputation

enum TestFailure: Error {
    case expected
}

actor TestGate: Hashable {
    nonisolated static func == (lhs: TestGate, rhs: TestGate) -> Bool {
        lhs === rhs
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    private var open = false

    private var arrivals = 0

    private var blocked: [CheckedContinuation<Void, Never>] = []

    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        arrivals += 1
        let ready = observers.filter {
            $0.0 <= arrivals
        }
        observers.removeAll {
            $0.0 <= arrivals
        }
        for (_, continuation) in ready {
            continuation.resume()
        }
        if !open {
            await withCheckedContinuation {
                blocked.append($0)
            }
        }
    }

    func waitForArrivals(_ count: Int = 1) async {
        if arrivals >= count {
            return
        }
        await withCheckedContinuation {
            observers.append((count, $0))
        }
    }

    func release() {
        open = true
        let pending = blocked
        blocked.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

actor GraphState: Hashable {
    private var values = ["number": 2, "condition": 1, "left": 7, "right": 7, "unrelated": 0]

    private var counts: [String: Int] = [:]

    private var failures: Set<String> = []

    private var gates: [String: TestGate] = [:]

    nonisolated static func == (lhs: GraphState, rhs: GraphState) -> Bool {
        lhs === rhs
    }
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func set(_ key: String, _ value: Int) {
        values[key] = value
    }
    func fail(_ key: String, _ enabled: Bool) {
        if enabled {
            failures.insert(key)
        } else {
            failures.remove(key)
        }
    }
    func gate(_ key: String, _ gate: TestGate?) {
        gates[key] = gate
    }
    func record(_ key: String) {
        counts[key, default: 0] += 1
    }
    func count(_ key: String) -> Int {
        counts[key, default: 0]
    }
    func read(_ key: String) async throws -> Int {
        record("input:" + key)
        if let gate = gates[key] {
            await gate.wait()
        }
        if failures.contains(key) {
            throw TestFailure.expected
        }
        return values[key, default: 0]
    }
}

struct Input: Query {
    let state: GraphState

    var name = "number"
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        try await state.read(name)
    }
}

struct Parity: Query {
    let state: GraphState
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Bool {
        await state.record("parity")
        return try await engine.fetch(Input(state: state), with: context).isMultiple(of: 2)
    }
}

struct Report: Query {
    let state: GraphState
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await state.record("report")
        return try await engine.fetch(Parity(state: state), with: context) ? "even" : "odd"
    }
}

struct Branch: Query {
    let state: GraphState
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        await state.record("branch")
        let condition = try await engine.fetch(
            Input(state: state, name: "condition"),
            with: context
        )
        return try await engine.fetch(
            Input(state: state, name: condition == 1 ? "left" : "right"),
            with: context
        )
    }
}

struct Fallback: Query {
    let state: GraphState
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        await state.record("fallback")
        do {
            return try await engine.fetch(Input(state: state), with: context)
        } catch is TestFailure {
            return -1
        }
    }
}

struct ValueReport: Query {
    let state: GraphState

    let even: Bool
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await state.record("valueReport")
        return even ? "even" : "odd"
    }
}

struct ValueWorkflow: Query {
    let state: GraphState
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> String {
        await state.record("workflow")
        let even = try await engine.fetch(Parity(state: state), with: context)
        return try await engine.fetch(ValueReport(state: state, even: even), with: context)
    }
}
