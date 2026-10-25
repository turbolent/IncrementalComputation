import Testing
import IncrementalComputation

struct ExecutionContextTests {
    // Use only public APIs so this engine has the same capabilities as a library client.
    actor ExternalEngine: QueryEngine {
        private var nextFetchOrder: UInt64 = 0

        func fetch<Q: Query>(
            _ query: Q,
            with context: ExecutionContext
        ) async throws -> Q.Value {
            nextFetchOrder += 1
            let child = context.child(
                for: AnyQuery(query),
                fetchOrder: nextFetchOrder
            )
            return try await query.compute(with: self, context: child)
        }
    }

    struct CaptureContext: Query {
        let depth: Int

        func compute<E: QueryEngine>(
            with engine: E,
            context: ExecutionContext
        ) async throws -> [ExecutionContext] {
            guard depth > 0 else {
                return [context]
            }
            let nested = try await engine.fetch(
                CaptureContext(depth: depth - 1),
                with: context
            )
            return [context] + nested
        }
    }

    @Test("External engines create contexts with invocation identity and ancestry")
    func externalEngine() async throws {
        let engine = ExternalEngine()
        let query = CaptureContext(depth: 2)
        let contexts = try await engine.fetch(query, with: .root)
        try #require(contexts.count == 3)

        #expect(contexts[0].invocationID != nil)
        #expect(contexts[0].parentInvocationID == nil)
        #expect(contexts[0].callerQuery == nil)
        #expect(contexts[0].parentQuery == AnyQuery(query))
        #expect(contexts.map(\.fetchOrder) == [1, 2, 3])
        for index in 1..<contexts.count {
            #expect(contexts[index].invocationID != contexts[index - 1].invocationID)
            #expect(contexts[index].parentInvocationID == contexts[index - 1].invocationID)
            #expect(contexts[index].callerQuery == contexts[index - 1].parentQuery)
            #expect(contexts[index].contains(AnyQuery(query)))
            #expect(!contexts[index].isValidationRead)
        }

        let second = try await engine.fetch(query, with: .root)
        #expect(second[0].invocationID != contexts[0].invocationID)
        #expect(second.map(\.fetchOrder) == [4, 5, 6])
        #expect(ExecutionContext.root.queries.isEmpty)
    }

    @Test("Validation contexts mark only the replayed read")
    func validationRead() {
        let parentKey = AnyQuery(CaptureContext(depth: 2))
        let dependencyKey = AnyQuery(CaptureContext(depth: 1))
        let parent = ExecutionContext.root.child(for: parentKey, fetchOrder: 1)
        let validation = parent.validatingDependencies().child(
            for: dependencyKey,
            fetchOrder: 2
        )
        let computationRead = validation.child(
            for: AnyQuery(CaptureContext(depth: 0)),
            fetchOrder: 3
        )

        #expect(validation.isValidationRead)
        #expect(validation.parentInvocationID == parent.invocationID)
        #expect(validation.callerQuery == parentKey)
        #expect(validation.contains(parentKey))
        #expect(!computationRead.isValidationRead)
        #expect(computationRead.parentInvocationID == validation.invocationID)
        #expect(computationRead.callerQuery == dependencyKey)
        #expect(!parent.isValidationRead)
    }
}
