import SwiftUI
import UniformTypeIdentifiers

let rowHeight: CGFloat = 20
let frameWidth: CGFloat = 8
let layerPanelWidth: CGFloat = 190
let layerIconColWidth: CGFloat = 18

struct TimelineView: View {
    @Bindable var doc: TimelineDocument
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
                    ColorPicker("", selection: doc.undoableBinding(\.stageColor, coalesce: "stageColor")).labelsHidden()
                }

                HStack(spacing: 6) {
                    Text("Frame rate:").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: doc.undoableBinding(\.fps, coalesce: "fps"), formatter: Self.fpsFormatter)
                            .frame(width: 34)
                            .textFieldStyle(.roundedBorder)
                        Text("fps").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    Button(action: { doc.onionSkinEnabled.toggle() }) {
                        Image(systemName: "square.stack")
                            .foregroundStyle(doc.onionSkinEnabled ? Color.accentColor : Color.secondary)
                    }
                    .help("Onion Skin — ghost nearby frames' content on the Stage")
                    if doc.onionSkinEnabled {
                        Stepper(value: $doc.onionSkinRange, in: 1...5) {
                            Text("±\(doc.onionSkinRange)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .help("Frames before/after the playhead to ghost")
                        .fixedSize()
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
                        doc.withUndoSnapshot {
                            doc.stageWidth = w
                            doc.stageHeight = h
                        }
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
    let doc: TimelineDocument
    let layer: TLLayer
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
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 0.5))
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
        }
    }
}

// MARK: - Ruler

struct RulerView: View {
    let doc: TimelineDocument
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
    let doc: TimelineDocument
    let layer: TLLayer
    let frameCount: Int

    var body: some View {
        // Frame -> its tween's start frame, for every frame that's a
        // tween's end keyframe — lets each cell know whether (and how far
        // back) it's allowed to be dragged.
        let tweenEndStarts: [Int: Int] = Dictionary(uniqueKeysWithValues: tweenSpans.map { ($0.end, $0.start) })

        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<frameCount, id: \.self) { i in
                    FrameCellSlot(doc: doc, layer: layer, frame: i + 1, columnIndex: i,
                                  tweenEndStart: tweenEndStarts[i + 1])
                }
            }
            tweenArrows
                .allowsHitTesting(false) // decorative — must not steal taps/double-clicks from the cells underneath
            frameLabelFlags
                .allowsHitTesting(false)
            // playhead line through this row
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 1, height: rowHeight)
                .offset(x: CGFloat(doc.playhead - 1) * frameWidth + frameWidth / 2 - 0.5)
        }
    }

    /// Every `.tween` run on this layer, as the (start, end) keyframes that
    /// bracket it — used to draw the connecting arrow.
    private var tweenSpans: [(start: Int, end: Int)] {
        var spans: [(Int, Int)] = []
        for (idx, mark) in layer.frames.enumerated() {
            switch mark {
            case .keyframe, .emptyKeyframe:
                let f = idx + 1
                if let end = layer.tweenTarget(from: f) { spans.append((f, end)) }
            default: break
            }
        }
        return spans
    }

    /// Every labeled keyframe on this layer, sorted so the flags always
    /// draw left to right regardless of `frameLabels`' (unspecified)
    /// dictionary iteration order.
    private var labeledFrames: [(frame: Int, text: String)] {
        layer.frameLabels.sorted { $0.key < $1.key }.map { (frame: $0.key, text: $0.value) }
    }

    /// A small red flag + the label text, Flash's own frame-label glyph —
    /// anchored at the labeled frame's left edge and allowed to overflow
    /// into the cells after it (there's no room for real text in an 8pt
    /// frame column), same as `tweenArrows`' decorative overlay.
    private var frameLabelFlags: some View {
        ForEach(labeledFrames, id: \.frame) { item in
            HStack(spacing: 2) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.red)
                Text(item.text)
                    .font(.system(size: 8))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            .offset(x: CGFloat(item.frame - 1) * frameWidth + 2, y: 1)
        }
    }

    private var tweenArrows: some View {
        // Keep clear of both dots (they're 5-7pt circles centered on their
        // cells) — the shaft starts after the start dot and the arrowhead's
        // tip stops before the end dot, never drawing over either.
        let dotClearance: CGFloat = 6
        let arrowSize: CGFloat = 6
        return ForEach(tweenSpans.indices, id: \.self) { i in
            let span = tweenSpans[i]
            let startX = CGFloat(span.start - 1) * frameWidth + frameWidth / 2 + dotClearance
            let endX = CGFloat(span.end - 1) * frameWidth + frameWidth / 2 - dotClearance
            let shaftWidth = max(0, endX - startX - arrowSize)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.65)).frame(width: shaftWidth, height: 1)
                Path { path in
                    // Coordinates local to this shape's own 0...arrowSize
                    // frame (not centered-at-origin) — Path draws in its
                    // frame's own top-left-origin space, so a triangle
                    // spanning y: -3...3 was actually drawn 3pt above the
                    // frame's true vertical center, not centered within it.
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: arrowSize, y: arrowSize / 2))
                    path.addLine(to: CGPoint(x: 0, y: arrowSize))
                    path.closeSubpath()
                }
                .fill(Color.black.opacity(0.65))
                .frame(width: arrowSize, height: arrowSize)
                .offset(x: shaftWidth)
            }
            .frame(height: rowHeight, alignment: .center)
            .offset(x: startX)
        }
    }
}

/// One frame cell plus its gestures — its own view (rather than inline in
/// FrameRowView's ForEach) so it can own `dragTranslationFrames` as local
/// state for sliding a tween's end keyframe.
private struct FrameCellSlot: View {
    let doc: TimelineDocument
    let layer: TLLayer
    let frame: Int
    let columnIndex: Int
    /// Non-nil, and equal to this tween's start frame, when this cell is a
    /// tween's end keyframe — the one thing that's draggable, and only to
    /// frames after that start.
    let tweenEndStart: Int?

    // Local-only during the drag — the model isn't touched until onEnded,
    // so the gesture stays attached to a stable, unchanging view the whole
    // time (mutating layer.frames mid-drag would swap this cell's own mark
    // out from under the very gesture recognizer tracking the drag).
    @State private var dragTranslationFrames: Int = 0

    var body: some View {
        FrameCellView(
            mark: columnIndex < layer.frames.count ? layer.frames[columnIndex] : .empty,
            columnIndex: columnIndex,
            dimmed: layer.hidden,
            isSelected: doc.selectedLayerID == layer.id && doc.selectedFrameRange.contains(frame)
        )
        .frame(width: frameWidth, height: rowHeight)
        .contentShape(Rectangle())
        .opacity(dragTranslationFrames != 0 ? 0.4 : 1.0)
        .onTapGesture(count: 2) {
            doc.selectFrame(layer: layer, frame: frame, extend: false)
            doc.insertKeyframe(layer: layer, at: frame, blank: false)
        }
        // simultaneousGesture instead of a second onTapGesture(count: 1):
        // stacking two exclusive tap-count gestures forces SwiftUI to
        // wait out the double-click window before committing to "single
        // click," which is exactly the ~1s selection delay this fixes.
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                doc.selectFrame(layer: layer, frame: frame, extend: NSEvent.modifierFlags.contains(.shift))
            }
        )
        .simultaneousGesture(tweenEndDrag)
        .contextMenu {
            Button("Insert Frame") { doc.insertFrame(layer: layer, at: frame) }
            Button("Insert Keyframe") { doc.insertKeyframe(layer: layer, at: frame, blank: false) }
            Button("Insert Blank Keyframe") { doc.insertKeyframe(layer: layer, at: frame, blank: true) }
            Divider()
            Button("Clear Frame", role: .destructive) { doc.clearFrame(layer: layer, at: frame) }
            Divider()
            Button("Create Tween") {
                let r = doc.selectedFrameRange
                doc.createTween(layer: layer, from: r.lowerBound, to: r.upperBound)
            }
            .disabled(doc.selectedLayerID != layer.id || doc.selectedFrameRange.count < 2)
            Button("Remove Tween") { doc.removeTween(layer: layer, at: frame) }
                .disabled(layer.governingKeyframe(at: frame).flatMap { layer.tweenTarget(from: $0) } == nil)
            Divider()
            Button("Copy Text") { doc.copySelectedPlacement() }
                .disabled(doc.selectedPlacement == nil)
            Button("Paste Text") { doc.pastePlacedText(layer: layer, at: frame) }
                .disabled(!doc.hasCopiedText)
            Divider()
            Button("Copy Frames") { doc.copySelectedFrames() }
                .disabled(doc.selectedLayerID != layer.id)
            Button("Paste Frames") { doc.pasteFrames(layer: layer, at: frame) }
                .disabled(!doc.hasCopiedFrames)
        }
    }

    /// No-ops entirely on any cell that isn't a tween's end keyframe.
    private var tweenEndDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard tweenEndStart != nil else { return }
                dragTranslationFrames = Int((value.translation.width / frameWidth).rounded())
            }
            .onEnded { value in
                guard let tweenEndStart else { return }
                let deltaFrames = Int((value.translation.width / frameWidth).rounded())
                // +2, not +1: a tween needs at least one interior .tween
                // frame to still register as a tween at all (that's the
                // model's only signal linking the two keyframes) — landing
                // right next to the start would silently turn it into two
                // disconnected keyframes instead of the shortest valid tween.
                let candidate = max(tweenEndStart + 2, frame + deltaFrames)
                dragTranslationFrames = 0
                if candidate != frame {
                    doc.moveTweenEnd(layer: layer, from: frame, to: candidate)
                }
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
        case .tween: return Color(red: 0.72, green: 0.65, blue: 0.95).opacity(0.55)
        case .plain, .spanEnd: return Color.gray.opacity(0.12)
        default: return (columnIndex / 5) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(isSelected ? Color.accentColor.opacity(0.3) : bandColor)
            if isSelected {
                Rectangle().stroke(Color.accentColor, lineWidth: 1)
            }
            // Skip the per-cell divider across a tween span — with every
            // cell tinted, these read as a row of unwanted vertical bars
            // instead of the plain grid they are elsewhere.
            if mark != .tween {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
            }

            switch mark {
            case .keyframe(let hasScript):
                Circle().fill(Color.primary).frame(width: 5, height: 5)
                if hasScript {
                    Circle().stroke(Color.orange, lineWidth: 1).frame(width: 7, height: 7).offset(y: -6)
                }
            case .emptyKeyframe:
                Circle().stroke(Color.primary, lineWidth: 1).frame(width: 5, height: 5)
            case .spanEnd:
                Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1).frame(width: 4, height: 4)
            case .tween, .plain, .empty:
                EmptyView()
            }
        }
        .opacity(dimmed ? 0.4 : 1.0)
    }
}
