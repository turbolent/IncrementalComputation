import XCTest
import IncrementalComputation

final class CacheInterceptorTests: XCTestCase {

    func testMemoization() async throws {
        let counter = Counter()

        struct CountingQuery: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                counter.count += 1
                return 42
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CountingQuery")
            }

            static func == (lhs: CountingQuery, rhs: CountingQuery) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(interceptors: [CacheInterceptor()])

        _ = try await engine.fetch(CountingQuery(counter: counter))
        _ = try await engine.fetch(CountingQuery(counter: counter))
        _ = try await engine.fetch(CountingQuery(counter: counter))

        XCTAssertEqual(counter.count, 1)  // Should only compute once
    }

    func testMemoizationWithDependencies() async throws {
        let counter = Counter()

        struct CountingBase: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                counter.count += 1
                return 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CountingBase")
            }

            static func == (lhs: CountingBase, rhs: CountingBase) -> Bool {
                return true
            }
        }

        struct DerivedA: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CountingBase(counter: counter)) + 1
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedA")
            }

            static func == (lhs: DerivedA, rhs: DerivedA) -> Bool {
                return true
            }
        }

        struct DerivedB: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CountingBase(counter: counter)) + 2
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedB")
            }

            static func == (lhs: DerivedB, rhs: DerivedB) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(interceptors: [CacheInterceptor()])

        _ = try await engine.fetch(DerivedA(counter: counter))
        _ = try await engine.fetch(DerivedB(counter: counter))

        XCTAssertEqual(counter.count, 1)  // Base should only compute once
    }

}
