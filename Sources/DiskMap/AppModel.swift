import AppKit
import SwiftUI
import DiskMapCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var root = SampleData.root
    let scanner: any DiskScanning = LocalDiskScanner()
    let trashManager: any TrashManaging = LocalTrashManager()

    @Published private(set) var currentFolderID = SampleData.root.id
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var selectedNode: FileNode?
    @Published private(set) var selectedChartSectorID: String?
    @Published private(set) var browserSelectionRequest = UUID()
    @Published private(set) var browserNotice: String?
    @Published var chartDepth = 3 { didSet { refreshChart(); saveDisplayPreferences() } }
    @Published private(set) var chartLayout = SunburstLayout.empty
    @Published private(set) var chartRevision = UUID()
    @Published private(set) var isChartLoading = true
    @Published private(set) var selectedFolderURL: URL?
    @Published private(set) var isSample = true
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var scanSummary: ScanSummary?
    @Published private(set) var scanMessage = "샘플 데이터로 둘러보기"
    @Published private(set) var scanFailed = false
    @Published var browserQuery = BrowserQuery() { didSet { refreshBrowser(); saveDisplayPreferences() } }
    @Published private(set) var browserNodes = SampleData.root.childrenBySize
    @Published private(set) var browserRevision = UUID()
    @Published private(set) var isFiltering = false
    @Published private(set) var searchFocusRequest = UUID()
    @Published var fileActionError: String?
    @Published private(set) var cleanupQueue = CleanupQueue(root: SampleData.root, isSample: true)
    @Published private(set) var cleanupNotice: String?
    @Published private(set) var selectedCleanupRestriction: CleanupBlockReason?
    @Published private(set) var isCheckingCleanup = false
    @Published private(set) var isUpdatingCleanup = false
    @Published var isCleanupPresented = false
    @Published var showingCleanupResults = false
    @Published var isTrashConfirmation = false
    @Published private(set) var isPreparingTrash = false
    @Published private(set) var isTrashing = false
    @Published private(set) var trashProgress: TrashProgress?
    @Published private(set) var trashReport: TrashReport?
    @Published private(set) var snapshotNeedsRefresh = false
    @Published private(set) var volumeSpace: VolumeSpace?
    @Published private(set) var volumeMessage: String?
    @Published private(set) var isRefreshingSpace = false
    @Published private(set) var recentLocations: [RecentLocation] = []
    @Published private(set) var settingsMessage: String?
    private let settingsStore = SettingsStore.runtime(bundleURL: Bundle.main.bundleURL)
    private var preferences = AppPreferences()
    private var restoringPreferences = true
    private var preparedTrash: [TrashRequest] = []
    private var trashTask: Task<Void, Never>?
    private var spaceTask: Task<Void, Never>?
    private var spaceRequest = UUID()
    private var cleanupEligibilityTask: Task<Void, Never>?
    private var cleanupActionTask: Task<Void, Never>?
    private var cleanupContext = UUID()
    private var cleanupSelectionRequest = UUID()
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()
    private var browserTask: Task<Void, Never>?
    private var browserGeneration = UUID()
    private var chartTask: Task<Void, Never>?
    private var chartGeneration = UUID()
    private var navigationIndex = try? FileSnapshotIndex(root: SampleData.root)

    init() {
        do { preferences = try settingsStore.load() }
        catch { settingsMessage = "설정을 읽지 못해 기본값을 사용합니다. \(error.localizedDescription)" }
        chartDepth = preferences.chartDepth
        browserQuery = preferences.query
        recentLocations = preferences.recent
        restoringPreferences = false
        refreshChart(); refreshBrowser()
    }

    var isTrashBusy: Bool { isPreparingTrash || isTrashing || isTrashConfirmation }
    var cleanupLocked: Bool { isScanning || isUpdatingCleanup || isTrashBusy || snapshotNeedsRefresh }

    private func saveDisplayPreferences() {
        guard !restoringPreferences else { return }
        var updated = preferences
        updated.update(query: browserQuery, depth: chartDepth)
        guard updated != preferences else { return }
        preferences = updated
        savePreferences()
    }

    private func savePreferences() {
        do { try settingsStore.save(preferences); settingsMessage = nil }
        catch { settingsMessage = "설정을 저장하지 못했습니다. \(error.localizedDescription)" }
    }

    func clearRecentLocations() {
        guard !isTrashBusy else { return }
        preferences.clearRecent(); recentLocations = []; savePreferences()
    }

    func reviewCleanup(results: Bool = false) {
        showingCleanupResults = results
        isCleanupPresented = true
    }

    func askToTrash() {
        guard !cleanupLocked, !isSample, !cleanupQueue.entries.isEmpty else { return }
        isPreparingTrash = true
        let queue = cleanupQueue
        trashTask = Task { [weak self] in
            do {
                let requests = try await Task.detached(priority: .userInitiated) { try queue.trashRequests() }.value
                guard let self else { return }
                self.preparedTrash = requests
                self.isPreparingTrash = false
                self.isTrashConfirmation = true
                self.trashTask = nil
            } catch {
                self?.isPreparingTrash = false
                self?.cleanupNotice = error.localizedDescription
                self?.trashTask = nil
            }
        }
    }

    func cancelTrashConfirmation() { preparedTrash = []; isTrashConfirmation = false }

    func confirmTrash() {
        guard !isTrashing, !isSample, !preparedTrash.isEmpty else { return }
        let requests = preparedTrash
        preparedTrash = []; isTrashConfirmation = false; isTrashing = true
        let manager = trashManager
        trashTask = Task { [weak self] in
            let report = await TrashBatch.run(requests, manager: manager) { [weak self] progress in
                await MainActor.run { self?.trashProgress = progress }
            }
            guard let self else { return }
            self.trashReport = report
            for result in report.moved { self.cleanupQueue.remove(result.id) }
            self.snapshotNeedsRefresh = !report.moved.isEmpty
            self.isTrashing = false; self.trashTask = nil
            self.showingCleanupResults = true
            self.cleanupNotice = report.summary
            self.refreshSpace()
            // Reconcile the whole selected root, including ancestors and shared hard-link accounting.
            let remaining = self.cleanupQueue
            self.startScan(URL(fileURLWithPath: report.rootPath), preserving: remaining)
        }
    }

    func stopTrash() { if isTrashing { trashTask?.cancel() } }

    func showTrashInFinder() {
        let urls = (trashReport?.moved.compactMap { $0.receipt?.trashURL } ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            cleanupNotice = "이동한 항목을 휴지통에서 찾지 못했습니다. Finder에서 비우거나 복원했을 수 있습니다."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshSpace() {
        guard !isSample else { return }
        spaceTask?.cancel()
        let request = UUID(); spaceRequest = request
        let url = URL(fileURLWithPath: root.path)
        isRefreshingSpace = true; volumeMessage = nil
        spaceTask = Task { [weak self] in
            do {
                let space = try await Task.detached(priority: .utility) { try VolumeSpace.read(at: url) }.value
                guard let self, self.spaceRequest == request, !Task.isCancelled else { return }
                self.volumeSpace = space; self.isRefreshingSpace = false; self.spaceTask = nil
            } catch {
                guard let self, self.spaceRequest == request, !Task.isCancelled else { return }
                self.volumeSpace = nil; self.isRefreshingSpace = false
                self.volumeMessage = "여유 공간 조회 실패: \(error.localizedDescription)"; self.spaceTask = nil
            }
        }
    }

    var dataLabel: String { isSample ? "샘플 데이터" : "실제 스캔 결과" }
    var sidebarFolders: [FileNode] { Array(root.childrenBySize.filter(\.isFolder).prefix(6)) }

    var currentFolder: FileNode { navigationIndex?.node(withID: currentFolderID) ?? root }
    var breadcrumb: [FileNode] { navigationIndex?.trail(to: currentFolderID) ?? [root] }

    func navigate(to node: FileNode) {
        guard node.isFolder, navigationIndex?.node(withID: node.id) != nil else { return }
        currentFolderID = node.id
        clearSelection()
        browserQuery.search = ""
        refreshChart()
    }

    func clearSelection() {
        cleanupEligibilityTask?.cancel()
        cleanupSelectionRequest = UUID()
        selectedCleanupRestriction = nil
        isCheckingCleanup = false
        selectedNodeID = nil
        selectedNode = nil
        selectedChartSectorID = nil
    }

    func select(_ node: FileNode) {
        guard let snapshot = navigationIndex?.node(withID: node.id) else { return }
        selectedNodeID = snapshot.id
        selectedNode = snapshot
        updateChartSelection()
        refreshCleanupEligibility()
    }

    var selectedCleanupCoverage: CleanupCoverage? {
        selectedNode.flatMap { cleanupQueue.coverage(ofPath: $0.path) }
    }

    func toggleSelectedCleanup() {
        guard let node = selectedNode else { return }
        toggleCleanup(node)
    }

    func toggleCleanup(_ node: FileNode) {
        guard !cleanupLocked else { return }
        switch cleanupQueue.coverage(ofPath: node.path) {
        case .direct: removeCleanup(node.id)
        case .ancestor(let name): cleanupNotice = "이미 ‘\(name)’ 폴더에 포함되어 있습니다."
        case nil: addCleanup(node.id)
        }
    }

    private func addCleanup(_ nodeID: String) {
        let queue = cleanupQueue
        let context = cleanupContext
        isUpdatingCleanup = true
        cleanupActionTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    var updated = queue
                    let result = try updated.add(nodeID)
                    return (updated, result)
                }
                let (updated, result) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.cleanupContext == context else { return }
                self.cleanupQueue = updated
                switch result {
                case .added(let replaced):
                    self.cleanupNotice = replaced > 0 ? "상위 폴더로 묶고 기존 하위 후보 \(replaced)개를 대체했습니다. 파일은 변경하지 않았습니다." : "정리 후보에 담았습니다. 파일은 변경하지 않았습니다."
                case .alreadyIncluded: self.cleanupNotice = "이미 정리 목록에 포함되어 있습니다."
                }
                self.isUpdatingCleanup = false
                self.cleanupActionTask = nil
            } catch {
                guard let self, self.cleanupContext == context, !Task.isCancelled else { return }
                self.cleanupNotice = error.localizedDescription
                self.isUpdatingCleanup = false
                self.cleanupActionTask = nil
            }
        }
    }

    func removeCleanup(_ entryID: String) {
        guard !cleanupLocked else { return }
        cleanupQueue.remove(entryID)
        cleanupNotice = "정리 목록에서 뺐습니다. 파일은 그대로 있습니다."
    }

    func clearCleanup() {
        guard !cleanupLocked else { return }
        cleanupQueue.removeAll()
        cleanupNotice = "정리 목록을 비웠습니다. 파일은 그대로 있습니다."
    }

    func locateCleanup(_ entryID: String) {
        guard let trail = navigationIndex?.trail(to: entryID), let node = trail.last, trail.count > 1 else { return }
        navigate(to: trail[trail.count - 2])
        selectFromChart(node)
        isCleanupPresented = false
    }

    private func refreshCleanupEligibility() {
        cleanupEligibilityTask?.cancel()
        let request = UUID()
        cleanupSelectionRequest = request
        guard let id = selectedNodeID else { isCheckingCleanup = false; return }
        let queue = cleanupQueue
        isCheckingCleanup = true
        selectedCleanupRestriction = nil
        cleanupEligibilityTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { try queue.restriction(for: id) }
                let restriction = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.cleanupSelectionRequest == request else { return }
                self.selectedCleanupRestriction = restriction
                self.isCheckingCleanup = false
                self.cleanupEligibilityTask = nil
            } catch {
                guard let self, self.cleanupSelectionRequest == request, !Task.isCancelled else { return }
                self.selectedCleanupRestriction = .outsideSnapshot
                self.isCheckingCleanup = false
                self.cleanupEligibilityTask = nil
            }
        }
    }

    private func replaceCleanupSnapshot(with queue: CleanupQueue? = nil, preservingCandidates: Bool = false) {
        cleanupContext = UUID()
        cleanupActionTask?.cancel()
        cleanupActionTask = nil
        isUpdatingCleanup = false
        let hadEntries = !cleanupQueue.entries.isEmpty
        cleanupQueue = queue ?? CleanupQueue(root: root, isSample: isSample)
        cleanupNotice = preservingCandidates ? "정리 후 재스캔했습니다. 변경되지 않은 남은 후보 \(cleanupQueue.entries.count)개를 유지합니다." :
            hadEntries ? "스캔 결과가 바뀌어 이전 정리 목록을 비웠습니다. 파일은 변경하지 않았습니다." : nil
        if !preservingCandidates { isCleanupPresented = false }
        snapshotNeedsRefresh = false
    }

    func selectFromChart(_ node: FileNode) {
        guard let trail = navigationIndex?.trail(to: node.id, from: currentFolderID), trail.count > 1 else { return }
        if !browserNodes.contains(where: { $0.id == node.id }) {
            var query = BrowserQuery()
            query.sort = browserQuery.sort
            query.includesDescendants = browserQuery.includesDescendants || trail.count > 2
            browserQuery = query
            browserNotice = "차트 항목을 표시하도록 목록 검색·필터를 초기화했습니다."
        }
        select(node)
        browserSelectionRequest = UUID()
    }

    private func updateChartSelection() {
        guard let id = selectedNodeID, let trail = navigationIndex?.trail(to: id, from: currentFolderID) else {
            selectedChartSectorID = nil
            return
        }
        selectedChartSectorID = chartLayout.representedSector(for: trail)?.id
    }

    private func refreshChart() {
        chartTask?.cancel()
        let requestID = UUID()
        chartGeneration = requestID
        let folder = currentFolder
        let depth = chartDepth
        chartLayout = .empty
        isChartLoading = true
        chartTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try SunburstLayout.build(for: folder, maximumDepth: depth)
                }
                let layout = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.chartGeneration == requestID else { return }
                self.chartLayout = layout
                self.chartRevision = UUID()
                self.isChartLoading = false
                self.updateChartSelection()
                self.chartTask = nil
            } catch {
                guard let self, self.chartGeneration == requestID else { return }
                self.isChartLoading = false
                self.chartTask = nil
            }
        }
    }

    func goBack() {
        guard breadcrumb.count > 1 else { return }
        navigate(to: breadcrumb[breadcrumb.count - 2])
    }

    func showSample() {
        guard !isTrashBusy else { return }
        cancelScan()
        selectedFolderURL = nil
        navigationIndex = try? FileSnapshotIndex(root: SampleData.root)
        root = SampleData.root
        currentFolderID = root.id
        clearSelection()
        isSample = true
        replaceCleanupSnapshot()
        scanSummary = nil
        scanProgress = nil
        scanFailed = false
        scanMessage = "샘플 데이터로 둘러보기"
        browserQuery = preferences.query
        spaceTask?.cancel(); spaceRequest = UUID(); volumeSpace = nil; volumeMessage = nil; isRefreshingSpace = false
        refreshChart()
    }

    func startScan(_ url: URL, preserving queue: CleanupQueue? = nil) {
        guard !isTrashBusy else { return }
        cleanupContext = UUID()
        cleanupActionTask?.cancel()
        cleanupActionTask = nil
        isUpdatingCleanup = false
        scanTask?.cancel()
        let scanID = UUID()
        generation = scanID
        selectedFolderURL = url
        scanProgress = nil
        scanFailed = false
        isScanning = true
        scanMessage = "\(url.lastPathComponent) 스캔 중"
        let scanner = scanner
        scanTask = Task { [weak self] in
            do {
                for try await event in scanner.scan(ScanRequest(rootURL: url)) {
                    try Task.checkCancellation()
                    guard let self, self.generation == scanID else { return }
                    switch event {
                    case .progress(let progress):
                        self.scanProgress = progress
                    case .completed(let root, let summary):
                        // Indexing and reconciliation of large candidate folders must not block UI.
                        let worker = Task.detached(priority: .userInitiated) {
                            let index = try FileSnapshotIndex(root: root)
                            let updated = queue?.rebased(on: root) ?? CleanupQueue(root: root, isSample: false)
                            try Task.checkCancellation()
                            return (index, updated)
                        }
                        let (index, updated) = try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: { worker.cancel() }
                        try Task.checkCancellation()
                        guard self.generation == scanID else { return }
                        self.navigationIndex = index
                        self.root = root
                        self.currentFolderID = root.id
                        self.clearSelection()
                        self.isSample = false
                        self.replaceCleanupSnapshot(with: updated, preservingCandidates: queue != nil)
                        self.scanSummary = summary
                        self.preferences.remember(root.path)
                        self.recentLocations = self.preferences.recent
                        self.savePreferences()
                        self.refreshSpace()
                        self.refreshBrowser()
                        self.refreshChart()
                        self.scanMessage = root.status.isIncomplete ? "스캔 완료 · 일부 항목 제외 또는 접근 불가" : "스캔 완료"
                    }
                }
                guard let self, self.generation == scanID else { return }
                self.isScanning = false
                self.scanTask = nil
            } catch {
                guard let self, self.generation == scanID, !Task.isCancelled else { return }
                self.isScanning = false
                self.scanFailed = true
                self.scanMessage = error.localizedDescription
                self.scanTask = nil
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanMessage = "스캔을 취소했습니다. 화면에는 이전 결과를 유지합니다."
    }

    func focusSearch() { searchFocusRequest = UUID() }

    func resetBrowserFilters() {
        let sort = browserQuery.sort
        let descendants = browserQuery.includesDescendants
        var query = BrowserQuery()
        query.sort = sort
        query.includesDescendants = descendants
        browserQuery = query
    }

    private func refreshBrowser() {
        browserTask?.cancel()
        let queryID = UUID()
        browserGeneration = queryID
        let query = browserQuery
        let folder = currentFolder
        // Remove stale rows immediately; a result from another query must not be actionable.
        browserNodes = []
        clearSelection()
        browserNotice = nil
        isFiltering = true
        browserTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) { try query.results(in: folder) }
                let nodes = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.browserGeneration == queryID else { return }
                self.browserNodes = nodes
                self.browserRevision = UUID()
                self.isFiltering = false
                if self.selectedNodeID != nil { self.browserSelectionRequest = UUID() }
                self.browserTask = nil
            } catch {
                guard let self, self.browserGeneration == queryID else { return }
                self.isFiltering = false
                self.browserTask = nil
            }
        }
    }

    func navigateToSelectedParent() {
        guard let id = selectedNodeID, let trail = navigationIndex?.trail(to: id), trail.count > 1 else { return }
        navigate(to: trail[trail.count - 2])
    }

    func copySelectedPath() {
        guard let node = selectedNode, !isSample else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func revealSelectedInFinder() {
        guard let node = selectedNode else { return }
        do {
            let url = try FileLocation.url(itemPath: node.path, rootPath: root.path, isSample: isSample)
            // The snapshot can outlive the file. Do not open a different file or app as a fallback.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            fileActionError = "이 위치를 확인할 수 없습니다. 파일이 이동되었거나 접근 권한이 바뀌었을 수 있습니다. 다시 스캔해 주세요.\n\(error.localizedDescription)"
        }
    }

    func chooseFolder() {
        guard !isCleanupPresented, !isTrashBusy, !isScanning else { return }
        let panel = NSOpenPanel()
        panel.title = "스캔할 폴더 선택"
        panel.prompt = "선택 및 스캔"
        panel.message = "선택한 폴더의 용량을 분석합니다. 파일 내용을 열거나 변경하지 않습니다."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // A sheet keeps the SwiftUI window active without a nested modal run loop.
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK else { return }
                if let url = panel.url { self?.startScan(url) }
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK else { return }
                if let url = panel.url { self?.startScan(url) }
            }
        }
    }
}
