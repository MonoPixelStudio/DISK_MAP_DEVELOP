import Foundation
import Darwin

/// Metadata captured during scanning; unlike a node ID, this identifies a filesystem object.
public struct FileFingerprint: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16
    public let flags: UInt32
    public let links: UInt16
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
    public let changedSeconds: Int
    public let changedNanoseconds: Int
    public let createdSeconds: Int
    public let createdNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        flags = value.st_flags; links = value.st_nlink; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        createdSeconds = value.st_birthtimespec.tv_sec; createdNanoseconds = value.st_birthtimespec.tv_nsec
    }

    public var modifiedAt: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9) }
    func identifies(_ other: FileFingerprint) -> Bool { device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT }
}
