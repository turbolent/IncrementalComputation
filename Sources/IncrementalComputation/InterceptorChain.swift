/// Compile-time state: the chain has no memoizing interceptor yet.
public enum NoMemoization: Sendable {}

/// Compile-time state: the chain already has a memoizing interceptor.
public enum HasMemoization: Sendable {}

/// Compile-time state: the chain has no deduplicating interceptor yet.
public enum NoDeduplication: Sendable {}

/// Compile-time state: the chain already has a deduplicating interceptor.
public enum HasDeduplication: Sendable {}

/// Builds a pipeline of compatible interceptors, checked by the compiler.
/// Start with `InterceptorChain()`, then add interceptors from inside out: each new
/// interceptor wraps the existing chain.
/// Observers run in registration order, independently of resolution.
///
/// Swift infers the state types.
/// The engine erases them only after accepting a valid
/// chain; there is no unchecked array initializer or general-purpose append.
/// Add at most one memoizer, followed by at most one deduplicator.
/// Observers can be added anywhere without changing those constraints.
/// Chains are immutable values; extending one shares its existing actors.
/// Use a separate `RedGreenInterceptor` instance per engine.
///
/// ```swift
/// let engine = ComposedEngine(
///     interceptorChain: InterceptorChain()
///         .memoizing(with: RedGreenInterceptor())
///         .deduplicating(with: InFlightInterceptor())
///         .observing(TrackingInterceptor())
/// )
/// ```
///
/// Here, in-flight deduplication wraps red-green memoization, which wraps computation.
/// Custom memoizers and deduplicators follow the same composition rules as the built-in types.
public struct InterceptorChain<Memoization, Deduplication>: Sendable {
    /// The actors installed by this chain's typed builder operations.
    /// Kept private so callers cannot forge a chain with different state types.
    private let storage: ChainStorage

    private init(storage: ChainStorage) {
        self.storage = storage
    }

    /// Creates an empty chain that computes every query directly.
    public init() where Memoization == NoMemoization, Deduplication == NoDeduplication {
        self.storage = ChainStorage()
    }

    /// Adds observation without changing the chain's resolution interceptors.
    /// Observations run even when resolution short-circuits or an observer throws.
    public func observing(_ observer: any QueryObserver) -> Self {
        var storage = self.storage
        storage.observers.append(observer)
        return Self(storage: storage)
    }

    /// The engine's execution plan after the compiler has checked the chain's state types.
    /// Internal and read-only so callers cannot bypass the builder's composition rules.
    var erased: ChainStorage {
        storage
    }
}

extension InterceptorChain where Memoization == NoMemoization, Deduplication == NoDeduplication {
    /// Adds the chain's single memoizing interceptor.
    /// Add deduplication afterward so only the producer reaches this resolution hook.
    public func memoizing(
        with interceptor: any MemoizingInterceptor
    ) -> InterceptorChain<HasMemoization, NoDeduplication> {
        InterceptorChain<HasMemoization, NoDeduplication>(storage: storage.wrapping(interceptor))
    }
}

extension InterceptorChain where Deduplication == NoDeduplication {
    /// Wraps the current resolution chain with one deduplicating interceptor.
    public func deduplicating(
        with interceptor: any DeduplicatingInterceptor
    ) -> InterceptorChain<Memoization, HasDeduplication> {
        InterceptorChain<Memoization, HasDeduplication>(storage: storage.wrapping(interceptor))
    }
}

/// The engine's type-erased execution plan, built only through typed chain operations.
struct ChainStorage: Sendable {
    /// Observers in registration order for admission and observation.
    var observers: [any QueryObserver] = []

    /// Resolution interceptors from innermost to outermost.
    /// Admission and result publication follow this order.
    /// Resolution and cleanup traverse it in reverse.
    var interceptors: [any QueryInterceptor] = []

    func wrapping(_ interceptor: any QueryInterceptor) -> Self {
        var storage = self
        storage.interceptors.append(interceptor)
        return storage
    }
}
