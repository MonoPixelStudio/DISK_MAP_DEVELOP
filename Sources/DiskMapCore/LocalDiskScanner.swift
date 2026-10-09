import Foundation
import Darwin

public struct ScanPolicy: Sendable {
    public let maximumDepth: Int
    public let excludedRoots: [URL]

    public init(maximumDepth: Int = 128, additionalExcludedRoots: [URL] = []) {
        self.maximumDepth = max(1, maximumDepth)
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.excludedRoots = [
            home.appendingPathComponent("Library/CloudStorage"),
            home.appendingPathComponent("Library/Mobile Documents"),
            home.appendingPathComponent("Dropbox"),
            home.appendingPathComponent("OneDrive"),
        ] + additionalExcludedRoots
    }

    public func excludes(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedRoots.contains {
            let root = $0.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }
}

public enum ScanFailure: Error, LocalizedError {
    case invalidRoot, excludedRoot(String), cannotReadRoot(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "스캔할 로컬 폴더를 선택해 주세요. 심볼릭 링크는 스캔하지 않습니다."
        case .excludedRoot(let reason): "선택한 폴더를 스캔할 수 없습니다. \(reason)"
        case .cannotReadRoot(let reason): "폴더에 접근할 수 없습니다. \(reason) 파일 및 폴더 접근 권한을 확인해 주세요."
        }
    }
}

public struct LocalDiskScanner: DiskScanning {
    private let policy: ScanPolicy
    public init(policy: ScanPolicy = ScanPolicy()) { self.policy = policy }

    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error> {
        // Only the latest progress is needed. The final summary retains bounded issue examples.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let worker = Task.detached(priority: .utility) {
                do {
                    try ScanWalker(policy: policy, continuation: continuation).run(request.rootURL)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}

/// Descriptor-relative traversal prevents a changed symlink from escaping into another tree.
/// No regular file is opened, read, downloaded, or modified.
private final class ScanWalker {
    private final class DirectoryFrame {
        let url: URL
        let directory: UnsafeMutablePointer<DIR>
        let depth: Int
        let initialFingerprint: FileFingerprint
        var children: [FileNode] = []
        var hadReadError = false

        init(url: URL, directory: UnsafeMutablePointer<DIR>, depth: Int, info: stat) {
            self.url = url
            self.directory = directory
            self.depth = depth
            initialFingerprint = FileFingerprint(info)
        }
        deinit { closedir(directory) }
    }

    let policy: ScanPolicy
    let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    private var processed = 0
    private var measured: Int64 = 0
    private var skipped = 0
    private var issues: [ScanIssue] = []
    private var hardLinks: Set<String> = []
    private let clock = ContinuousClock()
    private var lastProgress = ContinuousClock.now

    init(policy: ScanPolicy, continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation) {
        self.policy = policy
        self.continuation = continuation
    }

    func run(_ input: URL) throws {
        try Task.checkCancellation()
        guard input.isFileURL else { throw ScanFailure.invalidRoot }
        let accessing = input.startAccessingSecurityScopedResource()
        defer { if accessing { input.stopAccessingSecurityScopedResource() } }

        // Reject a symlink leaf before canonicalizing ancestor components.
        var rootInfo = stat()
        guard lstat(input.path, &rootInfo) == 0 else {
            throw ScanFailure.cannotReadRoot(systemError())
        }
        guard fileType(rootInfo) == S_IFDIR else { throw ScanFailure.invalidRoot }
        let rootURL = input.standardizedFileURL.resolvingSymlinksInPath()
        if let reason = exclusionReason(rootURL, info: rootInfo) {
            throw ScanFailure.excludedRoot(reason)
        }
        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ScanFailure.cannotReadRoot(systemError()) }
        var openedInfo = stat()
        guard fstat(rootFD, &openedInfo) == 0,
              openedInfo.st_dev == rootInfo.st_dev, openedInfo.st_ino == rootInfo.st_ino else {
            close(rootFD)
            throw ScanFailure.cannotReadRoot("스캔 시작 전에 폴더가 변경되었습니다.")
        }
        guard let rootDirectory = fdopendir(rootFD) else {
            let reason = systemError()
            close(rootFD)
            throw ScanFailure.cannotReadRoot(reason)
        }

        let start = clock.now
        var stack = [DirectoryFrame(url: rootURL, directory: rootDirectory, depth: 0, info: openedInfo)]
        emitProgress(path: rootURL.path, force: true)

        while let frame = stack.last {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(frame.directory) else {
                if errno != 0 {
                    recordIssue(frame.url.path, systemError())
                    frame.hadReadError = true
                }
                let children = frame.children
                var finalInfo = stat()
                let identity = fstat(dirfd(frame.directory), &finalInfo) == 0 ? FileFingerprint(finalInfo) : nil
                if identity == nil || identity != frame.initialFingerprint {
                    recordIssue(frame.url.path, "스캔 도중 폴더 내용이 바뀌었습니다. 다시 스캔해 주세요.")
                    frame.hadReadError = true
                }
                let status: NodeScanStatus = frame.hadReadError || children.contains(where: { $0.status.isIncomplete })
                    ? .partial : .complete
                let result = node(frame.url, kind: .folder, children: children, status: status, fingerprint: identity)
                stack.removeLast()
                if let parent = stack.last {
                    parent.children.append(result)
                } else {
                    try Task.checkCancellation()
                    emitProgress(path: rootURL.path, force: true)
                    let duration = start.duration(to: clock.now).components
                    continuation.yield(.completed(root: result, summary: ScanSummary(
                        processedItems: processed, skippedItems: skipped,
                        elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                        issues: issues
                    )))
                }
                continue
            }

            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            processed += 1
            let url = frame.url.appendingPathComponent(name)
            defer { emitProgress(path: url.path) }
            var info = stat()
            guard fstatat(dirfd(frame.directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                appendSkipped(frame, url, kind: .other, status: .unreadable(systemError()))
                continue
            }
            let type = fileType(info)
            if type == S_IFLNK {
                appendSkipped(frame, url, kind: .symbolicLink, status: .excluded("심볼릭 링크는 따라가지 않습니다."))
                continue
            }
            let kind: FileNode.Kind = type == S_IFDIR ? .folder : (type == S_IFREG ? .file : .other)
            if info.st_dev != openedInfo.st_dev {
                appendSkipped(frame, url, kind: kind, status: .excluded("다른 볼륨은 별도로 선택해 스캔해 주세요."))
                continue
            }
            if let reason = exclusionReason(url, info: info) {
                appendSkipped(frame, url, kind: isPackage(url) ? .package : kind, status: .excluded(reason))
                continue
            }

            if type == S_IFDIR {
                guard frame.depth < policy.maximumDepth else {
                    appendSkipped(frame, url, kind: .folder, status: .excluded("최대 폴더 깊이에 도달했습니다."))
                    continue
                }
                let fd = openat(dirfd(frame.directory), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    appendSkipped(frame, url, kind: .folder, status: .unreadable(systemError()))
                    continue
                }
                var childInfo = stat()
                guard fstat(fd, &childInfo) == 0, childInfo.st_dev == info.st_dev, childInfo.st_ino == info.st_ino else {
                    close(fd)
                    appendSkipped(frame, url, kind: .folder, status: .unreadable("스캔 도중 폴더가 변경되었습니다."))
                    continue
                }
                guard let directory = fdopendir(fd) else {
                    let reason = systemError()
                    close(fd)
                    appendSkipped(frame, url, kind: .folder, status: .unreadable(reason))
                    continue
                }
                stack.append(DirectoryFrame(url: url, directory: directory, depth: frame.depth + 1, info: childInfo))
            } else if type == S_IFREG {
                guard info.st_blocks >= 0, info.st_size >= 0 else {
                    appendSkipped(frame, url, kind: .file, status: .unreadable("파일 크기를 확인할 수 없습니다."))
                    continue
                }
                let key = "\(info.st_dev):\(info.st_ino)"
                let duplicate = info.st_nlink > 1 && !hardLinks.insert(key).inserted
                let allocated = duplicate ? 0 : Int64(info.st_blocks) * 512
                measured += allocated
                frame.children.append(node(url, kind: .file, bytes: allocated,
                                           logical: Int64(info.st_size), duplicate: duplicate, fingerprint: FileFingerprint(info)))
            } else {
                appendSkipped(frame, url, kind: .other, status: .excluded("소켓과 장치 등 일반 파일이 아닌 항목입니다."))
            }
        }
    }

    private func exclusionReason(_ url: URL, info: stat) -> String? {
        if policy.excludes(url) || url.pathExtension.lowercased() == "icloud" || info.st_flags & UInt32(SF_DATALESS) != 0 {
            return "클라우드 동기화 영역과 다운로드되지 않은 파일은 제외합니다."
        }
        if isPackage(url) { return "앱과 보관함 패키지 내부는 이번 스캔에서 제외합니다." }
        // Metadata query only: never request file contents or startDownloadingUbiquitousItem.
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey]) {
            if values.isUbiquitousItem == true { return "iCloud 동기화 항목은 제외합니다." }
            if values.isAliasFile == true { return "Finder 별칭의 대상을 따라가지 않습니다." }
        }
        return nil
    }

    private func isPackage(_ url: URL) -> Bool {
        ["app", "bundle", "framework", "photoslibrary", "photolibrary", "pkg", "rtfd", "playground"]
            .contains(url.pathExtension.lowercased())
    }

    private func fileType(_ info: stat) -> mode_t { info.st_mode & S_IFMT }
    private func systemError() -> String { String(cString: strerror(errno)) }

    private func appendSkipped(_ frame: DirectoryFrame, _ url: URL, kind: FileNode.Kind, status: NodeScanStatus) {
        recordIssue(url.path, status.detail ?? status.label)
        frame.children.append(node(url, kind: kind, status: status))
    }

    private func recordIssue(_ path: String, _ reason: String) {
        skipped += 1
        if issues.count < 100 { issues.append(ScanIssue(path: path, reason: reason)) }
    }

    private func emitProgress(path: String, force: Bool = false) {
        guard force || (processed % 64 == 0 && lastProgress.duration(to: clock.now) >= .milliseconds(100)) else { return }
        lastProgress = clock.now
        continuation.yield(.progress(ScanProgress(processedItems: processed, measuredBytes: measured,
                                                  currentPath: path, skippedItems: skipped)))
    }

    private func node(_ url: URL, kind: FileNode.Kind, bytes: Int64 = 0, children: [FileNode] = [],
                      status: NodeScanStatus = .complete, logical: Int64? = nil, duplicate: Bool = false,
                      fingerprint: FileFingerprint? = nil) -> FileNode {
        FileNode(id: url.path, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                 path: url.path, kind: kind, fileBytes: bytes, children: children,
                 category: category(url), status: status, logicalBytes: logical, isDuplicateHardLink: duplicate, fingerprint: fingerprint)
    }

    private func category(_ url: URL) -> FileCategory {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "mkv", "avi", "webm": return .movies
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "raw", "psd": return .pictures
        case "pdf", "txt", "md", "doc", "docx", "pages", "xlsx", "csv": return .documents
        case "swift", "cs", "js", "ts", "py", "unity", "blend": return .projects
        case "zip", "dmg", "tar", "gz": return .downloads
        default: return .other
        }
    }
}
