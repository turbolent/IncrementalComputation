import IncrementalComputation

// MARK: - Basic Test Queries

struct BaseQuery: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return 10
    }
}

struct DerivedQuery: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        let base = try await engine.fetch(BaseQuery(), with: context)
        return base + 5
    }
}

// MARK: - Cyclic Test Queries

struct CyclicQueryA: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return try await engine.fetch(CyclicQueryB(), with: context)
    }
}

struct CyclicQueryB: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return try await engine.fetch(CyclicQueryA(), with: context)
    }
}

struct SelfReferentialQuery: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return try await engine.fetch(SelfReferentialQuery(), with: context)
    }
}

// MARK: - Incremental Test Queries

struct IncA: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        return 1
    }
}

struct IncB: Query {
    typealias Value = Int
    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        let a = try await engine.fetch(IncA(), with: context)
        return a + 10
    }
}

struct IncC: Query {
    typealias Value = Int

    func compute<E: QueryEngine>(
        with engine: E,
        context: ExecutionContext
    ) async throws -> Int {
        let b = try await engine.fetch(IncB(), with: context)
        return b + 100
    }
}
