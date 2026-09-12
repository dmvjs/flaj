import XCTest
@testable import Flaj

/// Drives `TimelineDocument.performGIFExport(to:)` directly against
/// hand-built documents (see `DocumentFixtures`) and inspects the resulting
/// file with ImageIO — the same export path the app's "Export GIF…" menu
/// item calls, minus the NSSavePanel.
@MainActor
final class GIFExportTests: XCTestCase {

    func testBlackWhiteFlipExportsPixelAccurateFrames() throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        let url = TemporaryFile.url(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        doc.performGIFExport(to: url)

        let frames = try GIFDecoding.frames(of: url)
        XCTAssertEqual(frames.count, 2)

        XCTAssertEqual(frames[0].width, 8)
        XCTAssertEqual(frames[0].height, 8)
        XCTAssertTrue(frames[0].averageColor.isNear(.black), "frame 1 should be black, was \(frames[0].averageColor)")

        XCTAssertEqual(frames[1].width, 8)
        XCTAssertEqual(frames[1].height, 8)
        XCTAssertTrue(frames[1].averageColor.isNear(.white), "frame 2 should be white, was \(frames[1].averageColor)")
    }

    func testTweenedTextExportMatchesGoldenByteForByte() throws {
        let doc = DocumentFixtures.tweenedText()
        let url = TemporaryFile.url(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        doc.performGIFExport(to: url)

        let exported = try Data(contentsOf: url)
        guard let goldenURL = Bundle.module.url(forResource: "TweenedTextGolden", withExtension: "gif", subdirectory: "Resources") else {
            XCTFail("Missing golden fixture — see Tests/FlajTests/Resources/README.md to regenerate it")
            return
        }
        let golden = try Data(contentsOf: goldenURL)

        XCTAssertEqual(exported, golden, "exported GIF no longer matches the golden fixture byte-for-byte")
    }

    /// GIF export renders `StageContentView` directly (see
    /// `performGIFExport`/`renderStageImage`) — the same view the live Stage
    /// uses, which is exactly why the symbol-instance independent-playback
    /// loop (`FlajSymbol.localFrame`, `StageSymbolInstanceView`) should
    /// "just work" here architecturally. This proves it actually does,
    /// rather than trusting that claim: a solid-block glyph ("█") filling
    /// almost the whole (small) Stage, colored differently per symbol
    /// frame, shifts the exported frame's average color distinctly enough
    /// to tell frames apart — the same average-color technique
    /// `testBlackWhiteFlipExportsPixelAccurateFrames` already uses, just
    /// applied to a looping symbol instead of a plain frame script.
    func testLoopingSymbolInstanceExportsItsOwnFramesToGIF() throws {
        let symbolLayer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .keyframe(hasScript: false)])
        symbolLayer.textFrames[1] = PlacedText(text: "█", x: 0, y: 0, width: 20, height: 20, fontSize: 18, colorHex: "#FF0000")
        symbolLayer.textFrames[2] = PlacedText(text: "█", x: 0, y: 0, width: 20, height: 20, fontSize: 18, colorHex: "#0000FF")
        let symbol = FlajSymbol(id: UUID(), name: "Blink", layers: [symbolLayer], totalFrames: 2)

        let root = TLLayer(name: "root", swatch: .blue, frames: [.keyframe(hasScript: false), .plain])
        root.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 20, height: 20)

        let doc = TimelineDocument(layers: [root], totalFrames: 2)
        doc.library = [symbol]
        doc.stageWidth = 20
        doc.stageHeight = 20
        doc.stageColor = .white

        let url = TemporaryFile.url(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        doc.performGIFExport(to: url)

        let frames = try GIFDecoding.frames(of: url)
        XCTAssertEqual(frames.count, 2)
        // Not asserting near-pure red/blue: a glyph over a white background
        // still averages toward white at the edges/gaps a block character
        // doesn't perfectly fill. Asserting the *direction* each frame's
        // average leans is what actually proves the loop rendered a
        // different frame each time, without being fragile to exactly how
        // solidly this font rasterizes "█".
        XCTAssertGreaterThan(frames[0].averageColor.red, frames[0].averageColor.blue, "frame 1 (symbol's own red frame) should lean red")
        XCTAssertGreaterThan(frames[1].averageColor.blue, frames[1].averageColor.red, "frame 2 (symbol's own blue frame) should lean blue")
    }

    /// GIF export renders `StageContentView` directly — the same view that
    /// gained `StagePlacedShapeView` for the shape tool — so a solid,
    /// stroke-free rectangle filling the whole (small) Stage should export
    /// as a solid frame of its exact fill color, no shape-specific export
    /// code required (see PlacedShape's own doc comment on why it isn't
    /// tweenable: this only needs to prove the *static* rendering path
    /// works, which is all a shape has in v1).
    func testSolidFilledRectangleExportsItsFillColorToGIF() throws {
        let layer = TLLayer(name: "shape", swatch: .blue, frames: [.keyframe(hasScript: false)])
        layer.shapeFrames[1] = PlacedShape(
            kind: .rectangle, x: 0, y: 0, width: 20, height: 20,
            fillColorHex: "#3399FF", fillOpacity: 1, strokeColorHex: "#3399FF", strokeOpacity: 1, strokeWidth: 0
        )
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.stageWidth = 20
        doc.stageHeight = 20
        doc.stageColor = .white

        let url = TemporaryFile.url(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        doc.performGIFExport(to: url)

        let frames = try GIFDecoding.frames(of: url)
        XCTAssertEqual(frames.count, 1)
        let fill = GIFDecoding.RGB(red: 51, green: 153, blue: 255) // #3399FF
        XCTAssertTrue(frames[0].averageColor.isNear(fill, tolerance: 4), "expected the shape's fill color to cover the frame, was \(frames[0].averageColor)")
    }

    /// Onion skin (StageView.OnionSkinOverlay) is an editor-only aid layered
    /// on top of StageContentView in the live preview — GIF export renders
    /// StageContentView directly (see performGIFExport), so leaving onion
    /// skin enabled while exporting should be completely invisible to the
    /// output. Byte-for-byte against the same golden fixture as the test
    /// above is the strongest way to prove that: any leak at all would
    /// change at least one pixel.
    func testOnionSkinEnabledHasNoEffectOnGIFExport() throws {
        let doc = DocumentFixtures.tweenedText()
        doc.onionSkinEnabled = true
        doc.onionSkinRange = 5
        let url = TemporaryFile.url(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        doc.performGIFExport(to: url)

        let exported = try Data(contentsOf: url)
        guard let goldenURL = Bundle.module.url(forResource: "TweenedTextGolden", withExtension: "gif", subdirectory: "Resources") else {
            XCTFail("Missing golden fixture — see Tests/FlajTests/Resources/README.md to regenerate it")
            return
        }
        let golden = try Data(contentsOf: goldenURL)

        XCTAssertEqual(exported, golden, "onion skin state leaked into the exported GIF")
    }
}
