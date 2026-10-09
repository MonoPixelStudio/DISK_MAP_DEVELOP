import Foundation
import Darwin
import DiskMapCore

enum CleanupChecks {
    static func run() async throws {
        try eligibleAndSamplePlans()
        print("PASS snapshot-bound candidates, sample isolation, known zero and large totals")
        try protectedPaths()
        print("PASS system/home/config/cloud/package protection and component boundaries")
        try malformedAndIncompleteSnapshots()
        print("PASS outside-root, malformed paths, unsafe descendants, links and incomplete candidates")
        try overlapAndRemoval()
        print("PASS duplicate/ancestor deduplication, parent replacement and list-only removal")
        try await limitsAndCancellation()
        print("PASS 500-candidate cap, atomic rejection, parent consolidation and validation cancellation")
        try await realFilesStayUntouched()
        print("PASS project-local real scan, candidate operations preserve contents, names and metadata")
    }

    private static let policy = CleanupPolicy(homePath: "/Users/test")
    private static func file(_ path: String, bytes: Int64 = 100, kind: FileNode.Kind = .file,
                             status: NodeScanStatus = .complete, duplicate: Bool = false) -> FileNode {
        FileNode(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path, kind: kind,
                 fileBytes: bytes, category: .other, status: status, isDuplicateHardLink: duplicate)
    }
    private static func folder(_ path: String, _ children: [FileNode] = [], status: NodeScanStatus = .complete) -> FileNode {
        FileNode(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                 kind: .folder, children: children, category: .other, status: status)
    }
    private static func blocked(_ node: FileNode, root: FileNode, reason: CleanupBlockReason,
                                policy: CleanupPolicy = policy) throws {
        var queue = CleanupQueue(root: root, isSample: false, policy: policy)
        try expect(try queue.restriction(for: node.id) == reason, "Wrong restriction for \(node.path)")
        do {
            try queue.add(node.id)
            throw CheckFailure(description: "Blocked candidate was accepted: \(node.path)")
        } catch let actual as CleanupBlockReason { try expect(actual == reason, "Wrong enqueue rejection") }
        try expect(queue.entries.isEmpty && queue.totalBytes == 0, "Rejected add changed queue")
    }

    private static func eligibleAndSamplePlans() throws {
        let zero = file("/fixture/empty", bytes: 0)
        let hardLink = file("/fixture/hard-link", bytes: 0, duplicate: true)
        let empty = folder("/fixture/empty-folder")
        let a = file("/fixture/a", bytes: 4_000_000_000_000_000_000)
        let b = file("/fixture/b", bytes: 3_000_000_000_000_000_000)
        let root = folder("/fixture", [zero, hardLink, empty, a, b])
        var queue = CleanupQueue(root: root, isSample: false, policy: policy)
        for node in root.children { try expect(try queue.add(node.id) == .added(replacedDescendants: 0), "Eligible item rejected") }
        try expect(queue.entries.count == 5 && queue.fileCount == 4, "Candidate and file counts differ")
        try expect(queue.totalBytes == 7_000_000_000_000_000_000, "Large allocation total is inaccurate")
        try expect(!queue.isSample && queue.rootPath == root.path, "Queue lost snapshot context")
        try blocked(root, root: root, reason: .scanRoot)
        var sample = CleanupQueue(root: SampleData.root, isSample: true, policy: policy)
        try sample.add("unity-build")
        try expect(sample.isSample && sample.entries.first?.allocatedBytes == 18_600_000_000, "Sample rehearsal failed")
        let fresh = CleanupQueue(root: SampleData.root, isSample: true, policy: policy)
        try expect(fresh.entries.isEmpty && fresh.totalBytes == 0, "New snapshot carried stale candidates")
    }

    private static func protectedPaths() throws {
        for path in ["/System/cache", "/Library/cache", "/Applications/Test.app", "/usr/local/data", "/private/data",
                     "/opt/tool", "/Users/test/Library/Caches/a", "/Users/test/.Trash/a", "/Users/test/.config/a",
                     "/Users/test/Dropbox/a", "/Users/test/OneDrive/a", "/fixture/.ssh/key", "/fixture/.aws/key",
                     "/fixture/Test.APP/inside", "/fixture/Photos.photoslibrary/inside", "/fixture/remote.icloud"] {
            let item = file(path)
            // A valid synthetic ancestry makes this a policy test, not a malformed-tree test.
            let components = path.split(separator: "/").map(String.init)
            var tree = item
            for depth in stride(from: components.count - 1, through: 1, by: -1) {
                tree = folder("/" + components.prefix(depth).joined(separator: "/"), [tree])
            }
            let root = folder("/", [tree])
            try blocked(item, root: root, reason: .protectedPath)
        }
        let home = folder("/Users/test")
        try blocked(home, root: folder("/Users", [home]), reason: .protectedPath)
        let custom = CleanupPolicy(homePath: "/Users/test", additionalProtectedPaths: ["/fixture/protected"])
        let parent = folder("/fixture")
        try blocked(parent, root: folder("/", [parent]), reason: .containsProtectedPath, policy: custom)
        let safe = file("/fixture/protected-neighbor")
        var queue = CleanupQueue(root: folder("/fixture", [safe]), isSample: false, policy: custom)
        try queue.add(safe.id)
        let download = file("/Users/test/Downloads/work.txt")
        var allowed = CleanupQueue(root: folder("/Users/test/Downloads", [download]), isSample: false, policy: policy)
        try allowed.add(download.id)
        let invalidHome = CleanupPolicy(homePath: "relative")
        try blocked(safe, root: folder("/fixture", [safe]), reason: .protectedPath, policy: invalidHome)
        let upper = file("/users/TEST/library/cache")
        try blocked(upper, root: folder("/users/TEST/library", [upper]), reason: .protectedPath)
    }

    private static func malformedAndIncompleteSnapshots() throws {
        let outside = file("/fixture-other/file")
        try blocked(outside, root: folder("/fixture", [outside]), reason: .outsideRoot)
        let traversal = file("/fixture/../escape")
        try blocked(traversal, root: folder("/fixture", [traversal]), reason: .invalidPath)
        let relative = FileNode(id: "relative", name: "file", path: "relative/file", kind: .file, category: .other)
        try blocked(relative, root: folder("/fixture", [relative]), reason: .invalidPath)
        let malformed = file("/fixture/missing/file")
        try blocked(malformed, root: folder("/fixture", [malformed]), reason: .invalidPath)
        for kind: FileNode.Kind in [.symbolicLink, .package, .other] {
            let item = file("/fixture/item", kind: kind)
            try blocked(item, root: folder("/fixture", [item]), reason: .unsupportedKind)
        }
        for status: NodeScanStatus in [.partial, .unreadable("test"), .excluded("test")] {
            let item = folder("/fixture/partial", [file("/fixture/partial/safe")], status: status)
            let root = folder("/fixture", [item], status: .partial)
            try blocked(item, root: root, reason: .incomplete)
            var queue = CleanupQueue(root: root, isSample: false, policy: policy)
            try queue.add("/fixture/partial/safe") // A readable child of a partial ancestor remains eligible.
        }
        let unsafe = folder("/fixture/folder", [file("/fixture/folder/link", kind: .symbolicLink)])
        try blocked(unsafe, root: folder("/fixture", [unsafe]), reason: .unsafeDescendant)
        let escape = folder("/fixture/folder", [file("/outside/secret")])
        try blocked(escape, root: folder("/fixture", [escape]), reason: .unsafeDescendant)
        let secrets = folder("/fixture/folder", [folder("/fixture/folder/.ssh")])
        try blocked(secrets, root: folder("/fixture", [secrets]), reason: .unsafeDescendant)
        let emptyRoot = folder("/fixture")
        var missing = CleanupQueue(root: emptyRoot, isSample: false, policy: policy)
        do { try missing.add("absent"); throw CheckFailure(description: "Unknown snapshot ID accepted") }
        catch CleanupBlockReason.outsideSnapshot {}
    }

    private static func overlapAndRemoval() throws {
        let a = file("/fixture/group/a", bytes: 700)
        let b = file("/fixture/group/b", bytes: 300)
        let group = folder("/fixture/group", [a, b])
        let neighbor = file("/fixture/groupish", bytes: 50)
        let root = folder("/fixture", [group, neighbor])
        var queue = CleanupQueue(root: root, isSample: false, policy: policy)
        try queue.add(a.id)
        try expect(try queue.add(a.id) == .alreadyIncluded && queue.entries.count == 1, "Duplicate candidate counted twice")
        try queue.add(b.id)
        try queue.add(neighbor.id)
        try expect(try queue.add(group.id) == .added(replacedDescendants: 2), "Parent did not replace children")
        try expect(queue.entries.count == 2 && queue.totalBytes == 1050 && queue.fileCount == 3, "Parent overlap distorted totals")
        try expect(queue.coverage(of: group.id) == .direct && queue.coverage(of: a.id) == .ancestor(name: "group"), "Coverage wrong")
        try expect(try queue.add(b.id) == .alreadyIncluded && queue.totalBytes == 1050, "Covered child was counted twice")
        queue.remove("unknown")
        try expect(queue.entries.count == 2, "Unknown removal changed queue")
        queue.remove(group.id)
        try expect(queue.entries.map(\.id) == [neighbor.id] && queue.coverage(of: a.id) == nil, "Removal left stale coverage")
        queue.removeAll()
        try expect(queue.entries.isEmpty && queue.totalBytes == 0 && root.children.count == 2, "Clear mutated snapshot")
    }

    private static func limitsAndCancellation() async throws {
        let children = (0...500).map { file("/fixture/group/item\($0)", bytes: 1) }
        let group = folder("/fixture/group", children)
        let root = folder("/fixture", [group])
        var queue = CleanupQueue(root: root, isSample: false, policy: policy)
        for child in children.prefix(500) { try queue.add(child.id) }
        do { try queue.add(children[500].id); throw CheckFailure(description: "Candidate cap exceeded") }
        catch CleanupBlockReason.limitReached {}
        try expect(queue.entries.count == 500 && queue.totalBytes == 500, "Failed add was not atomic")
        try expect(try queue.add(group.id) == .added(replacedDescendants: 500), "Consolidation at cap failed")
        try expect(queue.entries.count == 1 && queue.totalBytes == 501, "Consolidated parent omitted undrafted child")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                var copy = CleanupQueue(root: root, isSample: false, policy: policy)
                try copy.add(group.id)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(cancelled, "Candidate validation ignored cancellation")
    }

    private static func realFilesStayUntouched() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().resolvingSymlinksInPath()
        let base = project.appendingPathComponent(".diskmap-test-fixtures")
        var info = stat()
        try expect(lstat(base.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
                   base.resolvingSymlinksInPath().path == base.path, "Fixture base is unsafe")
        let fixture = base.appendingPathComponent("CleanupChecks-\(UUID().uuidString)")
        try expect(mkdir(fixture.path, 0o700) == 0, "Cannot create unique cleanup fixture")
        defer {
            if fixture.deletingLastPathComponent() == base && fixture.resolvingSymlinksInPath().path == fixture.path {
                try? FileManager.default.removeItem(at: fixture)
            }
        }
        let dir = fixture.appendingPathComponent("한글 폴더")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let url = dir.appendingPathComponent("보고서.bin")
        let payload = Data(repeating: 0x5A, count: 32_768)
        try payload.write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let (root, _, _) = try await ScannerChecks.collect(fixture)
        let folderNode = try require(root.children.first, "Missing folder snapshot")
        let fileNode = try require(folderNode.children.first, "Missing file snapshot")
        var queue = CleanupQueue(root: root, isSample: false)
        try queue.add(fileNode.id)
        try expect(try queue.add(folderNode.id) == .added(replacedDescendants: 1), "Unicode ancestry was not normalized")
        queue.remove(folderNode.id)
        try queue.add(fileNode.id)
        queue.removeAll()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        try expect(try Data(contentsOf: url) == payload, "Candidate operations changed file contents")
        for key: FileAttributeKey in [.modificationDate, .creationDate, .posixPermissions, .systemFileNumber] {
            try expect((before[key] as? NSObject) == (after[key] as? NSObject), "Candidate operations changed \(key)")
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [url.lastPathComponent], "Candidate operations moved/renamed file")
    }
}
