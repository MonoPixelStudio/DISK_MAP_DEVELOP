import Foundation

public enum BrowserSort: String, CaseIterable, Sendable {
    case sizeDescending, sizeAscending, nameAscending, nameDescending

    public var label: String {
        switch self {
        case .sizeDescending: "용량 큰 순"
        case .sizeAscending: "용량 작은 순"
        case .nameAscending: "이름 오름차순"
        case .nameDescending: "이름 내림차순"
        }
    }
}

public enum BrowserKind: String, CaseIterable, Sendable {
    case all, files, folders
    public var label: String {
        switch self {
        case .all: "모든 항목"
        case .files: "파일만"
        case .folders: "폴더만"
        }
    }
}

public enum BrowserMinimumSize: Int64, CaseIterable, Sendable {
    case all = 0, megabyte = 1_000_000, hundredMegabytes = 100_000_000, gigabyte = 1_000_000_000
    public var label: String { self == .all ? "모든 용량" : "\(StorageFormat.bytes(rawValue)) 이상" }
}

public struct BrowserQuery: Sendable, Equatable {
    public var search = ""
    public var includesDescendants = false
    public var kind: BrowserKind = .all
    public var minimumSize: BrowserMinimumSize = .all
    public var sort: BrowserSort = .sizeDescending
    public var showsHidden = true

    public init() {}

    public var hasFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        kind != .all || minimumSize != .all || !showsHidden
    }

    /// Operates on the completed snapshot only; never reads the filesystem.
    public func results(in folder: FileNode) throws -> [FileNode] {
        let term = normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        var pending = folder.children
        var matches: [FileNode] = []
        var visited = 0
        while let node = pending.popLast() {
            if visited % 256 == 0 { try Task.checkCancellation() }
            visited += 1
            if !showsHidden && node.name.hasPrefix(".") { continue }
            if includesDescendants && node.isFolder { pending.append(contentsOf: node.children) }
            if kind == .files && node.kind != .file { continue }
            if kind == .folders && !node.isFolder { continue }
            if minimumSize != .all {
                // Unknown entries are not known zero-byte files.
                if node.status.isIncomplete && node.totalBytes == 0 { continue }
                if node.totalBytes < minimumSize.rawValue { continue }
            }
            if !term.isEmpty && !normalized(node.name).contains(term) { continue }
            matches.append(node)
        }
        try Task.checkCancellation()
        var comparisons = 0
        let ordered = try matches.sorted { left, right in
            if comparisons % 1024 == 0 { try Task.checkCancellation() }
            comparisons += 1
            if sort == .sizeDescending || sort == .sizeAscending {
                let leftUnknown = left.status.isIncomplete && left.totalBytes == 0
                let rightUnknown = right.status.isIncomplete && right.totalBytes == 0
                if leftUnknown != rightUnknown { return !leftUnknown }
                if left.totalBytes != right.totalBytes {
                    return sort == .sizeDescending ? left.totalBytes > right.totalBytes : left.totalBytes < right.totalBytes
                }
            }
            let comparison = left.name.localizedStandardCompare(right.name)
            if comparison == .orderedSame { return left.path < right.path }
            return sort == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
        try Task.checkCancellation()
        return ordered
    }

    private func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ko_KR"))
    }
}

public enum FileLocationFailure: Error, LocalizedError {
    case sample, outsideRoot
    public var errorDescription: String? {
        switch self {
        case .sample: "샘플 항목에는 실제 파일 위치가 없습니다."
        case .outsideRoot: "스캔한 폴더 안의 항목만 확인할 수 있습니다."
        }
    }
}

public enum FileLocation {
    /// Lexical containment, intentionally preserving symlink leaves for Finder selection.
    /// This is for revealing locations, never authorization for file mutation.
    public static func url(itemPath: String, rootPath: String, isSample: Bool) throws -> URL {
        guard !isSample else { throw FileLocationFailure.sample }
        guard itemPath.hasPrefix("/"), rootPath.hasPrefix("/") else { throw FileLocationFailure.outsideRoot }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let item = URL(fileURLWithPath: itemPath).standardizedFileURL
        let prefix = root == "/" ? "/" : root + "/"
        guard item.path == root || item.path.hasPrefix(prefix) else { throw FileLocationFailure.outsideRoot }
        return item
    }
}
