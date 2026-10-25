import Foundation
import HashTreeCollections

/// Tracks a query's execution chain and invocation.
/// Pass it unchanged to nested fetches.
/// The engine creates a new context for each fetch.
public struct ExecutionContext: Sendable {
    /// The empty context used to start a top-level fetch.
    public static let root = ExecutionContext()

    /// Persistent set of all queries in the current execution chain, including
    /// the current query.
    /// Supports membership checks without walking a linked list.
    public let queries: TreeSet<AnyQuery>

    /// The current query; it is the parent of any fetch issued by `compute`.
    public let parentQuery: AnyQuery?

    /// The query that issued this fetch, or `nil` for a top-level fetch.
    /// Identifies the caller for reverse-dependency tracking without searching the set.
    public let callerQuery: AnyQuery?

    /// Identity of this fetch, distinct even for concurrent fetches of the same key.
    /// `nil` only in the root context.
    public let invocationID: UUID?

    /// Identity of the caller's fetch, or `nil` for a top-level fetch.
    public let parentInvocationID: UUID?

    /// Whether this fetch validates an old dependency.
    /// Observers must not record it as an additional semantic dependency.
    public let isValidationRead: Bool

    /// Queries preceding the current fetch, used to detect cycles before resolution.
    let ancestors: TreeSet<AnyQuery>

    /// Ancestor invocations awaiting this fetch, including its lifecycle callbacks.
    /// In-flight cycle detection uses these even before admission or after resolution.
    let ancestorInvocationIDs: TreeSet<UUID>

    /// This fetch's sequence number within its engine, or zero for the root context.
    /// Reserved before the first suspension so hooks cannot reorder dependency records.
    /// Red-green sorts a memo's reads by this number and validates them in that order.
    public let fetchOrder: UInt64

    /// Whether the next child context represents validation of an existing dependency.
    /// Applies to one fetch only; computations triggered by validation still collect
    /// their own ordinary dependency reads.
    private let nextReadIsValidation: Bool

    private init(
        queries: TreeSet<AnyQuery> = [],
        parentQuery: AnyQuery? = nil,
        callerQuery: AnyQuery? = nil,
        invocationID: UUID? = nil,
        parentInvocationID: UUID? = nil,
        isValidationRead: Bool = false,
        ancestors: TreeSet<AnyQuery> = [],
        ancestorInvocationIDs: TreeSet<UUID> = [],
        fetchOrder: UInt64 = 0,
        nextReadIsValidation: Bool = false
    ) {
        self.queries = queries
        self.parentQuery = parentQuery
        self.callerQuery = callerQuery
        self.invocationID = invocationID
        self.parentInvocationID = parentInvocationID
        self.isValidationRead = isValidationRead
        self.ancestors = ancestors
        self.ancestorInvocationIDs = ancestorInvocationIDs
        self.fetchOrder = fetchOrder
        self.nextReadIsValidation = nextReadIsValidation
    }

    /// Returns whether the query is in the execution chain.
    public func contains(_ query: AnyQuery) -> Bool {
        queries.contains(query)
    }

    /// Creates a child context for a nested query with a fresh invocation identity.
    /// Engines must create the child before calling query hooks or `compute`.
    /// - Parameters:
    ///   - query: The query being fetched
    ///   - fetchOrder: A strictly increasing number reserved by the engine for each fetch,
    ///     before its first suspension, so dependency validation preserves read order
    public func child(
        for query: AnyQuery,
        fetchOrder: UInt64
    ) -> ExecutionContext {
        var updated = queries
        updated.insert(query)
        var invocationAncestors = ancestorInvocationIDs
        if let invocationID {
            invocationAncestors.insert(invocationID)
        }
        return ExecutionContext(
            queries: updated,
            parentQuery: query,
            callerQuery: parentQuery,
            invocationID: UUID(),
            parentInvocationID: invocationID,
            isValidationRead: nextReadIsValidation,
            ancestors: queries,
            ancestorInvocationIDs: invocationAncestors,
            fetchOrder: fetchOrder
        )
    }

    /// Marks the next fetch as validation while preserving the execution ancestry.
    /// Custom memoizers use this context when replaying old dependencies.
    /// The replayed query's own computation reads remain ordinary dependencies.
    public func validatingDependencies() -> ExecutionContext {
        ExecutionContext(
            queries: queries,
            parentQuery: parentQuery,
            callerQuery: callerQuery,
            invocationID: invocationID,
            parentInvocationID: parentInvocationID,
            isValidationRead: isValidationRead,
            ancestors: ancestors,
            ancestorInvocationIDs: ancestorInvocationIDs,
            fetchOrder: fetchOrder,
            nextReadIsValidation: true
        )
    }
}
