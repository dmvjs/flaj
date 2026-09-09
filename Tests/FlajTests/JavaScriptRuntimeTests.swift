import XCTest
@testable import Flaj

/// Exercises the JavaScriptCore bridge (`TimelineDocument.makeJSContext`)
/// through the exact path a real frame script runs on:
/// `stepSimulationFrame()` -> script eval -> the `console` shim ->
/// `consoleMessages`. This isn't testing JavaScriptCore itself — it's
/// pinning down that Flaj's own bridging (the console shim's `String(a)`
/// join, script evaluation, number formatting) behaves the way someone
/// authoring a frame script would expect.
@MainActor
final class JavaScriptRuntimeTests: XCTestCase {

    func testConsoleLogEvaluatesArithmetic() {
        let doc = DocumentFixtures.singleScript("console.log(2 + 5);")
        doc.stepSimulationFrame()

        XCTAssertEqual(doc.consoleMessages.map(\.text), ["7"])
        XCTAssertEqual(doc.consoleMessages.first?.level, .log)
    }

    func testExponentiationStaysExactBelowMaxSafeInteger() {
        // 2**40 is well under Number.MAX_SAFE_INTEGER (2**53 - 1) — this
        // pins down that the console shim's `String(a)` formatting prints
        // the exact integer, not a rounded value or scientific notation.
        let doc = DocumentFixtures.singleScript("console.log(2 ** 40);")
        doc.stepSimulationFrame()

        XCTAssertEqual(doc.consoleMessages.map(\.text), ["1099511627776"])
    }

    func testMaxSafeIntegerBoundaryIsRespected() {
        let doc = DocumentFixtures.singleScript("""
        console.log(Number.MAX_SAFE_INTEGER);
        console.log(2 ** 53 > Number.MAX_SAFE_INTEGER);
        """)
        doc.stepSimulationFrame()

        XCTAssertEqual(doc.consoleMessages.map(\.text), [
            "9007199254740991",
            "true"
        ])
    }

    /// The banner-ad clickTag convention (see TimelineDocument.
    /// clickTagURL) — a script assigns `stage.clickTag`, a plain property,
    /// not a method call, and it should read back on the native side after
    /// the frame's scripts finish running.
    func testStageClickTagPropagatesToTheNativeSide() {
        let doc = DocumentFixtures.singleScript("stage.clickTag = 'https://example.com/ad';")
        doc.stepSimulationFrame()

        XCTAssertEqual(doc.clickTagURL, "https://example.com/ad")
    }

    func testClickTagStaysUnsetWhenNoScriptSetsIt() {
        let doc = DocumentFixtures.singleScript("console.log('no click tag here');")
        doc.stepSimulationFrame()

        XCTAssertNil(doc.clickTagURL)
    }

    /// `stage` is a persistent JS object — once clickTag is set on one
    /// frame, it should still read back on a later frame whose own script
    /// doesn't touch it at all, matching real clickTag usage (set once,
    /// valid for the whole movie).
    func testClickTagPersistsAcrossFramesOnceSet() {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .keyframe(hasScript: true)]
        )
        layer.frameScripts[1] = "stage.clickTag = 'https://example.com';"
        layer.frameScripts[2] = "trace('frame two');"
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.stepSimulationFrame() // frame 1
        XCTAssertEqual(doc.clickTagURL, "https://example.com")

        doc.gotoAndStop(2)
        doc.stepSimulationFrame() // frame 2, doesn't touch clickTag itself
        XCTAssertEqual(doc.clickTagURL, "https://example.com")
    }

    func testResetRuntimeClearsClickTag() {
        let doc = DocumentFixtures.singleScript("stage.clickTag = 'https://example.com';")
        doc.stepSimulationFrame()
        XCTAssertNotNil(doc.clickTagURL)

        doc.resetRuntime()
        XCTAssertNil(doc.clickTagURL)
    }
}
