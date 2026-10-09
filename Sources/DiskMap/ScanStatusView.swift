import SwiftUI
import DiskMapCore

struct ScanStatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.scanFailed ? "exclamationmark.triangle" : "folder")
                        .foregroundStyle(model.scanFailed ? .orange : Theme.accent)
                }
                Text(model.scanMessage).lineLimit(2)
                Spacer(minLength: 6)
                if let summary = model.scanSummary, !model.isScanning, !model.scanFailed {
                    if summary.skippedItems > 0 {
                        Button("제외·오류·변경 \(summary.skippedItems)건") { showingIssues = true }
                            .buttonStyle(.borderless).foregroundStyle(.orange)
                            .accessibilityIdentifier("scan-issues")
                    }
                    Text("\(summary.processedItems)개 · \(summary.elapsedSeconds, specifier: "%.1f")초")
                        .foregroundStyle(Theme.muted).fixedSize()
                }
                Tag(title: model.isSample ? "샘플" : "실제 결과")
            }
            HStack(spacing: 8) {
                if model.isScanning, let progress = model.scanProgress {
                    Text("\(progress.processedItems)개 확인 · \(StorageFormat.bytes(progress.measuredBytes)) 집계")
                        .fixedSize()
                    Text(progress.currentPath).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(model.isSample ? "화면은 샘플입니다. 폴더를 선택하면 실제 용량을 분석합니다." : model.root.path)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(Theme.muted)
            if model.isScanning {
                Text("분석 중에는 이전 결과를 화면에 유지합니다.")
                    .foregroundStyle(Theme.muted)
            }
            if model.snapshotNeedsRefresh && !model.isScanning {
                Text("휴지통 이동 전의 목록입니다. 다시 스캔을 완료한 뒤 다음 정리를 진행하세요.")
                    .foregroundStyle(.orange)
            }
            if model.scanFailed {
                Text("폴더의 읽기 권한과 시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더를 확인해 주세요.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(minHeight: 70, alignment: .leading)
        .background(Theme.accent.opacity(0.045))
        .sheet(isPresented: $showingIssues) { issuesSheet }
    }

    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("스캔 제외·접근 오류·변경 감지").font(.headline)
                Spacer()
                Button("닫기") { showingIssues = false }.keyboardShortcut(.cancelAction)
            }
            Text("이 항목들의 용량은 0바이트로 판단하지 않습니다. 전체 건수와 최대 100개의 상세 경로를 표시합니다.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array((model.scanSummary?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text(issue.reason).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("권한으로 읽지 못한 경로는 폴더 자체의 읽기 권한과 시스템 설정의 개인정보 보호 및 보안 → 파일 및 폴더 접근 권한을 확인한 뒤 다시 스캔해 주세요.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(24).frame(width: 650, height: 450).background(Theme.background)
    }
}
