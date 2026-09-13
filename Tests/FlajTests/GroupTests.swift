import XCTest
@testable import Flaj

/// Illustrator/Flash's Group — a lightweight, non-reusable bundle of
/// placements (see `PlacedGroup`'s own doc comment on why it's distinct
/// from a Symbol). `TimelineDocument.groupSelection()`/`ungroupSelection()`
/// are the two operations under test here.
@MainActor
final class GroupTests: XCTestCase {

    func testGroupSelectionRequiresAtLeastTwoObjects() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectOnly(.shape(TimelineDocument.ShapePlacementRef(layerID: layer.id, keyframe: 1)))

        doc.groupSelection()

        XCTAssertTrue(layer.groupFrames.isEmpty, "grouping a single object should be a no-op")
        XCTAssertNotNil(layer.shapeFrames[1], "the shape should be untouched")
    }

    func testGroupSelectionBundlesTwoShapesAndComputesTheBoundingBox() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        a.shapeFrames[1] = PlacedShape(x: 10, y: 10, width: 20, height: 20)
        let b = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        b.shapeFrames[1] = PlacedShape(x: 50, y: 5, width: 10, height: 10)
        let doc = TimelineDocument(layers: [a, b], totalFrames: 1)
        doc.selectOnly(.shape(TimelineDocument.ShapePlacementRef(layerID: a.id, keyframe: 1)))
        doc.toggleSelection(.shape(TimelineDocument.ShapePlacementRef(layerID: b.id, keyframe: 1)))

        doc.groupSelection()

        // Bounding box: x from 10...60 (b's right edge at 50+10), y from 5...30 (a's bottom edge at 10+20).
        guard let group = a.groupFrames[1] else { return XCTFail("expected the group to land on layer a (the topmost contributing layer)") }
        XCTAssertEqual(group.x, 10)
        XCTAssertEqual(group.y, 5)
        XCTAssertEqual(group.width, 50) // 60 - 10
        XCTAssertEqual(group.height, 25) // 30 - 5
        XCTAssertEqual(group.shapes.count, 2)

        // Original content is cleared from both contributing layers/keyframes.
        XCTAssertNil(a.shapeFrames[1])
        XCTAssertNil(b.shapeFrames[1])

        // Each child's x/y is now relative to the group's own origin.
        let relativeXs = Set(group.shapes.map { $0.x })
        XCTAssertEqual(relativeXs, [0, 40]) // 10-10=0, 50-10=40

        XCTAssertEqual(doc.selectedGroupPlacement, TimelineDocument.GroupPlacementRef(layerID: a.id, keyframe: 1))
    }

    func testGroupSelectionLandsOnTheTopmostContributingLayerRegardlessOfSelectionOrder() {
        let top = TLLayer(name: "top", swatch: .green, frames: [.keyframe(hasScript: false)])
        top.shapeFrames[1] = PlacedShape(x: 0, y: 0, width: 10, height: 10)
        let bottom = TLLayer(name: "bottom", swatch: .blue, frames: [.keyframe(hasScript: false)])
        bottom.shapeFrames[1] = PlacedShape(x: 20, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [top, bottom], totalFrames: 1)
        // Select bottom first, then top — landing should still be `top`,
        // the one earlier in the layer list, not whichever was clicked first.
        doc.selectOnly(.shape(TimelineDocument.ShapePlacementRef(layerID: bottom.id, keyframe: 1)))
        doc.toggleSelection(.shape(TimelineDocument.ShapePlacementRef(layerID: top.id, keyframe: 1)))

        doc.groupSelection()

        XCTAssertNotNil(top.groupFrames[1])
        XCTAssertTrue(bottom.groupFrames.isEmpty)
    }

    func testUngroupSelectionRestoresChildrenAtTheirAbsolutePositions() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        a.shapeFrames[1] = PlacedShape(kind: .rectangle, x: 10, y: 10, width: 20, height: 20, fillColorHex: "#FF0000")
        let b = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        b.shapeFrames[1] = PlacedShape(kind: .ellipse, x: 50, y: 5, width: 10, height: 10, fillColorHex: "#00FF00")
        let doc = TimelineDocument(layers: [a, b], totalFrames: 1)
        doc.selectOnly(.shape(TimelineDocument.ShapePlacementRef(layerID: a.id, keyframe: 1)))
        doc.toggleSelection(.shape(TimelineDocument.ShapePlacementRef(layerID: b.id, keyframe: 1)))
        doc.groupSelection()

        doc.ungroupSelection()

        XCTAssertTrue(a.groupFrames.isEmpty, "the group itself should be gone")

        // One child reuses layer `a`'s own slot; the other gets a brand-new layer.
        let restoredShapes = doc.layers.compactMap { $0.shapeFrames[1] }
        XCTAssertEqual(restoredShapes.count, 2)
        let restoredPositions = Set(restoredShapes.map { [$0.x, $0.y] })
        XCTAssertEqual(restoredPositions, [[10, 10], [50, 5]], "each child should be restored at its original absolute position")
        let restoredColors = Set(restoredShapes.map(\.fillColorHex))
        XCTAssertEqual(restoredColors, ["#FF0000", "#00FF00"])

        // A new layer was actually created for the second child.
        XCTAssertEqual(doc.layers.count, 3)
    }

    func testGroupThenUngroupIsUndoable() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        a.shapeFrames[1] = PlacedShape(x: 0, y: 0, width: 10, height: 10)
        let b = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        b.shapeFrames[1] = PlacedShape(x: 20, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [a, b], totalFrames: 1)
        doc.selectOnly(.shape(TimelineDocument.ShapePlacementRef(layerID: a.id, keyframe: 1)))
        doc.toggleSelection(.shape(TimelineDocument.ShapePlacementRef(layerID: b.id, keyframe: 1)))

        doc.groupSelection()
        XCTAssertFalse(doc.layers[0].groupFrames.isEmpty)

        doc.undo()

        XCTAssertTrue(doc.layers[0].groupFrames.isEmpty)
        XCTAssertNotNil(doc.layers[0].shapeFrames[1])
        XCTAssertNotNil(doc.layers[1].shapeFrames[1])
    }
}
