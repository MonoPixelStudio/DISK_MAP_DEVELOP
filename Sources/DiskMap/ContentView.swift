import SwiftUI
import DiskMapCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                SidebarView().frame(width: 210)
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(spacing: 0) {
                    ScanStatusView()
                    HStack(spacing: 0) {
                        SunburstView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle().fill(Theme.line).frame(width: 1)
                        FileBrowserView().frame(width: 380)
                    }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            CleanupBarView()
        }
        .background(Theme.background)
        .frame(minWidth: 1120, minHeight: 740)
        .tint(Theme.accent)
        .sheet(isPresented: $model.isCleanupPresented) { CleanupReviewView().environmentObject(model) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 65, height: 1)
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 21)).foregroundStyle(Theme.accent)
            Text("DiskMap").font(.system(size: 17, weight: .semibold))
            Tag(title: model.isSample ? "샘플" : "폴더 분석")
            Spacer()
            Menu {
                if model.recentLocations.isEmpty { Text("최근 스캔 위치가 없습니다") }
                ForEach(model.recentLocations) { location in
                    Button(location.path) { model.startScan(URL(fileURLWithPath: location.path)) }
                }
                Divider()
                Button("최근 위치 목록 지우기") { model.clearRecentLocations() }
            } label: { Label("최근 위치", systemImage: "clock.arrow.circlepath") }
                .disabled(model.isScanning || model.isTrashBusy || model.isCleanupPresented)
                .accessibilityIdentifier("recent-locations")
            if model.isScanning {
                Button("스캔 취소") { model.cancelScan() }
                    .accessibilityIdentifier("cancel-scan")
            } else if let url = model.selectedFolderURL {
                Button { model.startScan(url) } label: {
                    Label("다시 스캔", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("rescan")
                .disabled(model.isTrashBusy)
            }
            Button { model.chooseFolder() } label: {
                Label("폴더 선택", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
            }
            .buttonStyle(.bordered).accessibilityIdentifier("choose-folder")
            .disabled(model.isScanning || model.isTrashBusy)
        }
        .padding(.horizontal, 18).frame(height: 62)
    }

}
