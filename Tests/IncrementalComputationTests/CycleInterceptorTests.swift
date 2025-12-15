import XCTest
import IncrementalComputation

final class CycleInterceptorTests: XCTestCase {

    func testCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )

        do {
            _ = try await engine.fetch(CyclicQueryA(), with: .root)
            XCTFail("Expected CyclicDependencyError")
        } catch is CyclicDependencyError {
            // Expected
        } catch {
            XCTFail("Expected CyclicDependencyError, got \(error)")
        }
    }

    func testSelfReferentialCycleDetection() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )

        do {
            _ = try await engine.fetch(SelfReferentialQuery(), with: .root)
            XCTFail("Expected CyclicDependencyError")
        } catch is CyclicDependencyError {
            // Expected
        } catch {
            XCTFail("Expected CyclicDependencyError, got \(error)")
        }
    }

    func testNoCycleWithValidQuery() async throws {
        let engine = ComposedEngine(
            interceptors: [
                CycleInterceptor()
            ]
        )
        let result = try await engine.fetch(DerivedQuery(), with: .root)
        XCTAssertEqual(result, 15)
    }

}
