import XCTest
@testable import Flaj

/// Frame labels (`TLLayer.frameLabels`, `TimelineDocument.frame(forLabel:)`,
/// and the `gotoAndStop`/`gotoAndPlay`/`goto` label-argument bridge in
/// `makeJSContext`) — see docs/SCRIPTING.md.
@MainActor
final class FrameLabelTests: XCTestCase {

    func testLabelBindingSetsAndClearsALabel() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        let binding = doc.labelBinding(layer: layer, at: 1)
        XCTAssertEqual(binding.wrappedValue, "")

        binding.wrappedValue = "start"
        XCTAssertEqual(layer.frameLabels[1]?.text, "start")

        binding.wrappedValue = ""
        XCTAssertNil(layer.frameLabels[1], "an empty string should clear the label, not store it as one")
    }

    func testLabelTypeBindingDefaultsToNameAndAnchorTogglingManagesHashPrefix() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.labelBinding(layer: layer, at: 1).wrappedValue = "chapter-two"

        let typeBinding = doc.labelTypeBinding(layer: layer, at: 1)
        XCTAssertEqual(typeBinding.wrappedValue, .name, "a freshly-typed label defaults to Name")

        typeBinding.wrappedValue = .anchor
        XCTAssertEqual(layer.frameLabels[1]?.text, "#chapter-two", "picking Anchor should add the '#' its behavior keys off")

        typeBinding.wrappedValue = .name
        XCTAssertEqual(layer.frameLabels[1]?.text, "chapter-two", "leaving Anchor should strip the '#' back off")
    }

    func testLabelTypeBindingIsANoOpWithNoLabelTextYet() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.labelTypeBinding(layer: layer, at: 1).wrappedValue = .anchor
        XCTAssertNil(layer.frameLabels[1], "there's nothing to attach a Type to until there's label text")
    }

    func testCommentTypeLabelsAreExcludedFromFrameForLabelLookup() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        layer.frameLabels[1] = FrameLabel(text: "todo", type: .comment)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        XCTAssertNil(doc.frame(forLabel: "todo"), "a Comment is documentation only, not a valid navigation target")
    }

    func testFrameForLabelSearchesEveryLayerInDocumentOrder() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false), .empty])
        let b = TLLayer(name: "b", swatch: .blue, frames: [.empty, .keyframe(hasScript: false)])
        b.frameLabels[2] = FrameLabel(text: "loop")
        let doc = TimelineDocument(layers: [a, b], totalFrames: 2)

        XCTAssertEqual(doc.frame(forLabel: "loop"), 2)
        XCTAssertNil(doc.frame(forLabel: "nope"))
    }

    func testClearFrameRemovesItsLabel() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        layer.frameLabels[1] = FrameLabel(text: "start")
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.clearFrame(layer: layer, at: 1)
        XCTAssertNil(layer.frameLabels[1])
    }

    /// `gotoAndPlay`/`gotoAndStop`/`goto` accept either a frame number or a
    /// label string from script code — this exercises the real JSContext
    /// bridge (`resolveFrameArgument`), not just the Swift-side helper.
    func testScriptsCanNavigateByLabelThroughGotoAndPlayAndGotoAndStop() {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .empty, .keyframe(hasScript: false)]
        )
        layer.frameLabels[3] = FrameLabel(text: "end")
        layer.frameScripts[1] = "gotoAndStop('end');"
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.stepSimulationFrame()
        XCTAssertEqual(doc.playhead, 3)
    }

    func testGotoAndPlayByLabelLogsAWarningForAnUnknownLabel() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: true)])
        layer.frameScripts[1] = "gotoAndPlay('nowhere');"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.stepSimulationFrame()
        XCTAssertEqual(doc.playhead, 1, "an unresolved label should leave the playhead where it was")
        XCTAssertEqual(doc.consoleMessages.last?.level, .warn)
    }

    func testRemoveTweenRevertsToPlainFramesButKeepsBothKeyframesContent() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[4] = PlacedText(text: "A", x: 50, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .quad, direction: .easeOut, amount: 100)
        let doc = TimelineDocument(layers: [layer], totalFrames: 4)

        doc.removeTween(layer: layer, at: 2)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain, .plain, .keyframe(hasScript: false)])
        XCTAssertNil(layer.tweenSettings[1])
        XCTAssertEqual(layer.textFrames[1]?.x, 0, "both keyframes' content should survive")
        XCTAssertEqual(layer.textFrames[4]?.x, 50)
    }

    func testRemoveTweenIsANoOpWhenTheFrameIsntPartOfATween() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain])
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.removeTween(layer: layer, at: 2) // shouldn't crash or alter anything
        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain])
    }

    func testCopyPasteFramesTransplantsMarksAndContentRelativeToTheNewStart() {
        let source = TLLayer(
            name: "source", swatch: .green,
            frames: [.keyframe(hasScript: true), .plain, .keyframe(hasScript: false)]
        )
        source.frameScripts[1] = "trace('hi');"
        source.textFrames[3] = PlacedText(text: "B", x: 5, y: 5, width: 10, height: 10)
        source.frameLabels[1] = FrameLabel(text: "clip-start")
        let doc = TimelineDocument(layers: [source], totalFrames: 3)
        doc.selectedLayerID = source.id
        doc.selectFrame(layer: source, frame: 1, extend: false)
        doc.selectFrame(layer: source, frame: 3, extend: true) // selects the 1...3 range

        doc.copySelectedFrames()
        XCTAssertTrue(doc.hasCopiedFrames)

        let dest = TLLayer(name: "dest", swatch: .blue, frames: Array(repeating: .empty, count: 10))
        doc.layers.append(dest)
        doc.pasteFrames(layer: dest, at: 6)

        XCTAssertEqual(dest.frames[5], .keyframe(hasScript: true)) // pasted at frame 6, index 5
        XCTAssertEqual(dest.frames[6], .plain)
        XCTAssertEqual(dest.frames[7], .keyframe(hasScript: false))
        XCTAssertEqual(dest.frameScripts[6], "trace('hi');")
        XCTAssertEqual(dest.textFrames[8]?.text, "B")
        XCTAssertEqual(dest.frameLabels[6]?.text, "clip-start")
    }

    func testPasteFramesIsANoOpWithNothingCopied() {
        let layer = TLLayer(name: "dest", swatch: .blue, frames: [.empty, .empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        XCTAssertFalse(doc.hasCopiedFrames)

        doc.pasteFrames(layer: layer, at: 1)
        XCTAssertEqual(layer.frames, [.empty, .empty])
    }
}
