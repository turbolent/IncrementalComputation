import XCTest
import IncrementalComputation

final class QueryKeyTests: XCTestCase {

    func testSameQueryValueProducesEqualKey() {
        let lhs = QueryKey(IncA())
        let rhs = QueryKey(IncA())

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.hashValue, rhs.hashValue)
    }

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

        let lhs = QueryKey(ParamQuery(id: 1))
        let rhs = QueryKey(ParamQuery(id: 2))

        XCTAssertNotEqual(lhs, rhs)
    }

    func testDifferentQueryTypesProduceDifferentKeys() {
        let lhs = QueryKey(IncA())
        let rhs = QueryKey(IncB())

        XCTAssertNotEqual(lhs, rhs)
    }
}
