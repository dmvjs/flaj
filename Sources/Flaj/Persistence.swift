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
    var layers: [FlajLayerFile]
}

struct FlajLayerFile: Codable {
    var name: String
    var swatchHex: String
    var kind: LayerKind
    var indent: Int
    var locked: Bool
    var hidden: Bool
    var expanded: Bool
    var frames: [FrameMark]
    var frameScripts: [Int: String]
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
            layers: layers.map { layer in
                FlajLayerFile(
                    name: layer.name, swatchHex: layer.swatch.hexString, kind: layer.kind,
                    indent: layer.indent, locked: layer.locked, hidden: layer.hidden,
                    expanded: layer.expanded, frames: layer.frames, frameScripts: layer.frameScripts
                )
            }
        )
    }

    func load(from file: FlajDocumentFile) {
        stop()
        resetRuntime()
        totalFrames = file.totalFrames
        fps = file.fps
        stageWidth = CGFloat(file.stageWidth)
        stageHeight = CGFloat(file.stageHeight)
        stageColor = Color(hex: file.stageColorHex)
        layers = file.layers.map { lf in
            let layer = TLLayer(
                name: lf.name, swatch: Color(hex: lf.swatchHex), kind: lf.kind, indent: lf.indent,
                locked: lf.locked, hidden: lf.hidden, frames: lf.frames
            )
            layer.expanded = lf.expanded
            layer.frameScripts = lf.frameScripts
            return layer
        }
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
