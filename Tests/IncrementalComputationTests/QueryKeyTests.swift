import Testing
import IncrementalComputation

struct QueryKeyTests {

    @Test("Same Query Value Produces Equal Key")
    func testSameQueryValueProducesEqualKey() {
        let lhs = QueryKey(IncA())
        let rhs = QueryKey(IncA())

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

        let lhs = QueryKey(ParamQuery(id: 1))
        let rhs = QueryKey(ParamQuery(id: 2))

        #expect(lhs != rhs)
    }

    @Test("Different Query Types Produce Different Keys")
    func testDifferentQueryTypesProduceDifferentKeys() {
        let lhs = QueryKey(IncA())
        let rhs = QueryKey(IncB())

        #expect(lhs != rhs)
    }
}
