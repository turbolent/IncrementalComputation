/// Sendable wrapper around a type-erased query key.
public struct QueryKey: Hashable, Sendable {
    private let raw: any Hashable & Sendable

    public init<Q: Query>(_ query: Q) {
        self.raw = query
    }

    public static func == (lhs: QueryKey, rhs: QueryKey) -> Bool {
        AnyHashable(lhs.raw) == AnyHashable(rhs.raw)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.raw)
    }
}
