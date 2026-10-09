import SwiftUI
import DiskMapCore

struct FileBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.browserNodes) { node in nodeRow(node).id(node.id) }
                        if model.browserNodes.isEmpty { emptyState }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }
                .id(model.browserRevision)
                .onChange(of: model.browserSelectionRequest) {
                    Task { @MainActor in
                        await Task.yield()
                        if let id = model.selectedNodeID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            details.padding(18).frame(minHeight: 190, alignment: .topLeading)
        }
        .background(Theme.sidebar.opacity(0.5))
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .alert("Finder에서 위치 확인", isPresented: Binding(
            get: { model.fileActionError != nil }, set: { if !$0 { model.fileActionError = nil } }
        )) {
            Button("확인", role: .cancel) { model.fileActionError = nil }
        } message: { Text(model.fileActionError ?? "") }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("파일과 폴더").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Picker("정렬", selection: $model.browserQuery.sort) {
                        ForEach(BrowserSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(model.browserQuery.sort.label, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("목록 정렬").accessibilityIdentifier("browser-sort")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("파일 또는 폴더 이름 검색", text: $model.browserQuery.search)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .focused($searchFocused).accessibilityIdentifier("browser-search")
                    .onExitCommand { model.browserQuery.search = "" }
                if !model.browserQuery.search.isEmpty {
                    Button { model.browserQuery.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                        .accessibilityLabel("검색어 지우기").accessibilityIdentifier("clear-search")
                }
            }
            .padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Picker("검색 범위", selection: $model.browserQuery.includesDescendants) {
                    Text("현재 폴더").tag(false)
                    Text("하위 포함").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("browser-scope")
                Menu {
                    Picker("종류", selection: $model.browserQuery.kind) {
                        ForEach(BrowserKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("최소 할당 용량", selection: $model.browserQuery.minimumSize) {
                        ForEach(BrowserMinimumSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Toggle("숨김 항목 표시", isOn: $model.browserQuery.showsHidden)
                    Button("검색·필터 초기화") { model.resetBrowserFilters() }
                } label: {
                    Label("필터", systemImage: model.browserQuery.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("browser-filter")
            }
            HStack(spacing: 6) {
                if model.isFiltering { ProgressView().controlSize(.mini) }
                Text(model.isFiltering ? "목록 찾는 중…" : "\(model.browserNodes.count)개 항목 · \(model.dataLabel)")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("browser-count")
                Spacer(minLength: 0)
                if model.browserQuery.hasFilters {
                    Button("초기화") { model.resetBrowserFilters() }
                        .font(.system(size: 10)).buttonStyle(.plain)
                        .accessibilityIdentifier("reset-browser-filters")
                }
            }
            if model.browserQuery.kind != .all || model.browserQuery.minimumSize != .all || !model.browserQuery.showsHidden {
                Text([model.browserQuery.kind.label, model.browserQuery.minimumSize.label,
                      model.browserQuery.showsHidden ? nil : "숨김 제외"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(Theme.accent).lineLimit(2)
            }
            if let notice = model.browserNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.browserQuery.hasFilters ? "magnifyingglass" : "folder")
                .font(.system(size: 28, weight: .light))
            Text(model.isFiltering ? "목록을 준비하고 있어요" : model.browserQuery.hasFilters ? "일치하는 항목이 없습니다" :
                 model.currentFolder.status.isIncomplete ? "스캔하지 못한 폴더입니다" : "비어 있는 폴더예요")
                .font(.system(size: 12))
            if model.browserQuery.hasFilters && !model.isFiltering {
                Text("검색 이름, 종류, 최소 할당 용량을 확인해 주세요.")
                    .font(.system(size: 10)).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func nodeRow(_ node: FileNode) -> some View {
        let isCleanupCandidate = model.cleanupQueue.coverage(ofPath: node.path) != nil
        return HStack(spacing: 5) {
            Button { model.select(node) } label: {
                HStack(spacing: 10) {
                    Image(systemName: node.isFolder ? "folder.fill" : node.kind == .symbolicLink ? "link" : node.category.symbol)
                        .font(.system(size: 17)).foregroundStyle(Theme.color(for: node.category))
                        .frame(width: 28, height: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.name).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(node.status.isIncomplete ? node.status.label :
                             (node.isFolder ? "\(node.fileCount)개 파일" : (node.isDuplicateHardLink ? "하드 링크 · 중복 집계 제외" : "파일")))
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        if model.browserQuery.includesDescendants {
                            Text(relativeParent(of: node)).font(.system(size: 9)).foregroundStyle(Theme.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    if isCleanupCandidate {
                        Image(systemName: "tray.full.fill").foregroundStyle(Theme.accent)
                            .font(.system(size: 10)).accessibilityHidden(true)
                    }
                    Text(node.formattedSize)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.color(for: node.category)).fixedSize()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("select-\(node.id)")
            .accessibilityValue(isCleanupCandidate ? "정리 후보에 포함됨" : "")
            .accessibilityAddTraits(model.selectedNodeID == node.id ? .isSelected : [])
            if node.isFolder {
                Button { model.navigate(to: node) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted).frame(width: 23, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("\(node.name) 폴더 열기")
                .accessibilityLabel("\(node.name) 폴더 열기").accessibilityIdentifier("open-\(node.id)")
            } else { Color.clear.frame(width: 23, height: 36) }
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
        .background(model.selectedNodeID == node.id ? Theme.accent.opacity(0.1) : Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            if node.isFolder { Button("이 폴더로 이동") { model.navigate(to: node) } }
            Button("포함된 폴더로 이동") { model.select(node); model.navigateToSelectedParent() }
            Divider()
            Button(model.cleanupQueue.coverage(ofPath: node.path) == .direct ? "정리 목록에서 빼기" : "정리 목록에 담기") {
                model.toggleCleanup(node)
            }.disabled(model.cleanupLocked)
            Divider()
            Button("Finder에서 보기") { model.select(node); model.revealSelectedInFinder() }.disabled(model.isSample)
            Button("전체 경로 복사") { model.select(node); model.copySelectedPath() }.disabled(model.isSample)
        }
    }

    private func relativeParent(of node: FileNode) -> String {
        let parent = URL(fileURLWithPath: node.path).deletingLastPathComponent().path
        let prefix = model.currentFolder.path.hasSuffix("/") ? model.currentFolder.path : model.currentFolder.path + "/"
        return parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : "현재 폴더"
    }

    @ViewBuilder private var details: some View {
        if let node = model.selectedNode {
            VStack(alignment: .leading, spacing: 9) {
                Label(node.name, systemImage: node.isFolder ? "folder" : "doc")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(node.path).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                HStack {
                    Text(node.formattedSize).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Tag(title: model.isSample ? "샘플" : node.status.label, color: Theme.muted)
                }
                if let detail = node.status.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
                if !model.isSample, let logical = node.logicalBytes {
                    Text("파일 자체 크기: \(StorageFormat.bytes(logical))")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                if let modified = node.fingerprint?.modifiedAt {
                    Text("수정: \(modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                if node.isDuplicateHardLink {
                    Text("할당 용량은 같은 데이터의 최초 발견 항목에만 포함합니다.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 12) {
                    Button("Finder에서 보기") { model.revealSelectedInFinder() }
                        .disabled(model.isSample).accessibilityIdentifier("reveal-in-finder")
                        .help(model.isSample ? "실제 폴더를 스캔한 뒤 사용할 수 있습니다." : "Finder에서 이 항목의 위치를 표시합니다.")
                    Button("경로 복사") { model.copySelectedPath() }.disabled(model.isSample)
                        .accessibilityIdentifier("copy-path")
                }.font(.system(size: 10)).buttonStyle(.bordered)
                Button("포함된 폴더로 이동") { model.navigateToSelectedParent() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("navigate-to-parent")
                SelectedCleanupControl()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("항목 자세히 보기", systemImage: "info.circle").font(.system(size: 12, weight: .medium))
                Text("항목을 선택하면 경로와 용량을 보여 줍니다. 하위 포함으로 검색하면 안쪽 폴더의 파일도 찾을 수 있어요.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                Text("검색과 필터는 오른쪽 목록에 적용됩니다.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }
}
