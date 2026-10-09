import Foundation

public enum SnapshotIndexFailure: Error, LocalizedError {
    case duplicateIdentity
    public var errorDescription: String? { "스캔 결과의 항목 식별자가 중복되었습니다. 다시 스캔해 주세요." }
}

/// Navigation only. Mutation eligibility still checks the complete snapshot and filesystem.
/// Build once off the main thread; lookups are constant-time and trails follow parent links.
public struct FileSnapshotIndex: Sendable {
    private struct Location: Sendable {
        let parentID: String
        let childOffset: Int
    }
    private let folders: [String: FileNode]
    private let locations: [String: Location]
    public var count: Int { locations.count + 1 }

    public init(root: FileNode) throws {
        var folders = [root.id: root]
        var locations: [String: Location] = [:]
        var pending = [root]
        while let folder = pending.popLast() {
            for (offset, node) in folder.children.enumerated() {
                if locations.count % 256 == 0 { try Task.checkCancellation() }
                guard node.id != root.id,
                      locations.updateValue(Location(parentID: folder.id, childOffset: offset), forKey: node.id) == nil else {
                    throw SnapshotIndexFailure.duplicateIdentity
                }
                if node.isFolder { folders[node.id] = node; pending.append(node) }
            }
        }
        try Task.checkCancellation()
        self.folders = folders; self.locations = locations
    }
    public func node(withID id: String) -> FileNode? {
        if let folder = folders[id] { return folder }
        guard let location = locations[id], let parent = folders[location.parentID] else { return nil }
        return parent.children[location.childOffset]
    }

    public func trail(to id: String, from ancestorID: String? = nil) -> [FileNode]? {
        guard let leaf = node(withID: id) else { return nil }
        var result = [leaf]
        var cursor = id
        while let parent = locations[cursor]?.parentID, let node = folders[parent] {
            if cursor == ancestorID { break }
            result.append(node); cursor = parent
        }
        if let ancestorID, result.last?.id != ancestorID { return nil }
        return result.reversed()
    }
}
