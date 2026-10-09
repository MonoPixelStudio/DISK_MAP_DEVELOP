import SwiftUI
import DiskMapCore

struct SunburstView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?
    @State private var selectedAggregateID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            breadcrumbs
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.currentFolder.name).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                    Text("안쪽부터 하위 폴더로 이어지는 용량 지도")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Picker("표시 깊이", selection: $model.chartDepth) {
                    ForEach(2...4, id: \.self) { Text("최대 \($0)층").tag($0) }
                }
                .labelsHidden().frame(width: 95).accessibilityLabel("차트 표시 깊이")
                .accessibilityIdentifier("chart-depth")
            }
            chart.frame(minHeight: 240, maxHeight: .infinity)
            legend
            information
            Text(model.currentFolder.status.isIncomplete ?
                 "부분 집계입니다. 제외·접근 불가 항목의 공간은 차트에 포함되지 않습니다." :
                 "0바이트 항목은 목록에서 확인하세요. 할당 용량은 실제 확보 가능한 공간과 다를 수 있어요.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .padding(24)
        .onChange(of: model.chartRevision) { hoveredID = nil; selectedAggregateID = nil }
        .onChange(of: model.selectedNodeID) { if model.selectedNodeID != nil { selectedAggregateID = nil } }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 7) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).disabled(model.breadcrumb.count < 2)
            .accessibilityLabel("상위 폴더로").accessibilityIdentifier("go-back")
            if model.breadcrumb.count > 3 {
                Menu {
                    ForEach(model.breadcrumb.dropLast(3)) { node in Button(node.name) { model.navigate(to: node) } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("앞쪽 경로")
            }
            ForEach(Array(model.breadcrumb.suffix(3).enumerated()), id: \.element.id) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted) }
                Button(node.name) { model.navigate(to: node) }
                    .buttonStyle(.plain).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(node.id == model.currentFolderID ? Color.white : Theme.muted)
                    .help(node.path)
            }
            Spacer(minLength: 0)
        }
    }

    private var chart: some View {
        GeometryReader { space in
            let side = max(0, min(space.size.width, space.size.height, 440))
            let geometry = SunburstGeometry(side: side, levels: model.chartLayout.levels)
            ZStack {
                if !model.isChartLoading && !model.chartLayout.sectors.isEmpty {
                    sectorCanvas(geometry: geometry)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    sectorInteractions(geometry: geometry)
                        .id(model.chartRevision)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                    hub(geometry: geometry)
                } else if model.isChartLoading {
                    ProgressView("차트 준비 중…").font(.system(size: 11)).tint(Theme.accent)
                } else {
                    Circle().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 7])).padding(16)
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 28, weight: .light))
                        Text(model.currentFolder.status.isIncomplete ? "확인된 할당 용량이 없습니다" :
                             model.currentFolder.children.isEmpty ? "비어 있는 폴더예요" : "표시할 할당 용량이 없습니다")
                            .font(.system(size: 12)).multilineTextAlignment(.center)
                        Text("0바이트·용량 미확인 항목은 목록에서 확인하세요.")
                            .font(.system(size: 10)).multilineTextAlignment(.center)
                    }.foregroundStyle(Theme.muted).padding(24)
                }
            }
            .frame(width: side, height: side)
            .position(x: space.size.width / 2, y: space.size.height / 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.chartRevision)
        }
    }

    private func sectorCanvas(geometry: SunburstGeometry) -> some View {
        Canvas { context, _ in
            let center = CGPoint(x: geometry.center, y: geometry.center)
            for depth in 1...geometry.levels {
                let radius = (geometry.innerRadius(at: depth) + geometry.outerRadius(at: depth)) / 2
                let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(circle, with: .color(Theme.panel), lineWidth: max(0, geometry.ringWidth - 2))
            }
            for sector in model.chartLayout.sectors {
                let shape = sectorPath(sector, geometry: geometry)
                let selected = sector.id == model.selectedChartSectorID || sector.id == selectedAggregateID
                let hovered = sector.id == hoveredID
                let opacity = sector.isAggregate ? 0.42 : max(0.58, 1 - Double(sector.depth - 1) * 0.12)
                context.fill(shape, with: .color(Theme.chartColor(sector.branchIndex).opacity(opacity)))
                if selected || hovered {
                    context.stroke(shape, with: .color(selected ? .white : Theme.accent), lineWidth: selected ? 2.5 : 1.5)
                }
                // Labels only where the arc has ample room; small sectors use hover/selection information.
                let middleRadius = (geometry.innerRadius(at: sector.depth) + geometry.outerRadius(at: sector.depth)) / 2
                let arcLength = (sector.visibleEnd - sector.visibleStart) * 2 * .pi * middleRadius
                if sector.depth <= 2, arcLength > 85, geometry.ringWidth > 30 {
                    let limit = min(10, max(3, Int(min(arcLength * 0.55, 85) / 10)))
                    let name = sector.name.count > limit ? String(sector.name.prefix(limit - 1)) + "…" : sector.name
                    let angle = (sector.startTurn + sector.endTurn) * .pi - .pi / 2
                    context.draw(Text(name).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.9)),
                                 at: CGPoint(x: center.x + cos(angle) * middleRadius, y: center.y + sin(angle) * middleRadius))
                }
            }
        }
        .frame(width: geometry.side, height: geometry.side)
    }

    private func sectorInteractions(geometry: SunburstGeometry) -> some View {
        ZStack {
            ForEach(model.chartLayout.sectors) { sector in
                let shape = sectorPath(sector, geometry: geometry)
                Button { activate(sector) } label: {
                    shape.fill(Color.clear).contentShape(shape)
                }
                .buttonStyle(.plain).contentShape(shape)
                .simultaneousGesture(TapGesture(count: 2).onEnded { open(sector) })
                .onHover { inside in
                    if inside { hoveredID = sector.id }
                    else if hoveredID == sector.id { hoveredID = nil }
                }
                .accessibilityLabel("\(sector.name), \(StorageFormat.bytes(sector.bytes)), \(percent(sector.bytes)), \(sector.depth)층")
                .accessibilityIdentifier("chart-sector-\(sector.id)")
                .accessibilityHint(sector.isAggregate ? "묶음의 포함 폴더를 확인합니다." : "선택하면 오른쪽 목록과 상세 정보에 표시합니다.")
                .help("\(sector.name) · \(StorageFormat.bytes(sector.bytes)) · 폴더 더블 클릭: 안으로 이동")
            }
        }
        .frame(width: geometry.side, height: geometry.side)
    }

    private func sectorPath(_ sector: SunburstSector, geometry: SunburstGeometry) -> Path {
        var path = Path()
        let center = CGPoint(x: geometry.center, y: geometry.center)
        let start = Angle.degrees(sector.visibleStart * 360 - 90)
        let end = Angle.degrees(sector.visibleEnd * 360 - 90)
        path.addArc(center: center, radius: geometry.outerRadius(at: sector.depth), startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: geometry.innerRadius(at: sector.depth), startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func hub(geometry: SunburstGeometry) -> some View {
        Button {
            if model.breadcrumb.count > 1 { model.goBack() }
            else { model.clearSelection(); selectedAggregateID = nil }
        } label: {
            VStack(spacing: 5) {
                Text(model.currentFolder.name).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                Text(model.currentFolder.formattedSize).font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(model.currentFolder.status.isIncomplete ? "부분 집계" : "\(model.currentFolder.fileCount)개 파일")
                    .font(.system(size: 8)).foregroundStyle(Theme.muted)
            }
            .frame(width: max(0, geometry.hubRadius * 2 - 12), height: max(0, geometry.hubRadius * 2 - 12))
            .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel("차트 중심, \(model.currentFolder.formattedSize), \(model.breadcrumb.count > 1 ? "상위 폴더로" : "선택 해제")")
        .accessibilityIdentifier("chart-go-back")
    }

    private var legend: some View {
        let roots = model.chartLayout.sectors.filter { $0.depth == 1 }
        return HStack(spacing: 10) {
            ForEach(roots.prefix(4)) { sector in
                Button { activate(sector) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.chartColor(sector.branchIndex).opacity(sector.isAggregate ? 0.42 : 1)).frame(width: 6, height: 6)
                        Text(sector.name).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                    }
                }.buttonStyle(.plain).help("\(sector.name) · \(StorageFormat.bytes(sector.bytes))")
            }
            if roots.count > 4 { Text("외 \(roots.count - 4)개").font(.system(size: 9)).foregroundStyle(Theme.muted).fixedSize() }
            Spacer(minLength: 0)
        }.frame(height: 16)
    }

    private var focusedSector: SunburstSector? {
        let id = hoveredID ?? selectedAggregateID
        return id.flatMap { id in model.chartLayout.sectors.first { $0.id == id } }
    }

    private var information: some View {
        let sector = focusedSector
        let node = sector == nil ? model.selectedNode : sector?.node
        let bytes = sector?.bytes ?? node?.totalBytes ?? model.currentFolder.totalBytes
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(sector?.name ?? node?.name ?? "현재 폴더 전체")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(node?.formattedSize ?? StorageFormat.bytes(bytes)).font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(node?.status.isIncomplete == true && bytes == 0 ? "미확인" : percent(bytes))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Text(sector?.path ?? node?.path ?? model.currentFolder.path)
                .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            if sector?.isAggregate == true {
                Text("작거나 표시 한도를 넘은 항목의 합계입니다. 포함 폴더의 목록에서 개별 항목을 확인하세요.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
            } else if let node, node.status.isIncomplete {
                Text(node.status.detail ?? node.status.label).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(spacing: 12) {
                if let groupID = selectedAggregateID,
                   let group = model.chartLayout.sectors.first(where: { $0.id == groupID }) {
                    Button("포함 폴더 목록 보기") { open(group) }
                        .accessibilityIdentifier("chart-open-group")
                } else if let selected = model.selectedNode {
                    if selected.isFolder {
                        Button("선택한 폴더 열기") { model.navigate(to: selected) }
                            .accessibilityIdentifier("chart-open-folder")
                    }
                    Button("목록에서 보기") { model.selectFromChart(selected) }
                        .accessibilityIdentifier("chart-show-in-list")
                } else {
                    Text("클릭하여 선택 · 폴더 더블 클릭하여 열기")
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Text("할당 용량 기준").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .padding(14).frame(minHeight: 92, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func percent(_ bytes: Int64) -> String {
        guard model.currentFolder.totalBytes > 0 else { return "—" }
        return String(format: "%.1f%%", Double(bytes) / Double(model.currentFolder.totalBytes) * 100)
    }

    private func activate(_ sector: SunburstSector) {
        hoveredID = nil
        if let node = sector.node { selectedAggregateID = nil; model.selectFromChart(node) }
        else { model.clearSelection(); selectedAggregateID = sector.id }
    }

    private func open(_ sector: SunburstSector) {
        if let node = sector.node {
            if node.isFolder { model.navigate(to: node) }
            else { activate(sector) }
        } else if let folder = model.root.node(withID: sector.parentID) {
            model.navigate(to: folder)
            model.resetBrowserFilters()
            model.browserQuery.includesDescendants = false
        }
    }
}
