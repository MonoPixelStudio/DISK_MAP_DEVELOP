import SwiftUI
import DiskMapCore

struct SelectedCleanupControl: View {
    @EnvironmentObject private var model: AppModel

    private var coveredByParent: Bool {
        if case .ancestor = model.selectedCleanupCoverage { return true }
        return false
    }

    private var label: String {
        switch model.selectedCleanupCoverage {
        case .direct: "정리 목록에서 빼기"
        case .ancestor: "상위 폴더에 포함됨"
        case nil: model.isCheckingCleanup ? "담기 가능 여부 확인 중…" : "정리 목록에 담기"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.toggleSelectedCleanup() } label: {
                Label(label, systemImage: model.selectedCleanupCoverage == nil ? "plus.circle" : "checkmark.circle")
            }
            .font(.system(size: 11)).buttonStyle(.bordered)
            .disabled(model.cleanupLocked || model.isCheckingCleanup || coveredByParent || model.selectedCleanupRestriction != nil)
            .accessibilityIdentifier("toggle-cleanup")
            if case .ancestor(let name) = model.selectedCleanupCoverage {
                Text("‘\(name)’ 후보에 포함되어 있습니다. 정리 목록에서 관리하세요.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else if let reason = model.selectedCleanupRestriction {
                Text(reason.localizedDescription).font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                Text(model.isSample ? "샘플 후보입니다. 실제 파일을 변경하지 않습니다." : "후보만 담습니다. 실제 파일은 변경하지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct CleanupBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "tray").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.accent)
                .frame(width: 50, height: 50).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("정리 목록").font(.system(size: 13, weight: .semibold))
                    Text("후보 \(model.cleanupQueue.entries.count)개 · 파일 \(model.cleanupQueue.fileCount)개")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("cleanup-count")
                    if model.cleanupQueue.isSample { Tag(title: "샘플") }
                    if model.isUpdatingCleanup { ProgressView().controlSize(.mini) }
                }
                Text(model.cleanupNotice ?? "항목을 선택해 정리 후보에 담으세요. 파일은 그대로 있습니다.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(StorageFormat.bytes(model.cleanupQueue.totalBytes)).font(.system(size: 19, weight: .medium, design: .rounded))
                    .accessibilityIdentifier("cleanup-bytes")
                Text("후보 할당 용량").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            if model.trashReport != nil {
                Button("최근 결과") { model.reviewCleanup(results: true) }
                    .buttonStyle(.bordered).accessibilityIdentifier("review-results")
            }
            Button("목록 검토") { model.reviewCleanup() }
                .buttonStyle(.bordered).accessibilityIdentifier("review-cleanup")
                .disabled(model.cleanupQueue.entries.isEmpty)
            Button { model.reviewCleanup() } label: { Label("휴지통으로 이동…", systemImage: "trash").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSample || model.cleanupQueue.entries.isEmpty || model.cleanupLocked)
                .help(model.isSample ? "샘플은 실제 파일을 이동하지 않습니다." : "대상 경로를 검토하고 확인한 뒤 이동합니다.")
                .accessibilityIdentifier("review-before-trash")
        }
        .padding(.horizontal, 26).frame(height: 100).background(Theme.sidebar)
    }
}

struct CleanupReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.showingCleanupResults ? "휴지통 이동 결과" : "정리 후보 검토").font(.system(size: 20, weight: .semibold))
                    Text(model.showingCleanupResults ? "이동 결과와 디스크의 실제 여유 공간을 확인하세요." : "후보를 빼거나 목록을 비워도 실제 파일은 그대로 있습니다.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("닫기") { model.isCleanupPresented = false }.keyboardShortcut(.cancelAction)
                    .disabled(model.isTrashBusy)
                    .accessibilityIdentifier("close-cleanup")
            }
            Picker("정리 화면", selection: $model.showingCleanupResults) {
                Text("정리 후보").tag(false)
                Text("최근 실행 결과").tag(true)
            }.pickerStyle(.segmented).frame(width: 280).disabled(model.isTrashBusy)
            if model.showingCleanupResults {
                CleanupResultContent()
            } else {
            HStack {
                Text("후보 \(model.cleanupQueue.entries.count)개 · 포함 파일 \(model.cleanupQueue.fileCount)개")
                if model.cleanupQueue.isSample { Tag(title: "샘플 후보") }
                Spacer()
                Text(StorageFormat.bytes(model.cleanupQueue.totalBytes)).fontWeight(.semibold)
                Text("할당 용량").foregroundStyle(Theme.muted)
            }.font(.system(size: 12))
            Text(model.cleanupQueue.rootPath).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).help(model.cleanupQueue.rootPath)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.cleanupQueue.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 26))
                            Text("정리 후보가 없습니다")
                            Text("파일 목록이나 차트에서 항목을 선택해 담아 주세요.").font(.system(size: 11))
                        }.foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(model.cleanupQueue.entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.kind == .folder ? "folder" : "doc").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(entry.path).font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.middle).help(entry.path)
                                if entry.kind == .folder {
                                    Text("하위 파일 \(entry.fileCount)개 포함").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(StorageFormat.bytes(entry.allocatedBytes)).font(.system(size: 11, design: .rounded)).fixedSize()
                            Button("앱에서 보기") { model.locateCleanup(entry.id) }
                                .accessibilityIdentifier("locate-cleanup-\(entry.id)")
                                .disabled(model.isTrashBusy)
                            Button("빼기") { model.removeCleanup(entry.id) }
                                .accessibilityLabel("\(entry.name) 정리 후보에서 빼기")
                                .accessibilityIdentifier("remove-cleanup-\(entry.id)")
                                .disabled(model.cleanupLocked)
                        }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            if let notice = model.cleanupNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(2)
            }
            Text("스캔 당시의 할당 용량 합계입니다. 하드 링크·공유 블록 때문에 실제 확보 공간과 다를 수 있습니다. 새 스캔 완료·샘플 전환·앱 종료 시 후보는 초기화됩니다.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("목록 비우기") { model.clearCleanup() }
                    .disabled(model.cleanupQueue.entries.isEmpty || model.cleanupLocked)
                    .accessibilityIdentifier("clear-cleanup")
                Spacer()
                if model.isPreparingTrash { ProgressView().controlSize(.small) }
                Button("휴지통으로 이동…") { model.askToTrash() }
                    .disabled(model.isSample || model.cleanupQueue.entries.isEmpty || model.cleanupLocked)
                    .accessibilityIdentifier("confirm-trash-review")
            }
            }
            if model.isTrashing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(model.trashProgress?.completed ?? 0) / \(model.trashProgress?.total ?? 0) · \(model.trashProgress?.name ?? "준비 중")")
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Button("남은 항목 중단") { model.stopTrash() }.accessibilityIdentifier("stop-trash")
                }
                Text("이미 시작한 항목은 완료한 뒤 결과에 표시합니다.").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(24).frame(width: 760, height: 600).background(Theme.background)
        .interactiveDismissDisabled(model.isTrashBusy)
        .alert("후보 \(model.cleanupQueue.entries.count)개를 휴지통으로 이동할까요?", isPresented: $model.isTrashConfirmation) {
            Button("취소", role: .cancel) { model.cancelTrashConfirmation() }
            Button("휴지통으로 이동", role: .destructive) { model.confirmTrash() }
        } message: {
            Text("검토한 전체 경로의 파일 \(model.cleanupQueue.fileCount)개, 할당 용량 \(StorageFormat.bytes(model.cleanupQueue.totalBytes))입니다. 폴더를 담았다면 그 안의 모든 항목을 포함합니다. 실행 직전 바뀐 항목은 건너뜁니다.\n\n휴지통을 비우기 전에는 공간이 확보되지 않을 수 있습니다. 영구 삭제는 실행하지 않습니다.")
        }
    }
}

private struct CleanupResultContent: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let report = model.trashReport {
            HStack {
                Text(report.summary).fontWeight(.semibold)
                Spacer()
                Text(report.completedAt, style: .time).foregroundStyle(Theme.muted)
            }.font(.system(size: 12))
            Text(report.rootPath).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("휴지통으로 옮긴 항목의 할당 용량").foregroundStyle(Theme.muted)
                    Text(StorageFormat.bytes(report.movedBytes)).font(.system(size: 20, design: .rounded))
                }
                Spacer()
                if let space = model.volumeSpace, model.root.path == report.rootPath {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("macOS가 보고한 디스크 여유 공간").foregroundStyle(Theme.muted)
                        Text(StorageFormat.bytes(space.availableBytes)).font(.system(size: 20, design: .rounded))
                    }
                }
            }.font(.system(size: 11))
            Text("이동한 용량은 확보된 공간이 아닙니다. 휴지통 비우기·복원은 Finder에서 직접 진행하세요.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(report.items) { result in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(result.outcome == .moved ? "이동 완료" : result.outcome == .failed ? "실패" : "건너뜀",
                                      systemImage: result.outcome == .moved ? "checkmark.circle" : "exclamationmark.triangle")
                                    .foregroundStyle(result.outcome == .moved ? .green : .orange)
                                Text(result.item.name).lineLimit(1)
                                Spacer()
                                Text(result.item.formattedSize).foregroundStyle(Theme.muted)
                            }.font(.system(size: 12))
                            Text(result.item.path).font(.system(size: 10)).lineLimit(2).textSelection(.enabled)
                            Text(result.message).font(.system(size: 10)).foregroundStyle(Theme.muted)
                            if let url = result.receipt?.trashURL {
                                Text("휴지통: \(url.path)").font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1).help(url.path)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            if model.isScanning {
                HStack { ProgressView().controlSize(.mini); Text("정리 후 폴더를 다시 스캔하고 있습니다.") }.font(.system(size: 11))
            } else if model.snapshotNeedsRefresh {
                Text("재스캔을 완료하지 못했습니다. 최신 목록을 확인하려면 다시 스캔하세요.").font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Text(model.cleanupNotice ?? "최근 실행 결과입니다.").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            HStack {
                Button("휴지통에서 보기") { model.showTrashInFinder() }
                    .disabled(report.moved.compactMap { $0.receipt?.trashURL }.isEmpty || model.isTrashBusy)
                    .accessibilityIdentifier("show-trash-results")
                Spacer()
                Button("여유 공간 새로고침") { model.refreshSpace() }
                    .disabled(model.isSample || model.isRefreshingSpace).accessibilityIdentifier("refresh-space-results")
                Button("다시 스캔") { model.startScan(URL(fileURLWithPath: report.rootPath)) }
                    .disabled(model.isScanning || model.isTrashBusy).accessibilityIdentifier("rescan-results")
            }
        } else {
            Spacer()
            Text("아직 휴지통 이동 결과가 없습니다.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            Spacer()
        }
    }
}
