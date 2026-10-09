import Foundation
import Darwin
import DiskMapCore

enum ReleaseChecks {
    static func run() async throws {
        try await longUnicodePaths()
        print("PASS long Unicode paths, canonical search and unchanged trash validation")
        try await changesDuringScan()
        print("PASS concurrent directory/file changes, partial scan notice and stale-candidate rejection")
        try await boundedErrors()
        print("PASS 150 denied folders, bounded issue samples and recovery without data changes")
        try await repeatedCancellation()
        print("PASS 30 scan/cancel/recovery cycles, stable contents and closed directory descriptors")
        try await indexedNavigation()
        print("PASS indexed navigation/trails, subtree boundaries, duplicate rejection and cancellation")
    }
    private static func longUnicodePaths() async throws {
        let fixture = try ProjectFixture("LongPaths")
        defer { try? fixture.clean() }
        let components = (0..<9).map { "한글 경로-\($0)-abcdefghijklmnop-e\u{301}" }
        // Stay below NAME_MAX after macOS decomposes Hangul in filesystem paths.
        let name = "검증할 파일-" + String(repeating: "가", count: 25) + ".bin"
        let file = try fixture.file((components + [name]).joined(separator: "/"))
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let (tree, summary, _) = try await ScannerChecks.collect(fixture.url)
        try expect(tree.fileCount == 1 && summary.skippedItems == 0 && file.path.utf8.count > 600, "Long path lost")
        var query = BrowserQuery(); query.includesDescendants = true
        query.search = name.decomposedStringWithCanonicalMapping
        try expect(try query.results(in: tree).map(\.path) == [file.path], "Long Unicode search failed")
        var queue = CleanupQueue(root: tree, isSample: false)
        try queue.add(file.path)
        try TrashValidation.check(queue.trashRequests()[0])
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        for key: FileAttributeKey in [.modificationDate, .creationDate, .posixPermissions, .systemFileNumber] {
            try expect((before[key] as? NSObject) == (after[key] as? NSObject), "Long-path validation modified file")
        }
        try expect(try Data(contentsOf: file) == Data(repeating: 0x53, count: 4096), "Long-path data changed")
    }
    private static func changesDuringScan() async throws {
        let fixture = try ProjectFixture("ConcurrentScan")
        defer { try? fixture.clean() }
        let stable = try fixture.file("선택하지않음.bin")
        let changing = try fixture.file("변경중.bin")
        for index in 0..<5000 { _ = try fixture.file("파일-\(index).bin", bytes: 0) }
        let (old, _, _) = try await ScannerChecks.collect(fixture.url)
        var queue = CleanupQueue(root: old, isSample: false)
        try queue.add(changing.path)
        let stale = try queue.trashRequests()[0]
        let stableIdentity = old.node(withID: stable.path)?.fingerprint
        var changed = false
        var finished: FileNode?
        var finishedSummary: ScanSummary?
        for try await event in LocalDiskScanner().scan(ScanRequest(rootURL: fixture.url)) {
            switch event {
            case .progress where !changed:
                _ = try fixture.file("스캔중 새 파일.bin", bytes: 100)
                try Data(repeating: 0x37, count: 8192).write(to: changing)
                changed = true
            case .completed(let tree, let summary): finished = tree; finishedSummary = summary
            default: break
            }
        }
        let tree = try require(finished, "Concurrent scan did not finish")
        try expect(changed && tree.status == .partial, "Directory mutation was reported as complete")
        try expect(finishedSummary?.issues.contains(where: { $0.reason.contains("바뀌") }) == true, "Missing mutation notice")
        do { try TrashValidation.check(stale); throw CheckFailure(description: "Stale changed candidate accepted") }
        catch is TrashSafetyError {}
        try expect(try Data(contentsOf: stable) == Data(repeating: 0x53, count: 4096), "Unselected contents changed")
        let (fresh, summary, _) = try await ScannerChecks.collect(fixture.url)
        try expect(fresh.status == .complete && fresh.fileCount == 5003 && summary.skippedItems == 0, "Recovery scan failed")
        try expect(fresh.node(withID: stable.path)?.fingerprint == stableIdentity, "Unselected fingerprint changed")
        try expect(fresh.node(withID: changing.path)?.totalLogicalBytes == 8192, "Recovery retained old size")
    }
    private static func boundedErrors() async throws {
        let fixture = try ProjectFixture("ManyErrors")
        var denied: [URL] = []
        defer {
            for folder in denied { _ = chmod(folder.path, 0o700) }
            try? fixture.clean()
        }
        for index in 0..<150 {
            let file = try fixture.file("denied-\(index)/내용.bin", bytes: 16)
            let folder = file.deletingLastPathComponent()
            denied.append(folder)
            try expect(chmod(folder.path, 0) == 0, "Cannot restrict own fixture")
        }
        let sentinel = try fixture.file(".ssh/선택불가.txt")
        let (tree, summary, _) = try await ScannerChecks.collect(fixture.url)
        try expect(tree.status == .partial && summary.skippedItems == 150 && summary.issues.count == 100, "Error samples unbounded or counts lost")
        var queue = CleanupQueue(root: tree, isSample: false)
        do { try queue.add(sentinel.path); throw CheckFailure(description: "Protected fixture candidate accepted") }
        catch CleanupBlockReason.protectedPath {}
        for folder in denied { try expect(chmod(folder.path, 0o700) == 0, "Cannot restore own fixture permission") }
        let (fresh, recovered, _) = try await ScannerChecks.collect(fixture.url)
        try expect(fresh.fileCount == 151 && recovered.skippedItems == 0, "Permission recovery lost files")
        try expect(try Data(contentsOf: sentinel) == Data(repeating: 0x53, count: 4096), "Protected fixture changed")
    }
    private static func descriptorCount() -> Int {
        (0..<1024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }
    private static func indexedNavigation() async throws {
        let root = SampleData.root
        let index = try FileSnapshotIndex(root: root)
        var pending = [root]
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            try expect(index.node(withID: node.id) == node && index.trail(to: node.id) == root.trail(to: node.id), "Indexed ancestry differs from snapshot")
            pending.append(contentsOf: node.children)
        }
        try expect(index.count == visited && index.node(withID: "missing") == nil && index.trail(to: "missing") == nil, "Index membership incorrect")
        try expect(index.trail(to: "unity-build", from: "unity")?.map(\.id) == ["unity", "unity-build"], "Subtree trail incorrect")
        try expect(index.trail(to: "unity-build", from: "downloads") == nil && index.trail(to: "unity", from: "unity")?.count == 1, "Subtree boundary ignored")
        let duplicate = FileNode(id: "bad", name: "bad", path: "/bad", kind: .folder,
                                 children: [root, root], category: .other)
        do { _ = try FileSnapshotIndex(root: duplicate); throw CheckFailure(description: "Duplicate IDs accepted") }
        catch SnapshotIndexFailure.duplicateIdentity {}
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try FileSnapshotIndex(root: root); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(cancelled, "Index ignored cancellation")
    }
    private static func repeatedCancellation() async throws {
        let fixture = try ProjectFixture("RepeatedScan")
        defer { try? fixture.clean() }
        for index in 0..<100 { _ = try fixture.file("folder-\(index)/내용.bin", bytes: 32) }
        _ = try await ScannerChecks.collect(fixture.url) // Warm runtime and Foundation caches.
        let before = descriptorCount()
        let fixtureURL = fixture.url
        for _ in 0..<30 {
            let cancelled = await Task {
                var completed = false
                do {
                    for try await event in LocalDiskScanner().scan(ScanRequest(rootURL: fixtureURL)) {
                        if case .progress = event { withUnsafeCurrentTask { $0?.cancel() } }
                        if case .completed = event { completed = true }
                    }
                } catch is CancellationError {} catch { return false }
                return !completed
            }.value
            try expect(cancelled, "Cancelled repeated scan completed")
            let (tree, summary, _) = try await ScannerChecks.collect(fixture.url)
            try expect(tree.fileCount == 100 && summary.skippedItems == 0, "Repeated recovery failed")
            _ = try BrowserQuery().results(in: tree)
            _ = try SunburstLayout.build(for: tree, maximumDepth: 4)
        }
        try await Task.sleep(for: .milliseconds(50))
        try expect(descriptorCount() <= before + 2, "Directory descriptors leaked during repeated cancellation")
        try expect(try Data(contentsOf: fixture.url.appendingPathComponent("folder-99/내용.bin")) == Data(repeating: 0x53, count: 32), "Repeated scan changed contents")
    }
}
