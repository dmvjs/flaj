import SwiftUI
import UniformTypeIdentifiers

let rowHeight: CGFloat = 20
let frameWidth: CGFloat = 8
let layerPanelWidth: CGFloat = 190
let layerIconColWidth: CGFloat = 18

/// The thin horizontal rule Flash draws between every layer row — shared by
/// `LayerRowView` and `FrameRowView` so the line lands at the same height
/// in both the layer-name panel and the frame grid beside it.
var layerRowDivider: some View {
    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
}

struct TimelineView: View {
    @Bindable var doc: TimelineDocument

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
                        // This ScrollView has no explicit height of its own
                        // (it's sized by its content, inside the outer
                        // vertical ScrollView), which leaves its horizontal
                        // scroll indicator with no well-defined place to
                        // sit — it was rendering as a bar tall enough to
                        // dominate a single 20pt frame row. Trackpad/mouse-
                        // wheel horizontal scrolling still works with the
                        // indicator hidden; nothing else did.
                        .scrollIndicators(.hidden, axes: .horizontal)
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

                // Deliberately `text:`, not `value:formatter:` — every
                // variant of the value/formatter initializer tried here
                // (fresh NumberFormatter() per render, one shared static
                // instance, a hand-built Binding instead of `$doc.playhead`)
                // still left this field permanently rendered as if it were
                // being edited, even with nothing in the window actually
                // focused (confirmed via the accessibility tree). A plain
                // text Binding with manual Int parsing doesn't have
                // whatever internal state `value:formatter:` was getting
                // stuck in, and behaves identically for the user.
                TextField("", text: Binding(
                    get: { String(doc.playhead) },
                    set: { if let v = Int($0) { doc.playhead = v } }
                ))
                    .frame(width: 34)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focusEffectDisabled()

                Text(String(format: "%.1fs", doc.elapsedSeconds))
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    Button(action: { doc.onionSkinEnabled.toggle() }) {
                        Image(systemName: "square.stack")
                            .foregroundStyle(doc.onionSkinEnabled ? Color.accentColor : Color.secondary)
                    }
                    .help("Onion Skin — ghost nearby frames' content on the Stage")
                    if doc.onionSkinEnabled {
                        // A plain Stepper is a full-size native control —
                        // visibly bulky next to this bar's tiny icon
                        // buttons regardless of controlSize. Two small
                        // plain buttons match the bar's own scale instead.
                        HStack(spacing: 3) {
                            Button(action: { doc.onionSkinRange = max(1, doc.onionSkinRange - 1) }) {
                                Image(systemName: "minus").font(.system(size: 8))
                            }
                            .disabled(doc.onionSkinRange <= 1)
                            Text("±\(doc.onionSkinRange)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Button(action: { doc.onionSkinRange = min(5, doc.onionSkinRange + 1) }) {
                                Image(systemName: "plus").font(.system(size: 8))
                            }
                            .disabled(doc.onionSkinRange >= 5)
                        }
                        .buttonStyle(.plain)
                        .help("Frames before/after the playhead to ghost")
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

}

// MARK: - Layer panel row

struct LayerRowView: View {
    let doc: TimelineDocument
    let layer: TLLayer
    @State private var isDropTarget = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var nameFieldFocused: Bool

    var isSelected: Bool { doc.selectedLayerID == layer.id }

    var body: some View {
        HStack(spacing: 4) {
            // The extra 10pt for a masked layer is independent of
            // `layer.indent` (folder nesting) — masking is its own
            // relationship, not a change to where this layer sits in the
            // folder hierarchy, but Flash's own visual convention (a
            // masked layer's row indented under its mask) is worth
            // reproducing even without touching that field.
            Spacer().frame(width: CGFloat(layer.indent) * 12 + (layer.masked ? 10 : 0))

            if layer.kind == .folder {
                Image(systemName: layer.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                    .onTapGesture { doc.toggleExpanded(layer) }
            }

            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(layer.masked ? AnyShapeStyle(.secondary) : AnyShapeStyle(layer.swatch))
                .frame(width: 14)

            if isEditingName {
                TextField("", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($nameFieldFocused)
                    .onAppear { nameFieldFocused = true }
                    .onSubmit { commitRename() }
                    .onExitCommand { isEditingName = false } // Escape cancels, doesn't commit
                    .onChange(of: nameFieldFocused) { _, focused in
                        // Clicking away also commits (Finder-style rename)
                        // — guarded on isEditingName so this doesn't
                        // re-fire commitRename() a second time after
                        // onSubmit/onExitCommand already resolved it (both
                        // set isEditingName = false first, which removes
                        // this TextField and drops focus as a side effect).
                        if !focused && isEditingName { commitRename() }
                    }
            } else {
                Text(layer.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        editedName = layer.name
                        isEditingName = true
                    }
            }

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
        .overlay(alignment: .bottom) { layerRowDivider }
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
            // A mask can't itself be masked, and a masked layer can't
            // itself become a mask — same rule TimelineDocument.
            // toggleLayerMask/toggleLayerMasked enforce, mirrored here so
            // the disabled state actually explains why nothing happens.
            Toggle("Mask", isOn: Binding(get: { layer.kind == .mask }, set: { _ in doc.toggleLayerMask(layer) }))
                .disabled(layer.masked)
            Toggle("Masked", isOn: Binding(get: { layer.masked }, set: { _ in doc.toggleLayerMasked(layer) }))
                .disabled(layer.kind == .mask)
            Divider()
            Button("Delete Layer", role: .destructive) { doc.deleteLayer(layer) }
        }
    }

    /// A blank/whitespace-only name is rejected (falls back to the layer's
    /// existing name) rather than left empty — an unlabeled layer row
    /// isn't a state this app should be able to get into via renaming.
    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != layer.name {
            doc.withUndoSnapshot { layer.name = trimmed }
        }
        isEditingName = false
    }

    private var iconName: String {
        switch layer.kind {
        case .normal: return "square.on.square"
        case .folder: return "folder.fill"
        case .mask: return "theatermasks.fill"
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

            playheadFlag
        }
        .frame(height: rowHeight)
        // On the outer ZStack, not just the tick-mark HStack: the red
        // playhead flag is drawn as a sibling on top of it with no gesture
        // of its own, and being an opaque shape it was blocking clicks
        // from reaching the gesture underneath instead of forwarding them
        // — you could drag anywhere on the ruler except the flag itself.
        .contentShape(Rectangle())
        .gesture(dragGesture)
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

    // Which frame a tween-end drag in progress on this row would land on —
    // scoped to the row (not TimelineDocument) deliberately: a dragged
    // cell's own body reads this to highlight the target, and mutating an
    // `@Observable` property from inside a gesture that same body defines
    // can redefine the gesture mid-drag and drop its tracking. Plain
    // `@State` read through a `Binding` doesn't have that problem.
    @State private var tweenDragTargetFrame: Int?

    var body: some View {
        // Frame -> its tween's start frame, for every frame that's a
        // tween's end keyframe — lets each cell know whether (and how far
        // back) it's allowed to be dragged.
        let tweenEndStarts: [Int: Int] = Dictionary(uniqueKeysWithValues: tweenSpans.map { ($0.end, $0.start) })
        let spanKinds = tweenSpanKinds

        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<frameCount, id: \.self) { i in
                    FrameCellSlot(doc: doc, layer: layer, frame: i + 1, columnIndex: i,
                                  tweenEndStart: tweenEndStarts[i + 1], tweenKind: spanKinds[i + 1],
                                  dropTargetFrame: $tweenDragTargetFrame)
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
        .overlay(alignment: .bottom) { layerRowDivider }
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

    /// Every frame inside a tween span, mapped to whether that span is
    /// tweening a shape (Flash's green-tinted "shape tween") or anything
    /// else (Flash's blue "motion tween") — Flaj's four content dictionaries
    /// are strictly mutually exclusive per keyframe, so checking
    /// `shapeFrames` at the span's start keyframe is enough to tell them
    /// apart.
    private var tweenSpanKinds: [Int: TweenSpanKind] {
        var kinds: [Int: TweenSpanKind] = [:]
        for span in tweenSpans {
            let kind: TweenSpanKind = layer.shapeFrames[span.start] != nil ? .shape : .motion
            for f in span.start...span.end { kinds[f] = kind }
        }
        return kinds
    }

    /// Every labeled keyframe on this layer, sorted so the flags always
    /// draw left to right regardless of `frameLabels`' (unspecified)
    /// dictionary iteration order.
    private var labeledFrames: [(frame: Int, label: FrameLabel)] {
        layer.frameLabels.sorted { $0.key < $1.key }.map { (frame: $0.key, label: $0.value) }
    }

    /// Flash's own frame-label glyphs — a red flag for a Name, a small
    /// anchor for an Anchor, and (unlike Flash, which draws these as a
    /// literal "//") a dimmed comment-bubble icon for a Comment, since a
    /// 6pt "//" doesn't read at this scale. Anchored at the labeled frame's
    /// left edge and allowed to overflow into the cells after it (there's
    /// no room for real text in an 8pt frame column), same as
    /// `tweenArrows`' decorative overlay.
    private var frameLabelFlags: some View {
        ForEach(labeledFrames, id: \.frame) { item in
            HStack(spacing: 2) {
                switch item.label.type {
                case .name:
                    Image(systemName: "flag.fill").foregroundStyle(.red)
                case .anchor:
                    Image(systemName: "anchor").foregroundStyle(.blue)
                case .comment:
                    Image(systemName: "text.bubble.fill").foregroundStyle(.secondary)
                }
                Text(item.label.text)
                    .font(.system(size: 8))
                    .foregroundStyle(item.label.type == .comment ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .italic(item.label.type == .comment)
                    .fixedSize()
            }
            .font(.system(size: 6))
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
/// FrameRowView's ForEach) so it can own its drag-local state for sliding a
/// tween's end keyframe or repositioning a plain one.
private struct FrameCellSlot: View {
    let doc: TimelineDocument
    let layer: TLLayer
    let frame: Int
    let columnIndex: Int
    /// Non-nil, and equal to this tween's start frame, when this cell is a
    /// tween's end keyframe — the one thing that's draggable, and only to
    /// frames after that start.
    let tweenEndStart: Int?
    /// Non-nil exactly when `mark` is `.tween` — which color Flash would
    /// tint this span's band (see `TweenSpanKind`).
    let tweenKind: TweenSpanKind?
    /// Owned by the parent FrameRowView, shared by every cell in this row —
    /// which frame a tween-end drag in progress would land on, so the
    /// destination cell (a different FrameCellSlot instance than the one
    /// being dragged) can highlight itself. Plain `@State`+`Binding`,
    /// deliberately not `doc`: this cell's own body reads it too (to know
    /// whether *it's* the target), and mutating an `@Observable` property
    /// from inside a gesture that same body defines can redefine the
    /// gesture mid-drag and drop its tracking entirely.
    @Binding var dropTargetFrame: Int?

    // True for the whole gesture, not just non-zero translation — this cell
    // still counts as "the one being dragged" even at the instant the mouse
    // is back at its start position, so the highlight doesn't flicker off.
    @State private var isDraggingKeyframe = false

    private var isDropTarget: Bool { dropTargetFrame == frame }

    var body: some View {
        FrameCellView(
            mark: columnIndex < layer.frames.count ? layer.frames[columnIndex] : .empty,
            columnIndex: columnIndex,
            dimmed: layer.hidden,
            isSelected: doc.hasSelectedFrame && doc.selectedLayerID == layer.id && doc.selectedFrameRange.contains(frame),
            isDropTarget: isDropTarget,
            tweenKind: tweenKind,
            isPropertyKeyframe: layer.isPropertyKeyframe(at: frame)
        )
        .frame(width: frameWidth, height: rowHeight)
        .contentShape(Rectangle())
        .opacity(isDraggingKeyframe ? 0.5 : 1.0)
        .overlay(isDraggingKeyframe ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
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
        .simultaneousGesture(keyframeDrag)
        .contextMenu {
            Button("Insert Frame") { doc.insertFrame(layer: layer, at: frame) }
            Button("Insert Keyframe") { doc.insertKeyframe(layer: layer, at: frame, blank: false) }
            Button("Insert Blank Keyframe") { doc.insertKeyframe(layer: layer, at: frame, blank: true) }
            Divider()
            Button("Remove Frames", role: .destructive) { doc.removeFrames(layer: layer, at: frame) }
            Button("Clear Frame", role: .destructive) { doc.clearFrame(layer: layer, at: frame) }
            Divider()
            Button("Create Tween") {
                let r = doc.selectedFrameRange
                doc.createTween(layer: layer, from: r.lowerBound, to: r.upperBound)
            }
            .disabled(doc.selectedLayerID != layer.id || doc.selectedFrameRange.count < 2)
            Button("Remove Tween") { doc.removeTween(layer: layer, at: frame) }
                .disabled(layer.governingKeyframe(at: frame).flatMap { layer.tweenTarget(from: $0) } == nil)
            if layer.isPropertyKeyframe(at: frame) {
                Button("Remove Property Keyframe") { doc.removePropertyKeyframe(layer: layer, at: frame) }
            } else {
                Button("Add Property Keyframe") { doc.addPropertyKeyframe(layer: layer, at: frame) }
                    .disabled(frame - 1 >= layer.frames.count || layer.frames[frame - 1] != .tween)
            }
            Divider()
            Button("Copy Text") { doc.copySelectedPlacement() }
                .disabled(doc.selectedPlacement == nil)
            Button("Paste Text") { doc.pastePlacedText(layer: layer, at: frame) }
                .disabled(!doc.hasCopiedText)
            Button("Convert to Symbol") {
                doc.selectFrame(layer: layer, frame: frame, extend: false)
                doc.convertSelectedTextToSymbol(name: layer.textFrames[frame]?.text ?? "Symbol")
            }
            .disabled(layer.textFrames[frame] == nil)
            Divider()
            Button("Cut Frames") { doc.cutSelectedFrames() }
                .disabled(doc.selectedLayerID != layer.id)
            Button("Copy Frames") { doc.copySelectedFrames() }
                .disabled(doc.selectedLayerID != layer.id)
            Button("Paste Frames") { doc.pasteFrames(layer: layer, at: frame) }
                .disabled(!doc.hasCopiedFrames)
            Button("Select All Frames") { doc.selectAllFrames() }
            Divider()
            Button("Reverse Frames") { doc.reverseFrames(layer: layer, range: doc.selectedFrameRange) }
                .disabled(doc.selectedLayerID != layer.id || doc.selectedFrameRange.count < 2)
        }
    }

    /// Two draggable cases share this one gesture: sliding a tween's end
    /// keyframe (`tweenEndStart != nil`, via `moveTweenEnd`) or repositioning
    /// a plain, non-tween keyframe (via `moveKeyframe`). No-ops on anything
    /// else — a tween's *start* keyframe isn't draggable at all (moving it
    /// would leave the span it anchors dangling), nor is a `.plain`/`.tween`/
    /// `.empty` continuation frame. Deliberately touches nothing on `doc`
    /// until `onEnded` — see `dropTargetFrame`'s doc comment above for why
    /// mutating the shared, `@Observable` document mid-drag is exactly what
    /// used to break this gesture's own tracking. Selecting the frame
    /// happens on release for the same reason; it still covers a plain
    /// click (translation 0 still fires `onEnded`).
    private var keyframeDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let candidate = dragCandidate(for: value.translation.width) else { return }
                isDraggingKeyframe = true
                dropTargetFrame = candidate
            }
            .onEnded { value in
                isDraggingKeyframe = false
                let candidate = dragCandidate(for: value.translation.width)
                dropTargetFrame = nil
                guard let candidate else { return }
                doc.selectFrame(layer: layer, frame: frame, extend: false)
                guard candidate != frame else { return }
                if tweenEndStart != nil {
                    doc.moveTweenEnd(layer: layer, from: frame, to: candidate)
                } else {
                    doc.moveKeyframe(layer: layer, from: frame, to: candidate)
                }
            }
    }

    /// The frame this drag would land on right now, or nil if this cell
    /// isn't a draggable one at all (see `keyframeDrag`'s doc comment).
    private func dragCandidate(for translationWidth: CGFloat) -> Int? {
        let deltaFrames = Int((translationWidth / frameWidth).rounded())
        if let tweenEndStart {
            // +2, not +1: a tween needs at least one interior .tween frame
            // to still register as a tween at all (the model's only signal
            // linking the two keyframes) — landing right next to the start
            // would silently turn it into two disconnected keyframes.
            return max(tweenEndStart + 2, frame + deltaFrames)
        }
        guard layer.isKeyframe(at: frame), layer.tweenTarget(from: frame) == nil else { return nil }
        return max(1, frame + deltaFrames)
    }
}

/// Which color Flash tints a tween span's band with — blue for a motion
/// tween (anything but a shape: text, symbol, or group), green for a shape
/// tween.
enum TweenSpanKind {
    case motion
    case shape
}

struct FrameCellView: View {
    let mark: FrameMark
    let columnIndex: Int
    let dimmed: Bool
    var isSelected: Bool = false
    /// True on the one cell a tween-end drag currently in progress would
    /// land on if released now (see FrameCellSlot.tweenEndDrag) — drawn
    /// distinctly from plain selection so "here's where it's going" reads
    /// at a glance while dragging.
    var isDropTarget: Bool = false
    /// Only meaningful when `mark == .tween` — nil elsewhere.
    var tweenKind: TweenSpanKind? = nil
    /// True on a `.tween` frame carrying a property keyframe (see
    /// `TLLayer.isPropertyKeyframe`) — Flash's diamond marker.
    var isPropertyKeyframe: Bool = false

    private var bandColor: Color {
        switch mark {
        case .tween:
            switch tweenKind {
            case .shape: return Color(red: 0.6, green: 0.85, blue: 0.6).opacity(0.55)
            case .motion, .none: return Color(red: 0.6, green: 0.75, blue: 0.95).opacity(0.55)
            }
        case .plain, .spanEnd: return Color.gray.opacity(0.12)
        default: return (columnIndex / 5) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(isDropTarget ? Color.accentColor.opacity(0.45) : (isSelected ? Color.accentColor.opacity(0.3) : bandColor))
            if isDropTarget {
                Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            } else if isSelected {
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
                    // Flash marks a frame carrying an action with a small
                    // italic "a", not a colored ring.
                    Text("a")
                        .font(.system(size: 7, weight: .semibold, design: .serif))
                        .italic()
                        .foregroundStyle(Color.primary)
                        .offset(y: -6)
                }
            case .emptyKeyframe:
                Circle().stroke(Color.primary, lineWidth: 1).frame(width: 5, height: 5)
            case .spanEnd:
                // Flash's own endframe glyph: a small hollow rectangle plus
                // a vertical line marking the end of the frame sequence,
                // not a circle.
                Rectangle().stroke(Color.primary.opacity(0.7), lineWidth: 1).frame(width: 6, height: 6)
                Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            case .tween:
                if isPropertyKeyframe {
                    // Flash's diamond marker — a mid-span checkpoint the
                    // eased curve re-targets through, distinct from a full
                    // keyframe's round dot.
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 5, height: 5)
                        .rotationEffect(.degrees(45))
                }
            case .plain, .empty:
                EmptyView()
            }
        }
        .opacity(dimmed ? 0.4 : 1.0)
    }
}
