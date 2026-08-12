import Foundation
import Testing

@testable import SwiraCore

@Suite("Filter paths")
struct FilterPathTests {
    @Test("The canonical example parses into its segments and round-trips")
    func parsesCanonicalExample() {
        // The real filter this feature is modeled on.
        let path = FilterPath(name: "Swira: Versions: Current")

        #expect(path.segments == ["Swira", "Versions", "Current"])
        #expect(path.leaf == "Current")
        #expect(path.filterName == "Swira: Versions: Current")
        #expect(path.parent == FilterPath(segments: ["Swira", "Versions"]))
        #expect(!path.isRoot)
    }

    @Test("Only ': ' separates — a bare colon stays inside a segment")
    func separatorIsExact() {
        #expect(FilterPath(name: "A:B").segments == ["A:B"])
        #expect(FilterPath(name: "Jira 8").segments == ["Jira 8"])
        #expect(FilterPath(name: "Jira 8").isRoot)
        #expect(FilterPath(name: "http://x: docs").segments == ["http://x", "docs"])
    }

    @Test("Paths compose and decompose")
    func composes() {
        let versions = FilterPath(segments: [FilterPath.defaultRoot, "Versions"])
        let current = versions.appending("Current")

        #expect(current.filterName == "Swira: Versions: Current")
        #expect(current.parent == versions)
        #expect(versions.isAncestor(of: current))
        #expect(!current.isAncestor(of: versions))
        #expect(!versions.isAncestor(of: versions))
    }

    @Test("Names round-trip through parse and render byte-for-byte")
    func roundTrips() {
        for name in ["Swira: Versions: Current", "A:B", " padded ", "x:  y", "Swira: "] {
            #expect(FilterPath(name: name).filterName == name)
        }
    }
}

@Suite("Filter tree")
struct FilterTreeTests {
    private func filter(_ id: String, _ name: String) -> JiraFilter {
        JiraFilter(id: id, name: name)
    }

    @Test("A flat list reassembles into the encoded forest")
    func buildsForest() {
        let nodes = FilterTree.build(from: [
            filter("1", "Swira: Versions: Current"),
            filter("2", "Swira: Versions: Old"),
            filter("3", "Swira: Bugs"),
            filter("4", "Jira 8"),
        ])

        #expect(nodes.map(\.name) == ["Jira 8", "Swira"])

        let swira = nodes[1]
        // No filter is named exactly "Swira": the root exists only as a branch point.
        #expect(swira.isVirtual)
        #expect(swira.children.map(\.name) == ["Bugs", "Versions"])

        let versions = swira.children[1]
        #expect(versions.isVirtual)
        #expect(versions.children.map(\.name) == ["Current", "Old"])
        #expect(versions.children[0].filter?.id == "1")
        #expect(versions.path.filterName == "Swira: Versions")
    }

    @Test("A node can be a filter and a parent at once")
    func nodeCanBeBoth() {
        let nodes = FilterTree.build(from: [
            filter("1", "Swira: Versions"),
            filter("2", "Swira: Versions: Current"),
        ])

        let versions = nodes[0].children[0]
        #expect(versions.filter?.id == "1")
        #expect(!versions.isVirtual)
        #expect(versions.children.count == 1)
        #expect(versions.children[0].filter?.id == "2")
    }

    @Test("Children sort case-insensitively, roots included")
    func sortsCaseInsensitively() {
        let nodes = FilterTree.build(from: [
            filter("1", "beta"),
            filter("2", "Alpha"),
            filter("3", "gamma: x"),
        ])
        #expect(nodes.map(\.name) == ["Alpha", "beta", "gamma"])
    }

    @Test("Duplicate full names keep the first filter instead of forking the node")
    func deduplicatesNames() {
        let nodes = FilterTree.build(from: [
            filter("1", "Swira: Bugs"),
            filter("2", "Swira: Bugs"),
        ])

        let swira = nodes[0]
        #expect(swira.children.count == 1)
        #expect(swira.children[0].filter?.id == "1")
    }

    @Test("allFilters walks the subtree depth-first; node(at:) addresses by path")
    func navigates() {
        let nodes = FilterTree.build(from: [
            filter("1", "Swira: Versions: Current"),
            filter("2", "Swira: Versions"),
            filter("3", "Swira: Bugs"),
        ])
        let swira = nodes[0]

        #expect(swira.allFilters.map(\.id) == ["3", "2", "1"])

        let found = swira.node(at: FilterPath(name: "Swira: Versions: Current"))
        #expect(found?.filter?.id == "1")
        #expect(swira.node(at: FilterPath(name: "Swira: Missing")) == nil)
    }

    @Test("The tree the user's real filters produce")
    func buildsRealWorldTree() {
        // The actual filter set observed on the live account.
        let nodes = FilterTree.build(from: [
            filter("128720", "Jira 8"),
            filter("128721", "Swira: Versions: Current"),
        ])

        #expect(nodes.count == 2)
        #expect(nodes[0].name == "Jira 8")
        #expect(!nodes[0].isVirtual)

        let swira = nodes[1]
        #expect(swira.isVirtual)
        let current = swira.node(at: FilterPath(name: "Swira: Versions: Current"))
        #expect(current?.filter?.id == "128721")
    }
}

@Suite("FiltersService hierarchy")
struct FiltersServiceHierarchyTests {
    @Test("tree() merges own and favourite filters without duplicating shared ids")
    func buildsTreeFromService() async throws {
        let mine = Data(#"""
        [{"id":"1","name":"Swira: Versions: Current","favourite":false},
         {"id":"2","name":"Swira: Bugs","favourite":true}]
        """#.utf8)
        let favourites = Data(#"""
        [{"id":"2","name":"Swira: Bugs","favourite":true},
         {"id":"3","name":"Jira 8","favourite":true}]
        """#.utf8)
        let mock = MockTransport(stubs: [.ok(mine), .ok(favourites)])
        let service = FiltersService(client: JiraClient(transport: mock, auth: NoAuthProvider()))

        let tree = try await service.tree()

        #expect(tree.origin == .network)
        #expect(tree.value.map(\.name) == ["Jira 8", "Swira"])

        let swira = tree.value[1]
        // Filter id 2 appears in both source lists but must land in the tree exactly once.
        #expect(swira.allFilters.map(\.id) == ["2", "1"])
    }

    @Test("create(at:) stores the filter under the path's flat name, non-favourite")
    func createsAtPath() async throws {
        let mock = MockTransport(stubs: [.ok(try Fixture.data("filter"))])
        let service = FiltersService(client: JiraClient(transport: mock, auth: NoAuthProvider()))

        let path = FilterPath(segments: [FilterPath.defaultRoot, "Versions"]).appending("Old")
        _ = try await service.create(at: path, jql: "fixVersion ~ '7.*'")

        let request = try #require(await mock.recorded.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["name"]?.stringValue == "Swira: Versions: Old")
        #expect(body["favourite"]?.boolValue == false)
    }
}
