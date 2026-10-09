import Foundation

public struct ScanRequest: Sendable {
    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case completed(root: FileNode, summary: ScanSummary)
}

public struct ScanProgress: Sendable {
    public let processedItems: Int
    public let measuredBytes: Int64
    public let currentPath: String
    public let skippedItems: Int
}

public struct ScanIssue: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

public struct ScanSummary: Sendable {
    public let processedItems: Int
    public let skippedItems: Int
    public let elapsedSeconds: Double
    /// Bounded examples; skippedItems is the full count.
    public let issues: [ScanIssue]
}

public protocol DiskScanning: Sendable {
    /// Cancelling the consuming task must cancel the underlying scan.
    func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error>
}

/// Only a real, snapshot-bound CleanupQueue can construct requests.
public struct TrashRequest: Sendable {
    public var url: URL { URL(fileURLWithPath: item.path) }
    public var allowedRoot: URL { URL(fileURLWithPath: root.path) }
    public let item: FileNode
    let root: FileNode
    let ancestors: [FileNode]
    init(root: FileNode, item: FileNode, ancestors: [FileNode]) {
        self.root = root; self.item = item; self.ancestors = ancestors
    }
}

public struct TrashReceipt: Sendable {
    public let originalURL: URL
    public let trashURL: URL?
    public init(originalURL: URL, trashURL: URL?) {
        self.originalURL = originalURL
        self.trashURL = trashURL
    }
}

public protocol TrashManaging: Sendable {
    func moveToTrash(_ request: TrashRequest) async throws -> TrashReceipt
}

public enum FeatureUnavailable: Error, LocalizedError {
    case scanning, trash

    public var errorDescription: String? {
        switch self {
        case .scanning: "실제 폴더 스캔은 아직 지원하지 않습니다."
        case .trash: "현재 버전에서는 실제 휴지통 이동을 지원하지 않습니다."
        }
    }
}

public struct UnavailableScanner: DiskScanning {
    public init() {}
    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: FeatureUnavailable.scanning) }
    }
}

public struct UnavailableTrashManager: TrashManaging {
    public init() {}
    public func moveToTrash(_ request: TrashRequest) async throws -> TrashReceipt {
        throw FeatureUnavailable.trash
    }
}
