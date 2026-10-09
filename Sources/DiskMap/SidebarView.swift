import SwiftUI
import DiskMapCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text("저장공간").font(.system(size: 10, weight: .semibold))
                .tracking(1.5).foregroundStyle(Theme.muted)
                .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 14)
            Button { model.navigate(to: model.root) } label: {
                HStack(spacing: 11) {
                    Image(systemName: "internaldrive").font(.system(size: 20)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isSample ? "나의 Mac" : model.root.name)
                            .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(model.isSample ? "샘플 저장공간" : "선택한 폴더")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }.padding(13)
                .background(Theme.accent.opacity(model.currentFolderID == model.root.id ? 0.13 : 0.04),
                            in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityIdentifier("sample-home").padding(.horizontal, 12)

            Text(model.isSample ? "샘플 폴더" : "하위 폴더").font(.system(size: 10, weight: .semibold))
                .tracking(1.5).foregroundStyle(Theme.muted)
                .padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 12)
            ForEach(model.sidebarFolders) { node in
                Button { model.navigate(to: node) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: node.category.symbol).frame(width: 18)
                            .foregroundStyle(Theme.color(for: node.category))
                        Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(node.formattedSize)
                            .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 12)
                    .background(model.breadcrumb.contains(where: { $0.id == node.id })
                                ? Color.white.opacity(0.055) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).accessibilityIdentifier("sidebar-\(node.id)")
                .padding(.horizontal, 12)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                    Text(model.isSample ? "샘플 미리보기" : "확인 후 휴지통 이동").font(.system(size: 11, weight: .medium))
                }
                Text(model.isSample ? "현재 화면은 가상의 파일로\n구성된 미리보기입니다." : "스캔은 읽기 전용입니다.\n검토·확인한 후보만 이동합니다.")
                    .font(.system(size: 10)).lineSpacing(4).foregroundStyle(Theme.muted)
            }
            .padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .padding(14)
            if !model.isSample {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("디스크 여유 공간").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button { model.refreshSpace() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(model.isRefreshingSpace)
                            .accessibilityLabel("디스크 여유 공간 새로고침").accessibilityIdentifier("refresh-space")
                    }
                    if let space = model.volumeSpace {
                        Text(StorageFormat.bytes(space.availableBytes)).font(.system(size: 19, design: .rounded))
                        Text("\(space.name) · 전체 \(StorageFormat.bytes(space.totalBytes))")
                            .font(.system(size: 9)).foregroundStyle(Theme.muted)
                        Text("조회 \(space.checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 9)).foregroundStyle(Theme.muted)
                    } else {
                        Text(model.isRefreshingSpace ? "조회 중…" : model.volumeMessage ?? "아직 조회하지 않았습니다.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Text("선택한 폴더와 같은 디스크의 macOS 보고값입니다.")
                        .font(.system(size: 9)).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 22).padding(.bottom, 14)
            }
            if let message = model.settingsMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(.orange).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Button("샘플 보기") { model.showSample() }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                .padding(.horizontal, 24).padding(.bottom, 12).disabled(model.isScanning || model.isTrashBusy)
            Text("DiskMap · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발")").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.6))
                .padding(.horizontal, 24).padding(.bottom, 20)
        }
        }
        .frame(maxHeight: .infinity).background(Theme.sidebar)
    }
}
