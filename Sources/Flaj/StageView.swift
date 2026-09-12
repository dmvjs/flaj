import SwiftUI
import AppKit

extension View {
    /// Applies a `PlacedText`'s Drop Shadow and Glow filters (if set) as
    /// two stacked SwiftUI shadows — a glow is a shadow with no offset
    /// (see `GlowFilter`'s own doc comment), so both compose exactly the
    /// way two real Flash filters on the same object would. Applied
    /// unconditionally with a fully transparent, zero-radius fallback
    /// rather than branching on nil, so this never needs `@ViewBuilder` —
    /// a zero-radius, zero-alpha shadow renders as nothing. Inserted
    /// before `.scaleEffect`/`.rotationEffect` in a caller's modifier
    /// chain so the shadow scales/rotates along with its text, not fixed
    /// to the Stage's own axes.
    func placedTextFilters(_ content: PlacedText, scale: CGFloat) -> some View {
        self
            .shadow(
                color: Color(hex: content.glow?.colorHex ?? "#000000").opacity(content.glow?.opacity ?? 0),
                radius: (content.glow?.blur ?? 0) * scale, x: 0, y: 0
            )
            .shadow(
                color: Color(hex: content.dropShadow?.colorHex ?? "#000000").opacity(content.dropShadow?.opacity ?? 0),
                radius: (content.dropShadow?.blur ?? 0) * scale,
                x: (content.dropShadow?.offsetX ?? 0) * scale, y: (content.dropShadow?.offsetY ?? 0) * scale
            )
    }
}

/// The Stage's actual content — background + text objects — at a given
/// `scale` factor. Shared between the live preview (StageView, scaled to
/// fit its panel) and GIF export (rendered 1:1 at the Stage's real pixel
/// size via ImageRenderer), so what you see while editing is exactly what
/// gets exported.
struct StageContentView: View {
    let doc: TimelineDocument
    var scale: CGFloat

    // Live rect while drawing a shape, in Stage pixel coordinates — nil the
    // rest of the time (including during GIF export's static
    // ImageRenderer snapshot, where no gesture ever fires to begin with).
    // Purely a preview: the real PlacedShape is only created in
    // shapeDrawGesture's onEnded, via doc.placeShape.
    @State private var shapeDragRect: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(doc.stageColor)
                .contentShape(Rectangle())
                .onTapGesture { location in handleBaseTap(at: location) }
                // simultaneousGesture, not gesture: this must recognize
                // alongside the tap gesture above, not compete with and
                // possibly suppress it — a plain click with a shape tool
                // active still needs handleBaseTap's own deselect behavior
                // to run, since a drag distance of ~0 never places a shape
                // (see shapeDrawGesture's own onEnded guard).
                .simultaneousGesture(shapeDrawGesture)
            if let shapeDragRect {
                shapePreview.frame(width: shapeDragRect.width * scale, height: shapeDragRect.height * scale)
                    .position(x: (shapeDragRect.midX) * scale, y: (shapeDragRect.midY) * scale)
                    .allowsHitTesting(false)
            }
            ForEach(doc.stageObjects) { obj in
                StageTextView(obj: obj, scale: scale)
            }
            ForEach(doc.visibleLayers.filter { !$0.hidden }) { layer in
                if let kf = layer.governingKeyframe(at: doc.playhead) {
                    if layer.textFrames[kf] != nil {
                        StagePlacedTextView(doc: doc, layer: layer, keyframe: kf, scale: scale)
                    } else if layer.shapeFrames[kf] != nil {
                        StagePlacedShapeView(doc: doc, layer: layer, keyframe: kf, scale: scale)
                    } else if let instance = layer.symbolFrames[kf],
                              instance.name.isEmpty || doc.stageObject(id: instance.name) == nil {
                        // A named instance that's already spawned into
                        // doc.stageObjects (see TimelineDocument.
                        // spawnNamedInstances) is rendered by the
                        // StageTextView loop above instead — it's now a
                        // live, script-controlled object, not
                        // Timeline-authored content.
                        StageSymbolInstanceView(doc: doc, layer: layer, keyframe: kf, scale: scale)
                    }
                }
            }
            // The banner-ad clickTag convention (see TimelineDocument.
            // clickTagURL): while playing, if a script has set one, the
            // *whole* Stage becomes one big link — this sits on top of
            // everything else in the ZStack specifically so a click lands
            // here even over placed text/stage objects, which otherwise
            // have their own tap/drag gestures that would win instead.
            // Only present during playback so it never shadows normal
            // editing clicks (select/move/place-text) the rest of the time.
            if doc.isPlaying, let clickTagURL = doc.clickTagURL {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { openClickTag(clickTagURL) }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
            }
        }
        .frame(width: doc.stageWidth * scale, height: doc.stageHeight * scale)
    }

    private func handleBaseTap(at location: CGPoint) {
        let stagePoint = CGPoint(x: location.x / scale, y: location.y / scale)
        switch doc.selectedTool {
        case .text:
            doc.placeText(at: stagePoint)
        case .selection, .rectangle, .ellipse:
            // A shape tool's actual creation happens via shapeDrawGesture's
            // drag, not a plain click (a real drag distance is what gives a
            // shape a real size) — a bare click with one of those tools
            // active just deselects, matching .selection's own behavior,
            // rather than doing nothing at all.
            doc.selectedPlacement = nil
            doc.selectedSymbolPlacement = nil
            doc.selectedShapePlacement = nil
        }
    }

    /// A rough, semi-transparent preview of the shape currently being
    /// drawn — the real fill/stroke styling (and the real `PlacedShape`)
    /// only exist once `shapeDrawGesture` actually commits it in `onEnded`.
    private var shapePreview: some View {
        Group {
            switch doc.selectedTool {
            case .ellipse: Ellipse().fill(Color.accentColor.opacity(0.25)).overlay(Ellipse().stroke(Color.accentColor, lineWidth: 1))
            default: Rectangle().fill(Color.accentColor.opacity(0.25)).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            }
        }
    }

    /// Click-and-drag to draw a shape, sized live as you drag — not
    /// click-to-place-a-default-size-box-then-resize, which is what makes
    /// this feel like a real drawing tool rather than a placeholder stamp.
    /// Holding Shift while dragging constrains to a square/circle, the
    /// universal modern convention (and Flash's own). Inert (every branch
    /// no-ops) unless a shape tool is actually selected, so this can stay
    /// permanently attached rather than conditionally added/removed as the
    /// tool changes.
    private var shapeDrawGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard doc.selectedTool == .rectangle || doc.selectedTool == .ellipse else { return }
                let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                var end = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                if NSEvent.modifierFlags.contains(.shift) {
                    let side = max(abs(end.x - start.x), abs(end.y - start.y))
                    end.x = start.x + (end.x < start.x ? -side : side)
                    end.y = start.y + (end.y < start.y ? -side : side)
                }
                shapeDragRect = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(end.x - start.x), height: abs(end.y - start.y)
                )
            }
            .onEnded { _ in
                defer { shapeDragRect = nil }
                guard doc.selectedTool == .rectangle || doc.selectedTool == .ellipse,
                      let rect = shapeDragRect, rect.width > 1, rect.height > 1
                else { return }
                doc.placeShape(kind: doc.selectedTool == .ellipse ? .ellipse : .rectangle, rect: rect)
            }
    }

    private func openClickTag(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Ghosted nearby-frame content, Flash's own onion-skin convention — frames
/// before the playhead tint blue, frames after tint orange, so which
/// direction a ghost is in stays legible even with several stacked.
/// Deliberately lives in StageView, not StageContentView: the latter is
/// shared with GIF export's frame-by-frame render (see its own doc
/// comment), and a ghost frame must never leak into exported output —
/// this overlay is drawn as a sibling, editor-preview only.
private struct OnionSkinOverlay: View {
    let doc: TimelineDocument
    var scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(offsets, id: \.self) { offset in
                let frame = doc.playhead + offset
                if frame >= 1 && frame <= doc.totalFrames {
                    ForEach(doc.visibleLayers.filter { !$0.hidden }) { layer in
                        if let placement = layer.interpolatedPlacedText(at: frame) {
                            ghost(placement, tint: offset < 0 ? .blue : .orange, spin: spinDegrees(layer: layer, at: frame))
                        } else if let instance = layer.interpolatedSymbolInstance(at: frame),
                                  let symbol = doc.library.first(where: { $0.id == instance.symbolID }),
                                  let kf = layer.governingKeyframe(at: frame),
                                  let content = symbol.content(atLocalFrame: symbol.localFrame(atParentFrame: frame, governingKeyframe: kf)) {
                            ghost(instance, content: content, tint: offset < 0 ? .blue : .orange, spin: spinDegrees(layer: layer, at: frame))
                        }
                    }
                }
            }
        }
        .frame(width: doc.stageWidth * scale, height: doc.stageHeight * scale)
        .allowsHitTesting(false) // purely a visual aid — never steals the real content's taps/drags
    }

    /// `-range...range` excluding 0 (the playhead's own frame, already
    /// drawn at full opacity by StageContentView).
    private var offsets: [Int] {
        (-doc.onionSkinRange...doc.onionSkinRange).filter { $0 != 0 }
    }

    /// A flat tint rather than the placement's own color — the point is to
    /// see *where* content was/will be at a glance, not to preview an
    /// in-progress color tween a second time. Scale/rotation are still the
    /// real interpolated values though (`p.scale`/`p.rotation`, plus the
    /// same "Rotate: CW/CCW, N times" spin bonus StagePlacedTextView
    /// applies) — those aren't part of the "flatten the color" simplification.
    private func ghost(_ p: PlacedText, tint: Color, spin: Double) -> some View {
        Text(p.text)
            .font(.custom(p.fontName, size: p.fontSize * scale))
            .bold(p.bold)
            .italic(p.italic)
            .foregroundStyle(tint)
            .multilineTextAlignment(p.alignment.swiftUIAlignment)
            .frame(width: p.width * scale, height: p.height * scale, alignment: p.alignment.frameAlignment)
            .opacity(0.35)
            .scaleEffect(p.scale)
            .rotationEffect(.degrees(p.rotation + spin))
            .position(x: (p.x + p.width / 2) * scale, y: (p.y + p.height / 2) * scale)
    }

    /// Same idea as `ghost(_:tint:spin:)`, for a symbol instance — pulls the
    /// text/font/color to render from `content`, the symbol's own resolved
    /// content at whichever of its frames this instance is independently
    /// showing at the ghost's frame (see `FlajSymbol.localFrame`), not
    /// necessarily its first — a multi-frame symbol's onion-skin ghosts
    /// should show it mid-loop just like the real, undimmed instance does.
    private func ghost(_ p: SymbolInstance, content: PlacedText, tint: Color, spin: Double) -> some View {
        Text(content.text)
            .font(.custom(content.fontName, size: content.fontSize * scale))
            .bold(content.bold)
            .italic(content.italic)
            .foregroundStyle(tint)
            .multilineTextAlignment(content.alignment.swiftUIAlignment)
            .frame(width: p.width * scale, height: p.height * scale, alignment: content.alignment.frameAlignment)
            .opacity(0.35) // deliberately flat, not content.opacity*p.opacity — a ghost's whole point is a uniform tint, not a real preview (see ghost(_:tint:spin:)'s own doc comment)
            .scaleEffect(p.scale * content.scale)
            .rotationEffect(.degrees(p.rotation + content.rotation + spin))
            .position(x: (p.x + p.width / 2) * scale, y: (p.y + p.height / 2) * scale)
    }

    /// Same "Rotate: CW/CCW, N times" tween bonus StagePlacedTextView's own
    /// `spinDegrees` computes, just re-derived for an arbitrary onion-skin
    /// `frame` instead of the live playhead.
    private func spinDegrees(layer: TLLayer, at frame: Int) -> Double {
        guard let kf = layer.governingKeyframe(at: frame),
              let endKf = layer.tweenTarget(from: kf), endKf > kf else { return 0 }
        let settings = layer.tweenSettings[kf] ?? TweenSettings()
        let rawT = Double(frame - kf) / Double(endKf - kf)
        return settings.spinDegrees(at: rawT)
    }
}

/// A layer's authored, design-time text — placed and edited with the Text
/// tool, distinct from the script-driven StageObject/StageTextView above.
private struct StagePlacedTextView: View {
    let doc: TimelineDocument
    let layer: TLLayer
    let keyframe: Int
    var scale: CGFloat

    // DragGesture.translation is cumulative from the gesture's start, not a
    // per-tick delta — these capture the placement at drag-start so each
    // onChanged computes an absolute new value (start + translation)
    // instead of compounding translation into itself every tick.
    @State private var moveStart: PlacedText?
    @State private var resizeStart: PlacedText?
    // The live candidate placement during an active move/resize — kept
    // purely local and committed to `layer.textFrames`/`doc.selectedPlacement`
    // only in `onEnded`, not on every tick. Writing to those shared
    // `@Observable` properties on every pixel dragged — this view's own
    // body reads both, for `displayPlacement` and `isSelected` — used to
    // make the selection box visibly flicker, and forced every *other*
    // view reading the same placement (the Properties panel's fields, the
    // Timeline) to re-render on every tick too, not just this one.
    @State private var liveDrag: PlacedText?

    private var ref: TimelineDocument.TextPlacementRef {
        TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: keyframe)
    }
    private var placement: PlacedText { layer.textFrames[keyframe] ?? PlacedText(x: 0, y: 0) }
    private var isSelected: Bool { doc.selectedPlacement == ref }

    /// The rendered state at the current playhead — `placement` itself
    /// outside a tween, or eased-interpolated toward the tween's end
    /// keyframe while the playhead is inside that span (TLLayer.
    /// interpolatedPlacedText is the single source of truth for this math —
    /// insertKeyframe uses the same function to snapshot a mid-tween split).
    /// Gestures (move/resize) always read/write `placement`/
    /// `layer.textFrames[keyframe]` directly, never this — you edit a
    /// tween's endpoints, not an in-between frame.
    private var displayPlacement: PlacedText {
        liveDrag ?? layer.interpolatedPlacedText(at: doc.playhead) ?? placement
    }

    private var spinDegrees: Double {
        guard let endKf = layer.tweenTarget(from: keyframe), endKf > keyframe else { return 0 }
        let settings = layer.tweenSettings[keyframe] ?? TweenSettings()
        let rawT = Double(doc.playhead - keyframe) / Double(endKf - keyframe)
        return settings.spinDegrees(at: rawT)
    }

    var body: some View {
        let shown = displayPlacement
        Text(shown.text)
            .font(.custom(shown.fontName, size: shown.fontSize * scale))
            .bold(shown.bold)
            .italic(shown.italic)
            .foregroundStyle(Color(hex: shown.colorHex))
            .multilineTextAlignment(shown.alignment.swiftUIAlignment)
            .frame(width: shown.width * scale, height: shown.height * scale,
                   alignment: shown.alignment.frameAlignment)
            .placedTextFilters(shown, scale: scale)
            .opacity(shown.opacity)
            .contentShape(Rectangle())
            .overlay(isSelected ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
            .scaleEffect(shown.scale)
            .rotationEffect(.degrees(shown.rotation + spinDegrees))
            .position(x: (shown.x + shown.width / 2) * scale, y: (shown.y + shown.height / 2) * scale)
            .onTapGesture { doc.selectedPlacement = ref }
            .gesture(moveGesture)
            // A stable hook for UI automation/accessibility tooling to find
            // this exact element — the SwiftUI/AppKit equivalent of a
            // data-testid, invisible to VoiceOver users (unlike
            // accessibilityLabel), queryable via the accessibility tree.
            .accessibilityIdentifier("stage-placed-text")
            .contextMenu {
                // Right-click doesn't fire onTapGesture on macOS, so each
                // action explicitly selects this placement first — matching
                // what a left-click would have done — rather than assuming
                // it's already `doc.selectedPlacement`.
                Button("Cut") {
                    doc.selectedPlacement = ref
                    doc.copySelectedPlacement()
                    doc.deleteSelectedPlacement()
                }
                Button("Copy") {
                    doc.selectedPlacement = ref
                    doc.copySelectedPlacement()
                }
                Button("Delete", role: .destructive) {
                    doc.selectedPlacement = ref
                    doc.deleteSelectedPlacement()
                }
                Divider()
                Button("Convert to Symbol…") {
                    doc.selectedPlacement = ref
                    doc.convertSelectedTextToSymbol(name: placement.text)
                }
            }
    }

    private var moveGesture: some Gesture {
        // .global, not the default .local: this view's own frame moves as
        // a *result* of the drag (`.position(...)` tracks `liveDrag` live),
        // so a .local translation is measured against a coordinate space
        // that's shifting under the gesture mid-drag — translation drifts
        // out of sync with the actual cursor. Global screen coordinates
        // don't move just because this view did.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard doc.selectedTool == .selection else { return }
                let start = moveStart ?? placement
                if moveStart == nil { moveStart = start }
                var p = start
                p.x = start.x + value.translation.width / scale
                p.y = start.y + value.translation.height / scale
                liveDrag = p
            }
            .onEnded { _ in
                if let liveDrag {
                    doc.withUndoSnapshot(coalesce: ref.undoToken) {
                        doc.selectedPlacement = ref
                        layer.textFrames[keyframe] = liveDrag
                    }
                }
                moveStart = nil
                liveDrag = nil
            }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .gesture(
                // .global for the same reason as moveGesture — the handle
                // sits at .bottomTrailing of the very frame that's resizing
                // live, so its .local origin moves under the gesture too.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? placement
                        if resizeStart == nil { resizeStart = start }
                        var p = start
                        p.width = max(20, start.width + value.translation.width / scale)
                        p.height = max(16, start.height + value.translation.height / scale)
                        liveDrag = p
                    }
                    .onEnded { _ in
                        if let liveDrag {
                            doc.withUndoSnapshot(coalesce: ref.undoToken) { layer.textFrames[keyframe] = liveDrag }
                        }
                        resizeStart = nil
                        liveDrag = nil
                    }
            )
    }
}

/// A placed Rectangle/Ellipse — same drag/resize mechanics as
/// `StagePlacedTextView` (see that view's own doc comments for why local
/// `@State` + `.global` coordinate space matter here). No `displayPlacement`
/// interpolation: shapes aren't tweenable yet (see `PlacedShape`'s own doc
/// comment), so this always just shows `placement` itself, live-drag
/// override aside — there's no tween span to ease across.
private struct StagePlacedShapeView: View {
    let doc: TimelineDocument
    let layer: TLLayer
    let keyframe: Int
    var scale: CGFloat

    @State private var moveStart: PlacedShape?
    @State private var resizeStart: PlacedShape?
    @State private var liveDrag: PlacedShape?

    private var ref: TimelineDocument.ShapePlacementRef {
        TimelineDocument.ShapePlacementRef(layerID: layer.id, keyframe: keyframe)
    }
    private var placement: PlacedShape { layer.shapeFrames[keyframe] ?? PlacedShape(x: 0, y: 0) }
    private var isSelected: Bool { doc.selectedShapePlacement == ref }
    private var displayPlacement: PlacedShape { liveDrag ?? placement }

    private func shape(for kind: ShapeKind) -> AnyShape {
        switch kind {
        case .rectangle: return AnyShape(Rectangle())
        case .ellipse: return AnyShape(Ellipse())
        }
    }

    var body: some View {
        let shown = displayPlacement
        let anyShape = shape(for: shown.kind)
        anyShape
            .fill(Color(hex: shown.fillColorHex).opacity(shown.fillOpacity))
            .overlay(
                anyShape.stroke(Color(hex: shown.strokeColorHex).opacity(shown.strokeOpacity), lineWidth: shown.strokeWidth * scale)
            )
            .frame(width: shown.width * scale, height: shown.height * scale)
            .opacity(shown.opacity)
            .contentShape(anyShape)
            .overlay(isSelected ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .overlay(alignment: .topLeading) { if isSelected { resizeHandle(.topLeading) } }
            .overlay(alignment: .topTrailing) { if isSelected { resizeHandle(.topTrailing) } }
            .overlay(alignment: .bottomLeading) { if isSelected { resizeHandle(.bottomLeading) } }
            .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle(.bottomTrailing) } }
            .position(x: (shown.x + shown.width / 2) * scale, y: (shown.y + shown.height / 2) * scale)
            .onTapGesture { doc.selectedShapePlacement = ref }
            .gesture(moveGesture)
            .accessibilityIdentifier("stage-placed-shape")
            .contextMenu {
                Button("Cut") {
                    doc.selectedShapePlacement = ref
                    doc.copySelectedShapePlacement()
                    doc.deleteSelectedShapePlacement()
                }
                Button("Copy") {
                    doc.selectedShapePlacement = ref
                    doc.copySelectedShapePlacement()
                }
                Button("Delete", role: .destructive) {
                    doc.selectedShapePlacement = ref
                    doc.deleteSelectedShapePlacement()
                }
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard doc.selectedTool == .selection else { return }
                let start = moveStart ?? placement
                if moveStart == nil { moveStart = start }
                var p = start
                p.x = start.x + value.translation.width / scale
                p.y = start.y + value.translation.height / scale
                liveDrag = p
            }
            .onEnded { _ in
                if let liveDrag {
                    doc.withUndoSnapshot(coalesce: ref.undoToken) {
                        doc.selectedShapePlacement = ref
                        layer.shapeFrames[keyframe] = liveDrag
                    }
                }
                moveStart = nil
                liveDrag = nil
            }
    }

    /// Which corner of the box a resize handle sits on — `fraction` gives
    /// that corner's position within the box as a 0/1 multiple of width/
    /// height along each axis, which is all `resized(_:corner:dx:dy:)`
    /// needs to find both the corner being dragged and the fixed corner
    /// directly opposite it.
    private enum ResizeCorner {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var fraction: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeading: return (0, 0)
            case .topTrailing: return (1, 0)
            case .bottomLeading: return (0, 1)
            case .bottomTrailing: return (1, 1)
            }
        }
    }

    /// Resizes `start` by dragging `corner` by (dx, dy) in Stage units,
    /// keeping the opposite corner fixed — matches how every other resize
    /// handle in this app (and Flash's own) behaves: dragging a corner
    /// moves that corner, not just the box's far edge, unlike the old
    /// single bottom-trailing-only handle this replaced.
    private static func resized(_ start: PlacedShape, corner: ResizeCorner, dx: CGFloat, dy: CGFloat) -> PlacedShape {
        let f = corner.fraction
        let fixedX = start.x + (1 - f.x) * start.width
        let fixedY = start.y + (1 - f.y) * start.height
        let draggedX = start.x + f.x * start.width + dx
        let draggedY = start.y + f.y * start.height + dy
        var p = start
        p.width = max(4, abs(draggedX - fixedX))
        p.height = max(4, abs(draggedY - fixedY))
        p.x = min(draggedX, fixedX)
        p.y = min(draggedY, fixedY)
        return p
    }

    private func resizeHandle(_ corner: ResizeCorner) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? placement
                        if resizeStart == nil { resizeStart = start }
                        liveDrag = Self.resized(start, corner: corner, dx: value.translation.width / scale, dy: value.translation.height / scale)
                    }
                    .onEnded { _ in
                        if let liveDrag {
                            doc.withUndoSnapshot(coalesce: ref.undoToken) { layer.shapeFrames[keyframe] = liveDrag }
                        }
                        resizeStart = nil
                        liveDrag = nil
                    }
            )
    }
}

/// A placed instance of a Library symbol — same drag/resize mechanics as
/// `StagePlacedTextView` (see that view's own doc comments for why local
/// `@State` + `.global` coordinate space matter here), rendering whatever
/// text/font/color the referenced `FlajSymbol` currently has rather than
/// carrying its own.
private struct StageSymbolInstanceView: View {
    let doc: TimelineDocument
    let layer: TLLayer
    let keyframe: Int
    var scale: CGFloat

    @State private var moveStart: SymbolInstance?
    @State private var resizeStart: SymbolInstance?
    @State private var liveDrag: SymbolInstance?

    private var ref: TimelineDocument.SymbolPlacementRef {
        TimelineDocument.SymbolPlacementRef(layerID: layer.id, keyframe: keyframe)
    }
    private var placement: SymbolInstance? { layer.symbolFrames[keyframe] }
    private var isSelected: Bool { doc.selectedSymbolPlacement == ref }

    private var displayPlacement: SymbolInstance? {
        liveDrag ?? layer.interpolatedSymbolInstance(at: doc.playhead) ?? placement
    }

    private var symbol: FlajSymbol? {
        guard let symbolID = placement?.symbolID else { return nil }
        return doc.library.first { $0.id == symbolID }
    }

    /// Which frame of the symbol's own Timeline this instance is currently
    /// showing — it plays independently and continuously once placed,
    /// looping its own frames, never synced to or waiting on the parent
    /// Timeline's playhead (see `FlajSymbol.localFrame`). `keyframe` (this
    /// instance's governing keyframe on the *parent* layer) is the fixed
    /// reference point "how long has this instance been showing" counts
    /// from, so this keeps advancing smoothly across an instance-level
    /// tween span, not just while the span sits still.
    private var localFrame: Int {
        guard let symbol else { return 1 }
        return symbol.localFrame(atParentFrame: doc.playhead, governingKeyframe: keyframe)
    }

    private var displayedContent: PlacedText? {
        symbol?.content(atLocalFrame: localFrame)
    }

    private var spinDegrees: Double {
        guard let endKf = layer.tweenTarget(from: keyframe), endKf > keyframe else { return 0 }
        let settings = layer.tweenSettings[keyframe] ?? TweenSettings()
        let rawT = Double(doc.playhead - keyframe) / Double(endKf - keyframe)
        return settings.spinDegrees(at: rawT)
    }

    var body: some View {
        if let shown = displayPlacement, let symbol, let content = displayedContent {
            Text(content.text)
                .font(.custom(content.fontName, size: content.fontSize * scale))
                .bold(content.bold)
                .italic(content.italic)
                .foregroundStyle(Color(hex: content.colorHex))
                .multilineTextAlignment(content.alignment.swiftUIAlignment)
                .frame(width: shown.width * scale, height: shown.height * scale,
                       alignment: content.alignment.frameAlignment)
                .placedTextFilters(content, scale: scale)
                // Multiplicative, not just the instance's own opacity: a
                // symbol's internal frame can carry its own opacity tween
                // (e.g. a fade authored inside the symbol via edit-in-place),
                // which should compound with whatever the *placed instance*
                // is separately tweened to, exactly like nested alpha
                // actually compounds in Flash — not one silently winning
                // over the other.
                .opacity(shown.opacity * content.opacity)
                .contentShape(Rectangle())
                .overlay(isSelected ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
                .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
                // Same compounding as opacity above, and for the same
                // reason: content.scale/content.rotation are the symbol's
                // own internal-frame values (tweenable inside its own
                // Timeline), shown.scale/shown.rotation are the placed
                // instance's own — both real, both must apply together.
                .scaleEffect(shown.scale * content.scale)
                .rotationEffect(.degrees(shown.rotation + content.rotation + spinDegrees))
                .position(x: (shown.x + shown.width / 2) * scale, y: (shown.y + shown.height / 2) * scale)
                // Double-click before single-click: SwiftUI resolves
                // simultaneous tap-count gestures on the same view by
                // trying the highest count first, so a real double-click
                // enters edit-in-place instead of also firing the
                // single-click selection handler first.
                .onTapGesture(count: 2) { doc.enterSymbolEditing(symbol.id) }
                .onTapGesture {
                    doc.selectedSymbolPlacement = ref
                    doc.selectedPlacement = nil
                }
                .gesture(moveGesture)
                .accessibilityIdentifier("stage-symbol-instance")
                .contextMenu {
                    Button("Cut") {
                        doc.selectedSymbolPlacement = ref
                        doc.copySelectedSymbolPlacement()
                        doc.deleteSelectedSymbolPlacement()
                    }
                    Button("Copy") {
                        doc.selectedSymbolPlacement = ref
                        doc.copySelectedSymbolPlacement()
                    }
                    Button("Delete", role: .destructive) {
                        doc.selectedSymbolPlacement = ref
                        doc.deleteSelectedSymbolPlacement()
                    }
                }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard doc.selectedTool == .selection, let placement else { return }
                let start = moveStart ?? placement
                if moveStart == nil { moveStart = start }
                var p = start
                p.x = start.x + value.translation.width / scale
                p.y = start.y + value.translation.height / scale
                liveDrag = p
            }
            .onEnded { _ in
                if let liveDrag {
                    doc.withUndoSnapshot(coalesce: ref.undoToken) {
                        doc.selectedSymbolPlacement = ref
                        doc.selectedPlacement = nil
                        layer.symbolFrames[keyframe] = liveDrag
                    }
                }
                moveStart = nil
                liveDrag = nil
            }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard let placement else { return }
                        let start = resizeStart ?? placement
                        if resizeStart == nil { resizeStart = start }
                        var p = start
                        p.width = max(20, start.width + value.translation.width / scale)
                        p.height = max(16, start.height + value.translation.height / scale)
                        liveDrag = p
                    }
                    .onEnded { _ in
                        if let liveDrag {
                            doc.withUndoSnapshot(coalesce: ref.undoToken) { layer.symbolFrames[keyframe] = liveDrag }
                        }
                        resizeStart = nil
                        liveDrag = nil
                    }
            )
    }
}

private struct StageTextView: View {
    let obj: StageObject
    var scale: CGFloat

    var body: some View {
        Text(obj.text)
            .font(.custom(obj.fontName, size: obj.fontSize * scale))
            .bold(obj.bold)
            .italic(obj.italic)
            .foregroundStyle(obj.color)
            .scaleEffect(obj.scale)
            .rotationEffect(.degrees(obj.rotation))
            .opacity(obj.opacity)
            .position(x: obj.x * scale, y: obj.y * scale)
    }
}

/// Shown atop the Stage while editing a symbol in place — "Scene 1 ▸
/// Badge ▸ Inner", one crumb per level of `doc.editingPath`, each a
/// button that jumps straight back to that level (matching Flash's own
/// edit-in-place breadcrumb, which does the same rather than only ever
/// backing out one level at a time).
private struct EditingBreadcrumbBar: View {
    let doc: TimelineDocument

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(doc.editingBreadcrumb.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Button {
                    doc.exitSymbolEditing(toDepth: index) // crumb 0 is the root, depth 0
                } label: {
                    Text(name).font(.system(size: 11, weight: index == doc.editingBreadcrumb.count - 1 ? .semibold : .regular))
                }
                .buttonStyle(.plain)
                .disabled(index == doc.editingBreadcrumb.count - 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }
}

/// Picks a "nice" round pixel step for ruler tick spacing so labels never
/// crowd together regardless of the current fit-to-panel scale — there's
/// no Stage zoom yet, so `scale` here is exactly what stands in for it;
/// this is the same adaptive-spacing idea any ruler/axis-drawing tool uses
/// as its zoom level changes.
private enum RulerTicks {
    static let niceSteps: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000]

    static func majorStep(scale: CGFloat, targetScreenSpacing: CGFloat = 50) -> CGFloat {
        for step in niceSteps where step * scale >= targetScreenSpacing { return step }
        return niceSteps.last!
    }
}

/// Flash's horizontal ruler bar — pixel-only (no unit switching, matching
/// what was asked for), ticks continuing across the whole panel including
/// the pasteboard area outside the Stage itself (same as Flash's own
/// rulers), dimmed there vs. the Stage's own on-screen span. Also the drag
/// source for a new horizontal guide: dragging down from this bar previews
/// the guide live via `dragPreview` (rendered by `GuidePreviewLine` in the
/// content ZStack, a sibling view — shared via a binding since neither
/// view is the other's ancestor) and commits it via `onDrop` only if the
/// drop lands within the Stage's own height, mirroring
/// `GuideLineView`'s drag-off-to-delete convention for the reverse case.
private struct HorizontalRulerView: View {
    var scale: CGFloat
    var xOrigin: CGFloat
    var xLength: CGFloat
    var yOrigin: CGFloat
    var stageHeight: CGFloat
    var rulerThickness: CGFloat
    @Binding var dragPreview: Guide?
    var onDrop: (Guide) -> Void

    var body: some View {
        Canvas { context, size in
            let majorStep = RulerTicks.majorStep(scale: scale)
            let minorStep = majorStep / 5
            let showMinor = minorStep * scale >= 6
            let leftValue = -xOrigin / scale
            let rightValue = (size.width - xOrigin) / scale
            var value = (leftValue / majorStep).rounded(.down) * majorStep
            while value <= rightValue {
                let x = xOrigin + value * scale
                let onStage = value >= 0 && value <= xLength / scale
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: size.height - 7)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(onStage ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5))
                )
                context.draw(
                    Text(String(Int(value.rounded()))).font(.system(size: 8)).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 2, y: 3), anchor: .topLeading
                )
                if showMinor {
                    var minorValue = value + minorStep
                    while minorValue < value + majorStep, minorValue <= rightValue {
                        let mx = xOrigin + minorValue * scale
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: mx, y: size.height - 4)); p.addLine(to: CGPoint(x: mx, y: size.height)) },
                            with: .color(Color.secondary.opacity(0.4))
                        )
                        minorValue += minorStep
                    }
                }
                value += majorStep
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onHover { hovering in (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    let contentRelativeY = value.location.y - rulerThickness
                    dragPreview = Guide(orientation: .horizontal, position: (contentRelativeY - yOrigin) / scale)
                }
                .onEnded { _ in
                    if let dragPreview, dragPreview.position >= 0, dragPreview.position <= stageHeight {
                        onDrop(dragPreview)
                    }
                    dragPreview = nil
                }
        )
    }
}

/// Flash's vertical ruler bar — same idiom as `HorizontalRulerView`
/// rotated 90°, drag-source for a new vertical guide instead. Tick labels
/// stay upright rather than rotated (Flash rotates its own vertical ruler
/// text) — a deliberate v1 simplification, still fully readable at this
/// ruler's 18pt width.
private struct VerticalRulerView: View {
    var scale: CGFloat
    var yOrigin: CGFloat
    var yLength: CGFloat
    var xOrigin: CGFloat
    var stageWidth: CGFloat
    var rulerThickness: CGFloat
    @Binding var dragPreview: Guide?
    var onDrop: (Guide) -> Void

    var body: some View {
        Canvas { context, size in
            let majorStep = RulerTicks.majorStep(scale: scale)
            let minorStep = majorStep / 5
            let showMinor = minorStep * scale >= 6
            let topValue = -yOrigin / scale
            let bottomValue = (size.height - yOrigin) / scale
            var value = (topValue / majorStep).rounded(.down) * majorStep
            while value <= bottomValue {
                let y = yOrigin + value * scale
                let onStage = value >= 0 && value <= yLength / scale
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: size.width - 7, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(onStage ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5))
                )
                context.draw(
                    Text(String(Int(value.rounded()))).font(.system(size: 7)).foregroundStyle(.secondary),
                    at: CGPoint(x: 2, y: y + 2), anchor: .topLeading
                )
                if showMinor {
                    var minorValue = value + minorStep
                    while minorValue < value + majorStep, minorValue <= bottomValue {
                        let my = yOrigin + minorValue * scale
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: size.width - 4, y: my)); p.addLine(to: CGPoint(x: size.width, y: my)) },
                            with: .color(Color.secondary.opacity(0.4))
                        )
                        minorValue += minorStep
                    }
                }
                value += majorStep
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onHover { hovering in (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    let contentRelativeX = value.location.x - rulerThickness
                    dragPreview = Guide(orientation: .vertical, position: (contentRelativeX - xOrigin) / scale)
                }
                .onEnded { _ in
                    if let dragPreview, dragPreview.position >= 0, dragPreview.position <= stageWidth {
                        onDrop(dragPreview)
                    }
                    dragPreview = nil
                }
        )
    }
}

/// A live, non-interactive preview of a guide still being dragged out from
/// a ruler — see `HorizontalRulerView`/`VerticalRulerView`'s own doc
/// comments on why this has to be a sibling view driven by a shared
/// binding rather than something the ruler draws itself.
private struct GuidePreviewLine: View {
    let guide: Guide
    var scale: CGFloat
    var stageOriginX: CGFloat
    var stageOriginY: CGFloat
    var stageScreenWidth: CGFloat
    var stageScreenHeight: CGFloat

    var body: some View {
        switch guide.orientation {
        case .horizontal:
            Rectangle().fill(Color.cyan.opacity(0.6))
                .frame(width: stageScreenWidth, height: 1)
                .position(x: stageOriginX + stageScreenWidth / 2, y: stageOriginY + guide.position * scale)
                .allowsHitTesting(false)
        case .vertical:
            Rectangle().fill(Color.cyan.opacity(0.6))
                .frame(width: 1, height: stageScreenHeight)
                .position(x: stageOriginX + guide.position * scale, y: stageOriginY + stageScreenHeight / 2)
                .allowsHitTesting(false)
        }
    }
}

/// A single placed, draggable ruler guide. Dragging it off the Stage's own
/// bounds (negative, or past stageWidth/stageHeight) deletes it on
/// release — mirrors Flash's own "drag a guide back onto the ruler to
/// remove it" convention, generalized to "off the Stage" rather than
/// literally requiring the cursor to reach the ruler bar itself.
private struct GuideLineView: View {
    let doc: TimelineDocument
    let guide: Guide
    var scale: CGFloat
    var stageOriginX: CGFloat
    var stageOriginY: CGFloat
    var stageScreenWidth: CGFloat
    var stageScreenHeight: CGFloat

    @State private var dragStart: CGFloat?
    @State private var liveDrag: CGFloat?

    private var isHorizontal: Bool { guide.orientation == .horizontal }
    private var displayPosition: CGFloat { liveDrag ?? guide.position }

    var body: some View {
        Rectangle()
            .fill(Color.cyan)
            .frame(width: isHorizontal ? stageScreenWidth : 1, height: isHorizontal ? 1 : stageScreenHeight)
            // A generous invisible hit strip around the hairline — a bare
            // 1px target would make guides nearly impossible to grab.
            .frame(width: isHorizontal ? stageScreenWidth : 10, height: isHorizontal ? 10 : stageScreenHeight)
            .contentShape(Rectangle())
            .position(
                x: isHorizontal ? stageOriginX + stageScreenWidth / 2 : stageOriginX + displayPosition * scale,
                y: isHorizontal ? stageOriginY + displayPosition * scale : stageOriginY + stageScreenHeight / 2
            )
            .onHover { hovering in
                if hovering {
                    (isHorizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? guide.position
                        if dragStart == nil { dragStart = start }
                        let delta = (isHorizontal ? value.translation.height : value.translation.width) / scale
                        liveDrag = start + delta
                    }
                    .onEnded { _ in
                        if let liveDrag {
                            let bound = isHorizontal ? doc.stageHeight : doc.stageWidth
                            if liveDrag < 0 || liveDrag > bound {
                                doc.removeGuide(id: guide.id)
                            } else {
                                doc.moveGuide(id: guide.id, to: liveDrag)
                            }
                        }
                        dragStart = nil
                        liveDrag = nil
                    }
            )
    }
}

private struct GuidesOverlay: View {
    let doc: TimelineDocument
    var scale: CGFloat
    var stageOriginX: CGFloat
    var stageOriginY: CGFloat
    var stageScreenWidth: CGFloat
    var stageScreenHeight: CGFloat

    var body: some View {
        ForEach(doc.guides) { guide in
            GuideLineView(
                doc: doc, guide: guide, scale: scale, stageOriginX: stageOriginX, stageOriginY: stageOriginY,
                stageScreenWidth: stageScreenWidth, stageScreenHeight: stageScreenHeight
            )
        }
    }
}

/// Flash's "Stage" — the fixed-size render surface, sized/colored from
/// frame scripts via the `stage`/`bg` JS globals (see TimelineModel).
/// The Stage itself has fixed pixel dimensions, but this view always scales
/// it to fit the available panel with real padding, at any window size —
/// a literal `.frame(width:height:)` at the Stage's raw pixel size would
/// overflow edge-to-edge whenever the panel is smaller than the Stage.
struct StageView: View {
    let doc: TimelineDocument
    private let padding: CGFloat = 28
    private let rulerThickness: CGFloat = 18

    // A local NSEvent monitor rather than SwiftUI's .onKeyPress: the Stage
    // sits inside HSplitView, whose divider intercepts left/right arrow
    // keys for its own keyboard-driven resize before .onKeyPress ever saw
    // them (confirmed live — up/down nudge worked, left/right silently
    // did nothing). A local monitor intercepts at the application level,
    // ahead of any view's responder chain, so it isn't at the mercy of
    // whichever control happens to hold focus.
    @State private var keyMonitor: Any?

    // A guide still being dragged out from a ruler, not yet committed to
    // doc.guides — lives here (StageView, the common ancestor) rather than
    // on either ruler view, since the live preview it drives (
    // GuidePreviewLine) renders inside the content ZStack, a sibling of
    // the rulers in the layout below.
    @State private var rulerDragPreview: Guide?

    var body: some View {
        GeometryReader { geo in
            let showRulers = doc.rulersVisible
            let reserved = showRulers ? rulerThickness : 0
            let contentWidth = max(1, geo.size.width - reserved)
            let contentHeight = max(1, geo.size.height - reserved)
            let availableWidth = max(1, contentWidth - padding * 2)
            let availableHeight = max(1, contentHeight - padding * 2)
            let scale = min(availableWidth / doc.stageWidth, availableHeight / doc.stageHeight)
            let stageScreenWidth = doc.stageWidth * scale
            let stageScreenHeight = doc.stageHeight * scale
            let stageOriginX = (contentWidth - stageScreenWidth) / 2
            let stageOriginY = (contentHeight - stageScreenHeight) / 2

            VStack(spacing: 0) {
                if showRulers {
                    HStack(spacing: 0) {
                        Color(nsColor: .controlBackgroundColor)
                            .frame(width: rulerThickness, height: rulerThickness)
                        HorizontalRulerView(
                            scale: scale, xOrigin: stageOriginX, xLength: stageScreenWidth,
                            yOrigin: stageOriginY, stageHeight: doc.stageHeight, rulerThickness: rulerThickness,
                            dragPreview: $rulerDragPreview,
                            onDrop: { doc.addGuide(orientation: $0.orientation, position: $0.position) }
                        )
                        .frame(height: rulerThickness)
                    }
                }
                HStack(spacing: 0) {
                    if showRulers {
                        VerticalRulerView(
                            scale: scale, yOrigin: stageOriginY, yLength: stageScreenHeight,
                            xOrigin: stageOriginX, stageWidth: doc.stageWidth, rulerThickness: rulerThickness,
                            dragPreview: $rulerDragPreview,
                            onDrop: { doc.addGuide(orientation: $0.orientation, position: $0.position) }
                        )
                        .frame(width: rulerThickness)
                    }
                    ZStack {
                        Color(nsColor: .underPageBackgroundColor)
                        StageContentView(doc: doc, scale: scale)
                            // A visibly different border while editing a symbol in
                            // place — Flash's own edit-in-place cue is a tinted
                            // outline plus a dimmed rest-of-movie behind it; this
                            // MVP only does the outline (dimming the parent context
                            // needs rendering it and the symbol simultaneously,
                            // which nothing here does yet).
                            .overlay(Rectangle().stroke(
                                doc.editingPath.isEmpty ? Color.black.opacity(0.35) : Color.accentColor,
                                lineWidth: doc.editingPath.isEmpty ? 1 : 2
                            ))
                            .shadow(color: .black.opacity(0.25), radius: 6)
                        if doc.onionSkinEnabled {
                            OnionSkinOverlay(doc: doc, scale: scale)
                        }
                        if doc.guidesVisible {
                            GuidesOverlay(
                                doc: doc, scale: scale, stageOriginX: stageOriginX, stageOriginY: stageOriginY,
                                stageScreenWidth: stageScreenWidth, stageScreenHeight: stageScreenHeight
                            )
                            if let rulerDragPreview {
                                GuidePreviewLine(
                                    guide: rulerDragPreview, scale: scale, stageOriginX: stageOriginX, stageOriginY: stageOriginY,
                                    stageScreenWidth: stageScreenWidth, stageScreenHeight: stageScreenHeight
                                )
                            }
                        }
                        Text("\(Int(doc.stageWidth)) × \(Int(doc.stageHeight))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if !doc.editingPath.isEmpty {
                            EditingBreadcrumbBar(doc: doc)
                                .padding(.top, 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(width: contentWidth, height: contentHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                nudgeSelection(event) ? nil : event // nil consumes the event; returning it lets it propagate as normal
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Arrow keys move the selected Stage item — a placed text box or a
    /// symbol instance, whichever is currently selected — 1pt per press,
    /// 10pt with Shift held — Flash's classic nudge amounts — plus Delete
    /// (removes the selection), Cmd+C/Cmd+V (copy/paste it, pasting into
    /// whatever's currently selected on the Timeline, not necessarily back
    /// onto the same frame — so copy, click a different frame, paste lands
    /// it there), and Cmd+X (copy then delete in one step — cheap to add
    /// since it's just those two existing operations back to back). Text
    /// and symbol placements keep separate clipboards (`hasCopiedText`/
    /// `hasCopiedSymbolInstance`) — Cmd+V picks whichever one matches the
    /// current selection so pasting can't silently swap content kinds.
    /// Returns whether the event was consumed; when nothing applies it
    /// isn't, so the key event propagates normally. The actual moves/copy/
    /// paste/delete are TimelineDocument methods, each with their own
    /// direct unit test.
    private func nudgeSelection(_ event: NSEvent) -> Bool {
        // Don't steal keys from an actively-focused text field/editor
        // elsewhere in the app (the Actions panel's script editor, a
        // Properties panel field, etc.) — this monitor fires for every
        // keyDown app-wide, and Delete/Cmd+C/Cmd+V/Cmd+X need to mean "edit
        // the Stage selection" only when nothing else has focus that would
        // more naturally claim them.
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return false }

        // Escape backs out of edit-in-place one level at a time, same as
        // Flash's own convention — checked before the Cmd+-prefixed and
        // plain-selection branches below since it applies regardless of
        // whether anything on Stage happens to be selected.
        if event.keyCode == 53, !doc.editingPath.isEmpty { // Escape
            doc.exitSymbolEditing()
            return true
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                if doc.selectedPlacement != nil { doc.copySelectedPlacement(); return true }
                if doc.selectedSymbolPlacement != nil { doc.copySelectedSymbolPlacement(); return true }
                if doc.selectedShapePlacement != nil { doc.copySelectedShapePlacement(); return true }
                return false
            case "x":
                if doc.selectedPlacement != nil {
                    doc.copySelectedPlacement()
                    doc.deleteSelectedPlacement()
                    return true
                }
                if doc.selectedSymbolPlacement != nil {
                    doc.copySelectedSymbolPlacement()
                    doc.deleteSelectedSymbolPlacement()
                    return true
                }
                if doc.selectedShapePlacement != nil {
                    doc.copySelectedShapePlacement()
                    doc.deleteSelectedShapePlacement()
                    return true
                }
                return false
            case "v":
                guard let layer = doc.selectedLayer else { return false }
                // Symbol/shape paste wins if their clipboard happens to be
                // populated and that kind was (or still is) selected —
                // matches which selection Cmd+C would have just set.
                if doc.selectedSymbolPlacement != nil, doc.hasCopiedSymbolInstance {
                    doc.pasteSymbolInstance(layer: layer, at: doc.selectedFrame)
                    return true
                }
                if doc.selectedShapePlacement != nil, doc.hasCopiedShape {
                    doc.pasteShape(layer: layer, at: doc.selectedFrame)
                    return true
                }
                if doc.hasCopiedText {
                    doc.pastePlacedText(layer: layer, at: doc.selectedFrame)
                    return true
                }
                if doc.hasCopiedSymbolInstance {
                    doc.pasteSymbolInstance(layer: layer, at: doc.selectedFrame)
                    return true
                }
                if doc.hasCopiedShape {
                    doc.pasteShape(layer: layer, at: doc.selectedFrame)
                    return true
                }
                return false
            default:
                return false
            }
        }

        guard doc.selectedPlacement != nil || doc.selectedSymbolPlacement != nil || doc.selectedShapePlacement != nil else { return false }

        if event.keyCode == 51 || event.keyCode == 117 { // Delete (backspace) / Forward Delete
            if doc.selectedPlacement != nil { doc.deleteSelectedPlacement() }
            if doc.selectedSymbolPlacement != nil { doc.deleteSelectedSymbolPlacement() }
            if doc.selectedShapePlacement != nil { doc.deleteSelectedShapePlacement() }
            return true
        }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let (dx, dy): (CGFloat, CGFloat)
        switch Int(event.keyCode) {
        case 126: (dx, dy) = (0, -step) // up
        case 125: (dx, dy) = (0, step)  // down
        case 123: (dx, dy) = (-step, 0) // left
        case 124: (dx, dy) = (step, 0)  // right
        default: return false
        }
        if doc.selectedPlacement != nil { doc.nudgeSelectedPlacement(dx: dx, dy: dy) }
        if doc.selectedSymbolPlacement != nil { doc.nudgeSelectedSymbolPlacement(dx: dx, dy: dy) }
        if doc.selectedShapePlacement != nil { doc.nudgeSelectedShapePlacement(dx: dx, dy: dy) }
        return true
    }
}
