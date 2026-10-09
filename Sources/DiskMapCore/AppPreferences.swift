import Foundation
import Darwin

public struct RecentLocation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let usedAt: Date
}

public struct AppPreferences: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var chartDepth = 3
    public var sort = BrowserSort.sizeDescending.rawValue
    public var showsHidden = true
    public var includesDescendants = false
    public var kind = BrowserKind.all.rawValue
    public var minimumSize: Int64 = 0
    public private(set) var recent: [RecentLocation] = []
    public init() {}
    public var query: BrowserQuery {
        var query = BrowserQuery()
        query.sort = BrowserSort(rawValue: sort) ?? .sizeDescending
        query.showsHidden = showsHidden; query.includesDescendants = includesDescendants
        query.kind = BrowserKind(rawValue: kind) ?? .all
        query.minimumSize = BrowserMinimumSize(rawValue: minimumSize) ?? .all
        return query
    }
    public mutating func remember(_ path: String, at date: Date = Date()) {
        guard let path = CleanupPolicy.path(path) else { return }
        recent.removeAll { $0.path == path }
        recent.insert(RecentLocation(path: path, usedAt: date), at: 0)
        recent = Array(recent.prefix(5))
    }
    public mutating func clearRecent() { recent = [] }
    public mutating func sanitize() {
        chartDepth = min(4, max(2, chartDepth))
        var seen = Set<String>()
        recent = Array(recent.filter { CleanupPolicy.path($0.path) != nil && seen.insert($0.path).inserted }.prefix(5))
    }
    public mutating func update(query: BrowserQuery, depth: Int) {
        chartDepth = min(4, max(2, depth)); sort = query.sort.rawValue
        showsHidden = query.showsHidden; includesDescendants = query.includesDescendants
        kind = query.kind.rawValue; minimumSize = query.minimumSize.rawValue
    }
}

public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppPreferences {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return AppPreferences() }
            throw CocoaError(.fileReadNoPermission)
        }
        let directoryFD = try openDirectory(create: false)
        defer { close(directoryFD) }
        let fd = openat(directoryFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        guard preferences.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        preferences.sanitize()
        return preferences
    }
    public func save(_ preferences: AppPreferences) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let directoryFD = try openDirectory(create: true)
        defer { close(directoryFD) }
        var info = stat()
        if fstatat(directoryFD, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CocoaError(.fileWriteNoPermission) }
        } else if errno != ENOENT { throw CocoaError(.fileWriteNoPermission) }
        let temporary = ".preferences-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var renamed = false
        defer { if !renamed { _ = unlinkat(directoryFD, temporary, 0) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        var current = stat()
        if fstatat(directoryFD, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 {
            guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  current.st_ino == info.st_ino, current.st_dev == info.st_dev else { throw CocoaError(.fileWriteNoPermission) }
        } else if errno != ENOENT || info.st_ino != 0 { throw CocoaError(.fileWriteNoPermission) }
        guard renameat(directoryFD, temporary, directoryFD, url.lastPathComponent) == 0 else { throw CocoaError(.fileWriteUnknown) }
        renamed = true
    }
    // Walk and create relative to directory descriptors, never through a symlink ancestor.
    private func openDirectory(create: Bool) throws -> Int32 {
        guard url.isFileURL, CleanupPolicy.path(url.path) != nil else { throw CocoaError(.fileWriteNoPermission) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        do {
            for component in url.deletingLastPathComponent().path.split(separator: "/") {
                let name = String(component)
                var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, name, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
                    next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                close(fd); fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    public static func runtime(bundleURL: URL) -> SettingsStore {
        let parent = bundleURL.deletingLastPathComponent()
        let project = parent.deletingLastPathComponent()
        if parent.lastPathComponent == "dist", FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path) {
            return SettingsStore(url: project.appendingPathComponent(".diskmap-state/preferences.json"))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(url: support.appendingPathComponent("DiskMap/preferences.json"))
    }
}
