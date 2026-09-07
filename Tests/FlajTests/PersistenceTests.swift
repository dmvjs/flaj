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
        XCTAssertEqual(reloaded.layers.count, original.layers.count)
        // load(from:) re-selects the first layer, same as opening a document fresh.
        XCTAssertEqual(reloaded.selectedLayerID, reloaded.layers.first?.id)

        for (want, got) in zip(original.layers, reloaded.layers) {
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.swatch.hexString, want.swatch.hexString)
            XCTAssertEqual(got.kind, want.kind)
            XCTAssertEqual(got.indent, want.indent)
            XCTAssertEqual(got.locked, want.locked)
            XCTAssertEqual(got.hidden, want.hidden)
            XCTAssertEqual(got.expanded, want.expanded)
            XCTAssertEqual(got.frames, want.frames)
            XCTAssertEqual(got.frameScripts, want.frameScripts)
            XCTAssertEqual(got.textFrames, want.textFrames)
            XCTAssertEqual(got.tweenSettings, want.tweenSettings)
            XCTAssertEqual(got.colorTweenSettings, want.colorTweenSettings)
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
        XCTAssertTrue(file.layers[0].tweenSettings.isEmpty)

        let doc = TimelineDocument(layers: [TLLayer(name: "placeholder", swatch: .black, frames: [.empty])], totalFrames: 1)
        doc.load(from: file)

        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].frames, [.keyframe(hasScript: false), .empty])
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
