import SwiftUI
import UniformTypeIdentifiers

let rowHeight: CGFloat = 20
let frameWidth: CGFloat = 8
let layerPanelWidth: CGFloat = 190
let layerIconColWidth: CGFloat = 18

struct TimelineView: View {
    @ObservedObject var doc: TimelineDocument
    @State private var showingSizePopover = false
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        GeometryReader { geo in
            let frameCount = visibleFrameCount(forTotalWidth: geo.size.width)
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        layerPanel
                        Divider()
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                RulerView(doc: doc, frameCount: frameCount)
                                ForEach(doc.visibleLayers) { layer in
                                    FrameRowView(doc: doc, layer: layer, frameCount: frameCount)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                Divider()
                bottomBar
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Frames drawn always cover at least the document's real frame count,
    /// but stretch further to keep filling the grid as the window widens.
    private func visibleFrameCount(forTotalWidth totalWidth: CGFloat) -> Int {
        let gridWidth = totalWidth - layerPanelWidth - 2
        let fitCount = Int((gridWidth / frameWidth).rounded(.up))
        return max(doc.totalFrames, fitCount)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down").font(.system(size: 9))
            Text("Timeline").font(.system(size: 11, weight: .semibold))
            Spacer()
            Image(systemName: "square.grid.2x2").font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    private var layerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header row for eye / lock / color columns — the trailing
            // cluster's widths/spacing must exactly match LayerRowView's for
            // the columns to actually line up.
            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    Image(systemName: "eye").font(.system(size: 9)).frame(width: layerIconColWidth)
                    Image(systemName: "lock").font(.system(size: 9)).frame(width: layerIconColWidth)
                    Color.clear.frame(width: layerIconColWidth, height: 1)
                }
            }
            .frame(height: rowHeight)
            .padding(.trailing, 4)

            ForEach(doc.visibleLayers) { layer in
                LayerRowView(doc: doc, layer: layer)
            }

            // Drop here to pull a layer out to the top level (root, end of list).
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                        guard let raw = reading as? String, let uuid = UUID(uuidString: raw) else { return }
                        DispatchQueue.main.async {
                            doc.moveLayer(id: uuid, beforeLayerID: nil, indent: 0)
                        }
                    }
                    return true
                }
        }
        .frame(width: layerPanelWidth, alignment: .leading)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Button(action: { doc.addLayer() }) { Image(systemName: "plus.square") }
                Button(action: { doc.addFolder() }) { Image(systemName: "folder.badge.plus") }
                Button(action: {}) { Image(systemName: "person.crop.square.badge.camera") }
                Spacer(minLength: 0)
                Button(action: { doc.deleteSelectedLayer() }) { Image(systemName: "trash") }
                    .disabled(doc.selectedLayerID == nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .frame(width: layerPanelWidth)

            Divider().frame(height: 16)

            HStack(spacing: 10) {
                Button(action: { doc.gotoAndStop(1) }) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: { doc.gotoAndStop(max(1, doc.playhead - 1)) }) {
                    Image(systemName: "backward.frame.fill")
                }
                Button(action: { doc.togglePlay() }) {
                    Image(systemName: doc.isPlaying ? "stop.fill" : "play.fill")
                }
                Button(action: { doc.gotoAndStop(min(doc.totalFrames, doc.playhead + 1)) }) {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.plain)

                TextField("", value: $doc.playhead, formatter: NumberFormatter())
                    .frame(width: 34)
                    .textFieldStyle(.roundedBorder)

                Text(String(format: "%.1fs", doc.elapsedSeconds))
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                Divider().frame(height: 16)

                HStack(spacing: 6) {
                    Text("Size:").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("\(Int(doc.stageWidth)) x \(Int(doc.stageHeight)) px") {
                        widthText = "\(Int(doc.stageWidth))"
                        heightText = "\(Int(doc.stageHeight))"
                        showingSizePopover = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .popover(isPresented: $showingSizePopover) { sizePopoverContent }
                }

                HStack(spacing: 8) {
                    Text("Background:").font(.system(size: 11)).foregroundStyle(.secondary)
                    ColorPicker("", selection: $doc.stageColor).labelsHidden()
                }

                HStack(spacing: 6) {
                    Text("Frame rate:").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $doc.fps, formatter: Self.fpsFormatter)
                            .frame(width: 34)
                            .textFieldStyle(.roundedBorder)
                        Text("fps").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var sizePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Document Properties").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Text("Width:").font(.system(size: 11)).fixedSize().frame(width: 44, alignment: .leading)
                TextField("", text: $widthText).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("px").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            HStack(spacing: 6) {
                Text("Height:").font(.system(size: 11)).fixedSize().frame(width: 44, alignment: .leading)
                TextField("", text: $heightText).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("px").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { showingSizePopover = false }
                Button("OK") {
                    if let w = Double(widthText), let h = Double(heightText), w > 0, h > 0 {
                        doc.stageWidth = w
                        doc.stageHeight = h
                    }
                    showingSizePopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 230)
    }

    private static let fpsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        return f
    }()
}

// MARK: - Layer panel row

struct LayerRowView: View {
    @ObservedObject var doc: TimelineDocument
    @ObservedObject var layer: TLLayer
    @State private var isDropTarget = false

    var isSelected: Bool { doc.selectedLayerID == layer.id }

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(layer.indent) * 12)

            if layer.kind == .folder {
                Image(systemName: layer.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                    .onTapGesture { doc.toggleExpanded(layer) }
            }

            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(layer.swatch)
                .frame(width: 14)

            Text(layer.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Matches the header's trailing cluster exactly (same widths,
            // same zero spacing) so the columns actually line up.
            HStack(spacing: 0) {
                Image(systemName: layer.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 9))
                    .frame(width: layerIconColWidth)
                    .onTapGesture { layer.hidden.toggle() }

                Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 9))
                    .frame(width: layerIconColWidth)
                    .onTapGesture { layer.locked.toggle() }

                Rectangle()
                    .fill(layer.swatch)
                    .frame(width: 12, height: 12)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                    .frame(width: layerIconColWidth)
            }
        }
        .padding(.trailing, 4)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDropTarget ? Color.accentColor.opacity(0.35) : (isSelected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { doc.selectedLayerID = layer.id })
        .onDrag {
            NSItemProvider(object: layer.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                guard let raw = reading as? String, let uuid = UUID(uuidString: raw) else { return }
                DispatchQueue.main.async {
                    if layer.kind == .folder {
                        doc.reparent(id: uuid, intoFolder: layer)
                    } else {
                        doc.moveLayer(id: uuid, beforeLayerID: layer.id, indent: layer.indent)
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button("Add Layer") { doc.addLayer() }
            Button("Add Folder") { doc.addFolder() }
            Divider()
            Button("Delete Layer", role: .destructive) { doc.deleteLayer(layer) }
        }
    }

    private var iconName: String {
        switch layer.kind {
        case .normal: return "square.on.square"
        case .folder: return "folder.fill"
        case .mask: return "circle.lefthalf.filled"
        case .maskedGuide: return "square.dashed"
        case .guide: return "line.diagonal"
        }
    }
}

// MARK: - Ruler

struct RulerView: View {
    @ObservedObject var doc: TimelineDocument
    let frameCount: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(1...frameCount, id: \.self) { frame in
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill((frame - 1) / 5 % 2 == 0 ? Color(nsColor: .controlBackgroundColor)
                                                            : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        if frame % 5 == 1 {
                            Text("\(frame)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .offset(x: 1)
                                .zIndex(1)
                        }
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
                    }
                    .frame(width: frameWidth, height: rowHeight)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)

            playheadFlag
        }
        .frame(height: rowHeight)
    }

    private var playheadFlag: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.red)
            .frame(width: frameWidth + 2, height: rowHeight - 6)
            .overlay(
                Text("\(doc.playhead)").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            )
            .offset(x: CGFloat(doc.playhead - 1) * frameWidth - 1, y: 3)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let frame = Int(value.location.x / frameWidth) + 1
            doc.gotoAndStop(min(max(frame, 1), doc.totalFrames))
        }
    }
}

// MARK: - Per-layer frame row

struct FrameRowView: View {
    @ObservedObject var doc: TimelineDocument
    @ObservedObject var layer: TLLayer
    let frameCount: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<frameCount, id: \.self) { i in
                    FrameCellView(
                        mark: i < layer.frames.count ? layer.frames[i] : .empty,
                        columnIndex: i,
                        dimmed: layer.hidden,
                        isSelected: doc.selectedLayerID == layer.id && doc.selectedFrame == i + 1
                    )
                    .frame(width: frameWidth, height: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        doc.selectedLayerID = layer.id
                        doc.insertKeyframe(layer: layer, at: i + 1, blank: false)
                        doc.gotoAndStop(i + 1)
                    }
                    // simultaneousGesture instead of a second onTapGesture(count: 1):
                    // stacking two exclusive tap-count gestures forces SwiftUI to
                    // wait out the double-click window before committing to "single
                    // click," which is exactly the ~1s selection delay this fixes.
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            doc.selectedLayerID = layer.id
                            doc.gotoAndStop(i + 1)
                        }
                    )
                    .contextMenu {
                        Button("Insert Frame") { doc.insertFrame(layer: layer, at: i + 1) }
                        Button("Insert Keyframe") { doc.insertKeyframe(layer: layer, at: i + 1, blank: false) }
                        Button("Insert Blank Keyframe") { doc.insertKeyframe(layer: layer, at: i + 1, blank: true) }
                        Divider()
                        Button("Clear Frame", role: .destructive) { doc.clearFrame(layer: layer, at: i + 1) }
                    }
                }
            }
            // playhead line through this row
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 1, height: rowHeight)
                .offset(x: CGFloat(doc.playhead - 1) * frameWidth + frameWidth / 2 - 0.5)
        }
    }
}

struct FrameCellView: View {
    let mark: FrameMark
    let columnIndex: Int
    let dimmed: Bool
    var isSelected: Bool = false

    private var bandColor: Color {
        switch mark {
        case .tween, .plain, .spanEnd: return Color.gray.opacity(0.12)
        default: return (columnIndex / 5) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(isSelected ? Color.accentColor.opacity(0.3) : bandColor)
            if isSelected {
                Rectangle().stroke(Color.accentColor, lineWidth: 1)
            }
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)

            switch mark {
            case .keyframe(let hasScript):
                Circle().fill(Color.black).frame(width: 5, height: 5)
                if hasScript {
                    Circle().stroke(Color.orange, lineWidth: 1).frame(width: 7, height: 7).offset(y: -6)
                }
            case .emptyKeyframe:
                Circle().stroke(Color.black, lineWidth: 1).frame(width: 5, height: 5)
            case .spanEnd:
                Circle().stroke(Color.black.opacity(0.6), lineWidth: 1).frame(width: 4, height: 4)
            case .tween, .plain, .empty:
                EmptyView()
            }
        }
        .opacity(dimmed ? 0.4 : 1.0)
    }
}
