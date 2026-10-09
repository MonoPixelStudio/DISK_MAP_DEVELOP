import Foundation
import Darwin
import DiskMapCore

enum ScannerChecks {
    static func run() async throws {
        try await sizesAndReadOnlyMetadata()
        print("PASS real allocated/logical sizes, hard links, hidden and Unicode files, read-only scan")
        try await linksAndSpecialFiles()
        print("PASS symlink loop and outside-root link isolation, FIFO exclusion")
        try await permissionFailures()
        print("PASS unreadable child, unreadable root and missing root")
        try await exclusionsAndDepth()
        print("PASS packages, cloud roots, cloud placeholders and depth boundary")
        try await cancellationAndLargeDirectory()
        print("PASS 10,000-item scan, progress, consumer cancellation and recovery")
    }

    // Derive the project from this source, so running from another working directory
    // never creates fixtures in an unrelated folder or the system temporary directory.
    private static let fixtureBase = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .resolvingSymlinksInPath().appendingPathComponent(".diskmap-test-fixtures")

    private static func fixture() throws -> URL {
        if mkdir(fixtureBase.path, 0o700) != 0 && errno != EEXIST {
            throw CheckFailure(description: "Cannot create project-local fixture directory")
        }
        var info = stat()
        try expect(lstat(fixtureBase.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
                   "Fixture base must be a directory, not a symlink")
        try expect(fixtureBase.resolvingSymlinksInPath().path == fixtureBase.path,
                   "Fixture base must remain inside the project")
        let url = fixtureBase.appendingPathComponent("DiskMapChecks-\(UUID().uuidString)")
        // mkdir fails on an existing path; never reuse or clean someone else's files.
        try expect(mkdir(url.path, 0o700) == 0, "Cannot create unique fixture directory")
        return url
    }

    private static func removeFixture(_ url: URL) {
        guard url.deletingLastPathComponent().path == fixtureBase.path,
              url.lastPathComponent.hasPrefix("DiskMapChecks-"),
              url.resolvingSymlinksInPath().path == url.path else {
            FileHandle.standardError.write(Data("Refused fixture cleanup outside the project test directory\n".utf8))
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func collect(_ root: URL, policy: ScanPolicy = ScanPolicy()) async throws -> (FileNode, ScanSummary, [ScanProgress]) {
        var result: (FileNode, ScanSummary)?
        var updates: [ScanProgress] = []
        for try await event in LocalDiskScanner(policy: policy).scan(ScanRequest(rootURL: root)) {
            switch event {
            case .progress(let update): updates.append(update)
            case .completed(let node, let summary): result = (node, summary)
            }
        }
        let completed = try require(result, "Scanner did not complete")
        return (completed.0, completed.1, updates)
    }

    private static func diskBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        try expect(lstat(url.path, &info) == 0, "Cannot inspect fixture")
        return Int64(info.st_blocks) * 512
    }

    private static func sizesAndReadOnlyMetadata() async throws {
        let root = try fixture()
        defer { removeFixture(root) }
        let nested = root.appendingPathComponent("한글 폴더")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let a = root.appendingPathComponent(".hidden.bin")
        let b = nested.appendingPathComponent("실제 파일.bin")
        let link = root.appendingPathComponent("hardlink.bin")
        let sparse = root.appendingPathComponent("sparse.bin")
        // Noncompressible-ish content; exact allocated totals are checked against stat, not assumed.
        let content: [UInt8] = (0..<80_001).map { (index: Int) -> UInt8 in
            let value: Int = index * 31 + index / 255
            return UInt8(value % 256)
        }
        let payload = Data(content)
        try payload.write(to: a)
        try Data(repeating: 0xA5, count: 12_345).write(to: b)
        try FileManager.default.linkItem(at: a, to: link)
        let fd = open(sparse.path, O_CREAT | O_RDWR, 0o600)
        try expect(fd >= 0, "Cannot create sparse fixture")
        let truncated = ftruncate(fd, 16_000_000)
        close(fd)
        try expect(truncated == 0, "Cannot create sparse fixture size")
        let before = try FileManager.default.attributesOfItem(atPath: a.path)
        let expected = try diskBytes(a) + diskBytes(b) + diskBytes(sparse)
        let (node, summary, updates) = try await collect(root)
        try expect(node.totalBytes == expected, "Allocated bytes must match unique file allocation")
        try expect(node.totalLogicalBytes == 80_001 * 2 + 12_345 + 16_000_000, "Logical bytes must retain each directory entry")
        try expect(node.fileCount == 4 && summary.skippedItems == 0, "Unexpected fixture counts")
        try expect(node.node(withID: a.path) != nil && node.node(withID: b.path) != nil, "Hidden or Unicode path missing")
        try expect([node.node(withID: a.path), node.node(withID: link.path)].compactMap { $0 }.filter(\.isDuplicateHardLink).count == 1,
                   "Hard-link allocation was not deduplicated")
        try expect(updates.last?.processedItems == summary.processedItems, "Final progress count is stale")
        let afterContents = try Data(contentsOf: a)
        try expect(afterContents == payload, "Scan changed file contents")
        let after = try FileManager.default.attributesOfItem(atPath: a.path)
        try expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date, "Scan changed modification date")
    }

    private static func linksAndSpecialFiles() async throws {
        let root = try fixture()
        let outside = try fixture()
        defer {
            removeFixture(root)
            removeFixture(outside)
        }
        try Data(repeating: 0x1F, count: 99).write(to: outside.appendingPathComponent("outside-secret.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0, "Cannot create FIFO fixture")
        let (node, summary, _) = try await collect(root)
        try expect(node.fileCount == 0 && node.children.count == 3, "Scanner followed a link or opened a FIFO")
        try expect(node.status == .partial && summary.skippedItems == 3, "Excluded branches must be marked partial")
        try expect(node.children.allSatisfy { $0.status.isIncomplete && $0.formattedSize == "알 수 없음" }, "Excluded items reported as zero")
        do {
            _ = try await collect(root.appendingPathComponent("loop"))
            throw CheckFailure(description: "Symlink root accepted")
        } catch is ScanFailure {}
    }

    private static func permissionFailures() async throws {
        let root = try fixture()
        let blocked = root.appendingPathComponent("blocked")
        defer {
            chmod(blocked.path, 0o700)
            chmod(root.path, 0o700)
            removeFixture(root)
        }
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1234).write(to: root.appendingPathComponent("readable.bin"))
        try Data(repeating: 7, count: 4321).write(to: blocked.appendingPathComponent("private.bin"))
        try expect(chmod(blocked.path, 0) == 0, "Cannot set fixture permissions")
        let (node, summary, _) = try await collect(root)
        try expect(node.fileCount == 1 && node.status == .partial && summary.skippedItems == 1, "Permission denial aborted or corrupted scan")
        let denied = try require(node.node(withID: blocked.path), "Unreadable folder disappeared")
        try expect(denied.formattedSize == "알 수 없음", "Permission denial was reported as zero bytes")
        if case .unreadable = denied.status {} else { throw CheckFailure(description: "Permission denial not marked unreadable") }
        try expect(chmod(root.path, 0) == 0, "Cannot restrict root")
        do {
            _ = try await collect(root)
            throw CheckFailure(description: "Unreadable root accepted")
        } catch is ScanFailure {}
        chmod(root.path, 0o700)
        do {
            _ = try await collect(root.appendingPathComponent("not-here"))
            throw CheckFailure(description: "Missing root accepted")
        } catch is ScanFailure {}
    }

    private static func exclusionsAndDepth() async throws {
        let root = try fixture()
        defer { removeFixture(root) }
        for name in ["Test.app", "Cloud", "Cloudish", "deep/level2/level3"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1000).write(to: dir.appendingPathComponent("data.bin"))
        }
        try Data().write(to: root.appendingPathComponent("remote.icloud"))
        let cloud = root.appendingPathComponent("Cloud")
        let policy = ScanPolicy(maximumDepth: 1, additionalExcludedRoots: [cloud])
        try expect(policy.excludes(cloud.appendingPathComponent("child")) && !policy.excludes(root.appendingPathComponent("Cloudish")),
                   "Cloud policy must respect path component boundaries")
        let (node, summary, _) = try await collect(root, policy: policy)
        try expect(node.node(withID: root.appendingPathComponent("Test.app/data.bin").path) == nil, "Package traversed")
        try expect(node.node(withID: cloud.appendingPathComponent("data.bin").path) == nil, "Cloud root traversed")
        try expect(node.node(withID: root.appendingPathComponent("Cloudish/data.bin").path) != nil, "Unrelated path was excluded")
        try expect(node.node(withID: root.appendingPathComponent("deep/level2/level3").path) == nil, "Depth boundary ignored")
        try expect(summary.skippedItems == 4 && node.status == .partial, "Exclusion count is wrong")
        do {
            _ = try await collect(cloud, policy: policy)
            throw CheckFailure(description: "Excluded root accepted")
        } catch is ScanFailure {}
    }

    private static func cancellationAndLargeDirectory() async throws {
        let root = try fixture()
        defer { removeFixture(root) }
        for index in 0..<10_000 {
            let fd = open(root.appendingPathComponent("item-\(index)").path, O_CREAT | O_WRONLY, 0o600)
            try expect(fd >= 0, "Cannot create large fixture")
            close(fd)
        }
        let consumer = Task {
            var completed = false
            var sawProgress = false
            do {
                for try await event in LocalDiskScanner().scan(ScanRequest(rootURL: root)) {
                    switch event {
                    case .progress:
                        sawProgress = true
                        withUnsafeCurrentTask { $0?.cancel() }
                    case .completed: completed = true
                    }
                }
            } catch is CancellationError {}
            return (sawProgress, completed)
        }
        let cancelled = try await consumer.value
        try expect(cancelled.0 && !cancelled.1, "Cancelled scan emitted a completed result")
        let (node, summary, updates) = try await collect(root)
        try expect(node.fileCount == 10_000 && summary.processedItems == 10_000, "Large directory scan lost files")
        try expect(node.totalBytes == 0 && node.status == .complete, "Empty regular files must be known zero bytes")
        try expect(updates.count >= 2 && updates.last?.processedItems == 10_000, "Missing progress or final counters")
    }
}
