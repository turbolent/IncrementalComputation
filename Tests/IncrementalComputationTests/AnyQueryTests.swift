import Testing
import IncrementalComputation

struct AnyQueryTests {

    @Test("Same Query Value Produces Equal Key")
    func testSameQueryValueProducesEqualKey() {
        let lhs = AnyQuery(IncA())
        let rhs = AnyQuery(IncA())

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }

    @Test("Different Query Values Produce Different Keys")
    func testDifferentQueryValuesProduceDifferentKeys() {
        struct ParamQuery: Query {
            typealias Value = Int

            let id: Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                id
            }
        }

        let lhs = AnyQuery(ParamQuery(id: 1))
        let rhs = AnyQuery(ParamQuery(id: 2))

        #expect(lhs != rhs)
    }

    @Test("Different Query Types Produce Different Keys")
    func testDifferentQueryTypesProduceDifferentKeys() {
        let lhs = AnyQuery(IncA())
        let rhs = AnyQuery(IncB())

        #expect(lhs != rhs)
    }

    private class Identifier: Hashable, @unchecked Sendable {
        let value: Int

        init(_ value: Int) {
            self.value = value
        }

        static func == (lhs: Identifier, rhs: Identifier) -> Bool {
            lhs.value == rhs.value
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(value)
        }
    }

    private class TextQuery: Identifier, Query, @unchecked Sendable {
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> String {
            "value: \(value)"
        }
    }

    private final class AlternateTextQuery: TextQuery, @unchecked Sendable {
        override func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> String {
            "alternate: \(value)"
        }
    }

    private final class NumberQuery: Identifier, Query, @unchecked Sendable {
        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> Int {
            value
        }
    }

    @Test("Inherited conformances preserve dynamic query identity")
    func inheritedConformances() async throws {
        let original = TextQuery(7)
        let alternate = AlternateTextQuery(7)
        let upcast: TextQuery = alternate
        let originalKey = AnyQuery(original)
        let alternateKey = AnyQuery(alternate)

        #expect(originalKey != alternateKey)
        #expect(AnyQuery(upcast) == alternateKey)
        #expect(AnyQuery(upcast).hashValue == alternateKey.hashValue)
        #expect(AnyQuery(AlternateTextQuery(7)) == alternateKey)
        #expect(Set([originalKey, alternateKey, AnyQuery(upcast)]).count == 2)

        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: CacheInterceptor())
        )
        #expect(try await engine.fetch(original, with: .root) == "value: 7")
        #expect(try await engine.fetch(upcast, with: .root) == "alternate: 7")
        #expect(
            try await originalKey.fetch(with: engine, context: .root) as? String == "value: 7"
        )
        #expect(
            try await AnyQuery(upcast).fetch(
                with: engine,
                context: .root
            ) as? String == "alternate: 7"
        )
    }

    @Test("Queries sharing inherited equality keep different result types separate")
    func distinctResultTypes() async throws {
        let text = TextQuery(7)
        let number = NumberQuery(7)
        try #require(AnyQuery(text) != AnyQuery(number))

        let cache = CacheInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
        )
        #expect(try await engine.fetch(text, with: .root) == "value: 7")
        #expect(try await engine.fetch(number, with: .root) == 7)
        #expect(try await engine.fetch(TextQuery(7), with: .root) == "value: 7")
        #expect(await cache.count == 2)
    }

    @Test("Erased queries share typed caches and preserve dependency identity")
    func erasedFetches() async throws {
        let state = GraphState()
        let cache = CacheInterceptor()
        let reverse = ReverseDepsInterceptor()
        let tracker = TrackingInterceptor()
        let engine = ComposedEngine(
            interceptorChain: InterceptorChain()
                .memoizing(with: cache)
                .observing(reverse)
                .observing(tracker)
        )
        let input = AnyQuery(Input(state: state))
        let report = AnyQuery(Report(state: state))
        let names = [input: "input", report: "report"]

        #expect(try await input.fetch(with: engine, context: .root) as? Int == 2)
        #expect(try await report.fetch(with: engine, context: .root) as? String == "even")
        #expect(try await engine.fetch(Input(state: state), with: .root) == 2)
        #expect(
            try await AnyQuery(Report(state: state)).fetch(
                with: engine,
                context: .root
            ) as? String == "even"
        )
        #expect(await state.count("input:number") == 1)
        #expect(await state.count("report") == 1)
        #expect(await cache.count == 3)
        #expect(await tracker.fetchedQueries == [input, AnyQuery(Parity(state: state)), report])
        #expect(await reverse.directDependents(of: input) == [AnyQuery(Parity(state: state))])
        // Fetching changes neither the identity nor the hash used by existing dictionary entries.
        #expect(names[AnyQuery(Input(state: state))] == "input")
        #expect(names[AnyQuery(Report(state: state))] == "report")
    }
}
