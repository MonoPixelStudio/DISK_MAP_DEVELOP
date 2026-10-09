import Foundation

public enum CleanupBlockReason: Error, LocalizedError, Sendable, Equatable {
    case scanRoot, outsideSnapshot, invalidPath, outsideRoot, protectedPath, containsProtectedPath
    case incomplete, unsupportedKind, unsafeDescendant, limitReached, sizeOverflow

    public var errorDescription: String? {
        switch self {
        case .scanRoot: "스캔한 최상위 폴더 전체는 정리 목록에 담을 수 없습니다. 안쪽 항목을 선택하세요."
        case .outsideSnapshot: "현재 스캔 결과에 없는 항목입니다. 다시 선택해 주세요."
        case .invalidPath: "항목의 경로를 안전하게 확인할 수 없습니다. 다시 스캔해 주세요."
        case .outsideRoot: "스캔한 폴더 밖의 항목은 정리 목록에 담을 수 없습니다."
        case .protectedPath: "시스템·앱·설정·클라우드 보호 경로는 정리 목록에 담을 수 없습니다."
        case .containsProtectedPath: "보호 경로를 포함한 폴더입니다. 필요한 개별 항목을 선택하세요."
        case .incomplete: "제외·접근 불가·부분 집계 항목은 담을 수 없습니다. 확인된 개별 항목을 선택하세요."
        case .unsupportedKind: "일반 파일과 폴더만 담을 수 있습니다. 링크·패키지·특수 파일은 제외합니다."
        case .unsafeDescendant: "폴더 안에 경로·종류·집계 상태를 확인할 수 없는 항목이 있습니다."
        case .limitReached: "정리 목록은 최대 500개 항목까지 담을 수 있습니다."
        case .sizeOverflow: "합계 용량을 안전하게 계산할 수 없어 항목을 담지 않았습니다."
        }
    }
}

/// Conservative snapshot policy. Passing this policy NEVER authorizes a filesystem mutation.
/// A later trash operation must independently revalidate identity, ancestry and current state.
public struct CleanupPolicy: Sendable {
    private let protectedRoots: [String]
    private let protectedContainers: Set<String>
    private let sensitiveComponents: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".codex"]
    private let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "pkg", "rtfd", "playground", "icloud"]

    public init(homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
                additionalProtectedPaths: [String] = []) {
        let home = Self.path(homePath) ?? "/"
        let system = ["/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/etc",
                      "/private", "/var", "/tmp", "/dev", "/cores", "/opt", "/Network"]
        let personal = ["Library", ".Trash", ".config", ".local", "Dropbox", "OneDrive"]
            .map { home + "/" + $0 }
        protectedRoots = (system + personal + additionalProtectedPaths + (Self.path(homePath) == nil ? ["/"] : []))
            .compactMap(Self.path).map(Self.fold)
        protectedContainers = Set(["/", "/Users", "/Volumes", home].map(Self.fold))
    }

    func restriction(_ node: FileNode, path: String) -> CleanupBlockReason? {
        let folded = Self.fold(path)
        let components = folded.split(separator: "/").map(String.init)
        if protectedContainers.contains(folded) || protectedRoots.contains(where: { Self.contains(folded, in: $0) }) ||
            components.contains(where: { sensitiveComponents.contains($0) || packageExtensions.contains(($0 as NSString).pathExtension) }) {
            return .protectedPath
        }
        if node.isFolder && protectedRoots.contains(where: { Self.contains($0, in: folded) }) { return .containsProtectedPath }
        guard node.kind == .file || node.kind == .folder else { return .unsupportedKind }
        guard node.status == .complete else { return .incomplete }
        return nil
    }

    // Component-based lexical comparisons only. Do not resolve or follow any live symlinks.
    static func path(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { return nil }
        let components = value.split(separator: "/")
        guard !components.contains("."), !components.contains("..") else { return nil }
        return "/" + components.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    static func contains(_ item: String, in folder: String) -> Bool {
        item == folder || item.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    private static func fold(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Candidate metadata belongs to one completed snapshot, not a deletion request.
public struct CleanupEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let kind: FileNode.Kind
    public let allocatedBytes: Int64
    public let fileCount: Int
}

public enum CleanupCoverage: Sendable, Equatable {
    case direct
    case ancestor(name: String)
}

public enum CleanupAddResult: Sendable, Equatable {
    case added(replacedDescendants: Int)
    case alreadyIncluded
}

/// In-memory plan bound to its immutable snapshot. Contains no file operations or trash service.
public struct CleanupQueue: Sendable {
    public static let maximumEntries = 500
    public private(set) var entries: [CleanupEntry] = []
    public let isSample: Bool
    public var rootPath: String { snapshot.path }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
    public var fileCount: Int { entries.reduce(0) { $0 + $1.fileCount } }
    private let snapshot: FileNode
    private let policy: CleanupPolicy

    public init(root: FileNode, isSample: Bool, policy: CleanupPolicy = CleanupPolicy()) {
        snapshot = root
        self.isSample = isSample
        self.policy = policy
    }

    public func coverage(of nodeID: String) -> CleanupCoverage? {
        guard !entries.isEmpty, let node = snapshot.node(withID: nodeID) else { return nil }
        return coverage(ofPath: node.path)
    }

    /// Presentation hint for known snapshot rows; never authorizes adding or moving a file.
    public func coverage(ofPath nodePath: String) -> CleanupCoverage? {
        guard !entries.isEmpty, let path = CleanupPolicy.path(nodePath) else { return nil }
        for entry in entries {
            if path == entry.path { return .direct }
            if entry.kind == .folder && CleanupPolicy.contains(path, in: entry.path) { return .ancestor(name: entry.name) }
        }
        return nil
    }

    public func restriction(for nodeID: String) throws -> CleanupBlockReason? {
        try Task.checkCancellation()
        guard let trail = snapshot.trail(to: nodeID), let node = trail.last else { return .outsideSnapshot }
        guard trail.count > 1 else { return .scanRoot }
        guard let rootPath = CleanupPolicy.path(snapshot.path) else { return .invalidPath }
        var parentPath = rootPath
        for item in trail.dropFirst() {
            guard let path = CleanupPolicy.path(item.path) else { return .invalidPath }
            guard path != rootPath, CleanupPolicy.contains(path, in: rootPath) else { return .outsideRoot }
            guard Self.isDirectChild(item, path: path, parent: parentPath) else { return .invalidPath }
            parentPath = path
        }
        if let reason = policy.restriction(node, path: parentPath) { return reason }
        // Inspect descendants too, including snapshots whose parent was incorrectly marked complete.
        var pending = node.children.map { ($0, parentPath) }
        var visited = 0
        while let (child, parent) = pending.popLast() {
            if visited % 256 == 0 { try Task.checkCancellation() }
            visited += 1
            guard let path = CleanupPolicy.path(child.path), Self.isDirectChild(child, path: path, parent: parent),
                  policy.restriction(child, path: path) == nil else { return .unsafeDescendant }
            pending.append(contentsOf: child.children.map { ($0, path) })
        }
        return nil
    }

    @discardableResult public mutating func add(_ nodeID: String) throws -> CleanupAddResult {
        if let reason = try restriction(for: nodeID) { throw reason }
        guard coverage(of: nodeID) == nil else { return .alreadyIncluded }
        guard let node = snapshot.node(withID: nodeID), let path = CleanupPolicy.path(node.path) else {
            throw CleanupBlockReason.outsideSnapshot
        }
        let retained = entries.filter { !CleanupPolicy.contains($0.path, in: path) }
        guard retained.count < Self.maximumEntries else { throw CleanupBlockReason.limitReached }
        let retainedBytes = retained.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard !retainedBytes.addingReportingOverflow(node.totalBytes).overflow else { throw CleanupBlockReason.sizeOverflow }
        let replaced = entries.count - retained.count
        entries = retained + [CleanupEntry(id: node.id, name: node.name, path: path, kind: node.kind,
                                          allocatedBytes: node.totalBytes, fileCount: node.fileCount)]
        return .added(replacedDescendants: replaced)
    }

    public mutating func remove(_ entryID: String) { entries.removeAll { $0.id == entryID } }
    public mutating func removeAll() { entries.removeAll() }

    public func trashRequests() throws -> [TrashRequest] {
        guard !isSample else { throw TrashSafetyError.sample }
        return try entries.map { entry in
            if let reason = try restriction(for: entry.id) { throw reason }
            guard let trail = snapshot.trail(to: entry.id), trail.allSatisfy({ $0.fingerprint != nil }),
                  let item = trail.last else { throw TrashSafetyError.noIdentity }
            return TrashRequest(root: snapshot, item: item, ancestors: Array(trail.dropLast()))
        }
    }

    /// Keep only unchanged, still-eligible failed candidates after a post-cleanup rescan.
    public func rebased(on root: FileNode) -> CleanupQueue {
        var result = CleanupQueue(root: root, isSample: isSample, policy: policy)
        guard let beforeRoot = snapshot.fingerprint, let afterRoot = root.fingerprint,
              beforeRoot.identifies(afterRoot) else { return result }
        for entry in entries {
            guard !Task.isCancelled else { return result }
            guard let before = snapshot.node(withID: entry.id), let after = root.node(withID: entry.id),
                  Self.sameTree(before, after) else { continue }
            _ = try? result.add(after.id)
        }
        return result
    }

    private static func sameTree(_ a: FileNode, _ b: FileNode) -> Bool {
        guard !Task.isCancelled else { return false }
        guard a.fingerprint != nil, a.fingerprint == b.fingerprint, a.path == b.path,
              a.kind == b.kind, a.children.count == b.children.count else { return false }
        let byID = Dictionary(b.children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return a.children.allSatisfy { child in byID[child.id].map { sameTree(child, $0) } ?? false }
    }

    private static func isDirectChild(_ node: FileNode, path: String, parent: String) -> Bool {
        let name = node.name.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
        return path == (parent == "/" ? "/" : parent + "/") + name
    }
}
