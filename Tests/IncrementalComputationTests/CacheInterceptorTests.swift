import XCTest
import IncrementalComputation

final class CacheInterceptorTests: XCTestCase {

    func testMemoization() async throws {

        struct CountingQuery: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                return 42
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CountingQuery")
            }

            static func == (lhs: CountingQuery, rhs: CountingQuery) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor()
            ]
        )

        let counter = Counter()

        _ = try await engine.fetch(CountingQuery(counter: counter), with: .root)
        _ = try await engine.fetch(CountingQuery(counter: counter), with: .root)
        _ = try await engine.fetch(CountingQuery(counter: counter), with: .root)

        let count = await counter.value
        XCTAssertEqual(count, 1)  // Should only compute once
    }

    func testMemoizationWithDependencies() async throws {

        struct CountingBase: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {
                _ = await counter.increment()
                return 10
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("CountingBase")
            }

            static func == (lhs: CountingBase, rhs: CountingBase) -> Bool {
                return true
            }
        }

        struct DerivedA: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {

                let value = try await engine.fetch(
                    CountingBase(counter: counter),
                    with: context
                )
                return value + 1
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedA")
            }

            static func == (lhs: DerivedA, rhs: DerivedA) -> Bool {
                return true
            }
        }

        struct DerivedB: Query {
            typealias Value = Int

            let counter: Counter

            func compute<E: QueryEngine>(
                with engine: E,
                context: ExecutionContext
            ) async throws -> Int {

                let value = try await engine.fetch(
                    CountingBase(counter: counter),
                    with: context
                )
                return value + 2
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine("DerivedB")
            }

            static func == (lhs: DerivedB, rhs: DerivedB) -> Bool {
                return true
            }
        }

        let engine = ComposedEngine(
            interceptors: [
                CacheInterceptor()
            ]
        )

        let counter = Counter()

        _ = try await engine.fetch(DerivedA(counter: counter), with: .root)
        _ = try await engine.fetch(DerivedB(counter: counter), with: .root)

        let count = await counter.value
        XCTAssertEqual(count, 1)  // Base should only compute once
    }

    func testConvenienceOverloadsMatchQueryKeyVariants() async throws {
        let cache = CacheInterceptor()
        let engine = ComposedEngine(interceptors: [cache])

        _ = try await engine.fetch(IncA(), with: .root)

        let cachedViaTyped = await cache.isCached(query: IncA())
        let cachedViaKey = await cache.isCached(query: QueryKey(IncA()))
        XCTAssertEqual(cachedViaTyped, cachedViaKey)
        XCTAssertTrue(cachedViaTyped)

        await cache.clear(query: IncA())

        let afterTypedClearViaTyped = await cache.isCached(query: IncA())
        let afterTypedClearViaKey = await cache.isCached(query: QueryKey(IncA()))
        XCTAssertEqual(afterTypedClearViaTyped, afterTypedClearViaKey)
        XCTAssertFalse(afterTypedClearViaTyped)

        _ = try await engine.fetch(IncA(), with: .root)
        await cache.clear(query: QueryKey(IncA()))

        let afterKeyClearViaTyped = await cache.isCached(query: IncA())
        let afterKeyClearViaKey = await cache.isCached(query: QueryKey(IncA()))
        XCTAssertEqual(afterKeyClearViaTyped, afterKeyClearViaKey)
        XCTAssertFalse(afterKeyClearViaTyped)
    }
}
