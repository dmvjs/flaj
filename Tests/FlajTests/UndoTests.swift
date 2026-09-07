import XCTest
@testable import Flaj

/// `TimelineDocument.undo()`/`.redo()` (see Undo.swift) — whole-document
/// snapshot undo built on the same Codable round-trip Persistence.swift
/// uses for `.flaj` files. These tests exercise the snapshot/coalescing
/// machinery itself, not any particular editing feature.
@MainActor
final class UndoTests: XCTestCase {

    func testAddLayerIsUndoableAndRedoable() {
        let doc = DocumentFixtures.richDocumentForPersistence()
        let countBefore = doc.layers.count
        XCTAssertFalse(doc.canUndo)

        doc.addLayer()
        XCTAssertEqual(doc.layers.count, countBefore + 1)
        XCTAssertTrue(doc.canUndo)

        doc.undo()
        XCTAssertEqual(doc.layers.count, countBefore)
        XCTAssertTrue(doc.canRedo)

        doc.redo()
        XCTAssertEqual(doc.layers.count, countBefore + 1)
    }

    func testNewEditAfterUndoClearsTheRedoStack() {
        let doc = DocumentFixtures.richDocumentForPersistence()
        doc.addLayer()
        doc.undo()
        XCTAssertTrue(doc.canRedo)

        doc.addFolder()
        XCTAssertFalse(doc.canRedo, "a fresh edit branches away from the undone one — redo shouldn't resurrect it")
    }

    /// Dragging a placed text box fires `onChanged` many times a second;
    /// `withUndoSnapshot(coalesce:)` is what keeps that from becoming one
    /// undo step per pixel. Simulates that by writing through `binding(for:)`
    /// repeatedly, matching what StageView's move gesture does.
    func testCoalescedEditsToTheSamePlacementCollapseIntoOneUndoStep() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "Hi", x: 0, y: 0, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        let ref = TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: 1)
        guard let binding = doc.binding(for: ref) else { return XCTFail("expected a binding") }

        for x in stride(from: CGFloat(1), through: 50, by: 1) {
            var p = binding.wrappedValue
            p.x = x
            binding.wrappedValue = p
        }
        XCTAssertEqual(layer.textFrames[1]?.x, 50)
        XCTAssertEqual(doc.undoStack.count, 1, "49 drag ticks against the same placement should coalesce into a single snapshot")

        doc.undo()
        // `undo()` rebuilds `layers` with fresh TLLayer instances (see
        // `applySaveFile`), so the original `layer` reference is now stale —
        // read back through `doc.layers`, same as any real caller would
        // after an undo.
        XCTAssertEqual(doc.layers.first?.textFrames[1]?.x, 0, "undo should restore the pre-drag position in one step")
    }

    /// A different placement (or any other discrete edit) in between two
    /// drags should NOT be swallowed into either drag's coalescing group.
    func testEditingADifferentTargetStartsAFreshUndoStep() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        a.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 20, height: 10)
        let b = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        b.textFrames[1] = PlacedText(text: "B", x: 0, y: 0, width: 20, height: 10)
        let doc = TimelineDocument(layers: [a, b], totalFrames: 1)
        let refA = TimelineDocument.TextPlacementRef(layerID: a.id, keyframe: 1)
        let refB = TimelineDocument.TextPlacementRef(layerID: b.id, keyframe: 1)
        let bindingA = doc.binding(for: refA)!
        let bindingB = doc.binding(for: refB)!

        bindingA.wrappedValue.x = 10
        bindingB.wrappedValue.x = 20
        bindingA.wrappedValue.x = 15

        XCTAssertEqual(doc.undoStack.count, 3)
        doc.undo() // undoes bindingA.x = 15 (the second edit to A)
        XCTAssertEqual(doc.layers[0].textFrames[1]?.x, 10)
        XCTAssertEqual(doc.layers[1].textFrames[1]?.x, 20)
        doc.undo() // undoes bindingB.x = 20
        XCTAssertEqual(doc.layers[1].textFrames[1]?.x, 0)
        doc.undo() // undoes bindingA.x = 10 (the first edit to A)
        XCTAssertEqual(doc.layers[0].textFrames[1]?.x, 0)
    }

    /// `createTween` calls `insertKeyframe` internally — both are wrapped in
    /// `withUndoSnapshot`, and the reentrancy guard (`undoActionDepth`)
    /// should mean that nested call doesn't also record its own, partial
    /// snapshot. One user action, one undo step.
    func testCreateTweenIsOneUndoStepDespiteCallingInsertKeyframeInternally() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)] + Array(repeating: .empty, count: 4))
        layer.textFrames[1] = PlacedText(text: "Hi", x: 0, y: 0, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        doc.createTween(layer: layer, from: 1, to: 5)
        XCTAssertTrue(layer.isKeyframe(at: 5))
        XCTAssertEqual(doc.undoStack.count, 1)

        doc.undo()
        let restored = doc.layers[0]
        XCTAssertFalse(restored.isKeyframe(at: 5), "the whole tween creation — including the internal insertKeyframe — should revert as one step")
        XCTAssertNil(restored.tweenSettings[1])
    }

    /// Undo/redo round-trips the document through `FlajDocumentFile`, which
    /// rebuilds `layers` with brand-new `TLLayer` instances — without a
    /// stable id surviving that round trip (`FlajLayerFile.id`, see
    /// Persistence.swift) every undo would silently drop the current layer
    /// selection.
    func testUndoPreservesLayerSelectionAcrossTheSnapshotRoundTrip() {
        let doc = DocumentFixtures.richDocumentForPersistence()
        let secondLayerID = doc.layers[1].id
        doc.selectedLayerID = secondLayerID

        doc.addLayer()
        XCTAssertNotEqual(doc.selectedLayerID, secondLayerID, "addLayer selects the new layer")

        doc.undo()
        XCTAssertEqual(doc.layers[1].id, secondLayerID, "layer identity itself should survive the snapshot round trip")
        XCTAssertEqual(doc.selectedLayerID, secondLayerID, "and selection should be re-resolved against it, not reset")
    }

    /// Undoing shouldn't reset the playhead the way opening a file does —
    /// that's the one behavioral difference between `load(from:)` and the
    /// undo/redo path (`applySaveFile` is the part they share).
    func testUndoDoesNotResetThePlayheadOrClearTheConsole() {
        let doc = DocumentFixtures.richDocumentForPersistence()
        doc.playhead = 2
        doc.selectedFrame = 2
        doc.logToConsole("hello", level: .log)

        doc.addLayer()
        doc.undo()

        XCTAssertEqual(doc.playhead, 2)
        XCTAssertEqual(doc.selectedFrame, 2)
        XCTAssertEqual(doc.consoleMessages.count, 1)
    }
}
