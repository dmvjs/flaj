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
    var library: [FlajSymbolFile]
    var guides: [Guide]

    private enum CodingKeys: String, CodingKey {
        case version, totalFrames, fps, stageWidth, stageHeight, stageColorHex,
             webExportTitle, webExportFit, webExportAlignment,
             webExportPageBackgroundHex, webExportPageBackgroundOpacity, webExportMinify, layers, library, guides
    }

    init(version: Int = 1, totalFrames: Int, fps: Double, stageWidth: Double, stageHeight: Double,
         stageColorHex: String, webExportTitle: String = "", webExportFit: StageFit = .contain,
         webExportAlignment: StageAlignment = .center, webExportPageBackgroundHex: String = "#000000",
         webExportPageBackgroundOpacity: Double = 0, webExportMinify: Bool = true, layers: [FlajLayerFile],
         library: [FlajSymbolFile] = [], guides: [Guide] = []) {
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
        self.library = library
        self.guides = guides
    }

    // Custom decode so .flaj files saved before the web-export options (or
    // the Library, or guides) existed still open.
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
        library = try c.decodeIfPresent([FlajSymbolFile].self, forKey: .library) ?? []
        guides = try c.decodeIfPresent([Guide].self, forKey: .guides) ?? []
    }
}

/// Converts a live `TLLayer` to/from its plain-Codable file shape — shared
/// by the document's own top-level `layers` and a `FlajSymbolFile`'s nested
/// ones (a symbol's Timeline is the exact same shape as the document's),
/// so this one place is the only thing that needs updating when a layer
/// gains a new field, instead of two near-identical construction sites.
extension FlajLayerFile {
    init(_ layer: TLLayer) {
        self.init(
            id: layer.id, name: layer.name, swatchHex: layer.swatch.hexString, kind: layer.kind,
            indent: layer.indent, locked: layer.locked, hidden: layer.hidden, masked: layer.masked,
            expanded: layer.expanded, frames: layer.frames, frameScripts: layer.frameScripts,
            textFrames: layer.textFrames, symbolFrames: layer.symbolFrames, shapeFrames: layer.shapeFrames,
            groupFrames: layer.groupFrames, tweenSettings: layer.tweenSettings,
            colorTweenSettings: layer.colorTweenSettings, frameLabels: layer.frameLabels
        )
    }
}

extension TLLayer {
    convenience init(_ file: FlajLayerFile) {
        self.init(
            id: file.id, name: file.name, swatch: Color(hex: file.swatchHex), kind: file.kind, indent: file.indent,
            locked: file.locked, hidden: file.hidden, frames: file.frames
        )
        masked = file.masked
        expanded = file.expanded
        frameScripts = file.frameScripts
        textFrames = file.textFrames
        symbolFrames = file.symbolFrames
        shapeFrames = file.shapeFrames
        groupFrames = file.groupFrames
        tweenSettings = file.tweenSettings
        colorTweenSettings = file.colorTweenSettings
        frameLabels = file.frameLabels
    }
}

/// A Library symbol's on-disk shape — `layers`/`totalFrames` are the exact
/// same nested Timeline `FlajSymbol` itself carries at runtime, converted
/// through `FlajLayerFile` for the same reason a document's own `layers`
/// are (a `TLLayer` isn't itself `Codable`).
struct FlajSymbolFile: Codable {
    var id: UUID
    var name: String
    var layers: [FlajLayerFile]
    var totalFrames: Int

    private enum CodingKeys: String, CodingKey { case id, name, layers, totalFrames }

    init(id: UUID, name: String, layers: [FlajLayerFile], totalFrames: Int) {
        self.id = id
        self.name = name
        self.layers = layers
        self.totalFrames = totalFrames
    }

    init(_ symbol: FlajSymbol) {
        self.init(id: symbol.id, name: symbol.name, layers: symbol.layers.map(FlajLayerFile.init), totalFrames: symbol.totalFrames)
    }

    /// Accepts either shape: the current nested `layers`/`totalFrames`, or
    /// a pre-nested-Timeline .flaj file's flat `text`/`fontName`/`fontSize`/
    /// `bold`/`italic`/`colorHex`/`alignment` fields, which get synthesized
    /// into the same one-layer/one-frame Timeline `FlajSymbol`'s own flat
    /// convenience initializer builds — so a symbol saved before this
    /// change still opens looking exactly the same.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let decodedLayers = try c.decodeIfPresent([FlajLayerFile].self, forKey: .layers) {
            layers = decodedLayers
            totalFrames = try c.decodeIfPresent(Int.self, forKey: .totalFrames) ?? 1
        } else {
            let flat = try FlatSymbolFields(from: decoder)
            let symbol = FlajSymbol(
                id: id, name: name, text: flat.text, fontName: flat.fontName, fontSize: flat.fontSize,
                bold: flat.bold, italic: flat.italic, colorHex: flat.colorHex, alignment: flat.alignment
            )
            layers = symbol.layers.map(FlajLayerFile.init)
            totalFrames = symbol.totalFrames
        }
    }

    /// Just the old flat fields, decoded with the exact defaults
    /// `FlajSymbol`'s pre-Timeline flat initializer used to have — kept
    /// separate from `FlajSymbolFile.CodingKeys` since these aren't part of
    /// the current on-disk shape at all, only ever read as a migration path.
    private struct FlatSymbolFields: Decodable {
        var text: String
        var fontName: String
        var fontSize: CGFloat
        var bold: Bool
        var italic: Bool
        var colorHex: String
        var alignment: TextHAlign

        enum CodingKeys: String, CodingKey { case text, fontName, fontSize, bold, italic, colorHex, alignment }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? "Text"
            fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
            fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 24
            bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#000000"
            alignment = try c.decodeIfPresent(TextHAlign.self, forKey: .alignment) ?? .leading
        }
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
    var masked: Bool
    var expanded: Bool
    var frames: [FrameMark]
    var frameScripts: [Int: String]
    var textFrames: [Int: PlacedText]
    var symbolFrames: [Int: SymbolInstance]
    var shapeFrames: [Int: PlacedShape]
    var groupFrames: [Int: PlacedGroup]
    var tweenSettings: [Int: TweenSettings]
    var colorTweenSettings: [Int: TweenSettings]
    var frameLabels: [Int: FrameLabel]

    private enum CodingKeys: String, CodingKey {
        case id, name, swatchHex, kind, indent, locked, hidden, masked, expanded, frames, frameScripts, textFrames,
             symbolFrames, shapeFrames, groupFrames, tweenSettings, colorTweenSettings, frameLabels
    }

    init(id: UUID = UUID(), name: String, swatchHex: String, kind: LayerKind, indent: Int, locked: Bool, hidden: Bool,
         masked: Bool = false, expanded: Bool, frames: [FrameMark], frameScripts: [Int: String], textFrames: [Int: PlacedText],
         symbolFrames: [Int: SymbolInstance] = [:], shapeFrames: [Int: PlacedShape] = [:], groupFrames: [Int: PlacedGroup] = [:],
         tweenSettings: [Int: TweenSettings], colorTweenSettings: [Int: TweenSettings], frameLabels: [Int: FrameLabel] = [:]) {
        self.id = id
        self.name = name
        self.swatchHex = swatchHex
        self.kind = kind
        self.indent = indent
        self.locked = locked
        self.hidden = hidden
        self.masked = masked
        self.expanded = expanded
        self.frames = frames
        self.frameScripts = frameScripts
        self.textFrames = textFrames
        self.symbolFrames = symbolFrames
        self.shapeFrames = shapeFrames
        self.groupFrames = groupFrames
        self.tweenSettings = tweenSettings
        self.colorTweenSettings = colorTweenSettings
        self.frameLabels = frameLabels
    }

    // Custom decode so .flaj files saved before id/textFrames/symbolFrames/
    // shapeFrames/groupFrames/tweenSettings/colorTweenSettings/masked existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        swatchHex = try c.decode(String.self, forKey: .swatchHex)
        kind = try c.decode(LayerKind.self, forKey: .kind)
        indent = try c.decode(Int.self, forKey: .indent)
        locked = try c.decode(Bool.self, forKey: .locked)
        hidden = try c.decode(Bool.self, forKey: .hidden)
        masked = try c.decodeIfPresent(Bool.self, forKey: .masked) ?? false
        expanded = try c.decode(Bool.self, forKey: .expanded)
        frames = try c.decode([FrameMark].self, forKey: .frames)
        frameScripts = try c.decode([Int: String].self, forKey: .frameScripts)
        textFrames = try c.decodeIfPresent([Int: PlacedText].self, forKey: .textFrames) ?? [:]
        symbolFrames = try c.decodeIfPresent([Int: SymbolInstance].self, forKey: .symbolFrames) ?? [:]
        shapeFrames = try c.decodeIfPresent([Int: PlacedShape].self, forKey: .shapeFrames) ?? [:]
        groupFrames = try c.decodeIfPresent([Int: PlacedGroup].self, forKey: .groupFrames) ?? [:]
        tweenSettings = try c.decodeIfPresent([Int: TweenSettings].self, forKey: .tweenSettings) ?? [:]
        colorTweenSettings = try c.decodeIfPresent([Int: TweenSettings].self, forKey: .colorTweenSettings) ?? [:]
        // Older .flaj files stored a plain String per label — decode that
        // shape too, inferring `.anchor` for anything already using the
        // "#"-prefix convention (see FrameLabelType's own doc comment) so a
        // reopened file doesn't silently lose that behavior's visibility.
        if let structured = try? c.decodeIfPresent([Int: FrameLabel].self, forKey: .frameLabels) {
            frameLabels = structured
        } else {
            let legacy = try c.decodeIfPresent([Int: String].self, forKey: .frameLabels) ?? [:]
            frameLabels = legacy.mapValues { FrameLabel(text: $0, type: $0.hasPrefix("#") ? .anchor : .name) }
        }
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
            totalFrames: rootTotalFrames,
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
            // The document's own root Timeline specifically — never
            // whatever symbol edit-in-place currently has `layers`/
            // `totalFrames` redirected to (see TimelineModel.swift). A
            // symbol's own content round-trips independently below via
            // `library`, which already reads each entry's real `layers`/
            // `totalFrames` directly, regardless of `editingPath`.
            layers: rootLayers.map(FlajLayerFile.init),
            library: library.map(FlajSymbolFile.init),
            guides: guides
        )
    }

    /// Restores every field `FlajDocumentFile` captures. Shared by
    /// `load(from:)` (opening a file — also resets playhead/selection/
    /// console, below) and undo/redo (`Undo.swift`), which instead leave
    /// that transient state alone and just re-resolve it against the new
    /// `layers` array, since undoing a small edit shouldn't also yank the
    /// playhead back to frame 1 or drop the current selection. Always
    /// targets the document's own root Timeline (`rootLayers`/
    /// `rootTotalFrames`), mirroring `makeSaveFile()` — restoring whichever
    /// symbol's Timeline `editingPath` currently means is Undo.swift's job
    /// (`editingPath` is its own UndoEntry field, restored independently of
    /// this), not something content restoration needs to know about.
    func applySaveFile(_ file: FlajDocumentFile) {
        stop()
        resetRuntime()
        rootTotalFrames = file.totalFrames
        fps = file.fps
        stageWidth = CGFloat(file.stageWidth)
        stageHeight = CGFloat(file.stageHeight)
        stageColor = Color(hex: file.stageColorHex)
        webExportTitle = file.webExportTitle
        webExportFit = file.webExportFit
        webExportAlignment = file.webExportAlignment
        webExportPageBackground = Color(hex: file.webExportPageBackgroundHex).opacity(file.webExportPageBackgroundOpacity)
        webExportMinify = file.webExportMinify
        library = file.library.map { sf in
            FlajSymbol(id: sf.id, name: sf.name, layers: sf.layers.map(TLLayer.init), totalFrames: sf.totalFrames)
        }
        rootLayers = file.layers.map(TLLayer.init)
        guides = file.guides
    }

    func load(from file: FlajDocumentFile) {
        applySaveFile(file)
        editingPath = []
        selectedLayerID = layers.first?.id
        playhead = 1
        selectedFrame = 1
        hasSelectedFrame = false
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
