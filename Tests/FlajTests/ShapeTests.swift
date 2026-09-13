import XCTest
@testable import Flaj

/// Vector shapes (`PlacedShape`/`ShapeKind` in StageObject.swift) — a
/// rectangle or ellipse with its own fill/stroke color+opacity, stroke
/// width, and position/size, drawn via click-drag on the Stage
/// (TimelineDocument.placeShape) rather than click-to-place, and tweenable
/// exactly like text/symbols (see `TLLayer.interpolatedPlacedShape`).
/// Deliberately an independent, always-selectable object rather than
/// Flash's classic shape-merge drawing model — the same "third governing
/// content kind" treatment `textFrames`/`symbolFrames` already get
/// throughout TimelineModel.swift is what these tests are checking for.
@MainActor
final class ShapeTests: XCTestCase {

    /// A `.flaj` file saved before `cornerRadius`/`strokeStyle` existed
    /// still opens, defaulting to a square corner (0) and a solid stroke —
    /// same `decodeIfPresent`-per-field convention every other content
    /// type in this codebase already follows.
    func testPlacedShapeDecodesLegacyJSONMissingCornerRadiusAndStrokeStyle() throws {
        let legacyJSON = Data("""
        {"kind": "rectangle", "x": 5, "y": 6, "width": 40, "height": 20}
        """.utf8)

        let shape = try JSONDecoder().decode(PlacedShape.self, from: legacyJSON)

        XCTAssertEqual(shape.cornerRadius, 0)
        XCTAssertEqual(shape.strokeStyle, .solid)
    }

    func testPlacedShapeCornerRadiusAndStrokeStyleRoundTripThroughJSON() throws {
        var shape = PlacedShape(kind: .rectangle, x: 0, y: 0, width: 10, height: 10)
        shape.cornerRadius = 8
        shape.strokeStyle = .dashed

        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(PlacedShape.self, from: data)

        XCTAssertEqual(decoded.cornerRadius, 8)
        XCTAssertEqual(decoded.strokeStyle, .dashed)
    }

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

    /// Shapes are tweenable exactly like text/symbols — `createTween`'s
    /// content gate accepts a shape-only start keyframe, and (with no
    /// shape yet at the end keyframe) seeds it from the start's own shape,
    /// same "the end inherits the start" contract
    /// `testCreateTweenAcceptsASymbolInstanceAtTheSpanStart` proves for
    /// symbol instances.
    func testCreateTweenAcceptsAShapeAtTheSpanStart() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .empty, .empty])
        layer.shapeFrames[1] = PlacedShape(kind: .ellipse, x: 0, y: 0, fillColorHex: "#3399FF")
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.createTween(layer: layer, from: 1, to: 3)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        XCTAssertEqual(layer.shapeFrames[3]?.kind, .ellipse, "the end keyframe should inherit the start's shape")
        XCTAssertEqual(layer.shapeFrames[3]?.fillColorHex, "#3399FF")
    }

    /// `interpolatedPlacedShape` resolves through a mid-span frame to its
    /// governing keyframe's shape unchanged outside a tween — the same
    /// "snapshot at any frame in the span" contract
    /// `interpolatedPlacedText`/`interpolatedSymbolInstance` have — this is
    /// what both `insertKeyframe`'s carry-forward and `OnionSkinOverlay`'s
    /// shape ghosting rely on.
    func testInterpolatedPlacedShapeResolvesThroughAMidSpanFrameToItsGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .plain])
        layer.shapeFrames[1] = PlacedShape(kind: .ellipse, x: 5, y: 6, width: 40, height: 20, fillColorHex: "#ABCDEF")

        XCTAssertEqual(layer.interpolatedPlacedShape(at: 1)?.x, 5)
        XCTAssertEqual(layer.interpolatedPlacedShape(at: 3)?.x, 5, "a mid-span frame should still resolve to the governing keyframe's own shape")
        XCTAssertEqual(layer.interpolatedPlacedShape(at: 3)?.fillColorHex, "#ABCDEF")
    }

    func testInterpolatedPlacedShapeIsNilWithoutAGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.empty])
        XCTAssertNil(layer.interpolatedPlacedShape(at: 1))
    }

    /// Real tween math, mirroring `testScaleAndRotationTweenAlongsidePositionNotColor`
    /// — deliberately mismatched curves on the two independent groups
    /// (`tweenSettings` for position/size/strokeWidth, `colorTweenSettings`
    /// for fill/stroke color and every opacity) so the midpoint values
    /// below would only line up by coincidence if the groups secretly
    /// shared one curve.
    func testInterpolatedPlacedShapeEasesPositionSizeAndColorIndependently() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "art", swatch: .green, frames: frames)
        layer.shapeFrames[1] = PlacedShape(
            kind: .rectangle, x: 0, y: 0, width: 10, height: 10,
            fillColorHex: "#000000", fillOpacity: 0, strokeColorHex: "#000000", strokeOpacity: 0,
            strokeWidth: 0, opacity: 0
        )
        layer.shapeFrames[3] = PlacedShape(
            kind: .rectangle, x: 100, y: 0, width: 10, height: 10,
            fillColorHex: "#FFFFFF", fillOpacity: 1, strokeColorHex: "#FFFFFF", strokeOpacity: 1,
            strokeWidth: 10, opacity: 1
        )
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        layer.colorTweenSettings[1] = TweenSettings(family: .quad, direction: .easeIn, amount: 100)

        // rawT at frame 2 = 0.5. Position/size/strokeWidth (linear): 0.5
        // exactly. Color group (quad easeIn): 0.5^2 = 0.25.
        let mid = layer.interpolatedPlacedShape(at: 2)
        XCTAssertEqual(mid?.x ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(mid?.strokeWidth ?? -1, 5, accuracy: 0.01)
        XCTAssertEqual(mid?.fillOpacity ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(mid?.strokeOpacity ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(mid?.opacity ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(mid?.fillColorHex, "#404040")
        XCTAssertEqual(mid?.strokeColorHex, "#404040")
        XCTAssertEqual(mid?.kind, .rectangle)
    }

    /// `cornerRadius` eases on the position/size curve (it's geometric,
    /// not a color) exactly like `strokeWidth` does; `strokeStyle` never
    /// interpolates (a dash pattern has no meaningful "halfway" state) and
    /// should stick to the base keyframe's own value throughout the span.
    func testInterpolatedPlacedShapeEasesCornerRadiusButNotStrokeStyle() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "art", swatch: .green, frames: frames)
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0, width: 10, height: 10, cornerRadius: 0, opacity: 1)
        layer.shapeFrames[1]?.strokeStyle = .dashed
        layer.shapeFrames[3] = PlacedShape(x: 0, y: 0, width: 10, height: 10, cornerRadius: 20, opacity: 1)
        layer.shapeFrames[3]?.strokeStyle = .dotted
        layer.tweenSettings[1] = TweenSettings(family: .linear)

        let mid = layer.interpolatedPlacedShape(at: 2)
        XCTAssertEqual(mid?.cornerRadius ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(mid?.strokeStyle, .dashed, "strokeStyle should stay at the start keyframe's own value throughout the span")
    }

    /// A shape's own X/Y/W/H drag gestures always read/write the raw
    /// keyframe value, not the eased one — same invariant
    /// `StagePlacedTextView`'s gestures rely on. Nothing in this app lets a
    /// test drive a SwiftUI gesture directly, so this instead pins down
    /// the underlying contract those gestures depend on: `shapeFrames[kf]`
    /// itself is never mutated by reading `interpolatedPlacedShape`.
    func testInterpolatedPlacedShapeNeverMutatesTheUnderlyingKeyframes() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "art", swatch: .green, frames: frames)
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        layer.shapeFrames[3] = PlacedShape(x: 100, y: 0)
        layer.tweenSettings[1] = TweenSettings(family: .linear)

        _ = layer.interpolatedPlacedShape(at: 2)

        XCTAssertEqual(layer.shapeFrames[1]?.x, 0)
        XCTAssertEqual(layer.shapeFrames[3]?.x, 100)
    }

    /// Regression test: F6 (`insertKeyframe(blank: false)`) already carried
    /// placed text and symbol instances forward to the new keyframe at the
    /// same position (see `TimelineModelTests.
    /// testKeyframeInsertedFarPastAnUnextendedKeyframeInheritsItsContent`)
    /// — shapes were missing the equivalent branch, so F6 after a
    /// shape-only keyframe silently produced an empty keyframe instead of
    /// carrying the shape forward at its same x/y, unlike every other
    /// content kind.
    func testInsertKeyframeCarriesTheShapeForwardAtTheSamePosition() {
        let layer = TLLayer(name: "shape", swatch: .green, frames: [.keyframe(hasScript: false)] + Array(repeating: .empty, count: 9))
        layer.shapeFrames[1] = PlacedShape(kind: .ellipse, x: 12, y: 34, width: 50, height: 40, fillColorHex: "#112233")

        let doc = TimelineDocument(layers: [layer], totalFrames: 10)
        doc.insertKeyframe(layer: layer, at: 10, blank: false)

        XCTAssertEqual(layer.shapeFrames[10]?.kind, .ellipse)
        XCTAssertEqual(layer.shapeFrames[10]?.x, 12)
        XCTAssertEqual(layer.shapeFrames[10]?.y, 34)
        XCTAssertEqual(layer.shapeFrames[10]?.fillColorHex, "#112233")
        XCTAssertTrue(layer.isKeyframe(at: 10))

        for frame in 2...9 {
            XCTAssertEqual(layer.governingKeyframe(at: frame), 1)
        }
    }

    /// A blank keyframe (F7) must NOT carry the shape forward — mirrors
    /// the same "blank" contract text/symbols already have.
    func testBlankInsertKeyframeDoesNotCarryTheShapeForward() {
        let layer = TLLayer(name: "shape", swatch: .green, frames: [.keyframe(hasScript: false), .empty])
        layer.shapeFrames[1] = PlacedShape(x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.insertKeyframe(layer: layer, at: 2, blank: true)

        XCTAssertNil(layer.shapeFrames[2])
        XCTAssertTrue(layer.isKeyframe(at: 2))
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
