import XCTest
@testable import Flaj

/// The Library/Symbol system (`FlajSymbol`/`SymbolInstance` in
/// StageObject.swift) — a reusable, single-frame symbol wraps one text
/// box's content, instanceable with its own independent position/size/
/// scale/rotation/opacity per placement, tweenable exactly like a plain
/// `PlacedText` box. See docs/README's "Library" mention and
/// TimelineDocument.convertSelectedTextToSymbol/placeSymbolInstance.
@MainActor
final class SymbolTests: XCTestCase {

    func testConvertSelectedTextToSymbolReplacesThePlacementButKeepsGeometry() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(
            text: "Hero", x: 10, y: 20, width: 80, height: 24, fontName: "Helvetica",
            fontSize: 18, bold: true, colorHex: "#112233", opacity: 0.8, scale: 1.5, rotation: 30
        )
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedPlacement = TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: 1)

        doc.convertSelectedTextToSymbol(name: "Hero Symbol")

        XCTAssertNil(layer.textFrames[1], "the text placement should be gone, replaced by an instance")
        XCTAssertNil(doc.selectedPlacement)
        XCTAssertEqual(doc.library.count, 1)
        let symbol = doc.library[0]
        XCTAssertEqual(symbol.name, "Hero Symbol")
        XCTAssertEqual(symbol.text, "Hero")
        XCTAssertEqual(symbol.fontSize, 18)
        XCTAssertTrue(symbol.bold)
        XCTAssertEqual(symbol.colorHex, "#112233")

        guard let instance = layer.symbolFrames[1] else { return XCTFail("expected a symbol instance at frame 1") }
        XCTAssertEqual(instance.symbolID, symbol.id)
        // Geometry carries over unchanged — nothing should visibly move.
        XCTAssertEqual(instance.x, 10)
        XCTAssertEqual(instance.y, 20)
        XCTAssertEqual(instance.width, 80)
        XCTAssertEqual(instance.height, 24)
        XCTAssertEqual(instance.opacity, 0.8)
        XCTAssertEqual(instance.scale, 1.5)
        XCTAssertEqual(instance.rotation, 30)
        XCTAssertEqual(doc.selectedSymbolPlacement, TimelineDocument.SymbolPlacementRef(layerID: layer.id, keyframe: 1))
    }

    func testConvertSelectedTextToSymbolIsANoOpWithNoTextSelected() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.convertSelectedTextToSymbol(name: "Nothing")

        XCTAssertTrue(doc.library.isEmpty)
    }

    func testPlaceSymbolInstanceCentersANewInstanceOnTheGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .plain])
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.selectedLayerID = layer.id
        doc.selectFrame(layer: layer, frame: 2, extend: false) // mid-span, governed by keyframe 1
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        doc.library = [symbol]

        doc.placeSymbolInstance(symbol)

        guard let instance = layer.symbolFrames[1] else { return XCTFail("expected an instance at the governing keyframe (1), not frame 2") }
        XCTAssertEqual(instance.symbolID, symbol.id)
        XCTAssertEqual(instance.x, (doc.stageWidth - instance.width) / 2)
        XCTAssertEqual(instance.y, (doc.stageHeight - instance.height) / 2)
        XCTAssertEqual(doc.selectedSymbolPlacement, TimelineDocument.SymbolPlacementRef(layerID: layer.id, keyframe: 1))
    }

    func testPlaceSymbolInstanceWarnsWithoutAGoverningKeyframe() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedLayerID = layer.id
        let symbol = FlajSymbol(name: "Badge", text: "NEW")

        doc.placeSymbolInstance(symbol)

        XCTAssertTrue(layer.symbolFrames.isEmpty)
        XCTAssertEqual(doc.consoleMessages.last?.level, .warn)
    }

    func testSelectingTextAndSymbolPlacementsAreMutuallyExclusive() {
        let textLayer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        textLayer.textFrames[1] = PlacedText(x: 0, y: 0)
        let symbolLayer = TLLayer(name: "symbol", swatch: .blue, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        symbolLayer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        let doc = TimelineDocument(layers: [textLayer, symbolLayer], totalFrames: 1)
        doc.library = [symbol]

        doc.selectFrame(layer: textLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedPlacement)
        XCTAssertNil(doc.selectedSymbolPlacement)

        doc.selectFrame(layer: symbolLayer, frame: 1, extend: false)
        XCTAssertNotNil(doc.selectedSymbolPlacement)
        XCTAssertNil(doc.selectedPlacement, "selecting a symbol instance should clear any text-placement selection")
    }

    func testInterpolatedSymbolInstanceEasesGeometryAcrossATweenSpan() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "art", swatch: .green, frames: frames)
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 20, opacity: 1, scale: 1, rotation: 0)
        layer.symbolFrames[3] = SymbolInstance(symbolID: symbol.id, x: 100, y: 0, width: 40, height: 20, opacity: 0, scale: 2, rotation: 90)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        layer.colorTweenSettings[1] = TweenSettings(family: .linear)

        let mid = layer.interpolatedSymbolInstance(at: 2)
        XCTAssertEqual(mid?.x, 50)
        XCTAssertEqual(mid?.scale, 1.5)
        XCTAssertEqual(mid?.rotation, 45)
        XCTAssertEqual(mid?.opacity, 0.5)
        XCTAssertEqual(mid?.symbolID, symbol.id)
    }

    func testDeleteSelectedSymbolPlacementRemovesTheInstanceOnly() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]
        doc.selectedSymbolPlacement = TimelineDocument.SymbolPlacementRef(layerID: layer.id, keyframe: 1)

        doc.deleteSelectedSymbolPlacement()

        XCTAssertNil(layer.symbolFrames[1])
        XCTAssertNil(doc.selectedSymbolPlacement)
        XCTAssertEqual(doc.library.count, 1, "deleting a placement shouldn't touch the Library symbol itself")
    }

    func testNudgeSelectedSymbolPlacementMovesItByTheGivenDelta() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 10, y: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedSymbolPlacement = TimelineDocument.SymbolPlacementRef(layerID: layer.id, keyframe: 1)

        doc.nudgeSelectedSymbolPlacement(dx: 5, dy: -3)

        XCTAssertEqual(layer.symbolFrames[1]?.x, 15)
        XCTAssertEqual(layer.symbolFrames[1]?.y, 7)
    }

    func testCopyPasteSymbolInstanceLandsOnTheDestinationFrame() {
        let source = TLLayer(name: "source", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        source.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 3, y: 4, width: 40, height: 20)
        let doc = TimelineDocument(layers: [source], totalFrames: 1)
        doc.library = [symbol]
        doc.selectedSymbolPlacement = TimelineDocument.SymbolPlacementRef(layerID: source.id, keyframe: 1)

        doc.copySelectedSymbolPlacement()
        XCTAssertTrue(doc.hasCopiedSymbolInstance)

        let dest = TLLayer(name: "dest", swatch: .blue, frames: [.keyframe(hasScript: false), .plain])
        doc.layers.append(dest)
        doc.pasteSymbolInstance(layer: dest, at: 1)

        XCTAssertEqual(dest.symbolFrames[1]?.symbolID, symbol.id)
        XCTAssertEqual(dest.symbolFrames[1]?.x, 3)
        XCTAssertEqual(doc.selectedSymbolPlacement, TimelineDocument.SymbolPlacementRef(layerID: dest.id, keyframe: 1))
    }

    func testRenameSymbolUpdatesTheLibraryEntry() {
        let symbol = FlajSymbol(name: "Old Name", text: "Hi")
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.library = [symbol]

        doc.renameSymbol(symbol.id, to: "New Name")

        XCTAssertEqual(doc.library[0].name, "New Name")
    }

    func testSymbolBindingEditsRippleToEveryInstance() {
        let layerA = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        let layerB = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "OLD")
        layerA.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        layerB.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 50, y: 0)
        let doc = TimelineDocument(layers: [layerA, layerB], totalFrames: 1)
        doc.library = [symbol]

        guard let binding = doc.symbolBinding(symbol.id) else { return XCTFail("expected a binding") }
        binding.wrappedValue.text = "NEW"

        XCTAssertEqual(doc.library[0].text, "NEW")
        // Both instances still reference the same symbol id — the shared
        // content update is visible to both without touching either
        // instance's own geometry.
        XCTAssertEqual(layerA.symbolFrames[1]?.x, 0)
        XCTAssertEqual(layerB.symbolFrames[1]?.x, 50)
    }

    func testDeleteSymbolPurgesEveryInstanceAcrossEveryLayer() {
        let layerA = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false)])
        let layerB = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        let keep = FlajSymbol(name: "Keep", text: "STAY")
        layerA.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        layerB.symbolFrames[1] = SymbolInstance(symbolID: keep.id, x: 0, y: 0)
        let doc = TimelineDocument(layers: [layerA, layerB], totalFrames: 1)
        doc.library = [symbol, keep]
        doc.selectedSymbolPlacement = TimelineDocument.SymbolPlacementRef(layerID: layerA.id, keyframe: 1)

        doc.deleteSymbol(symbol.id)

        XCTAssertEqual(doc.library.map(\.id), [keep.id])
        XCTAssertNil(layerA.symbolFrames[1], "the orphaned instance should be removed, not left dangling")
        XCTAssertNotNil(layerB.symbolFrames[1], "an instance of a different symbol should be untouched")
        XCTAssertNil(doc.selectedSymbolPlacement, "the selection pointed at the now-deleted instance")
    }

    func testCreateTweenAcceptsASymbolInstanceAtTheSpanStart() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .empty, .empty])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)
        doc.library = [symbol]

        doc.createTween(layer: layer, from: 1, to: 3)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        XCTAssertEqual(layer.symbolFrames[3]?.symbolID, symbol.id, "the end keyframe should inherit the start's instance")
    }

    func testMoveKeyframeCarriesTheSymbolInstanceAlong() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .empty, .empty])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 7, y: 8)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)
        doc.library = [symbol]

        doc.moveKeyframe(layer: layer, from: 1, to: 3)

        XCTAssertNil(layer.symbolFrames[1])
        XCTAssertEqual(layer.symbolFrames[3]?.x, 7)
    }

    // MARK: - Named instances: spawning into stageObjects, script control

    func testNamedInstanceSpawnsIntoStageObjectsWhenItsKeyframeIsReached() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "HELLO", fontName: "Courier", fontSize: 20, bold: true, colorHex: "#FF0000")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 10, y: 20, width: 40, height: 10, name: "badge1")
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]

        doc.stepSimulationFrame()

        guard let obj = doc.stageObject(id: "badge1") else { return XCTFail("expected a spawned stage object named \"badge1\"") }
        XCTAssertEqual(obj.text, "HELLO")
        XCTAssertEqual(obj.fontName, "Courier")
        XCTAssertTrue(obj.bold)
        XCTAssertEqual(obj.x, 10 + 20, "spawn should convert the instance's top-left box into a center point")
        XCTAssertEqual(obj.y, 20 + 5)
    }

    func testUnnamedInstanceNeverSpawns() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "HELLO")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0) // name left empty
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]

        doc.stepSimulationFrame()

        XCTAssertTrue(doc.stageObjects.isEmpty)
    }

    /// The whole point of unifying instance names into `stageObjects`: no
    /// new API needed. A frame script can move/tween a named instance
    /// through the exact same `stage.setTransform`/`stage.tween` a
    /// script-created object already uses.
    func testFrameScriptCanMoveANamedInstanceThroughTheExistingStageAPI() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: true)])
        let symbol = FlajSymbol(name: "Badge", text: "HELLO")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 10, name: "badge1")
        layer.frameScripts[1] = "stage.setTransform('badge1', { x: 200, y: 150 });"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]

        doc.stepSimulationFrame()

        XCTAssertEqual(doc.stageObject(id: "badge1")?.x, 200)
        XCTAssertEqual(doc.stageObject(id: "badge1")?.y, 150)
    }

    /// A same-named `stage.addText` call must no-op against an
    /// already-spawned instance, exactly like two `addText` calls with the
    /// same id already do — the whole point of sharing one id namespace.
    func testAddTextWithACollidingNameIsANoOpAgainstAnAlreadySpawnedInstance() {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: true)])
        let symbol = FlajSymbol(name: "Badge", text: "HELLO")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 10, name: "badge1")
        layer.frameScripts[1] = "stage.addText('badge1', 'IGNORED', 999, 999);"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]

        doc.stepSimulationFrame()

        XCTAssertEqual(doc.stageObject(id: "badge1")?.text, "HELLO", "the spawned instance should win, not the colliding addText call")
    }

    func testCopyPasteFramesCarriesSymbolInstancesRelativeToTheNewStart() {
        let source = TLLayer(name: "source", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Badge", text: "NEW")
        source.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 9, y: 9)
        let doc = TimelineDocument(layers: [source], totalFrames: 1)
        doc.library = [symbol]
        doc.selectedLayerID = source.id
        doc.selectFrame(layer: source, frame: 1, extend: false)

        doc.copySelectedFrames()
        let dest = TLLayer(name: "dest", swatch: .blue, frames: Array(repeating: .empty, count: 5))
        doc.layers.append(dest)
        doc.pasteFrames(layer: dest, at: 3)

        XCTAssertEqual(dest.symbolFrames[3]?.symbolID, symbol.id)
        XCTAssertEqual(dest.symbolFrames[3]?.x, 9)
    }
}
