import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The .flaj on-disk format (JSON under the hood)

struct FlajDocumentFile: Codable {
    var version = 1
    var totalFrames: Int
    var fps: Double
    var stageWidth: Double
    var stageHeight: Double
    var stageColorHex: String
    var webExportTitle: String
    var webExportFit: StageFit
    var webExportAlignment: StageAlignment
    var webExportPageBackgroundHex: String
    var webExportPageBackgroundOpacity: Double
    var webExportMinify: Bool
    var layers: [FlajLayerFile]

    private enum CodingKeys: String, CodingKey {
        case version, totalFrames, fps, stageWidth, stageHeight, stageColorHex,
             webExportTitle, webExportFit, webExportAlignment,
             webExportPageBackgroundHex, webExportPageBackgroundOpacity, webExportMinify, layers
    }

    init(version: Int = 1, totalFrames: Int, fps: Double, stageWidth: Double, stageHeight: Double,
         stageColorHex: String, webExportTitle: String = "", webExportFit: StageFit = .contain,
         webExportAlignment: StageAlignment = .center, webExportPageBackgroundHex: String = "#000000",
         webExportPageBackgroundOpacity: Double = 0, webExportMinify: Bool = true, layers: [FlajLayerFile]) {
        self.version = version
        self.totalFrames = totalFrames
        self.fps = fps
        self.stageWidth = stageWidth
        self.stageHeight = stageHeight
        self.stageColorHex = stageColorHex
        self.webExportTitle = webExportTitle
        self.webExportFit = webExportFit
        self.webExportAlignment = webExportAlignment
        self.webExportPageBackgroundHex = webExportPageBackgroundHex
        self.webExportPageBackgroundOpacity = webExportPageBackgroundOpacity
        self.webExportMinify = webExportMinify
        self.layers = layers
    }

    // Custom decode so .flaj files saved before the web-export options existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        totalFrames = try c.decode(Int.self, forKey: .totalFrames)
        fps = try c.decode(Double.self, forKey: .fps)
        stageWidth = try c.decode(Double.self, forKey: .stageWidth)
        stageHeight = try c.decode(Double.self, forKey: .stageHeight)
        stageColorHex = try c.decode(String.self, forKey: .stageColorHex)
        webExportTitle = try c.decodeIfPresent(String.self, forKey: .webExportTitle) ?? ""
        webExportFit = try c.decodeIfPresent(StageFit.self, forKey: .webExportFit) ?? .contain
        webExportAlignment = try c.decodeIfPresent(StageAlignment.self, forKey: .webExportAlignment) ?? .center
        webExportPageBackgroundHex = try c.decodeIfPresent(String.self, forKey: .webExportPageBackgroundHex) ?? "#000000"
        webExportPageBackgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .webExportPageBackgroundOpacity) ?? 0
        webExportMinify = try c.decodeIfPresent(Bool.self, forKey: .webExportMinify) ?? true
        layers = try c.decode([FlajLayerFile].self, forKey: .layers)
    }
}

struct FlajLayerFile: Codable {
    // Not user-visible, not meaningful across separate documents — purely
    // so a layer's identity survives a round trip through this struct
    // (undo/redo rebuilds `layers` from one of these snapshots; without a
    // stable id, every undo would also silently drop the current layer/
    // text/tween selection, since TLLayer.id is otherwise freshly
    // generated per instance). Defaults to a fresh UUID on decode so
    // pre-existing .flaj files without this field still open.
    var id: UUID
    var name: String
    var swatchHex: String
    var kind: LayerKind
    var indent: Int
    var locked: Bool
    var hidden: Bool
    var expanded: Bool
    var frames: [FrameMark]
    var frameScripts: [Int: String]
    var textFrames: [Int: PlacedText]
    var tweenSettings: [Int: TweenSettings]
    var colorTweenSettings: [Int: TweenSettings]
    var frameLabels: [Int: String]

    private enum CodingKeys: String, CodingKey {
        case id, name, swatchHex, kind, indent, locked, hidden, expanded, frames, frameScripts, textFrames,
             tweenSettings, colorTweenSettings, frameLabels
    }

    init(id: UUID = UUID(), name: String, swatchHex: String, kind: LayerKind, indent: Int, locked: Bool, hidden: Bool,
         expanded: Bool, frames: [FrameMark], frameScripts: [Int: String], textFrames: [Int: PlacedText],
         tweenSettings: [Int: TweenSettings], colorTweenSettings: [Int: TweenSettings], frameLabels: [Int: String] = [:]) {
        self.id = id
        self.name = name
        self.swatchHex = swatchHex
        self.kind = kind
        self.indent = indent
        self.locked = locked
        self.hidden = hidden
        self.expanded = expanded
        self.frames = frames
        self.frameScripts = frameScripts
        self.textFrames = textFrames
        self.tweenSettings = tweenSettings
        self.colorTweenSettings = colorTweenSettings
        self.frameLabels = frameLabels
    }

    // Custom decode so .flaj files saved before id/textFrames/tweenSettings/
    // colorTweenSettings/frameLabels existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        swatchHex = try c.decode(String.self, forKey: .swatchHex)
        kind = try c.decode(LayerKind.self, forKey: .kind)
        indent = try c.decode(Int.self, forKey: .indent)
        locked = try c.decode(Bool.self, forKey: .locked)
        hidden = try c.decode(Bool.self, forKey: .hidden)
        expanded = try c.decode(Bool.self, forKey: .expanded)
        frames = try c.decode([FrameMark].self, forKey: .frames)
        frameScripts = try c.decode([Int: String].self, forKey: .frameScripts)
        textFrames = try c.decodeIfPresent([Int: PlacedText].self, forKey: .textFrames) ?? [:]
        tweenSettings = try c.decodeIfPresent([Int: TweenSettings].self, forKey: .tweenSettings) ?? [:]
        colorTweenSettings = try c.decodeIfPresent([Int: TweenSettings].self, forKey: .colorTweenSettings) ?? [:]
        frameLabels = try c.decodeIfPresent([Int: String].self, forKey: .frameLabels) ?? [:]
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(white: 1, alpha: 1)
        return String(
            format: "#%02X%02X%02X",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }

    var opacityComponent: Double {
        Double((NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(white: 1, alpha: 1)).alphaComponent)
    }

    /// CSS color literal for this exact color, alpha included — "transparent"
    /// when fully transparent, `#rrggbb` when fully opaque, `rgba(...)`
    /// otherwise. Used for `webExportPageBackground`, which (unlike
    /// `stageColor`) can be partially or fully transparent.
    var cssString: String {
        let opacity = opacityComponent
        if opacity <= 0.001 { return "transparent" }
        if opacity >= 0.999 { return hexString }
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(white: 1, alpha: 1)
        return "rgba(\(Int(round(ns.redComponent * 255))), \(Int(round(ns.greenComponent * 255))), \(Int(round(ns.blueComponent * 255))), \(opacity))"
    }
}

// MARK: - Save / Open

extension TimelineDocument {
    private static let flajType = UTType(filenameExtension: "flaj", conformingTo: .json) ?? .json

    func makeSaveFile() -> FlajDocumentFile {
        FlajDocumentFile(
            totalFrames: totalFrames,
            fps: fps,
            stageWidth: Double(stageWidth),
            stageHeight: Double(stageHeight),
            stageColorHex: stageColor.hexString,
            webExportTitle: webExportTitle,
            webExportFit: webExportFit,
            webExportAlignment: webExportAlignment,
            webExportPageBackgroundHex: webExportPageBackground.hexString,
            webExportPageBackgroundOpacity: webExportPageBackground.opacityComponent,
            webExportMinify: webExportMinify,
            layers: layers.map { layer in
                FlajLayerFile(
                    id: layer.id, name: layer.name, swatchHex: layer.swatch.hexString, kind: layer.kind,
                    indent: layer.indent, locked: layer.locked, hidden: layer.hidden,
                    expanded: layer.expanded, frames: layer.frames, frameScripts: layer.frameScripts,
                    textFrames: layer.textFrames, tweenSettings: layer.tweenSettings,
                    colorTweenSettings: layer.colorTweenSettings, frameLabels: layer.frameLabels
                )
            }
        )
    }

    /// Restores every field `FlajDocumentFile` captures. Shared by
    /// `load(from:)` (opening a file — also resets playhead/selection/
    /// console, below) and undo/redo (`Undo.swift`), which instead leave
    /// that transient state alone and just re-resolve it against the new
    /// `layers` array, since undoing a small edit shouldn't also yank the
    /// playhead back to frame 1 or drop the current selection.
    func applySaveFile(_ file: FlajDocumentFile) {
        stop()
        resetRuntime()
        totalFrames = file.totalFrames
        fps = file.fps
        stageWidth = CGFloat(file.stageWidth)
        stageHeight = CGFloat(file.stageHeight)
        stageColor = Color(hex: file.stageColorHex)
        webExportTitle = file.webExportTitle
        webExportFit = file.webExportFit
        webExportAlignment = file.webExportAlignment
        webExportPageBackground = Color(hex: file.webExportPageBackgroundHex).opacity(file.webExportPageBackgroundOpacity)
        webExportMinify = file.webExportMinify
        layers = file.layers.map { lf in
            let layer = TLLayer(
                id: lf.id, name: lf.name, swatch: Color(hex: lf.swatchHex), kind: lf.kind, indent: lf.indent,
                locked: lf.locked, hidden: lf.hidden, frames: lf.frames
            )
            layer.expanded = lf.expanded
            layer.frameScripts = lf.frameScripts
            layer.textFrames = lf.textFrames
            layer.tweenSettings = lf.tweenSettings
            layer.colorTweenSettings = lf.colorTweenSettings
            layer.frameLabels = lf.frameLabels
            return layer
        }
    }

    func load(from file: FlajDocumentFile) {
        applySaveFile(file)
        selectedLayerID = layers.first?.id
        playhead = 1
        selectedFrame = 1
        consoleMessages.removeAll()
    }

    func saveDocument(forceDialog: Bool = false) {
        if let url = currentFileURL, !forceDialog {
            write(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.flajType]
        panel.nameFieldStringValue = "Untitled.flaj"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                self.currentFileURL = url
                self.write(to: url)
            }
        }
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.flajType]
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                do {
                    let data = try Data(contentsOf: url)
                    let file = try JSONDecoder().decode(FlajDocumentFile.self, from: data)
                    self.load(from: file)
                    self.currentFileURL = url
                } catch {
                    self.logToConsole("Open failed: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    private func write(to url: URL) {
        do {
            let data = try JSONEncoder().encode(makeSaveFile())
            try data.write(to: url)
        } catch {
            logToConsole("Save failed: \(error.localizedDescription)", level: .error)
        }
    }
}
