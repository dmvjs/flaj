import XCTest
@testable import Flaj

/// Exercises the `.flaj` file format end to end: `makeSaveFile()` ->
/// `JSONEncoder` -> `JSONDecoder` -> `load(from:)`, the same round trip
/// `saveDocument()`/`openDocument()` do around an NSSavePanel/NSOpenPanel.
@MainActor
final class PersistenceTests: XCTestCase {

    func testRoundTripPreservesEveryField() throws {
        let original = DocumentFixtures.richDocumentForPersistence()

        let data = try JSONEncoder().encode(original.makeSaveFile())
        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: data)

        let reloaded = TimelineDocument(layers: [TLLayer(name: "placeholder", swatch: .black, frames: [.empty])], totalFrames: 1)
        reloaded.load(from: file)

        XCTAssertEqual(reloaded.totalFrames, original.totalFrames)
        XCTAssertEqual(reloaded.fps, original.fps)
        XCTAssertEqual(reloaded.stageWidth, original.stageWidth)
        XCTAssertEqual(reloaded.stageHeight, original.stageHeight)
        XCTAssertEqual(reloaded.stageColor.hexString, original.stageColor.hexString)
        XCTAssertEqual(reloaded.webExportTitle, original.webExportTitle)
        XCTAssertEqual(reloaded.webExportFit, original.webExportFit)
        XCTAssertEqual(reloaded.webExportAlignment, original.webExportAlignment)
        XCTAssertEqual(reloaded.webExportPageBackground.cssString, original.webExportPageBackground.cssString)
        XCTAssertEqual(reloaded.webExportMinify, original.webExportMinify)
        XCTAssertEqual(reloaded.guides, original.guides)
        XCTAssertEqual(reloaded.layers.count, original.layers.count)
        // load(from:) re-selects the first layer, same as opening a document fresh.
        XCTAssertEqual(reloaded.selectedLayerID, reloaded.layers.first?.id)
        // FlajSymbol isn't Equatable (it carries TLLayer, a class, same
        // reason the top-level `layers` comparison below is also
        // field-by-field rather than a single XCTAssertEqual).
        XCTAssertEqual(reloaded.library.count, original.library.count)
        for (want, got) in zip(original.library, reloaded.library) {
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.totalFrames, want.totalFrames)
            XCTAssertEqual(got.layers.count, want.layers.count)
            for (wantLayer, gotLayer) in zip(want.layers, got.layers) {
                XCTAssertEqual(gotLayer.textFrames, wantLayer.textFrames)
            }
        }

        for (want, got) in zip(original.layers, reloaded.layers) {
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.swatch.hexString, want.swatch.hexString)
            XCTAssertEqual(got.kind, want.kind)
            XCTAssertEqual(got.indent, want.indent)
            XCTAssertEqual(got.locked, want.locked)
            XCTAssertEqual(got.hidden, want.hidden)
            XCTAssertEqual(got.masked, want.masked)
            XCTAssertEqual(got.expanded, want.expanded)
            XCTAssertEqual(got.frames, want.frames)
            XCTAssertEqual(got.frameScripts, want.frameScripts)
            XCTAssertEqual(got.textFrames, want.textFrames)
            XCTAssertEqual(got.symbolFrames, want.symbolFrames)
            XCTAssertEqual(got.shapeFrames, want.shapeFrames)
            XCTAssertEqual(got.groupFrames, want.groupFrames)
            XCTAssertEqual(got.tweenSettings, want.tweenSettings)
            XCTAssertEqual(got.colorTweenSettings, want.colorTweenSettings)
            XCTAssertEqual(got.frameLabels, want.frameLabels)
        }
    }

    func testLegacyFileWithoutNewerFieldsStillOpens() throws {
        let legacyJSON = Data("""
        {
          "version": 1,
          "totalFrames": 2,
          "fps": 12,
          "stageWidth": 550,
          "stageHeight": 400,
          "stageColorHex": "#FFFFFF",
          "layers": [
            {
              "name": "actions",
              "swatchHex": "#FFCC00",
              "kind": {"normal": {}},
              "indent": 0,
              "locked": false,
              "hidden": false,
              "expanded": true,
              "frames": [{"type": "keyframe", "hasScript": false}, {"type": "empty"}],
              "frameScripts": {}
            }
          ]
        }
        """.utf8)

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: legacyJSON)
        XCTAssertTrue(file.layers[0].textFrames.isEmpty)
        XCTAssertTrue(file.layers[0].symbolFrames.isEmpty)
        XCTAssertTrue(file.layers[0].shapeFrames.isEmpty)
        XCTAssertTrue(file.layers[0].groupFrames.isEmpty)
        XCTAssertTrue(file.layers[0].tweenSettings.isEmpty)
        XCTAssertTrue(file.library.isEmpty)
        XCTAssertTrue(file.guides.isEmpty)
        XCTAssertFalse(file.layers[0].masked)

        let doc = TimelineDocument(layers: [TLLayer(name: "placeholder", swatch: .black, frames: [.empty])], totalFrames: 1)
        doc.load(from: file)

        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].frames, [.keyframe(hasScript: false), .empty])
    }

    /// A `.flaj` file saved before frame labels carried a Type (Name/
    /// Comment/Anchor) stored them as a plain string per frame — decoding
    /// must still open these, inferring `.anchor` for the pre-existing
    /// "#"-prefix convention and `.name` for everything else.
    func testLegacyPlainStringFrameLabelsDecodeWithInferredType() throws {
        let legacyJSON = Data("""
        {
          "version": 1,
          "totalFrames": 2,
          "fps": 12,
          "stageWidth": 550,
          "stageHeight": 400,
          "stageColorHex": "#FFFFFF",
          "layers": [
            {
              "name": "actions",
              "swatchHex": "#FFCC00",
              "kind": {"normal": {}},
              "indent": 0,
              "locked": false,
              "hidden": false,
              "expanded": true,
              "frames": [{"type": "keyframe", "hasScript": false}, {"type": "keyframe", "hasScript": false}],
              "frameScripts": {},
              "frameLabels": {"1": "start", "2": "#chapter-two"}
            }
          ]
        }
        """.utf8)

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: legacyJSON)
        XCTAssertEqual(file.layers[0].frameLabels[1], FrameLabel(text: "start", type: .name))
        XCTAssertEqual(file.layers[0].frameLabels[2], FrameLabel(text: "#chapter-two", type: .anchor))
    }

    /// A `.flaj` file saved before a symbol's content became a nested
    /// Timeline (`FlajSymbol.layers`/`totalFrames`) has flat `text`/
    /// `fontName`/`fontSize`/`bold`/`italic`/`colorHex`/`alignment` fields
    /// directly on each library entry instead — `FlajSymbolFile`'s custom
    /// decoder must synthesize the same one-layer/one-frame Timeline the
    /// current flat convenience initializer builds, so an old symbol still
    /// opens looking exactly the same.
    func testLegacyFlatSymbolLibraryStillOpensAsANestedTimeline() throws {
        let legacyJSON = Data("""
        {
          "version": 1,
          "totalFrames": 1,
          "fps": 12,
          "stageWidth": 550,
          "stageHeight": 400,
          "stageColorHex": "#FFFFFF",
          "layers": [],
          "library": [
            {
              "id": "8C8A9A9E-1DDB-4B3C-9C8F-1E7C6E9F0A01",
              "name": "Badge",
              "text": "HELLO",
              "fontName": "Courier",
              "fontSize": 20,
              "bold": true,
              "italic": false,
              "colorHex": "#FF0000",
              "alignment": "leading"
            }
          ]
        }
        """.utf8)

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: legacyJSON)
        XCTAssertEqual(file.library.count, 1)
        XCTAssertEqual(file.library[0].totalFrames, 1)
        XCTAssertEqual(file.library[0].layers.count, 1)
        let content = try XCTUnwrap(file.library[0].layers[0].textFrames[1])
        XCTAssertEqual(content.text, "HELLO")
        XCTAssertEqual(content.fontName, "Courier")
        XCTAssertEqual(content.fontSize, 20)
        XCTAssertTrue(content.bold)
        XCTAssertEqual(content.colorHex, "#FF0000")

        let doc = TimelineDocument(layers: [TLLayer(name: "placeholder", swatch: .black, frames: [.empty])], totalFrames: 1)
        doc.load(from: file)

        XCTAssertEqual(doc.library.count, 1)
        XCTAssertEqual(doc.library[0].name, "Badge")
        XCTAssertEqual(doc.library[0].text, "HELLO")
        XCTAssertEqual(doc.library[0].fontName, "Courier")
        XCTAssertTrue(doc.library[0].bold)
    }

    func testLoadResetsTransientPlaybackState() throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        doc.playhead = 2
        doc.selectedFrame = 2
        doc.logToConsole("stale message from the previous document")

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: JSONEncoder().encode(doc.makeSaveFile()))
        doc.load(from: file)

        XCTAssertEqual(doc.playhead, 1)
        XCTAssertEqual(doc.selectedFrame, 1)
        XCTAssertTrue(doc.consoleMessages.isEmpty)
        XCTAssertFalse(doc.isPlaying)
    }
}
