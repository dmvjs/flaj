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
