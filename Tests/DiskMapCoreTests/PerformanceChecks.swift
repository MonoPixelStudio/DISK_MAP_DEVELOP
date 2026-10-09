import Foundation
import Darwin
import DiskMapCore

/// Real on-disk fixtures only. CPU deltas exclude fixture creation; peak RSS is process-wide.
enum PerformanceChecks {
    private struct Measurement: Codable {
        let seconds: Double
        let cpuSeconds: Double
    }
    private struct Report: Codable {
        let recordedAt: Date
        let files: Int
        let folders: Int
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let fixtureCreation: Measurement
        let scan: Measurement
        let index: Measurement
        let lookup500: Measurement
        let search: Measurement
        let chart: Measurement
        let cancel: Measurement
        let peakResidentBytes: Int64
        let matchedFiles: Int
        let chartSectors: Int
    }
    private static func usage() -> rusage {
        var result = rusage()
        getrusage(RUSAGE_SELF, &result)
        return result
    }
    private static func cpu(_ value: rusage) -> Double {
        Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) +
        Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    private static func measurement(_ start: ContinuousClock.Instant, _ before: rusage) -> Measurement {
        let duration = start.duration(to: .now).components
        return Measurement(seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                           cpuSeconds: max(0, cpu(usage()) - cpu(before)))
    }
    static func runBenchmark() async throws {
        let fixture = try ProjectFixture("Performance")
        defer { try? fixture.clean() }
        let count = 50_000
        var start = ContinuousClock.now; var before = usage()
        let payload = [UInt8](repeating: 0x53, count: 4096)
        for group in 0..<100 {
            let folder = fixture.url.appendingPathComponent("한글 그룹-\(group)")
            try expect(mkdir(folder.path, 0o700) == 0, "Cannot create benchmark folder")
            for index in 0..<500 {
                let url = folder.appendingPathComponent("파일-\(index).bin")
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                try expect(fd >= 0, "Cannot create benchmark file")
                let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                try expect(written == payload.count, "Cannot write benchmark data")
            }
        }
        let creation = measurement(start, before)
        start = .now; before = usage()
        let (root, summary, _) = try await ScannerChecks.collect(fixture.url)
        let scan = measurement(start, before)
        try expect(root.fileCount == count && summary.skippedItems == 0, "Benchmark scan lost files")
        let id = try require(root.children.last?.children.last?.id, "Missing benchmark item")
        start = .now; before = usage()
        let index = try FileSnapshotIndex(root: root)
        let indexing = measurement(start, before)
        start = .now; before = usage()
        // Models the repeated membership and breadcrumb checks triggered by UI updates.
        for _ in 0..<500 { try expect(index.node(withID: id)?.id == id, "Lookup failed") }
        let lookup = measurement(start, before)
        var query = BrowserQuery(); query.includesDescendants = true; query.search = "파일-49"
        start = .now; before = usage()
        let matches = try query.results(in: root)
        let search = measurement(start, before)
        start = .now; before = usage()
        let layout = try SunburstLayout.build(for: root, maximumDepth: 4)
        let chart = measurement(start, before)
        start = .now; before = usage()
        let fixtureURL = fixture.url
        let cancelled = await Task {
            var completed = false
            do {
                for try await event in LocalDiskScanner().scan(ScanRequest(rootURL: fixtureURL)) {
                    if case .progress = event { withUnsafeCurrentTask { $0?.cancel() } }
                    if case .completed = event { completed = true }
                }
            } catch is CancellationError {} catch { return false }
            return !completed
        }.value
        let cancellation = measurement(start, before)
        try expect(cancelled, "Cancelled benchmark scan completed")
        let report = Report(recordedAt: Date(), files: count, folders: 100, logicalBytes: root.totalLogicalBytes,
                            allocatedBytes: root.totalBytes, fixtureCreation: creation, scan: scan, index: indexing,
                            lookup500: lookup, search: search, chart: chart, cancel: cancellation,
                            peakResidentBytes: Int64(usage().ru_maxrss), matchedFiles: matches.count,
                            chartSectors: layout.sectors.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report))
        print("")
    }
}
