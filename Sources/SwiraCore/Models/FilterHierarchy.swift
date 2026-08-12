import Foundation

/// A filter's position in the name-encoded hierarchy.
///
/// Jira itself has no filter folders. Swira encodes a tree into plain filter names: path segments
/// joined by `": "`, so the filter named `Swira: Versions: Current` is the node `Current` under
/// `Versions` under the root `Swira`. Any Jira client — including Jira's own UI — still sees an
/// ordinary flat name, which is the whole point: the scheme degrades gracefully.
public struct FilterPath: Sendable, Hashable {
    /// The segment separator. Exactly a colon and one space — a name like `A:B` is a single
    /// segment, not a nested one.
    public static let separator = ": "

    /// The root Swira's clients create under by default. Nothing in the core requires it: any
    /// segment can be a root, and trees built from real filters keep whatever roots they find.
    public static let defaultRoot = "Swira"

    public var segments: [String]

    public init(segments: [String]) {
        self.segments = segments
    }

    /// Splits a filter name into its path. Exact split, no trimming — parsing and `filterName`
    /// must round-trip byte-for-byte, or renames would corrupt names the user typed.
    public init(name: String) {
        self.init(segments: name.components(separatedBy: Self.separator))
    }

    /// The flat Jira filter name this path is stored under.
    public var filterName: String {
        segments.joined(separator: Self.separator)
    }

    /// The node's own name — the last segment.
    public var leaf: String {
        segments.last ?? ""
    }

    public var parent: FilterPath? {
        segments.count > 1 ? FilterPath(segments: Array(segments.dropLast())) : nil
    }

    public var isRoot: Bool {
        segments.count == 1
    }

    public func appending(_ segment: String) -> FilterPath {
        FilterPath(segments: segments + [segment])
    }

    /// Whether `other` sits anywhere below this path.
    public func isAncestor(of other: FilterPath) -> Bool {
        other.segments.count > segments.count
            && Array(other.segments.prefix(segments.count)) == segments
    }
}

extension FilterPath: CustomStringConvertible {
    public var description: String { filterName }
}

extension JiraFilter {
    /// The filter's place in the name-encoded hierarchy.
    public var path: FilterPath {
        FilterPath(name: name)
    }
}

/// One node of the reconstructed filter tree.
///
/// A node can be three things, and the combinations all occur in real data:
/// - backed by a filter and childless — an ordinary leaf;
/// - backed by a filter *and* a parent — `Swira: Versions` exists and so does
///   `Swira: Versions: Current`;
/// - virtual (`filter == nil`) — no filter named `Swira` exists, but the segment is still needed
///   as a branch point for everything beneath it.
public struct FilterTreeNode: Sendable {
    /// The node's own name — the last segment of `path`.
    public let name: String
    public let path: FilterPath
    /// The filter stored at exactly this path, if one exists.
    public let filter: JiraFilter?
    /// Sorted by name, case-insensitively.
    public let children: [FilterTreeNode]

    /// A branch point with no filter of its own.
    public var isVirtual: Bool {
        filter == nil
    }

    /// Every filter at or below this node, depth-first.
    public var allFilters: [JiraFilter] {
        var result: [JiraFilter] = []
        if let filter {
            result.append(filter)
        }
        for child in children {
            result.append(contentsOf: child.allFilters)
        }
        return result
    }

    /// The node at `path` within this subtree, if present.
    public func node(at path: FilterPath) -> FilterTreeNode? {
        guard path.segments.first == name else { return nil }
        let remainder = Array(path.segments.dropFirst())
        guard !remainder.isEmpty else { return self }
        for child in children {
            if let found = child.node(at: FilterPath(segments: remainder)) {
                return found
            }
        }
        return nil
    }
}

/// Builds the tree clients render from the flat list Jira stores.
public enum FilterTree {
    /// Reconstructs the forest encoded in the filters' names.
    ///
    /// Filters whose names contain no separator become root nodes of their own — a flat filter
    /// like `Jira 8` is simply a tree of one. When several filters carry the same full name
    /// (possible when the list mixes owners), the first keeps the node and the rest are dropped
    /// rather than producing duplicate nodes.
    public static func build(from filters: [JiraFilter]) -> [FilterTreeNode] {
        buildLevel(entries: filters.map { (FilterPath(name: $0.name).segments, $0) }, prefix: [])
    }

    private static func buildLevel(
        entries: [(segments: [String], filter: JiraFilter)],
        prefix: [String]
    ) -> [FilterTreeNode] {
        // Group by leading segment, remembering first-appearance order only long enough to sort.
        var groups: [String: [(segments: [String], filter: JiraFilter)]] = [:]
        for entry in entries where !entry.segments.isEmpty {
            groups[entry.segments[0], default: []].append(
                (Array(entry.segments.dropFirst()), entry.filter)
            )
        }

        return groups
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { segment, members in
                let path = FilterPath(segments: prefix + [segment])
                // The filter stored at exactly this node is the member with no segments left.
                let own = members.first { $0.segments.isEmpty }?.filter
                let deeper = members.filter { !$0.segments.isEmpty }
                return FilterTreeNode(
                    name: segment,
                    path: path,
                    filter: own,
                    children: buildLevel(entries: deeper, prefix: path.segments)
                )
            }
    }
}
