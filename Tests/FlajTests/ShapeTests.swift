import XCTest
@testable import Flaj

/// Vector shapes (`PlacedShape`/`ShapeKind` in StageObject.swift) — a
/// rectangle or ellipse with its own fill/stroke color+opacity, stroke
/// width, and position/size, drawn via click-drag on the Stage
/// (TimelineDocument.placeShape) rather than click-to-place. Deliberately
/// not tweenable in v1 (see `PlacedShape`'s own doc comment) and
/// deliberately an independent, always-selectable object rather than
/// Flash's classic shape-merge drawing model — the same "third governing
/// content kind" treatment `textFrames`/`symbolFrames` already get
/// throughout TimelineModel.swift is what these tests are checking for.
@MainActor
final class ShapeTests: XCTestCase {

    func testPlaceShapeDropsItAtTheGivenRectOnTheGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .plain])
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.selectedLayerID = layer.id
        doc.selectFrame(layer: layer, frame: 2, extend: false) // mid-span, governed by keyframe 1

        doc.placeShape(kind: .ellipse, rect: CGRect(x: 10, y: 20, width: 30, height: 40))

        guard let shape = layer.shapeFrames[1] else { return XCTFail("expected a shape at the governing keyframe (1), not frame 2") }
        XCTAssertEqual(shape.kind, .ellipse)
        XCTAssertEqual(shape.x, 10)
        XCTAssertEqual(shape.y, 20)
        XCTAssertEqual(shape.width, 30)
        XCTAssertEqual(shape.height, 40)
        XCTAssertEqual(doc.selectedShapePlacement, TimelineDocument.ShapePlacementRef(layerID: layer.id, keyframe: 1))
    }

    func testPlaceShapeWarnsWithoutAGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedLayerID = layer.id

        doc.placeShape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))

        XCTAssertTrue(layer.shapeFrames.isEmpty)
        XCTAssertEqual(doc.consoleMessages.last?.level, .warn)
    }

    func testPlaceShapeClampsAZeroOrNegativeSizeToAtLeastOnePoint() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedLayerID = layer.id

        doc.placeShape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 0, height: 0))

        XCTAssertEqual(layer.shapeFrames[1]?.width, 1)
        XCTAssertEqual(layer.shapeFrames[1]?.height, 1)
    }

    /// Placing a shape on a keyframe that already carries text/a symbol
    /// instance replaces it — the three content kinds are mutually
    /// exclusive per keyframe (see TLLayer's own doc comment).
    func testPlacingAShapeReplacesExistingTextOrSymbolContentOnThatKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedLayerID = layer.id

        doc.placeShape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))

        XCTAssertNil(layer.textFrames[1])
        XCTAssertNotNil(layer.shapeFrames[1])
    }

    func testSelectingTextAndShapePlacementsAreMutuallyExclusive() {
        let textLayer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        textLayer.textFrames[1] = PlacedText(x: 0, y: 0)
        let shapeLayer = TLLayer(name: "shape", swatch: .blue, frames: [.keyframe(hasScript: false)])
        shapeLayer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [textLayer, shapeLayer], totalFrames: 1)

        doc.selectFrame(layer: textLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedPlacement)
        XCTAssertNil(doc.selectedShapePlacement)

        doc.selectFrame(layer: shapeLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedShapePlacement)
        XCTAssertNil(doc.selectedPlacement, "selecting a shape should clear any text-placement selection")
    }

    func testSelectingASymbolAndShapePlacementAreMutuallyExclusive() {
        let symbolLayer = TLLayer(name: "symbol", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        symbolLayer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        let shapeLayer = TLLayer(name: "shape", swatch: .blue, frames: [.keyframe(hasScript: false)])
        shapeLayer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [symbolLayer, shapeLayer], totalFrames: 1)
        doc.library = [symbol]

        doc.selectFrame(layer: shapeLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedShapePlacement)

        doc.selectFrame(layer: symbolLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedSymbolPlacement)
        XCTAssertNil(doc.selectedShapePlacement, "selecting a symbol instance should clear any shape selection")
    }

    func testDeleteSelectedShapePlacementRemovesTheShape() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedShapePlacement = TimelineDocument.ShapePlacementRef(layerID: layer.id, keyframe: 1)

        doc.deleteSelectedShapePlacement()

        XCTAssertNil(layer.shapeFrames[1])
        XCTAssertNil(doc.selectedShapePlacement)
    }

    func testNudgeSelectedShapePlacementMovesItByTheGivenDelta() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.shapeFrames[1] = PlacedShape(x: 10, y: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedShapePlacement = TimelineDocument.ShapePlacementRef(layerID: layer.id, keyframe: 1)

        doc.nudgeSelectedShapePlacement(dx: 5, dy: -3)

        XCTAssertEqual(layer.shapeFrames[1]?.x, 15)
        XCTAssertEqual(layer.shapeFrames[1]?.y, 7)
    }

    func testCopyPasteShapeLandsOnTheDestinationFrame() {
        let source = TLLayer(name: "source", swatch: .green, frames: [.keyframe(hasScript: false)])
        source.shapeFrames[1] = PlacedShape(kind: .ellipse, x: 3, y: 4, width: 40, height: 20, fillColorHex: "#ABCDEF")
        let doc = TimelineDocument(layers: [source], totalFrames: 1)
        doc.selectedShapePlacement = TimelineDocument.ShapePlacementRef(layerID: source.id, keyframe: 1)

        doc.copySelectedShapePlacement()
        XCTAssertTrue(doc.hasCopiedShape)

        let dest = TLLayer(name: "dest", swatch: .blue, frames: [.keyframe(hasScript: false), .plain])
        doc.layers.append(dest)
        doc.pasteShape(layer: dest, at: 1)

        XCTAssertEqual(dest.shapeFrames[1]?.kind, .ellipse)
        XCTAssertEqual(dest.shapeFrames[1]?.x, 3)
        XCTAssertEqual(dest.shapeFrames[1]?.fillColorHex, "#ABCDEF")
        XCTAssertEqual(doc.selectedShapePlacement, TimelineDocument.ShapePlacementRef(layerID: dest.id, keyframe: 1))
    }

    func testCopyPasteFramesCarriesShapesRelativeToTheNewStart() {
        let source = TLLayer(name: "source", swatch: .green, frames: [.keyframe(hasScript: false)])
        source.shapeFrames[1] = PlacedShape(x: 9, y: 9)
        let doc = TimelineDocument(layers: [source], totalFrames: 1)
        doc.selectedLayerID = source.id
        doc.selectFrame(layer: source, frame: 1, extend: false)

        doc.copySelectedFrames()
        let dest = TLLayer(name: "dest", swatch: .blue, frames: Array(repeating: .empty, count: 5))
        doc.layers.append(dest)
        doc.pasteFrames(layer: dest, at: 3)

        XCTAssertEqual(dest.shapeFrames[3]?.x, 9)
    }

    func testMoveKeyframeCarriesTheShapeAlong() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .empty, .empty])
        layer.shapeFrames[1] = PlacedShape(x: 7, y: 8)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.moveKeyframe(layer: layer, from: 1, to: 3)

        XCTAssertNil(layer.shapeFrames[1])
        XCTAssertEqual(layer.shapeFrames[3]?.x, 7)
    }

    func testClearFrameRemovesTheShape() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.clearFrame(layer: layer, at: 1)

        XCTAssertNil(layer.shapeFrames[1])
    }

    /// A keyframe carrying only a shape can't start Create Tween — shapes
    /// aren't tweenable in v1 (see `PlacedShape`'s own doc comment), so
    /// `createTween`'s content gate deliberately wasn't extended to shapes,
    /// same as it never covered bold/italic/filters either.
    func testCreateTweenIsANoOpOnAShapeOnlyKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .empty, .empty])
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.createTween(layer: layer, from: 1, to: 3)

        XCTAssertEqual(layer.frames[1], .empty, "no tween span should have been created")
    }

    func testUndoRestoresTheShapeSelectionAlongsideContent() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedLayerID = layer.id
        doc.selectFrame(layer: layer, frame: 1, extend: false)

        doc.placeShape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertNotNil(doc.selectedShapePlacement)

        doc.undo()

        // applySaveFile rebuilds `layers` from scratch (see Undo.swift), so
        // the original `layer` reference above is stale post-undo — assert
        // against doc.layers, same as every other undo test in this codebase.
        XCTAssertNil(doc.layers[0].shapeFrames[1])
        XCTAssertNil(doc.selectedShapePlacement, "undo should also drop the now-dangling shape selection")
    }
}
