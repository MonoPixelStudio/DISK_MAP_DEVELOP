import Foundation
import Darwin
import DiskMapCore

final class ProjectFixture {
    let url: URL
    let base: URL
    init(_ name: String) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        base = project.appendingPathComponent(".diskmap-test-fixtures")
        if mkdir(base.path, 0o700) != 0 && errno != EEXIST {
            throw CheckFailure(description: "Cannot create project-local fixture base")
        }
        var info = stat()
        try expect(lstat(base.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && base.resolvingSymlinksInPath() == base, "Unsafe fixture base")
        url = base.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try expect(mkdir(url.path, 0o700) == 0, "Cannot create unique fixture")
    }
    func file(_ name: String, bytes: Int = 4096) throws -> URL {
        let result = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x53, count: bytes).write(to: result)
        return result
    }
    func clean() throws {
        try expect(url.deletingLastPathComponent() == base && base.resolvingSymlinksInPath() == base && url.resolvingSymlinksInPath() == url, "Refusing unsafe fixture cleanup")
        try FileManager.default.removeItem(at: url)
    }
}

enum TrashChecks {
    static func run() async throws {
        try await nativeRoundTrip()
        print("PASS native trash file/folder round-trip, receipts, duplicate execution and unselected preservation")
        try await changedItems()
        print("PASS changed/renamed/replaced files and added folder contents are skipped")
        try await unsafePaths()
        print("PASS replaced scan root, symlink ancestors, sample and missing identity rejection")
        try await permissionAndProtected()
        print("PASS read-only parent, immutable file and protected candidate rejection without mutation")
        try await partialAndCancellation()
        print("PASS partial success/failure/skip reporting and cancellation before pending operations")
        try await rebaseCandidates()
        print("PASS post-cleanup rebase preserves unchanged failures and drops changed candidates")
    }

    static func queue(_ root: URL, _ items: [URL]) async throws -> CleanupQueue {
        let (tree, _, _) = try await ScannerChecks.collect(root)
        var queue = CleanupQueue(root: tree, isSample: false)
        for item in items { try queue.add(item.path) }
        return queue
    }
    static func rejected(_ request: TrashRequest) async throws {
        do { _ = try await LocalTrashManager().moveToTrash(request); throw CheckFailure(description: "Unsafe file was trashed") }
        catch is TrashSafetyError {}
        catch is CleanupBlockReason {}
    }
    static func restore(_ result: TrashItemResult, in fixture: ProjectFixture) throws {
        let receipt = try require(result.receipt, "Missing trash receipt")
        let destination = try require(receipt.trashURL, "Native API did not return test trash location")
        try expect(receipt.originalURL.path.hasPrefix(fixture.url.path + "/"), "Restore escaped fixture")
        try expect(destination.deletingLastPathComponent().lastPathComponent == ".Trash", "Unexpected test trash destination")
        var info = stat()
        try expect(lstat(destination.path, &info) == 0 && info.st_mode & S_IFMT != S_IFLNK, "Cannot verify own trashed fixture")
        try expect(result.item.fingerprint?.inode == info.st_ino && result.item.fingerprint?.device == info.st_dev, "Trash receipt identity mismatch")
        try expect(!FileManager.default.fileExists(atPath: receipt.originalURL.path), "Restore would overwrite an entry")
        try FileManager.default.moveItem(at: destination, to: receipt.originalURL)
    }

    private static func nativeRoundTrip() async throws {
        let fixture = try ProjectFixture("NativeTrash")
        defer { try? fixture.clean() }
        let first = try fixture.file("테스트-\(UUID().uuidString).bin", bytes: 32768)
        let nested = try fixture.file("폴더-\(UUID().uuidString)/내용.txt", bytes: 8192)
        let folder = nested.deletingLastPathComponent()
        let untouched = try fixture.file("선택하지않음.bin")
        let before = try FileManager.default.attributesOfItem(atPath: untouched.path)
        let queue = try await queue(fixture.url, [first, folder])
        let requests = try queue.trashRequests()
        for request in requests { try TrashValidation.check(request) }
        do { _ = try await UnavailableTrashManager().moveToTrash(requests[0]); throw CheckFailure(description: "Unavailable service executed") }
        catch is FeatureUnavailable {}
        let report = await TrashBatch.run(requests, manager: LocalTrashManager())
        try expect(report.moved.count == 2 && report.failedCount == 0 && report.skippedCount == 0, "Native trash failed: \(report.items.map(\.message))")
        try expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: folder.path), "Original paths remain after trash")
        try await rejected(requests[0])
        for result in report.moved { try restore(result, in: fixture) }
        try expect(try Data(contentsOf: first) == Data(repeating: 0x53, count: 32768), "Moved file contents changed")
        try expect(try Data(contentsOf: nested) == Data(repeating: 0x53, count: 8192), "Moved folder contents changed")
        let after = try FileManager.default.attributesOfItem(atPath: untouched.path)
        for key: FileAttributeKey in [.modificationDate, .creationDate, .posixPermissions, .systemFileNumber] {
            try expect((before[key] as? NSObject) == (after[key] as? NSObject), "Unselected file metadata changed")
        }
        try expect(try Data(contentsOf: untouched) == Data(repeating: 0x53, count: 4096), "Unselected file contents changed")
    }

    private static func changedItems() async throws {
        let fixture = try ProjectFixture("ChangedTrash")
        defer { try? fixture.clean() }
        let changed = try fixture.file("changed.bin")
        let renamed = try fixture.file("renamed.bin")
        let replaced = try fixture.file("replaced.bin")
        let child = try fixture.file("folder/child.bin")
        let requests = try await queue(fixture.url, [changed, renamed, replaced, child.deletingLastPathComponent()]).trashRequests()
        try Data(repeating: 0x33, count: 9000).write(to: changed)
        let renamedURL = renamed.deletingLastPathComponent().appendingPathComponent("renamed-new.bin")
        try FileManager.default.moveItem(at: renamed, to: renamedURL)
        try FileManager.default.moveItem(at: replaced, to: fixture.url.appendingPathComponent("old-replaced.bin"))
        try Data(repeating: 0x44, count: 4096).write(to: replaced)
        _ = try fixture.file("folder/new.bin")
        for request in requests { try await rejected(request) }
        try expect(FileManager.default.fileExists(atPath: renamedURL.path) && FileManager.default.fileExists(atPath: replaced.path), "Changed test file was moved")
        try expect(try Data(contentsOf: changed).count == 9000, "Changed contents altered by rejected operation")
        try expect(FileManager.default.fileExists(atPath: child.path), "Folder with new content was moved")
    }

    private static func unsafePaths() async throws {
        let fixture = try ProjectFixture("UnsafeTrash")
        defer { try? fixture.clean() }
        let file = try fixture.file("root/item.bin")
        let root = file.deletingLastPathComponent()
        let request = try await queue(root, [file]).trashRequests()[0]
        try FileManager.default.moveItem(at: root, to: fixture.url.appendingPathComponent("saved-root"))
        _ = try fixture.file("root/item.bin")
        try await rejected(request)
        let linked = try fixture.file("linked-root/group/item.bin")
        let linkedRoot = fixture.url.appendingPathComponent("linked-root")
        let linkRequest = try await queue(linkedRoot, [linked]).trashRequests()[0]
        let group = linked.deletingLastPathComponent()
        let saved = fixture.url.appendingPathComponent("saved-group")
        try FileManager.default.moveItem(at: group, to: saved)
        try FileManager.default.createSymbolicLink(at: group, withDestinationURL: saved)
        try await rejected(linkRequest)
        try FileManager.default.removeItem(at: group) // Only this test-created symlink.
        try FileManager.default.moveItem(at: saved, to: group)
        var sample = CleanupQueue(root: SampleData.root, isSample: true)
        try sample.add("unity-build")
        do { _ = try sample.trashRequests(); throw CheckFailure(description: "Sample produced native trash requests") }
        catch TrashSafetyError.sample {}
        let synthetic = SampleData.root
        var noIdentity = CleanupQueue(root: synthetic, isSample: false)
        try noIdentity.add("unity-build")
        do { _ = try noIdentity.trashRequests(); throw CheckFailure(description: "Missing identity accepted") }
        catch TrashSafetyError.noIdentity {}
    }

    private static func permissionAndProtected() async throws {
        let fixture = try ProjectFixture("PermissionTrash")
        defer { try? fixture.clean() }
        let denied = try fixture.file("readonly/item.bin")
        let parent = denied.deletingLastPathComponent()
        try expect(chmod(parent.path, 0o500) == 0, "Cannot set test permission")
        defer { _ = chmod(parent.path, 0o700) }
        let deniedRequest = try await queue(fixture.url, [denied]).trashRequests()[0]
        try await rejected(deniedRequest)
        let locked = try fixture.file("locked.bin")
        try expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0, "Cannot lock test file")
        defer { _ = chflags(locked.path, 0) }
        let lockedRequest = try await queue(fixture.url, [locked]).trashRequests()[0]
        try await rejected(lockedRequest)
        let protected = try fixture.file(".ssh/test-only.txt")
        let (tree, _, _) = try await ScannerChecks.collect(fixture.url)
        var draft = CleanupQueue(root: tree, isSample: false)
        do { try draft.add(protected.path); throw CheckFailure(description: "Protected path accepted") }
        catch CleanupBlockReason.protectedPath {}
        try expect(FileManager.default.fileExists(atPath: denied.path) && FileManager.default.fileExists(atPath: locked.path), "Denied file was moved")
    }

    private actor StubManager: TrashManaging {
        var calls = 0
        let cancelAfterFirst: Bool
        init(cancelAfterFirst: Bool = false) { self.cancelAfterFirst = cancelAfterFirst }
        func moveToTrash(_ request: TrashRequest) async throws -> TrashReceipt {
            calls += 1
            if cancelAfterFirst, calls == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            if request.item.name == "skip.bin" { throw TrashSafetyError.changed }
            if request.item.name == "fail.bin" { throw CocoaError(.fileWriteNoPermission) }
            return TrashReceipt(originalURL: request.url, trashURL: nil)
        }
    }
    private static func partialAndCancellation() async throws {
        let fixture = try ProjectFixture("BatchTrash")
        defer { try? fixture.clean() }
        let files = try ["okay.bin", "skip.bin", "fail.bin"].map { try fixture.file($0) }
        let requests = try await queue(fixture.url, files).trashRequests()
        let report = await TrashBatch.run(requests, manager: StubManager())
        try expect(report.moved.count == 1 && report.skippedCount == 1 && report.failedCount == 1, "Mixed results misclassified")
        try expect(report.movedBytes == requests[0].item.totalBytes && report.items.count == 3, "Result allocation total includes unsuccessful files")
        let stub = StubManager()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TrashBatch.run(requests, manager: stub)
        }.value
        try expect(cancelled.skippedCount == 3 && cancelled.moved.isEmpty, "Cancellation lost pending results")
        let calls = await stub.calls
        try expect(calls == 0 && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Cancelled batch invoked mutation")
        let interruptedManager = StubManager(cancelAfterFirst: true)
        let interrupted = await Task { await TrashBatch.run(requests, manager: interruptedManager) }.value
        let interruptedCalls = await interruptedManager.calls
        try expect(interrupted.moved.count == 1 && interrupted.skippedCount == 2 && interruptedCalls == 1,
                   "Stopping an in-flight batch lost the completed receipt or executed pending items")
    }
    private static func rebaseCandidates() async throws {
        let fixture = try ProjectFixture("RebaseTrash")
        defer { try? fixture.clean() }
        let failed = try fixture.file("remaining.bin")
        let other = try fixture.file("other.bin")
        let draft = try await queue(fixture.url, [failed])
        try Data(repeating: 0x22, count: 100).write(to: other)
        let (fresh, _, _) = try await ScannerChecks.collect(fixture.url)
        try expect(draft.rebased(on: fresh).entries.count == 1, "Unrelated change dropped unchanged candidate")
        try Data(repeating: 0x22, count: 100).write(to: failed)
        let (changed, _, _) = try await ScannerChecks.collect(fixture.url)
        try expect(draft.rebased(on: changed).entries.isEmpty, "Changed candidate was silently reapproved")
    }
}
