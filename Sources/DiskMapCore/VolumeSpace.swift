import Foundation

public struct VolumeSpace: Sendable {
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let checkedAt: Date
    public static func read(at url: URL) throws -> VolumeSpace {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0, available >= 0 else { throw CocoaError(.fileReadUnknown) }
        return VolumeSpace(name: values.volumeName ?? "디스크", totalBytes: Int64(total), availableBytes: Int64(available), checkedAt: Date())
    }
}
