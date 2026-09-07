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
                if let kf = layer.governingKeyframe(at: doc.playhead), layer.textFrames[kf] != nil {
                    StagePlacedTextView(doc: doc, layer: layer, keyframe: kf, scale: scale)
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
        }
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
        layer.interpolatedPlacedText(at: doc.playhead) ?? placement
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
            .rotationEffect(.degrees(spinDegrees))
            .position(x: (shown.x + shown.width / 2) * scale, y: (shown.y + shown.height / 2) * scale)
            .onTapGesture { doc.selectedPlacement = ref }
            .gesture(moveGesture)
            // A stable hook for UI automation/accessibility tooling to find
            // this exact element — the SwiftUI/AppKit equivalent of a
            // data-testid, invisible to VoiceOver users (unlike
            // accessibilityLabel), queryable via the accessibility tree.
            .accessibilityIdentifier("stage-placed-text")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard doc.selectedTool == .selection else { return }
                doc.selectedPlacement = ref
                let start = moveStart ?? placement
                if moveStart == nil { moveStart = start }
                var p = start
                p.x = start.x + value.translation.width / scale
                p.y = start.y + value.translation.height / scale
                layer.textFrames[keyframe] = p
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = resizeStart ?? placement
                        if resizeStart == nil { resizeStart = start }
                        var p = start
                        p.width = max(20, start.width + value.translation.width / scale)
                        p.height = max(16, start.height + value.translation.height / scale)
                        layer.textFrames[keyframe] = p
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }
}

private struct StageTextView: View {
    let obj: StageObject
    var scale: CGFloat

    var body: some View {
        Text(obj.text)
            .font(.system(size: obj.fontSize * scale))
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

    /// Arrow keys move the selected placed-text box 1pt per press, 10pt
    /// with Shift held — Flash's classic nudge amounts. Returns whether the
    /// event was consumed; when nothing's selected (or it's not an arrow
    /// key) it isn't, so the key event propagates normally. The actual
    /// move is TimelineDocument.nudgeSelectedPlacement, which has its own
    /// direct unit test.
    private func nudgeSelection(_ event: NSEvent) -> Bool {
        guard doc.selectedPlacement != nil else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 126: doc.nudgeSelectedPlacement(dx: 0, dy: -step) // up
        case 125: doc.nudgeSelectedPlacement(dx: 0, dy: step)  // down
        case 123: doc.nudgeSelectedPlacement(dx: -step, dy: 0) // left
        case 124: doc.nudgeSelectedPlacement(dx: step, dy: 0)  // right
        default: return false
        }
        return true
    }
}
