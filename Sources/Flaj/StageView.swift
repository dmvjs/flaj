import SwiftUI

/// The Stage's actual content — background + text objects — at a given
/// `scale` factor. Shared between the live preview (StageView, scaled to
/// fit its panel) and GIF export (rendered 1:1 at the Stage's real pixel
/// size via ImageRenderer), so what you see while editing is exactly what
/// gets exported.
struct StageContentView: View {
    @ObservedObject var doc: TimelineDocument
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
    @ObservedObject var doc: TimelineDocument
    @ObservedObject var layer: TLLayer
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

    var body: some View {
        Text(placement.text)
            .font(.custom(placement.fontName, size: placement.fontSize * scale))
            .bold(placement.bold)
            .italic(placement.italic)
            .foregroundStyle(Color(hex: placement.colorHex))
            .multilineTextAlignment(placement.alignment.swiftUIAlignment)
            .frame(width: placement.width * scale, height: placement.height * scale,
                   alignment: placement.alignment.frameAlignment)
            .contentShape(Rectangle())
            .overlay(isSelected ? Rectangle().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .overlay(alignment: .bottomTrailing) { if isSelected { resizeHandle } }
            .position(x: (placement.x + placement.width / 2) * scale, y: (placement.y + placement.height / 2) * scale)
            .onTapGesture { doc.selectedPlacement = ref }
            .gesture(moveGesture)
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
    @ObservedObject var obj: StageObject
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
    @ObservedObject var doc: TimelineDocument
    private let padding: CGFloat = 28

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
    }
}
