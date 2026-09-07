import SwiftUI

/// Flash's Output panel — every console.log/warn/error and trace() call
/// from frame scripts lands here, tagged with the frame it ran on.
struct DebugConsoleView: View {
    let doc: TimelineDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10))
                Text("Debug Console").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: { doc.consoleMessages.removeAll() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(doc.consoleMessages) { message in
                            HStack(alignment: .top, spacing: 6) {
                                Text("f\(message.frame)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(message.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: message.level))
                                    .textSelection(.enabled)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: doc.consoleMessages.count) { _, _ in
                    if let last = doc.consoleMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for level: ConsoleMessage.Level) -> Color {
        switch level {
        case .log: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
