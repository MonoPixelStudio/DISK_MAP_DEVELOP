import Foundation
import Darwin

public enum TrashSafetyError: Error, LocalizedError, Sendable {
    case sample, noIdentity, changed, missing, unsafeLocation, unsupportedVolume, permission, cancelled
    public var errorDescription: String? {
        switch self {
        case .sample: "샘플 항목은 휴지통으로 이동할 수 없습니다."
        case .noIdentity: "파일 식별 정보를 확인할 수 없습니다. 다시 스캔해 주세요."
        case .changed: "스캔 후 파일이나 폴더 내용이 변경되었습니다. 다시 스캔해 주세요."
        case .missing: "항목이 사라졌거나 이름·위치가 바뀌었습니다. 다시 스캔해 주세요."
        case .unsafeLocation: "경로가 링크로 바뀌었거나 스캔 범위를 안전하게 확인할 수 없습니다."
        case .unsupportedVolume: "쓰기 가능한 내장 로컬 디스크에서만 정리할 수 있습니다."
        case .permission: "이동 권한이 없거나 잠긴 항목입니다. Finder에서 권한을 확인해 주세요."
        case .cancelled: "사용자가 중단하여 처리하지 않았습니다."
        }
    }
}

/// Serializes mutations. Never falls back to removeItem, unlink, or permanent deletion.
public actor LocalTrashManager: TrashManaging {
    public init() {}
    public func moveToTrash(_ request: TrashRequest) async throws -> TrashReceipt {
        try Task.checkCancellation()
        return try TrashValidation.withValidatedItem(request) {
            try Task.checkCancellation()
            var destination: NSURL?
            try FileManager.default.trashItem(at: request.url, resultingItemURL: &destination)
            return TrashReceipt(originalURL: request.url, trashURL: destination as URL?)
        }
    }
}

public enum TrashValidation {
    /// Read-only validation; also used immediately before the native trash call.
    public static func check(_ request: TrashRequest) throws { try withValidatedItem(request) {} }

    static func withValidatedItem<T>(_ request: TrashRequest, _ action: () throws -> T) throws -> T {
        try Task.checkCancellation()
        var queue = CleanupQueue(root: request.root, isSample: false)
        try queue.add(request.item.id) // Reapply current protection rules independently of the UI.
        let volume = try request.allowedRoot.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
        guard volume.volumeIsInternal == true, volume.volumeIsLocal == true, volume.volumeIsReadOnly == false else {
            throw TrashSafetyError.unsupportedVolume
        }
        let parent = request.url.deletingLastPathComponent()
        let chain = try DirectoryChain(parent.path)
        guard let root = request.root.fingerprint,
              let actualRoot = chain.values.first(where: { $0.path == request.root.path }),
              root.identifies(actualRoot.fingerprint) else { throw TrashSafetyError.changed }
        for ancestor in request.ancestors {
            guard let expected = ancestor.fingerprint,
                  let actual = chain.values.first(where: { $0.path == ancestor.path }),
                  expected.identifies(actual.fingerprint) else { throw TrashSafetyError.changed }
        }
        guard access(parent.path, W_OK | X_OK) == 0 else { throw TrashSafetyError.permission }
        try validateTree(request.item, parentFD: chain.lastFD, device: root.device, depth: 0)
        // The Foundation API takes a path, not an fd. Detect ancestor replacement again at the boundary.
        // There is still an unavoidable check-to-API race; this is not an atomic filesystem transaction.
        try chain.verifyPaths()
        var finalInfo = stat()
        guard fstatat(chain.lastFD, request.item.name, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0,
              request.item.fingerprint == FileFingerprint(finalInfo) else { throw TrashSafetyError.changed }
        return try action()
    }

    private static func validateTree(_ node: FileNode, parentFD: Int32, device: Int32, depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= 128, let expected = node.fingerprint else { throw TrashSafetyError.noIdentity }
        var info = stat()
        guard fstatat(parentFD, node.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT ? TrashSafetyError.missing : TrashSafetyError.permission
        }
        guard info.st_dev == device, info.st_mode & S_IFMT != S_IFLNK else { throw TrashSafetyError.unsafeLocation }
        guard FileFingerprint(info) == expected else { throw TrashSafetyError.changed }
        guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw TrashSafetyError.permission }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw TrashSafetyError.unsafeLocation }
        let values = try URL(fileURLWithPath: node.path).resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey])
        guard values.isUbiquitousItem != true, values.isAliasFile != true else { throw TrashSafetyError.unsafeLocation }
        guard node.isFolder else {
            guard info.st_mode & S_IFMT == S_IFREG else { throw TrashSafetyError.unsafeLocation }
            return
        }
        let fd = openat(parentFD, node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TrashSafetyError.unsafeLocation }
        guard let directory = fdopendir(fd) else { close(fd); throw TrashSafetyError.permission }
        defer { closedir(directory) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, FileFingerprint(opened) == expected else { throw TrashSafetyError.changed }
        let children = Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard children.count == node.children.count else { throw TrashSafetyError.changed }
        var visited = Set<String>()
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw TrashSafetyError.permission }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard let child = children[name], visited.insert(name).inserted else { throw TrashSafetyError.changed }
            try validateTree(child, parentFD: fd, device: device, depth: depth + 1)
        }
        guard visited.count == children.count, fstat(fd, &opened) == 0,
              FileFingerprint(opened) == expected else { throw TrashSafetyError.changed }
    }

    private final class DirectoryChain {
        struct Value { let fd: Int32; let path: String; let fingerprint: FileFingerprint }
        var values: [Value] = []
        var lastFD: Int32 { values.last!.fd }
        init(_ path: String) throws {
            let start = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard start >= 0 else { throw TrashSafetyError.permission }
            var info = stat()
            guard fstat(start, &info) == 0 else { close(start); throw TrashSafetyError.permission }
            values.append(Value(fd: start, path: "/", fingerprint: FileFingerprint(info)))
            do {
                var current = ""
                for component in path.split(separator: "/") {
                    try Task.checkCancellation()
                    let name = String(component)
                    current += "/" + name
                    let fd = openat(lastFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw TrashSafetyError.unsafeLocation }
                    guard fstat(fd, &info) == 0 else { close(fd); throw TrashSafetyError.permission }
                    values.append(Value(fd: fd, path: current, fingerprint: FileFingerprint(info)))
                }
            } catch { values.forEach { close($0.fd) }; values = []; throw error }
        }
        deinit { values.forEach { close($0.fd) } }
        func verifyPaths() throws {
            for value in values {
                var current = stat()
                guard lstat(value.path, &current) == 0, value.fingerprint.identifies(FileFingerprint(current)) else {
                    throw TrashSafetyError.unsafeLocation
                }
            }
        }
    }
}
