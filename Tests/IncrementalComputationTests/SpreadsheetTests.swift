import XCTest
import IncrementalComputation

final class SpreadsheetTests: XCTestCase {

    func testSpreadsheetCalculation() async throws {

        struct CellA: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                return 10
            }
        }

        struct CellB: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(), with: context)
                return a + 20
            }
        }

        struct CellC: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(), with: context)
                return a + 30
            }
        }

        struct CellD: Query {
            typealias Value = Int

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let b = try await engine.fetch(CellB(), with: context)
                let c = try await engine.fetch(CellC(), with: context)
                return b + c
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor()
            ]
        )
        let result = try await engine.fetch(CellD(), with: .root)
        XCTAssertEqual(result, 70)
    }

    func testSpreadsheetMemoization() async throws {

        struct CellA: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
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

        struct CellB: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(counter: counter), with: context)
                return a + 20
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellB")
            }

            static func == (lhs: CellB, rhs: CellB) -> Bool {
                return true
            }
        }

        struct CellC: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(counter: counter), with: context)
                return a + 30
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellC")
            }

            static func == (lhs: CellC, rhs: CellC) -> Bool {
                return true
            }
        }

        struct CellD: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let b = try await engine.fetch(CellB(counter: counter), with: context)
                let c = try await engine.fetch(CellC(counter: counter), with: context)
                return b + c
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellD")
            }

            static func == (lhs: CellD, rhs: CellD) -> Bool {
                return true
            }
        }

        let counter = Counter()

        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor()
            ]
        )
        _ = try await engine.fetch(CellD(counter: counter), with: .root)

        XCTAssertEqual(counter.count, 1)
    }

    func testSpreadsheetWithoutMemoization() async throws {
        let counter = Counter()

        struct CellA: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
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

        struct CellB: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(counter: counter), with: context)
                return a + 20
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellB")
            }

            static func == (lhs: CellB, rhs: CellB) -> Bool {
                return true
            }
        }

        struct CellC: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let a = try await engine.fetch(CellA(counter: counter), with: context)
                return a + 30
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CellC")
            }

            static func == (lhs: CellC, rhs: CellC) -> Bool {
                return true
            }
        }

        struct CellD: Query {
            typealias Value = Int
            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                let b = try await engine.fetch(CellB(counter: counter), with: context)
                let c = try await engine.fetch(CellC(counter: counter), with: context)
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
        _ = try await engine.fetch(CellD(counter: counter), with: .root)

        XCTAssertEqual(counter.count, 2)
    }
}
