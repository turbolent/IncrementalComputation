import Foundation
import Testing
import IncrementalComputation

struct ErasedEqualityTests {
    typealias Snapshot = GenericEqualityTests.Snapshot<any Sendable>
    typealias Source = GenericEqualityTests.Source<any Sendable>

    struct TypeObserver: Query {
        /// Supplies values whose concrete types remain observable after erasure.
        let snapshot: Snapshot

        /// Records whether backdating skips a required execution.
        let counts: GraphState

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Bool {
            await counts.record("typeObserver")
            let value = try await engine.fetch(Source(snapshot: snapshot), with: context)
            return type(of: value) == Int.self
        }
    }

    @Test("Foundation bridging does not equate observably different erased result types")
    func bridgedEquality() {
        let integer: any Sendable = 1
        let number: any Sendable = NSNumber(value: 1)
        let query = AnyQuery(Source(snapshot: Snapshot(integer)))

        #expect(type(of: integer) != type(of: number))
        #expect(!Source.valuesEqual(integer, number))
        #expect(!Source.valuesEqual(number, integer))
        #expect(!query.valuesEqual(integer, number))
        #expect(!query.valuesEqual(number, integer))
        #expect(query.valuesEqual(integer, 1))
        #expect(query.valuesEqual(number, NSNumber(value: 1)))
    }

    @Test("Changing an erased result's concrete type recomputes dependents")
    func changedConcreteType() async throws {
        let snapshot = Snapshot(1)
        let counts = GraphState()
        let source = Source(snapshot: snapshot)
        let consumer = TypeObserver(snapshot: snapshot, counts: counts)
        let incremental = RedGreenInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: incremental)
        )

        #expect(try await engine.fetch(consumer, with: .root))
        try await incremental.update(invalidating: [AnyQuery(source)]) {
            await snapshot.set(NSNumber(value: 1))
        }
        #expect(!(try await engine.fetch(consumer, with: .root)))
        #expect(await counts.count("typeObserver") == 2)

        try await incremental.update(invalidating: [AnyQuery(source)]) {
            await snapshot.set(1)
        }
        #expect(try await engine.fetch(consumer, with: .root))
        #expect(await counts.count("typeObserver") == 3)
    }
}
