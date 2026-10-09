import Foundation
import DiskMapCore

enum SunburstChecks {
    static func run() async throws {
        try hierarchyAndConservation()
        print("PASS true hierarchy, proportional area, sibling conservation and stable layout")
        try hitTesting()
        print("PASS sector hit testing, ring/angular gaps, hub and full-circle geometry")
        try emptyAndPartial()
        print("PASS empty/zero/unknown/duplicate allocation and partial results")
        try groupingAndLimits()
        print("PASS per-parent/ring budgets, exact grouped allocation and selected-item mapping")
        try await depthAndCancellation()
        print("PASS depth limits, deep selection, 20,000-item aggregation and cancellation")
    }

    private static func file(_ id: String, _ bytes: Int64, status: NodeScanStatus = .complete) -> FileNode {
        FileNode(id: id, name: id, path: "/fixture/\(id)", kind: .file, fileBytes: bytes, category: .other, status: status)
    }

    private static func folder(_ id: String, _ children: [FileNode], status: NodeScanStatus = .complete) -> FileNode {
        FileNode(id: id, name: id, path: "/fixture/\(id)", kind: .folder, children: children, category: .other, status: status)
    }

    private static func checkConservation(_ layout: SunburstLayout, root: FileNode) throws {
        for parentID in Set(layout.sectors.map(\.parentID)) {
            let parent = try require(root.node(withID: parentID), "Missing sector parent")
            let siblings = layout.sectors.filter { $0.parentID == parentID }.sorted { $0.startTurn < $1.startTurn }
            let parentSector = layout.sectors.first { $0.node?.id == parentID }
            let start = parentSector?.startTurn ?? 0, end = parentSector?.endTurn ?? 1
            try expect(siblings.reduce(Int64(0)) { $0 + $1.bytes } == parent.totalBytes, "Sibling bytes do not preserve parent allocation")
            try expect(abs((siblings.first?.startTurn ?? -1) - start) < 1e-10 &&
                       abs((siblings.last?.endTurn ?? -1) - end) < 1e-10, "Children do not cover their parent interval")
            for (index, sector) in siblings.enumerated() {
                try expect(sector.bytes > 0 && sector.startTurn.isFinite && sector.endTurn.isFinite &&
                           sector.endTurn > sector.startTurn, "Invalid sector geometry")
                try expect(sector.depth == (parentSector?.depth ?? 0) + 1, "Child is in the wrong ring")
                let expected = Double(sector.bytes) / Double(root.totalBytes)
                try expect(abs(sector.endTurn - sector.startTurn - expected) < 1e-10, "Arc is not proportional to allocation")
                if index > 0 { try expect(abs(sector.startTurn - siblings[index - 1].endTurn) < 1e-10, "Siblings overlap or omit allocation") }
            }
        }
    }

    private static func hierarchyAndConservation() throws {
        let layout = try SunburstLayout.build(for: SampleData.root)
        try expect(layout.levels == 3 && layout.totalBytes == SampleData.root.totalBytes, "Sample hierarchy is wrong")
        try checkConservation(layout, root: SampleData.root)
        let build = try require(layout.sectors.first { $0.node?.id == "unity-build" }, "Large nested file missing")
        try expect(build.parentID == "unity" && build.depth == 3, "Nested file was flattened")
        try expect(!layout.sectors.contains { $0.parentID == "unity-build" }, "Leaf files must not fabricate outer rings")
        let repeatLayout = try SunburstLayout.build(for: SampleData.root)
        try expect(layout.sectors.map(\.id) == repeatLayout.sectors.map(\.id), "Layout is not stable")
        let large = folder("large-values", [file("a", 4_000_000_000_000_000_000), file("b", 3_000_000_000_000_000_000)])
        try checkConservation(try SunburstLayout.build(for: large), root: large)
    }

    private static func hitTesting() throws {
        let layout = try SunburstLayout.build(for: SampleData.root)
        let geometry = SunburstGeometry(side: 400, levels: layout.levels)
        for sector in layout.sectors {
            let angle = (sector.startTurn + sector.endTurn) * .pi - .pi / 2
            let radius = (geometry.innerRadius(at: sector.depth) + geometry.outerRadius(at: sector.depth)) / 2
            let x = geometry.center + cos(angle) * radius, y = geometry.center + sin(angle) * radius
            try expect(layout.hitTest(x: x, y: y, geometry: geometry)?.id == sector.id, "Hit selected a different sector or ring")
            let gapAngle = (sector.startTurn + sector.angularInset / 2) * 2 * .pi - .pi / 2
            try expect(layout.hitTest(x: geometry.center + cos(gapAngle) * radius,
                                      y: geometry.center + sin(gapAngle) * radius, geometry: geometry) == nil,
                       "Angular padding must not activate a neighboring file")
        }
        try expect(layout.hitTest(x: 200, y: 200, geometry: geometry) == nil, "Hub incorrectly selected a file")
        try expect(layout.hitTest(x: 400, y: 200, geometry: geometry) == nil, "Outside chart selected a file")
        try expect(layout.hitTest(x: .nan, y: .infinity, geometry: geometry) == nil, "Nonfinite input accepted")
        try expect(layout.hitTest(x: 0, y: 0, geometry: SunburstGeometry(side: 0, levels: 3)) == nil, "Zero-size chart accepted a hit")
        let betweenRings = geometry.hubRadius + geometry.ringWidth
        try expect(layout.hitTest(x: 200 + betweenRings, y: 200, geometry: geometry) == nil, "Ring padding must not activate a sector")
        let full = try SunburstLayout.build(for: folder("full", [file("single", 10)]))
        let fullGeometry = SunburstGeometry(side: 400, levels: 1)
        try expect(full.sectors.count == 1 && full.sectors[0].angularInset == 0, "Single item must form a full ring")
        for turn in [0.0, 0.25, 0.5, 0.75, 0.99999] {
            let angle = turn * 2 * .pi - .pi / 2
            try expect(full.hitTest(x: 200 + cos(angle) * 130, y: 200 + sin(angle) * 130, geometry: fullGeometry)?.node?.id == "single",
                       "Full circle has a hit-testing seam")
        }
    }

    private static func emptyAndPartial() throws {
        for root in [folder("empty", []), folder("zero", [file("zero-file", 0)]),
                     folder("unknown", [file("denied", 0, status: .unreadable("Test only"))], status: .partial)] {
            let layout = try SunburstLayout.build(for: root)
            try expect(layout.sectors.isEmpty && layout.totalBytes == 0, "Unknown or zero allocation acquired an area")
        }
        let duplicate = FileNode(id: "hardlink", name: "hardlink", path: "/fixture/hardlink", kind: .file,
                                 category: .other, logicalBytes: 5000, isDuplicateHardLink: true)
        let root = folder("partial", [file("known", 50), file("denied", 0, status: .excluded("Test only")), duplicate], status: .partial)
        let layout = try SunburstLayout.build(for: root)
        try expect(layout.sectors.count == 1 && layout.sectors[0].bytes == 50 && layout.sectors[0].endTurn == 1,
                   "Partial results must use measured allocation, not logical or unknown space")
        let deniedTrail = try require(root.trail(to: "denied"), "Missing denied item")
        try expect(layout.representedSector(for: deniedTrail) == nil, "Unknown root entry must not highlight an unrelated sector")
    }

    private static func groupingAndLimits() throws {
        let branches = (0..<8).map { branch in
            folder("branch-\(branch)", (0..<30).map { index in
                folder("branch-\(branch)-\(index)", [file("file-\(branch)-\(index)", 1000)])
            })
        }
        let root = folder("budget", branches)
        let layout = try SunburstLayout.build(for: root, maximumDepth: 4)
        try checkConservation(layout, root: root)
        try expect(layout.sectors.filter { $0.depth == 2 }.count == 128, "Ring budget did not exercise its boundary")
        try expect(layout.sectors.count <= 512, "Chart grew without a global bound")
        for depth in 1...4 { try expect(layout.sectors.filter { $0.depth == depth }.count <= 128, "Ring exceeds drawing budget") }
        for parent in Set(layout.sectors.map(\.parentID)) {
            try expect(layout.sectors.filter { $0.parentID == parent }.count <= 32, "Parent exceeds drawing budget")
        }
        let group = try require(layout.sectors.first { $0.isAggregate }, "Remainder group missing")
        let parent = try require(root.node(withID: group.parentID), "Group parent missing")
        let visibleIDs = Set(layout.sectors.compactMap { $0.parentID == parent.id ? $0.node?.id : nil })
        let hidden = parent.children.filter { !visibleIDs.contains($0.id) }
        try expect(hidden.count == group.groupedItems && hidden.reduce(Int64(0)) { $0 + $1.totalBytes } == group.bytes,
                   "Grouped count or bytes are inaccurate")
        let hiddenTrail = try require(root.trail(to: hidden[0].id), "Grouped item trail missing")
        try expect(layout.representedSector(for: hiddenTrail)?.id == group.id, "Grouped selected item was mapped to another group")
        let tiny = folder("tiny-root", [file("big", 1_000_000), file("tiny", 1)])
        let tinyLayout = try SunburstLayout.build(for: tiny)
        try expect(tinyLayout.sectors.count == 2 && tinyLayout.sectors.last?.bytes == 1, "Tiny remainder was lost or inflated")
        try checkConservation(tinyLayout, root: tiny)
    }

    private static func depthAndCancellation() async throws {
        var root = file("deep-file", 100)
        for level in (0..<8).reversed() { root = folder("level-\(level)", [root]) }
        let shallow = try SunburstLayout.build(for: root, maximumDepth: 2)
        let deep = try SunburstLayout.build(for: root, maximumDepth: 100)
        try expect(shallow.levels == 2 && deep.levels == 4, "Configured depth was not clamped")
        let trail = try require(root.trail(to: "deep-file"), "Missing deep trail")
        try expect(shallow.representedSector(for: trail)?.depth == 2, "Deep selection must map to its nearest drawn ancestor")
        let large = folder("many", (0..<20_000).map { file("item-\($0)", 1) })
        let layout = try SunburstLayout.build(for: large)
        try expect(layout.sectors.count == 1 && layout.sectors[0].groupedItems == 20_000 && layout.sectors[0].bytes == 20_000,
                   "Large set must retain its exact sum in a bounded aggregate")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try SunburstLayout.build(for: large); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(cancelled, "Cancelled chart computation must not publish a layout")
    }
}
