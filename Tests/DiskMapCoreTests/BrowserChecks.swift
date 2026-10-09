import Foundation
import DiskMapCore

enum BrowserChecks {
    static func run() async throws {
        try searchScopeAndUnicode()
        print("PASS scoped name search, Korean normalization, accents and case")
        try sortingAndUnknownSizes()
        print("PASS size/name sorting, natural numbers, ties and unknown sizes")
        try combinedFilters()
        print("PASS kind/size/name combinations and hidden subtree exclusion")
        try locationBoundaries()
        print("PASS sample and outside-root Finder requests rejected, symlink leaf preserved")
        try await largeQueryAndCancellation()
        print("PASS large snapshot query and cancellation")
    }

    private static func file(_ name: String, in parent: String = "/fixture", bytes: Int64 = 100) -> FileNode {
        let path = parent + "/" + name
        return FileNode(id: path, name: name, path: path, kind: .file, fileBytes: bytes, category: .other)
    }

    private static var snapshot: FileNode {
        let folder = FileNode(id: "/fixture/한글", name: "한글", path: "/fixture/한글", kind: .folder,
                              children: [file("보고서.TXT", in: "/fixture/한글", bytes: 2_000_000),
                                         file("Café.txt", in: "/fixture/한글")], category: .documents)
        let hidden = FileNode(id: "/fixture/.hidden", name: ".hidden", path: "/fixture/.hidden", kind: .folder,
                              children: [file("inside.txt", in: "/fixture/.hidden")], category: .other)
        let unknown = FileNode(id: "/fixture/unreadable", name: "unreadable", path: "/fixture/unreadable",
                               kind: .folder, category: .other, status: .unreadable("Test only"))
        return FileNode(id: "/fixture", name: "fixture", path: "/fixture", kind: .folder,
                        children: [file("item10.bin", bytes: 4_000_000), file("item2.bin", bytes: 0),
                                   file(".hidden.txt"), folder, hidden, unknown], category: .other)
    }

    private static func searchScopeAndUnicode() throws {
        var query = BrowserQuery()
        query.search = "보고서"
        try expect(try query.results(in: snapshot).isEmpty, "Direct search unexpectedly traversed descendants")
        query.includesDescendants = true
        query.search = "  보고서".decomposedStringWithCanonicalMapping + "  "
        let korean = try query.results(in: snapshot)
        try expect(korean.map(\.name) == ["보고서.TXT"], "Korean canonical normalization failed")
        query.search = "CAFE"
        try expect(try query.results(in: snapshot).map(\.name) == ["Café.txt"], "Case/diacritic search failed")
        query.search = "한글"
        try expect(try query.results(in: snapshot).map(\.name) == ["한글"], "Search must match names, not every parent path")
        query.search = " \n "
        try expect(try query.results(in: snapshot).count == 9, "Blank search or descendant traversal is wrong")
    }

    private static func sortingAndUnknownSizes() throws {
        var query = BrowserQuery()
        let root = snapshot
        try expect(try query.results(in: root).first?.name == "item10.bin", "Largest file must be first")
        query.sort = .sizeAscending
        let ascending = try query.results(in: root)
        try expect(ascending.first?.name == "item2.bin" && ascending.last?.name == "unreadable",
                   "Unknown size must remain last; known zero must sort as zero")
        query.kind = .files
        query.sort = .nameAscending
        try expect(try query.results(in: root).map(\.name) == [".hidden.txt", "item2.bin", "item10.bin"],
                   "Name sorting must use natural numeric order")
        query.sort = .nameDescending
        try expect(try query.results(in: root).map(\.name) == ["item10.bin", "item2.bin", ".hidden.txt"], "Descending name sort failed")
        let ties = FileNode(id: "ties", name: "ties", path: "/fixture", kind: .folder,
                            children: [file("same.txt", in: "/fixture/b"), file("same.txt", in: "/fixture/a")], category: .other)
        query.sort = .sizeDescending
        try expect(try query.results(in: ties).map(\.path) == ["/fixture/a/same.txt", "/fixture/b/same.txt"],
                   "Equal names and sizes need a deterministic path tie-breaker")
    }

    private static func combinedFilters() throws {
        var query = BrowserQuery()
        query.includesDescendants = true
        query.kind = .files
        query.minimumSize = .megabyte
        query.search = ".txt"
        try expect(try query.results(in: snapshot).map(\.name) == ["보고서.TXT"], "Combined filters lost or added an item")
        query.search = ""
        query.minimumSize = .hundredMegabytes
        try expect(try query.results(in: snapshot).isEmpty, "Minimum size filter failed")
        query.minimumSize = .all
        query.showsHidden = false
        let visible = try query.results(in: snapshot)
        try expect(Set(visible.map(\.name)) == ["item10.bin", "item2.bin", "보고서.TXT", "Café.txt"],
                   "Hidden folder descendants must also be hidden")
        query.kind = .folders
        query.minimumSize = .megabyte
        try expect(try query.results(in: snapshot).map(\.name) == ["한글"], "Folder size filter must use aggregated known allocation")
        try expect(BrowserQuery().hasFilters == false && query.hasFilters, "Filter state is wrong")
    }

    private static func locationBoundaries() throws {
        func rejected(_ item: String, root: String = "/fixture", sample: Bool = false) throws {
            do {
                _ = try FileLocation.url(itemPath: item, rootPath: root, isSample: sample)
                throw CheckFailure(description: "Unsafe Finder request accepted: \(item)")
            } catch is FileLocationFailure {}
        }
        try rejected("/fixture/file", sample: true)
        try rejected("/fixture-other/file")
        try rejected("/fixture/../outside/file")
        try rejected("relative/file")
        let link = try FileLocation.url(itemPath: "/fixture/link", rootPath: "/fixture/", isSample: false)
        try expect(link.path == "/fixture/link", "Location request must not resolve a symlink leaf")
        try expect(try FileLocation.url(itemPath: "/fixture", rootPath: "/fixture", isSample: false).path == "/fixture",
                   "Root item must be accepted")
        try expect(try FileLocation.url(itemPath: "/folder/file", rootPath: "/", isSample: false).path == "/folder/file",
                   "Filesystem root containment failed")
    }

    private static func largeQueryAndCancellation() async throws {
        let children = (0..<20_000).map { file("item\($0).bin", bytes: Int64($0)) }
        let root = FileNode(id: "large", name: "large", path: "/fixture", kind: .folder, children: children, category: .other)
        var query = BrowserQuery()
        query.search = "item19999"
        try expect(try query.results(in: root).map(\.name) == ["item19999.bin"], "Large search lost the last item")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try BrowserQuery().results(in: root)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(cancelled, "Cancelled query must stop before publishing stale results")
    }
}
