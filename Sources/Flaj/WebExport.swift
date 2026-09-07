import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// How the exported Stage scales to whatever page or iframe embeds it —
/// same vocabulary as CSS `object-fit`.
enum StageFit: String, Codable, CaseIterable, Equatable {
    case contain   // scaled to fit entirely on screen, letterboxed if needed
    case cover     // scaled to fill the screen, cropped if needed
    case none      // rendered at its real pixel size, unscaled

    var label: String {
        switch self {
        case .contain: return "Fit"
        case .cover: return "Fill"
        case .none: return "Actual Size"
        }
    }
}

/// Where the Stage sits within the page when `StageFit` leaves empty space
/// around it (always true for `.contain`, sometimes for `.none`).
enum StageAlignment: String, Codable, CaseIterable, Equatable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing
}

extension TimelineDocument {
    /// Entry point for "Export Web Page…" — opens the settings sheet first;
    /// the sheet's own Export button carries on to `beginWebExportSavePanel()`.
    func exportWebPage() {
        stop()
        webExportSheetPresented = true
    }

    /// Called after the settings sheet is dismissed to pick a destination
    /// file. Options are set on `doc` already, so the panel itself carries
    /// no accessory view.
    func beginWebExportSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = webExportTitle.isEmpty ? "Untitled.html" : "\(webExportTitle).html"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                self.performWebExport(to: url)
            }
        }
    }

    /// Exports a single self-contained HTML file: the document serialized
    /// as the same JSON `.flaj` files use (see Persistence.swift), plus a
    /// small vanilla-JS player (Resources/player.js) that reimplements the
    /// playback/tween/frame-script runtime in the browser. Unlike GIF
    /// export, which bakes one run through the movie into flat frames, this
    /// stays live — the exported page actually runs the frame scripts.
    ///
    /// Internal rather than private so tests can drive it directly against
    /// a known `TimelineDocument`, same as `performGIFExport`.
    func performWebExport(to url: URL) {
        do {
            guard
                let templateURL = Bundle.module.url(forResource: "export-template", withExtension: "html", subdirectory: "Resources"),
                let playerURL = Bundle.module.url(forResource: "player", withExtension: "js", subdirectory: "Resources")
            else {
                logToConsole("Web export failed: missing bundled export template", level: .error)
                return
            }
            let template = try String(contentsOf: templateURL, encoding: .utf8)
            let playerJS = try String(contentsOf: playerURL, encoding: .utf8)

            let jsonData = try JSONEncoder().encode(makeSaveFile())
            guard var json = String(data: jsonData, encoding: .utf8) else {
                logToConsole("Web export failed: couldn't encode document as JSON", level: .error)
                return
            }
            // The HTML tokenizer ends a <script> at the literal text
            // "</script", even inside a JSON string it isn't parsing as JS —
            // a frame script the user wrote could easily contain that
            // substring. `\/` is a valid JSON escape for `/`, so this
            // round-trips through JSON.parse in the player intact.
            json = json.replacingOccurrences(of: "</", with: "<\\/")

            let title = webExportTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : webExportTitle
            let html = template
                .replacingOccurrences(of: "__FLAJ_TITLE__", with: title)
                .replacingOccurrences(of: "__FLAJ_PAGE_BACKGROUND__", with: webExportPageBackground.cssString)
                .replacingOccurrences(of: "__FLAJ_DOCUMENT_JSON__", with: json)
                .replacingOccurrences(of: "__FLAJ_PLAYER_JS__", with: webExportMinify ? Self.minifyJS(playerJS) : playerJS)

            try html.write(to: url, atomically: true, encoding: .utf8)
            logToConsole("Exported web page to \(url.lastPathComponent)", level: .log)
        } catch {
            logToConsole("Web export failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// A conservative comment/whitespace strip, not a real minifier — no
    /// identifier renaming or statement joining, which need an actual JS
    /// parser to do safely. Safe here specifically because `player.js` is
    /// fixed, first-party source with no regex literals, no `//`/`/*`
    /// inside strings or template literals, and every statement already
    /// ends in `;` — so removing comment/blank lines can't shift meaning
    /// via automatic-semicolon-insertion the way it could for arbitrary JS.
    /// A trailing `// like this` comment is left alone: telling those apart
    /// from a `//` that's actually inside a string needs the same real
    /// parser, and leaving a handful in costs little.
    static func minifyJS(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression
        )
        let lines = withoutBlockComments.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return (trimmed.isEmpty || trimmed.hasPrefix("//")) ? nil : trimmed
        }
        return lines.joined(separator: "\n")
    }
}

/// Interstitial modal shown before the save panel for "Export Web Page…" —
/// title, fit, stage alignment, page background, and minify, all written
/// straight to `doc` so they're remembered with the document like the
/// Stage's own size and color are. Confirming here dismisses the sheet and
/// hands off to the (now option-free) NSSavePanel in `beginWebExportSavePanel()`.
struct WebExportSettingsSheet: View {
    @Bindable var doc: TimelineDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Web Page")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("PAGE TITLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Untitled", text: $doc.webExportTitle)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FIT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $doc.webExportFit) {
                        ForEach(StageFit.allCases, id: \.self) { fit in
                            Text(fit.label).tag(fit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("POSITION").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    StageAlignmentGrid(selection: $doc.webExportAlignment)
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PAGE BACKGROUND").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    // Distinct from the Stage's own bg.color() — this is
                    // what shows in any letterboxing, or through a
                    // transparent Stage. Opacity is included in the swatch,
                    // so dragging it to 0 is how you get "transparent".
                    ColorPicker("", selection: $doc.webExportPageBackground, supportsOpacity: true)
                        .labelsHidden()
                }
                Toggle("Minify JS", isOn: $doc.webExportMinify)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    doc.beginWebExportSavePanel()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

private struct StageAlignmentGrid: View {
    @Binding var selection: StageAlignment

    private static let order: [StageAlignment] = [
        .topLeading, .top, .topTrailing,
        .leading, .center, .trailing,
        .bottomLeading, .bottom, .bottomTrailing
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 3), count: 3), spacing: 3) {
            ForEach(Self.order, id: \.self) { alignment in
                Button(action: { selection = alignment }) {
                    Circle()
                        .fill(selection == alignment ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .frame(width: 20, height: 20)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
