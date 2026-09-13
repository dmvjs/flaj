import SwiftUI

// MARK: - Undo/Redo
//
// Whole-document snapshot undo/redo, built on the same Codable round-trip
// Persistence.swift already uses for .flaj files (`makeSaveFile()`/
// `applySaveFile(_:)`) rather than tracking per-field diffs — simple and
// correct for a document this size, at the cost of restoring some
// unrelated state incidentally (undoing an edit also reverts any folder
// expand/collapse or layer hide/lock toggle that happened after it, since
// those aren't given their own snapshot points — deliberately: they're one
// click to redo by hand and not worth a dedicated undo step). Frame-script
// text edits are deliberately excluded too — the Actions panel's
// NSTextView already has its own native per-keystroke undo while it's
// first responder (see CodeEditor.swift), and layering a second undo
// system onto the same field would just make Cmd+Z ambiguous there.
extension TimelineDocument {
    /// A saved document snapshot plus the transient selection/playhead
    /// state at the moment it was taken — undoing should put both back
    /// exactly, not just the document content, or Cmd+Z would leave you
    /// looking at whatever the *next* edit happened to select instead of
    /// what was selected right before the edit being undone.
    /// `FlajLayerFile.id` is what makes `selectedLayerID`/`selectedPlacement`
    /// resolvable again after `applySaveFile` rebuilds `layers` from
    /// scratch — without a stable id, every undo would silently drop the
    /// current selection.
    struct UndoEntry {
        let file: FlajDocumentFile
        let selectedLayerID: UUID?
        let playhead: Int
        let selectedFrame: Int
        let selectedPlacement: TextPlacementRef?
        let selectedSymbolPlacement: SymbolPlacementRef?
        let selectedShapePlacement: ShapePlacementRef?
        let selectedGroupPlacement: GroupPlacementRef?
        // Which symbol's Timeline (if any) `layers`/`totalFrames` meant at
        // the moment of this snapshot — restoring it is what makes undoing
        // an edit made while editing a symbol in place also put the Stage
        // back into that same edit-in-place context, not just revert its
        // content while silently leaving the view wherever it happened to
        // be. Not part of `file`/`makeSaveFile()`: that always captures the
        // document's own root Timeline plus every symbol's content
        // independently (see Persistence.swift), regardless of which one
        // was on screen — this is purely the navigation half.
        let editingPath: [UUID]
    }

    static let undoStackLimit = 200

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func makeUndoEntry() -> UndoEntry {
        UndoEntry(
            file: makeSaveFile(), selectedLayerID: selectedLayerID,
            playhead: playhead, selectedFrame: selectedFrame, selectedPlacement: selectedPlacement,
            selectedSymbolPlacement: selectedSymbolPlacement, selectedShapePlacement: selectedShapePlacement,
            selectedGroupPlacement: selectedGroupPlacement, editingPath: editingPath
        )
    }

    /// Wraps a discrete, undoable document edit. `token` coalesces a run of
    /// edits to the same target (dragging a handle, typing in a field) into
    /// one undo step instead of one per tick/keystroke — pass a string
    /// stable for the duration of that editing session (e.g.
    /// `TextPlacementRef.undoToken`) and distinct from any other target's.
    /// `nil` (the default) always starts a fresh step, for one-shot actions
    /// (add layer, insert keyframe, pick from a menu).
    ///
    /// Safe to nest: a method that calls another `withUndoSnapshot`-wrapped
    /// method as an internal step (e.g. `createTween` calling
    /// `insertKeyframe`) only records one snapshot, from the outermost
    /// call — both mutations are really one user action.
    func withUndoSnapshot(coalesce token: String? = nil, _ body: () -> Void) {
        let isOutermost = undoActionDepth == 0
        undoActionDepth += 1
        defer { undoActionDepth -= 1 }
        if isOutermost {
            if token == nil || token != coalescingToken {
                undoStack.append(makeUndoEntry())
                if undoStack.count > Self.undoStackLimit { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            coalescingToken = token
        }
        body()
    }

    /// A `doc.property` binding that snapshots before every write — for
    /// fields with no shared model method to hook (stage color/fps, the
    /// web-export settings sheet), the view-level equivalent of wrapping a
    /// model method's body in `withUndoSnapshot`.
    func undoableBinding<T>(_ keyPath: ReferenceWritableKeyPath<TimelineDocument, T>, coalesce token: String? = nil) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { newValue in self.withUndoSnapshot(coalesce: token) { self[keyPath: keyPath] = newValue } }
        )
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        coalescingToken = nil
        redoStack.append(makeUndoEntry())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        coalescingToken = nil
        undoStack.append(makeUndoEntry())
        restore(next)
    }

    private func restore(_ entry: UndoEntry) {
        applySaveFile(entry.file)
        // Restored before resolving selectedLayerID/selectedPlacement below
        // so `layers` (computed — see TimelineModel.swift) already points
        // at the right Timeline when those lookups run, same as it will
        // for every view reading `doc.layers` right after this returns.
        editingPath = entry.editingPath
        selectedLayerID = layers.first(where: { $0.id == entry.selectedLayerID })?.id ?? layers.first?.id
        playhead = min(max(entry.playhead, 1), max(totalFrames, 1))
        selectedFrame = min(max(entry.selectedFrame, 1), max(totalFrames, 1))
        rangeSelectionEnd = nil
        // A multi-selection beyond the primary ref isn't restored — each
        // additional member would need its own type-specific dangling-
        // reference check the way the four primary refs get below, and
        // Cmd+Z landing back on just the primary selection (rather than a
        // stale, possibly-dangling multi-selection) is the safer default.
        additionalSelectedPlacements.removeAll()
        if let ref = entry.selectedPlacement,
           layers.first(where: { $0.id == ref.layerID })?.textFrames[ref.keyframe] != nil {
            selectedPlacement = ref
        } else {
            selectedPlacement = nil
        }
        if let ref = entry.selectedSymbolPlacement,
           layers.first(where: { $0.id == ref.layerID })?.symbolFrames[ref.keyframe] != nil {
            selectedSymbolPlacement = ref
        } else {
            selectedSymbolPlacement = nil
        }
        if let ref = entry.selectedShapePlacement,
           layers.first(where: { $0.id == ref.layerID })?.shapeFrames[ref.keyframe] != nil {
            selectedShapePlacement = ref
        } else {
            selectedShapePlacement = nil
        }
        if let ref = entry.selectedGroupPlacement,
           layers.first(where: { $0.id == ref.layerID })?.groupFrames[ref.keyframe] != nil {
            selectedGroupPlacement = ref
        } else {
            selectedGroupPlacement = nil
        }
    }
}
