import XCTest
@testable import Flaj

/// Ruler guides (`Guide`/`GuideOrientation` in StageObject.swift) — a
/// dragged-from-the-ruler layout aid, persisted as real document content
/// (unlike `rulersVisible`/`guidesVisible`, which are transient view
/// preferences — see TimelineModel.swift's own doc comment on that split).
@MainActor
final class GuideTests: XCTestCase {

    func testAddGuideAppendsItToTheDocument() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)

        doc.addGuide(orientation: .horizontal, position: 40)

        XCTAssertEqual(doc.guides.count, 1)
        XCTAssertEqual(doc.guides[0].orientation, .horizontal)
        XCTAssertEqual(doc.guides[0].position, 40)
        XCTAssertTrue(doc.canUndo)
    }

    func testMoveGuideUpdatesItsPosition() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.addGuide(orientation: .vertical, position: 10)
        let id = doc.guides[0].id

        doc.moveGuide(id: id, to: 25)

        XCTAssertEqual(doc.guides[0].position, 25)
    }

    func testMoveGuideOnAnUnknownIDIsANoOp() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.addGuide(orientation: .vertical, position: 10)
        let undoCountBefore = doc.undoStack.count

        doc.moveGuide(id: UUID(), to: 99)

        XCTAssertEqual(doc.guides[0].position, 10)
        XCTAssertEqual(doc.undoStack.count, undoCountBefore, "an unknown id shouldn't push a no-op undo step")
    }

    func testRemoveGuideDeletesIt() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.addGuide(orientation: .horizontal, position: 10)
        let id = doc.guides[0].id

        doc.removeGuide(id: id)

        XCTAssertTrue(doc.guides.isEmpty)
    }

    func testRemoveGuideOnAnUnknownIDIsANoOp() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.addGuide(orientation: .horizontal, position: 10)
        let undoCountBefore = doc.undoStack.count

        doc.removeGuide(id: UUID())

        XCTAssertEqual(doc.guides.count, 1)
        XCTAssertEqual(doc.undoStack.count, undoCountBefore, "an unknown id shouldn't push a no-op undo step")
    }

    /// Guides ride the same whole-document-snapshot undo every other piece
    /// of document content does (see Undo.swift) — no guide-specific
    /// UndoEntry field needed, since `guides` is part of `makeSaveFile()`.
    func testUndoRemovesAnAddedGuide() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)

        doc.addGuide(orientation: .horizontal, position: 40)
        XCTAssertEqual(doc.guides.count, 1)

        doc.undo()

        XCTAssertTrue(doc.guides.isEmpty)
    }

    func testMultipleGuideMovesToTheSameGuideCoalesceIntoOneUndoStep() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.addGuide(orientation: .vertical, position: 0)
        let id = doc.guides[0].id
        let countAfterAdd = doc.undoStack.count

        for x in stride(from: CGFloat(1), through: 20, by: 1) {
            doc.moveGuide(id: id, to: x)
        }

        XCTAssertEqual(doc.guides[0].position, 20)
        XCTAssertEqual(doc.undoStack.count, countAfterAdd + 1, "20 drag ticks against the same guide should coalesce into a single snapshot")
    }
}
