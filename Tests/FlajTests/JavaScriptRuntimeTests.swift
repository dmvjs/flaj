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
}
