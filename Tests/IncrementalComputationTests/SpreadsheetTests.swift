import XCTest
import IncrementalComputation

final class SpreadsheetTests: XCTestCase {

    func testSpreadsheetCalculation() async throws {
        struct CellA: Query {
            typealias Value = Int
            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return 10
            }
        }

        struct CellB: Query {
            typealias Value = Int
            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA()) + 20
            }
        }

        struct CellC: Query {
            typealias Value = Int
            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA()) + 30
            }
        }

        struct CellD: Query {
            typealias Value = Int
            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                let b = try await engine.fetch(CellB())
                let c = try await engine.fetch(CellC())
                return b + c
            }
        }

        let engine = ComposedEngine(interceptors: [CacheInterceptor()])
        let result = try await engine.fetch(CellD())
        XCTAssertEqual(result, 70)
    }

    func testSpreadsheetMemoization() async throws {
        let counter = Counter()

        struct CellA: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                counter.count += 1
                return 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellA")
            }

            static func == (lhs: CellA, rhs: CellA) -> Bool {
                return true
            }
        }

        struct CellB: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA(counter: counter)) + 20
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellB")
            }

            static func == (lhs: CellB, rhs: CellB) -> Bool {
                return true
            }
        }

        struct CellC: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA(counter: counter)) + 30
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellC")
            }

            static func == (lhs: CellC, rhs: CellC) -> Bool {
                return true
            }
        }

        struct CellD: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                let b = try await engine.fetch(CellB(counter: counter))
                let c = try await engine.fetch(CellC(counter: counter))
                return b + c
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellD")
            }

            static func == (lhs: CellD, rhs: CellD) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(interceptors: [CacheInterceptor()])
        _ = try await engine.fetch(CellD(counter: counter))

        XCTAssertEqual(counter.count, 1)
    }

    func testSpreadsheetWithoutMemoization() async throws {
        let counter = Counter()

        struct CellA: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                counter.count += 1
                return 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellA")
            }

            static func == (lhs: CellA, rhs: CellA) -> Bool {
                return true
            }
        }

        struct CellB: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA(counter: counter)) + 20
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellB")
            }

            static func == (lhs: CellB, rhs: CellB) -> Bool {
                return true
            }
        }

        struct CellC: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                return try await engine.fetch(CellA(counter: counter)) + 30
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellC")
            }

            static func == (lhs: CellC, rhs: CellC) -> Bool {
                return true
            }
        }

        struct CellD: Query, Hashable {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(with engine: E) async throws -> Int {
                let b = try await engine.fetch(CellB(counter: counter))
                let c = try await engine.fetch(CellC(counter: counter))
                return b + c
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellD")
            }

            static func == (lhs: CellD, rhs: CellD) -> Bool {
                return true
            }
        }

        // No memoization - using empty interceptors
        let engine = ComposedEngine(interceptors: [])
        _ = try await engine.fetch(CellD(counter: counter))

        XCTAssertEqual(counter.count, 2)
    }
}
