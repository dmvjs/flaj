import SwiftUI

/// Flash's Tools panel, reduced to the two tools this app currently
/// supports — Selection (move/resize placed text) and Text (click the
/// Stage to place a new text box).
struct ToolbarView: View {
    @ObservedObject var doc: TimelineDocument

    var body: some View {
        VStack(spacing: 4) {
            toolButton(.selection, systemImage: "cursorarrow")
            toolButton(.text, systemImage: "textformat")
            Spacer()
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func toolButton(_ tool: TimelineDocument.StageTool, systemImage: String) -> some View {
        Button(action: { doc.selectedTool = tool }) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .background(
                    doc.selectedTool == tool ? Color.accentColor.opacity(0.3) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }
}
