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
            ForEach(doc.stageObjects) { obj in
                StageTextView(obj: obj, scale: scale)
            }
        }
        .frame(width: doc.stageWidth * scale, height: doc.stageHeight * scale)
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
