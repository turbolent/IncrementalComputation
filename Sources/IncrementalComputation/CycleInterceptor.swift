/// An interceptor that detects cyclic dependencies.
/// Throws `CyclicDependencyError` if a query depends on itself (directly or transitively).
public final class CycleInterceptor: QueryInterceptor {
    private var inProgress: Set<AnyHashable> = []

    public init() {}

    public func willFetch(key: AnyHashable) throws -> Any? {
        if inProgress.contains(key) {
            throw CyclicDependencyError()
        }
        inProgress.insert(key)
        return nil
    }

    public func didCompute(key: AnyHashable, value: Any) {
        inProgress.remove(key)
    }
}

/// Error thrown when a cyclic dependency is detected.
public struct CyclicDependencyError: Error, CustomStringConvertible {

    public var description: String {
        return "Cyclic dependency detected"
    }
}
