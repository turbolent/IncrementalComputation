import IncrementalComputation

// MARK: - Basic Test Queries

struct BaseQuery: Query, Hashable {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return 10
    }
}

struct DerivedQuery: Query, Hashable {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        let base = try await engine.fetch(BaseQuery())
        return base + 5
    }
}

// MARK: - Cyclic Test Queries

struct CyclicQueryA: Query, Hashable {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(CyclicQueryB())
    }
}

struct CyclicQueryB: Query, Hashable {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(CyclicQueryA())
    }
}

struct SelfReferentialQuery: Query, Hashable {
    typealias Value = Int

    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(SelfReferentialQuery())
    }
}

// MARK: - Incremental Test Queries

struct IncA: Query, Hashable {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return 1
    }
}

struct IncB: Query, Hashable {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(IncA()) + 10
    }
}

struct IncC: Query, Hashable {
    typealias Value = Int
    func compute<E: QueryEngine>(with engine: E) async throws -> Int {
        return try await engine.fetch(IncB()) + 100
    }
}
