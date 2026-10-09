import Foundation

public enum TrashOutcome: String, Sendable { case moved, failed, skipped }

public struct TrashItemResult: Identifiable, Sendable {
    public var id: String { item.id }
    public let item: FileNode
    public let outcome: TrashOutcome
    public let message: String
    public let receipt: TrashReceipt?
}

public struct TrashReport: Sendable {
    public let rootPath: String
    public let completedAt: Date
    public let items: [TrashItemResult]
    public var moved: [TrashItemResult] { items.filter { $0.outcome == .moved } }
    public var failedCount: Int { items.filter { $0.outcome == .failed }.count }
    public var skippedCount: Int { items.filter { $0.outcome == .skipped }.count }
    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.item.totalBytes } }
    public var summary: String { "이동 \(moved.count)개 · 실패 \(failedCount)개 · 건너뜀 \(skippedCount)개" }
}

public struct TrashProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let name: String
}

public enum TrashBatch {
    /// Cancellation stops pending items; an already-started native move completes and is reported.
    public static func run(_ requests: [TrashRequest], manager: any TrashManaging,
                           progress: @Sendable (TrashProgress) async -> Void = { _ in }) async -> TrashReport {
        var results: [TrashItemResult] = []
        for request in requests {
            await progress(TrashProgress(completed: results.count, total: requests.count, name: request.item.name))
            let result: TrashItemResult
            if Task.isCancelled {
                result = TrashItemResult(item: request.item, outcome: .skipped, message: TrashSafetyError.cancelled.localizedDescription, receipt: nil)
            } else {
                do {
                    let receipt = try await manager.moveToTrash(request)
                    result = TrashItemResult(item: request.item, outcome: .moved, message: "휴지통으로 이동했습니다.", receipt: receipt)
                } catch {
                    let skip = error is TrashSafetyError || error is CleanupBlockReason || error is CancellationError
                    result = TrashItemResult(item: request.item, outcome: skip ? .skipped : .failed,
                                             message: error is CancellationError ? TrashSafetyError.cancelled.localizedDescription : error.localizedDescription, receipt: nil)
                }
            }
            results.append(result)
        }
        await progress(TrashProgress(completed: results.count, total: requests.count, name: "완료"))
        return TrashReport(rootPath: requests.first?.allowedRoot.path ?? "", completedAt: Date(), items: results)
    }
}
