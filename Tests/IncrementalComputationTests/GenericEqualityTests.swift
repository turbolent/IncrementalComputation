import Testing
@testable import IncrementalComputation

@Suite
struct GenericEqualityTests {
    actor Snapshot<Value: Sendable>: Hashable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
        func set(_ value: Value) {
            self.value = value
        }

        nonisolated static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs === rhs
        }
        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }

    // This generic conformance knows only Sendable, even when Output is Bool or Int?.
    struct Source<Output: Sendable>: Query {
        let snapshot: Snapshot<Output>

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Output {
            await snapshot.value
        }
    }

    struct Consumer: Query {
        let snapshot: Snapshot<Bool>

        let counts: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> String {
            await counts.record("consumer")
            return try await engine.fetch(Source(snapshot: snapshot), with: context) ? "yes" : "no"
        }
    }

    @Test("Generic queries backdate Equatable results through their protocol witness")
    func genericBackdating() async throws {
        let snapshot = Snapshot(true)
        let counts = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let input = Source(snapshot: snapshot)
        let consumer = Consumer(snapshot: snapshot, counts: counts)
        #expect(try await engine.fetch(consumer, with: .root) == "yes")
        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await snapshot.set(true)
        }
        #expect(try await engine.fetch(consumer, with: .root) == "yes")
        #expect(await counts.count("consumer") == 1)
        #expect(await incremental.memoRevisions(for: AnyQuery(input))?.changedAt == 1)

        try await incremental.update(invalidating: [AnyQuery(input)]) {
            await snapshot.set(false)
        }
        #expect(try await engine.fetch(consumer, with: .root) == "no")
        #expect(await counts.count("consumer") == 2)
    }

    @Test("Erased comparisons preserve optional equality and reject incompatible values")
    func erasedEquality() async throws {
        let query = AnyQuery(Source(snapshot: Snapshot<Int?>(nil)))
        #expect(query.valuesEqual(Optional<Int>.none, Optional<Int>.none))
        #expect(query.valuesEqual(Optional(2), Optional(2)))
        #expect(!query.valuesEqual(Optional(2), Optional<Int>.none))
        #expect(!query.valuesEqual(Optional(2), "2"))

        // Opening the stored query must preserve an optional nil as a result value.
        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain().memoizing(with: cache)
        )
        let first = try await query.fetch(with: engine, context: .root)
        let second = try await query.fetch(with: engine, context: .root)
        #expect(query.valuesEqual(first, Optional<Int>.none))
        #expect(query.valuesEqual(first, second))
        #expect(await cache.count == 1)
    }

    private class BaseSource: Query, @unchecked Sendable {
        let snapshot: Snapshot<Int>

        init(snapshot: Snapshot<Int>) {
            self.snapshot = snapshot
        }

        static func == (lhs: BaseSource, rhs: BaseSource) -> Bool {
            lhs.snapshot == rhs.snapshot
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(snapshot)
        }

        class func valuesEqual(_ lhs: Int, _ rhs: Int) -> Bool {
            false
        }

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await snapshot.value
        }
    }

    private final class ComparedSource: BaseSource, @unchecked Sendable {
        override class func valuesEqual(_ lhs: Int, _ rhs: Int) -> Bool {
            lhs == rhs
        }
    }

    private struct UpcastConsumer: Query {
        let source: BaseSource

        let counts: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            await counts.record("upcastConsumer")
            return try await engine.fetch(source, with: context)
        }
    }

    @Test("Upcast class queries preserve comparison overrides and backdating")
    func inheritedComparison() async throws {
        let snapshot = Snapshot(7)
        let source = ComparedSource(snapshot: snapshot)
        let upcast: BaseSource = source
        let directQuery = AnyQuery(source)
        let upcastQuery = AnyQuery(upcast)
        #expect(directQuery == upcastQuery)
        #expect(directQuery.valuesEqual(7, 7))
        #expect(upcastQuery.valuesEqual(7, 7))
        #expect(!upcastQuery.valuesEqual(7, 8))
        #expect(!AnyQuery(BaseSource(snapshot: snapshot)).valuesEqual(7, 7))

        let counts = GraphState()
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )
        let consumer = UpcastConsumer(source: upcast, counts: counts)
        #expect(try await engine.fetch(consumer, with: .root) == 7)
        try await incremental.update(invalidating: [AnyQuery(source)]) {
            await snapshot.set(7)
        }
        #expect(try await engine.fetch(consumer, with: .root) == 7)
        #expect(await counts.count("upcastConsumer") == 1)

        try await incremental.update(invalidating: [AnyQuery(source)]) {
            await snapshot.set(8)
        }
        #expect(try await engine.fetch(consumer, with: .root) == 8)
        #expect(await counts.count("upcastConsumer") == 2)
    }
}
