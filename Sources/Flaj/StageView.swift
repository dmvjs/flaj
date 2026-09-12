import SwiftUI
import AppKit

/// The Stage's actual content — background + text objects — at a given
/// `scale` factor. Shared between the live preview (StageView, scaled to
/// fit its panel) and GIF export (rendered 1:1 at the Stage's real pixel
/// size via ImageRenderer), so what you see while editing is exactly what
/// gets exported.
struct StageContentView: View {
    let doc: TimelineDocument
    var scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(doc.stageColor)
                .contentShape(Rectangle())
                .onTapGesture { location in handleBaseTap(at: location) }
            ForEach(doc.stageObjects) { obj in
                StageTextView(obj: obj, scale: scale)
            }
            ForEach(doc.visibleLayers.filter { !$0.hidden }) { layer in
                if let kf = layer.governingKeyframe(at: doc.playhead) {
                    if layer.textFrames[kf] != nil {
                        StagePlacedTextView(doc: doc, layer: layer, keyframe: kf, scale: scale)
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
        case .selection:
            doc.selectedPlacement = nil
            doc.selectedSymbolPlacement = nil
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
                                  let symbol = doc.library.first(where: { $0.id == instance.symbolID }) {
                            ghost(instance, symbol: symbol, tint: offset < 0 ? .blue : .orange, spin: spinDegrees(layer: layer, at: frame))
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
    /// text/font/color to render from the Library entry it references,
    /// since (unlike PlacedText) an instance's own struct doesn't carry them.
    private func ghost(_ p: SymbolInstance, symbol: FlajSymbol, tint: Color, spin: Double) -> some View {
        Text(symbol.text)
            .font(.custom(symbol.fontName, size: symbol.fontSize * scale))
            .bold(symbol.bold)
            .italic(symbol.italic)
            .foregroundStyle(tint)
            .multilineTextAlignment(symbol.alignment.swiftUIAlignment)
            .frame(width: p.width * scale, height: p.height * scale, alignment: symbol.alignment.frameAlignment)
            .opacity(0.35)
            .scaleEffect(p.scale)
            .rotationEffect(.degrees(p.rotation + spin))
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

    private var spinDegrees: Double {
        guard let endKf = layer.tweenTarget(from: keyframe), endKf > keyframe else { return 0 }
        let settings = layer.tweenSettings[keyframe] ?? TweenSettings()
        let rawT = Double(doc.playhead - keyframe) / Double(endKf - keyframe)
        return settings.spinDegrees(at: rawT)
    }

    var body: some View {
        if let shown = displayPlacement, let symbol {
            Text(symbol.text)
                .font(.custom(symbol.fontName, size: symbol.fontSize * scale))
                .bold(symbol.bold)
                .italic(symbol.italic)
                .foregroundStyle(Color(hex: symbol.colorHex))
                .multilineTextAlignment(symbol.alignment.swiftUIAlignment)
                .frame(width: shown.width * scale, height: shown.height * scale,
                       alignment: symbol.alignment.frameAlignment)
                .opacity(shown.opacity)
                .contentShape(Rectangle())
                .overlay(isSelected ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
                .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
                .scaleEffect(shown.scale)
                .rotationEffect(.degrees(shown.rotation + spinDegrees))
                .position(x: (shown.x + shown.width / 2) * scale, y: (shown.y + shown.height / 2) * scale)
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

/// Flash's "Stage" — the fixed-size render surface, sized/colored from
/// frame scripts via the `stage`/`bg` JS globals (see TimelineModel).
/// The Stage itself has fixed pixel dimensions, but this view always scales
/// it to fit the available panel with real padding, at any window size —
/// a literal `.frame(width:height:)` at the Stage's raw pixel size would
/// overflow edge-to-edge whenever the panel is smaller than the Stage.
struct StageView: View {
    let doc: TimelineDocument
    private let padding: CGFloat = 28

    // A local NSEvent monitor rather than SwiftUI's .onKeyPress: the Stage
    // sits inside HSplitView, whose divider intercepts left/right arrow
    // keys for its own keyboard-driven resize before .onKeyPress ever saw
    // them (confirmed live — up/down nudge worked, left/right silently
    // did nothing). A local monitor intercepts at the application level,
    // ahead of any view's responder chain, so it isn't at the mercy of
    // whichever control happens to hold focus.
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(1, geo.size.width - padding * 2)
            let availableHeight = max(1, geo.size.height - padding * 2)
            let scale = min(availableWidth / doc.stageWidth, availableHeight / doc.stageHeight)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                StageContentView(doc: doc, scale: scale)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6)
                if doc.onionSkinEnabled {
                    OnionSkinOverlay(doc: doc, scale: scale)
                }
                Text("\(Int(doc.stageWidth)) × \(Int(doc.stageHeight))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                if doc.selectedPlacement != nil { doc.copySelectedPlacement(); return true }
                if doc.selectedSymbolPlacement != nil { doc.copySelectedSymbolPlacement(); return true }
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
                return false
            case "v":
                guard let layer = doc.selectedLayer else { return false }
                // Symbol paste wins if both clipboards happen to be
                // populated and a symbol instance is (or was) selected —
                // matches which selection Cmd+C would have just set.
                if doc.selectedSymbolPlacement != nil, doc.hasCopiedSymbolInstance {
                    doc.pasteSymbolInstance(layer: layer, at: doc.selectedFrame)
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
                return false
            default:
                return false
            }
        }

        guard doc.selectedPlacement != nil || doc.selectedSymbolPlacement != nil else { return false }

        if event.keyCode == 51 || event.keyCode == 117 { // Delete (backspace) / Forward Delete
            if doc.selectedPlacement != nil { doc.deleteSelectedPlacement() }
            if doc.selectedSymbolPlacement != nil { doc.deleteSelectedSymbolPlacement() }
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
        return true
    }
}
