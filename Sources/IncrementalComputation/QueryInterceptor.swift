/// Protocol for query execution interceptors.
/// Interceptors are classes that provide specific query handling behaviors.
/// They are owned by a ComposedEngine actor, which provides thread safety.
public protocol QueryInterceptor: AnyObject {
    /// Called before fetching a query.
    /// - Parameters:
    ///   - key: The type-erased query key
    /// - Returns: A cached value if available, or nil to continue with computation
    /// - Throws: Can throw (e.g., CyclicDependencyError for cycle detection)
    func willFetch(key: AnyHashable) throws -> Any?

    /// Called after a query value has been computed.
    /// - Parameters:
    ///   - key: The type-erased query key
    ///   - value: The computed value
    func didCompute(key: AnyHashable, value: Any)
}

/// Default implementations for optional methods
public extension QueryInterceptor {
    func willFetch(key: AnyHashable) throws -> Any? {
        return nil
    }

    func didCompute(key: AnyHashable, value: Any) {
        // Default: no-op
    }
}
