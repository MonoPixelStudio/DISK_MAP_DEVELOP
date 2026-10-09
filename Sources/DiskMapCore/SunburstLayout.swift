import Foundation

/// Angles are turns, clockwise from twelve o'clock. Depth 1 is the innermost ring.
public struct SunburstSector: Identifiable, Sendable {
    public let id: String
    public let node: FileNode?
    public let parentID: String
    public let parentPath: String
    public let depth: Int
    public let startTurn: Double
    public let endTurn: Double
    public let bytes: Int64
    public let branchIndex: Int
    public let groupedItems: Int

    public var isAggregate: Bool { node == nil }
    public var name: String { node?.name ?? "기타 \(groupedItems)개 항목" }
    public var path: String { node?.path ?? parentPath }
    public var angularInset: Double {
        endTurn - startTurn > 0.999999 ? 0 : min(0.0012, (endTurn - startTurn) / 4)
    }
    public var visibleStart: Double { startTurn + angularInset }
    public var visibleEnd: Double { endTurn - angularInset }
}

public struct SunburstGeometry: Sendable {
    public let side: Double
    public let levels: Int
    public var center: Double { side / 2 }
    public var outerRadius: Double { max(0, side / 2 - 8) }
    public var hubRadius: Double { outerRadius * 0.28 }
    public var ringWidth: Double { (outerRadius - hubRadius) / Double(levels) }

    public init(side: Double, levels: Int) {
        self.side = side.isFinite ? max(0, side) : 0
        self.levels = min(4, max(1, levels))
    }

    public func innerRadius(at depth: Int) -> Double { hubRadius + Double(depth - 1) * ringWidth + 1 }
    public func outerRadius(at depth: Int) -> Double { hubRadius + Double(depth) * ringWidth - 1 }
}

public struct SunburstLayout: Sendable {
    public let rootID: String
    public let totalBytes: Int64
    public let sectors: [SunburstSector]
    public let levels: Int

    public static let empty = SunburstLayout(rootID: "", totalBytes: 0, sectors: [], levels: 1)

    private struct Frame {
        let parent: FileNode
        let start: Double
        let end: Double
        let branch: Int
    }

    /// A ring has at most 128 sectors; a parent has at most 32. Remainders preserve
    /// their exact measured bytes in one aggregate sector, rather than disappearing.
    public static func build(for folder: FileNode, maximumDepth: Int = 3) throws -> SunburstLayout {
        try Task.checkCancellation()
        let maxDepth = min(4, max(1, maximumDepth))
        guard folder.totalBytes > 0 else {
            return SunburstLayout(rootID: folder.id, totalBytes: 0, sectors: [], levels: 1)
        }
        var sectors: [SunburstSector] = []
        var frames = [Frame(parent: folder, start: 0, end: 1, branch: -1)]
        for depth in 1...maxDepth {
            if frames.isEmpty { break }
            var next: [Frame] = []
            var remainingSlots = 128
            for (frameIndex, frame) in frames.enumerated() {
                try Task.checkCancellation()
                var positive: [FileNode] = []
                for (index, child) in frame.parent.childrenBySize.enumerated() {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    if child.totalBytes > 0 { positive.append(child) }
                }
                guard !positive.isEmpty else { continue }
                // Reserve one aggregate slot for every parent still to be processed.
                let slots = min(32, max(1, remainingSlots - (frames.count - frameIndex - 1)))
                let eligible = positive.prefix { Double($0.totalBytes) / Double(folder.totalBytes) >= 0.004 }.count
                let keepsAll = positive.count <= slots && eligible == positive.count
                let individualCount = keepsAll ? positive.count : min(eligible, slots - 1)
                var angle = frame.start
                for (index, node) in positive.prefix(individualCount).enumerated() {
                    let end = keepsAll && index == individualCount - 1 ? frame.end :
                        min(frame.end, angle + Double(node.totalBytes) / Double(folder.totalBytes))
                    let branch = depth == 1 ? index : frame.branch
                    sectors.append(SunburstSector(
                        id: "node:\(node.id)", node: node, parentID: frame.parent.id, parentPath: frame.parent.path,
                        depth: depth, startTurn: angle, endTurn: end, bytes: node.totalBytes,
                        branchIndex: branch, groupedItems: 0
                    ))
                    remainingSlots -= 1
                    if depth < maxDepth, node.isFolder, node.childrenBySize.first?.totalBytes ?? 0 > 0 {
                        next.append(Frame(parent: node, start: angle, end: end, branch: branch))
                    }
                    angle = end
                }
                if !keepsAll {
                    var bytes: Int64 = 0
                    for (index, node) in positive.dropFirst(individualCount).enumerated() {
                        if index % 256 == 0 { try Task.checkCancellation() }
                        bytes += node.totalBytes
                    }
                    sectors.append(SunburstSector(
                        id: "group:\(frame.parent.id)", node: nil, parentID: frame.parent.id, parentPath: frame.parent.path,
                        depth: depth, startTurn: angle, endTurn: frame.end, bytes: bytes,
                        branchIndex: depth == 1 ? individualCount : frame.branch,
                        groupedItems: positive.count - individualCount
                    ))
                    remainingSlots -= 1
                }
            }
            frames = next
        }
        try Task.checkCancellation()
        return SunburstLayout(rootID: folder.id, totalBytes: folder.totalBytes, sectors: sectors,
                              levels: sectors.map(\.depth).max() ?? 1)
    }

    public func hitTest(x: Double, y: Double, geometry: SunburstGeometry) -> SunburstSector? {
        guard x.isFinite, y.isFinite, geometry.ringWidth > 2 else { return nil }
        let dx = x - geometry.center, dy = y - geometry.center
        let radius = hypot(dx, dy)
        guard radius > geometry.hubRadius, radius < geometry.outerRadius else { return nil }
        let depth = Int((radius - geometry.hubRadius) / geometry.ringWidth) + 1
        guard depth <= levels, radius >= geometry.innerRadius(at: depth), radius <= geometry.outerRadius(at: depth) else { return nil }
        var turn = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if turn < 0 { turn += 1 }
        return sectors.first { $0.depth == depth && turn >= $0.visibleStart && turn < $0.visibleEnd }
    }

    /// A selected tiny/deep item is represented by its aggregate or nearest drawn ancestor.
    /// Known zero-byte and unmeasured entries never acquire fictitious sectors.
    public func representedSector(for trail: [FileNode]) -> SunburstSector? {
        var result: SunburstSector?
        for (index, node) in trail.enumerated() where index > 0 {
            if let exact = sectors.first(where: { $0.node?.id == node.id }) {
                result = exact
            } else if node.totalBytes > 0,
                      let group = sectors.first(where: { $0.isAggregate && $0.parentID == trail[index - 1].id }) {
                return group
            } else { break }
        }
        return result
    }
}
