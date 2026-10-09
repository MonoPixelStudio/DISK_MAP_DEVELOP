import Foundation

/// A snapshot of an item. IDs are snapshot-local, not filesystem identities.
public struct FileNode: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case folder, file, symbolicLink, package, other
    }

    public let id: String
    public let name: String
    public let path: String
    public let kind: Kind
    public let fileBytes: Int64
    public let children: [FileNode]
    public let category: FileCategory
    public let status: NodeScanStatus
    public let logicalBytes: Int64?
    public let isDuplicateHardLink: Bool
    public let fingerprint: FileFingerprint?
    public let totalBytes: Int64
    public let totalLogicalBytes: Int64
    public let fileCount: Int
    public let childrenBySize: [FileNode]

    public init(
        id: String, name: String, path: String, kind: Kind,
        fileBytes: Int64 = 0, children: [FileNode] = [], category: FileCategory,
        status: NodeScanStatus = .complete, logicalBytes: Int64? = nil,
        isDuplicateHardLink: Bool = false, fingerprint: FileFingerprint? = nil
    ) {
        precondition(fileBytes >= 0, "File sizes cannot be negative")
        precondition(kind == .folder || children.isEmpty, "Files cannot contain children")
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.fileBytes = fileBytes
        self.children = children
        self.category = category
        self.status = status
        self.logicalBytes = logicalBytes
        self.isDuplicateHardLink = isDuplicateHardLink
        self.fingerprint = fingerprint
        self.totalBytes = kind == .folder ? children.reduce(0) { $0 + $1.totalBytes } : fileBytes
        self.totalLogicalBytes = kind == .folder
            ? children.reduce(0) { $0 + $1.totalLogicalBytes } : (logicalBytes ?? fileBytes)
        self.fileCount = kind == .folder ? children.reduce(0) { $0 + $1.fileCount } : (kind == .file ? 1 : 0)
        self.childrenBySize = children.sorted {
            $0.totalBytes == $1.totalBytes ? $0.name < $1.name : $0.totalBytes > $1.totalBytes
        }
    }

    public var isFolder: Bool { kind == .folder }
    public var formattedSize: String {
        if status.isIncomplete && totalBytes == 0 { return "알 수 없음" }
        return StorageFormat.bytes(totalBytes)
    }

    public func node(withID id: String) -> FileNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(withID: id) { return found }
        }
        return nil
    }

    public func trail(to id: String) -> [FileNode]? {
        if self.id == id { return [self] }
        for child in children {
            if let trail = child.trail(to: id) { return [self] + trail }
        }
        return nil
    }
}

public enum NodeScanStatus: Sendable, Equatable {
    case complete, partial
    case excluded(String)
    case unreadable(String)

    public var isIncomplete: Bool { self != .complete }
    public var label: String {
        switch self {
        case .complete: "집계 완료"
        case .partial: "부분 집계"
        case .excluded: "스캔 제외"
        case .unreadable: "접근 불가"
        }
    }
    public var detail: String? {
        switch self {
        case .excluded(let reason), .unreadable(let reason): reason
        case .partial: "읽지 못했거나 제외된 항목이 있어 확인한 용량만 표시합니다."
        case .complete: nil
        }
    }
}

public enum FileCategory: String, Sendable, CaseIterable {
    case projects, downloads, movies, documents, pictures, other

    public var symbol: String {
        switch self {
        case .projects: "chevron.left.forwardslash.chevron.right"
        case .downloads: "arrow.down.circle"
        case .movies: "film"
        case .documents: "doc.text"
        case .pictures: "photo"
        case .other: "doc"
        }
    }
}

public enum StorageFormat {
    public static func bytes(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
