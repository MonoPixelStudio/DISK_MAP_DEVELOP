import Foundation
import Darwin
import DiskMapCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    let passed = try condition()
    if !passed { throw CheckFailure(description: message) }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

@main
struct FileTreeChecks {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--benchmark") {
                try await PerformanceChecks.runBenchmark()
                return
            }
            try sampleSizesAreConsistent()
            print("PASS sample totals and size ordering")
            try nestedNavigationPreservesAncestry()
            print("PASS nested navigation and unknown IDs")
            try emptyFolderIsNotAFile()
            print("PASS empty folder accounting")
            try sampleIdentitiesAndPathsAreUnique()
            print("PASS unique sample identities and synthetic paths")
            try await unavailableServicesCannotTouchDisk()
            print("PASS unavailable scan service rejects operations")
            try await ScannerChecks.run()
            try await BrowserChecks.run()
            try await SunburstChecks.run()
            try await CleanupChecks.run()
            try await TrashChecks.run()
            try ConvenienceChecks.run()
            try await ReleaseChecks.run()
            print("39 check groups passed")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }

    static func sampleSizesAreConsistent() throws {
        try expect(SampleData.root.totalBytes == 98_830_000_000, "Unexpected sample total")
        try expect(SampleData.root.fileCount == 15, "Unexpected sample file count")
        try expect(SampleData.root.childrenBySize.first?.id == "projects", "Largest folder must come first")
    }

    static func nestedNavigationPreservesAncestry() throws {
        let trail = try require(SampleData.root.trail(to: "unity-build"), "Missing nested trail")
        try expect(trail.map(\.id) == ["sample", "projects", "unity", "unity-build"], "Incorrect ancestry")
        try expect(SampleData.root.node(withID: "unity-build")?.isFolder == false, "File classified as folder")
        try expect(SampleData.root.node(withID: "missing") == nil, "Unknown node found")
        try expect(SampleData.root.trail(to: "missing") == nil, "Unknown trail found")
    }

    static func emptyFolderIsNotAFile() throws {
        let empty = try require(SampleData.root.node(withID: "empty"), "Empty fixture missing")
        try expect(empty.isFolder && empty.fileCount == 0 && empty.totalBytes == 0, "Incorrect empty folder accounting")
    }

    static func sampleIdentitiesAndPathsAreUnique() throws {
        func flatten(_ node: FileNode) -> [FileNode] { [node] + node.children.flatMap(flatten) }
        let nodes = flatten(SampleData.root)
        try expect(Set(nodes.map(\.id)).count == nodes.count, "Duplicate sample ID")
        try expect(Set(nodes.map(\.path)).count == nodes.count, "Duplicate sample path")
        try expect(nodes.allSatisfy { $0.path.hasPrefix("/샘플") }, "Sample points outside synthetic root")
    }

    static func unavailableServicesCannotTouchDisk() async throws {
        let url = URL(fileURLWithPath: "/this-path-must-never-be-accessed")
        do {
            for try await _ in UnavailableScanner().scan(ScanRequest(rootURL: url)) {
                throw CheckFailure(description: "Unavailable scanner emitted data")
            }
            throw CheckFailure(description: "Unavailable scanner succeeded")
        } catch is FeatureUnavailable {
            // Expected: no filesystem traversal is connected in milestone 1.
        }
    }
}
