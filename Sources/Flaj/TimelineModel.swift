import SwiftUI
import Observation
import Dispatch
import JavaScriptCore

/// What a single (layer, frame) cell looks like on the timeline grid.
enum FrameMark: Equatable, Codable {
    case empty                 // no content at all
    case keyframe(hasScript: Bool)   // solid dot — keyframe with content
    case emptyKeyframe         // hollow dot — keyframe placed but empty
    case tween                 // mid-span frame, part of a motion tween
    case plain                 // mid-span frame, just extends previous keyframe
    case spanEnd               // hollow marker closing out a span

    private enum CodingKeys: String, CodingKey { case type, hasScript }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty: try c.encode("empty", forKey: .type)
        case .keyframe(let hasScript):
            try c.encode("keyframe", forKey: .type)
            try c.encode(hasScript, forKey: .hasScript)
        case .emptyKeyframe: try c.encode("emptyKeyframe", forKey: .type)
        case .tween: try c.encode("tween", forKey: .type)
        case .plain: try c.encode("plain", forKey: .type)
        case .spanEnd: try c.encode("spanEnd", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "keyframe": self = .keyframe(hasScript: try c.decodeIfPresent(Bool.self, forKey: .hasScript) ?? false)
        case "emptyKeyframe": self = .emptyKeyframe
        case "tween": self = .tween
        case "plain": self = .plain
        case "spanEnd": self = .spanEnd
        default: self = .empty
        }
    }
}

enum LayerKind: Codable, Equatable {
    case normal, folder
}

/// One line in the debug console — Flash's Output panel equivalent.
struct ConsoleMessage: Identifiable {
    enum Level: Equatable { case log, warn, error }
    let id = UUID()
    let level: Level
    let text: String
    let frame: Int
}

@Observable
final class TLLayer: Identifiable {
    let id: UUID
    var name: String
    var swatch: Color
    var kind: LayerKind
    var indent: Int
    var locked: Bool
    var hidden: Bool
    var expanded: Bool = true
    var frames: [FrameMark]
    var frameScripts: [Int: String] = [:]   // 1-based frame number -> JS/TS source
    var textFrames: [Int: PlacedText] = [:] // 1-based keyframe number -> placed text
    // Named keyframes — a navigation target for gotoAndPlay("name")/
    // gotoAndStop("name")/goto("name") from a frame script, matching
    // Flash's own frame labels. Purely a keyframe annotation, same
    // dictionary shape as frameScripts/textFrames.
    var frameLabels: [Int: String] = [:]
    var tweenSettings: [Int: TweenSettings] = [:] // keyed by the tween span's start keyframe
    // Color/opacity ease independently of position/size — same start
    // keyframe key, same span, but its own family/direction/amount, the way
    // Flash's Properties panel splits "Position and Size" from "Color
    // Effect" as separate tween-affecting groups rather than one shared curve.
    var colorTweenSettings: [Int: TweenSettings] = [:]

    func isKeyframe(at frame: Int) -> Bool {
        let idx = frame - 1
        guard frames.indices.contains(idx) else { return false }
        switch frames[idx] {
        case .keyframe, .emptyKeyframe: return true
        default: return false
        }
    }

    /// The keyframe that governs `frame` on this layer — walking back over
    /// `.plain`/`.tween` span-continuation marks to the `.keyframe`/
    /// `.emptyKeyframe` that started the span. nil if `frame` isn't inside
    /// any span (e.g. still `.empty`).
    func governingKeyframe(at frame: Int) -> Int? {
        var i = frame - 1
        while i >= 0 && frames.indices.contains(i) {
            switch frames[i] {
            case .keyframe, .emptyKeyframe: return i + 1
            case .plain, .tween: i -= 1
            default: return nil
            }
        }
        return nil
    }

    /// The nearest actual keyframe at or before `frame`, regardless of
    /// what's in between — even across `.empty` gaps that `governingKeyframe`
    /// would stop dead at. Used to find what a brand new F5/F6 frame should
    /// inherit when it isn't part of a live span yet (see
    /// TimelineDocument.extendSpan) — Flash's own timeline behaves the same
    /// way: a keyframe's content implicitly reaches forward to wherever you
    /// next press F5/F6, not just to wherever an earlier F5 happened to stop.
    func nearestKeyframe(before frame: Int) -> Int? {
        var i = frame - 1
        while i >= 0 && frames.indices.contains(i) {
            switch frames[i] {
            case .keyframe, .emptyKeyframe: return i + 1
            default: i -= 1
            }
        }
        return nil
    }

    /// If `startKeyframe` opens a `.tween` run (created by `createTween`),
    /// the keyframe that closes it — i.e. the tween's "B" state. nil if
    /// `startKeyframe` isn't followed by an unbroken `.tween` run ending in
    /// a real keyframe (a plain span, or no span at all).
    func tweenTarget(from startKeyframe: Int) -> Int? {
        var i = startKeyframe // 0-based index of the frame right after startKeyframe
        guard frames.indices.contains(i) else { return nil }
        guard case .tween = frames[i] else { return nil }
        while frames.indices.contains(i) {
            switch frames[i] {
            case .tween: i += 1
            case .keyframe, .emptyKeyframe: return i + 1
            default: return nil
            }
        }
        return nil
    }

    /// What's actually showing at `frame` — the governing keyframe's
    /// PlacedText as-is for a plain span, or eased-interpolated toward the
    /// tween's end keyframe for a tween span. nil if there's no content at
    /// `frame` at all. Single source of truth shared by StagePlacedTextView
    /// (live rendering) and insertKeyframe (snapshotting a mid-tween split).
    func interpolatedPlacedText(at frame: Int) -> PlacedText? {
        guard let kf = governingKeyframe(at: frame), let base = textFrames[kf] else { return nil }
        guard let endKf = tweenTarget(from: kf), let end = textFrames[endKf], endKf > kf else { return base }
        let rawT = Double(frame - kf) / Double(endKf - kf)
        let t = (tweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        let colorT = (colorTweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        var result = base
        result.x = base.x + (end.x - base.x) * t
        result.y = base.y + (end.y - base.y) * t
        result.width = base.width + (end.width - base.width) * t
        result.height = base.height + (end.height - base.height) * t
        result.fontSize = base.fontSize + (end.fontSize - base.fontSize) * t
        result.opacity = base.opacity + (end.opacity - base.opacity) * colorT
        result.colorHex = Self.interpolateHex(base.colorHex, end.colorHex, colorT)
        return result
    }

    /// Linearly interpolates two "#rrggbb" colors by `t` (0...1), channel by
    /// channel — the standard sRGB lerp, matching how CSS itself interpolates
    /// a `color` animation between two hex values (see player.js), so the
    /// native app and the web export agree on the exact same colors.
    private static func interpolateHex(_ from: String, _ to: String, _ t: Double) -> String {
        func components(_ hex: String) -> (UInt8, UInt8, UInt8) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
            return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
        let (r0, g0, b0) = components(from)
        let (r1, g1, b1) = components(to)
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return String(format: "#%02X%02X%02X", lerp(r0, r1), lerp(g0, g1), lerp(b0, b1))
    }

    init(id: UUID = UUID(), name: String, swatch: Color, kind: LayerKind = .normal, indent: Int = 0,
         locked: Bool = false, hidden: Bool = false, frames: [FrameMark],
         textFrames: [Int: PlacedText] = [:]) {
        self.id = id
        self.name = name
        self.swatch = swatch
        self.kind = kind
        self.indent = indent
        self.locked = locked
        self.hidden = hidden
        self.frames = frames
        self.textFrames = textFrames
    }
}

@MainActor
@Observable
final class TimelineDocument {
    var layers: [TLLayer]
    var totalFrames: Int
    var playhead: Int = 1

    // Grounded in reality: below 1fps the playback math degenerates and
    // there's nothing meaningfully "animated"; above 120fps you're asking
    // for a rate no common display can even show (120Hz/ProMotion is the
    // practical ceiling), and a run-loop timer stops being reliable well
    // before that anyway.
    static let minFPS: Double = 1
    static let maxFPS: Double = 120
    var fps: Double = 12.0 {
        didSet {
            let clamped = min(max(fps, Self.minFPS), Self.maxFPS)
            if clamped != fps { fps = clamped }
        }
    }
    var isPlaying: Bool = false
    var selectedLayerID: UUID?

    // The frame shown in the Actions panel / highlighted in the grid.
    // Deliberately separate from `playhead`: while playing, `playhead`
    // advances every tick, but the code editor and selection box should
    // stay put on whatever frame was last explicitly clicked, not flicker
    // through every frame as the movie runs.
    var selectedFrame: Int = 1

    // Shift-click range extension on the timeline grid, anchored at
    // `selectedFrame`. Only meaningful on `selectedLayerID`'s row — picking
    // a different layer (with or without shift) starts a fresh anchor there
    // instead of extending across layers, since a tween/range is inherently
    // a single-layer span.
    var rangeSelectionEnd: Int?

    var selectedFrameRange: ClosedRange<Int> {
        guard let end = rangeSelectionEnd else { return selectedFrame...selectedFrame }
        return min(selectedFrame, end)...max(selectedFrame, end)
    }

    /// The single entry point the frame grid's click handlers call — a
    /// plain click moves the playhead and starts a fresh range anchor;
    /// shift-click (only honored on the already-selected layer) extends the
    /// range without moving the playhead, matching Flash's frame-selection
    /// behavior. Clears any stage text selection — the Properties panel
    /// shows text properties OR tween properties, matching whichever you
    /// selected most recently, never both at once.
    func selectFrame(layer: TLLayer, frame: Int, extend: Bool) {
        selectedPlacement = nil
        if extend && selectedLayerID == layer.id {
            rangeSelectionEnd = frame
        } else {
            selectedLayerID = layer.id
            gotoAndStop(frame)
            rangeSelectionEnd = nil
        }
    }

    // The Stage — Flash's term for the fixed-size render surface, scriptable
    // from frame code via the `stage`/`bg` JS globals below.
    var stageWidth: CGFloat = 550
    var stageHeight: CGFloat = 400
    var stageColor: Color = .white

    // Web export presentation — how the exported page's <title> reads and
    // how the Stage sits in whatever page or iframe embeds it. See
    // WebExport.swift. Persisted like the Stage properties above, since
    // they're a property of the document, not a one-off export choice.
    var webExportTitle: String = ""
    var webExportFit: StageFit = .contain
    var webExportAlignment: StageAlignment = .center
    // Distinct from `stageColor` (the movie's own background, settable at
    // runtime via `bg.color()`) — this is the page around it: what shows
    // through a `.contain` letterbox, or behind a transparent Stage.
    // Defaults transparent so the export blends into whatever page embeds it.
    var webExportPageBackground: Color = .clear
    var webExportMinify: Bool = true
    // Drives the settings sheet shown before the save panel — see
    // `exportWebPage()`/`WebExportSettingsSheet` in WebExport.swift.
    // Transient UI state, not part of the saved document.
    var webExportSheetPresented: Bool = false

    var consoleMessages: [ConsoleMessage] = []

    var currentFileURL: URL?

    var stageObjects: [StageObject] = []
    @ObservationIgnored private var activeTweens: [ActiveTween] = []

    // MARK: - Undo/Redo
    //
    // Whole-document snapshots (see Undo.swift), reusing the same Codable
    // round-trip Persistence.swift already uses for .flaj files rather than
    // tracking per-field diffs. Declared here, not in that extension,
    // because a stored property can only be added where the class itself
    // is declared. `undoStack`/`redoStack` stay observable (not
    // `@ObservationIgnored`) since `canUndo`/`canRedo` read them to drive
    // the Edit menu's enabled state; `coalescingToken`/`undoActionDepth`
    // are pure bookkeeping nothing displays.
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    @ObservationIgnored var coalescingToken: String?
    @ObservationIgnored var undoActionDepth = 0

    // MARK: - Text tool

    enum StageTool { case selection, text }
    struct TextPlacementRef: Equatable {
        let layerID: UUID; let keyframe: Int
        /// Undo-coalescing key (see `withUndoSnapshot`) — edits to the same
        /// placement collapse into one undo step regardless of which field
        /// changed (typing, dragging, a color pick), so a burst of edits to
        /// one text box reads as a single Cmd+Z instead of one per keystroke.
        var undoToken: String { "placement:\(layerID)-\(keyframe)" }
    }

    var selectedTool: StageTool = .selection
    var selectedPlacement: TextPlacementRef?

    // MARK: - Onion skinning
    //
    // A Stage-only editing aid — ghosted nearby-frame content — not part of
    // the saved document (same as selectedTool/webExportSheetPresented) and
    // deliberately never rendered by StageContentView, the piece GIF export
    // shares with the live preview (see StageView.OnionSkinOverlay's own
    // doc comment): a ghost frame must never leak into exported output.
    var onionSkinEnabled: Bool = false
    // How many frames before/after the playhead to ghost — Flash's own
    // onion markers are draggable on the ruler; a fixed symmetric range
    // with a small adjustable count is the scoped-down equivalent here.
    var onionSkinRange: Int = 2

    /// Places a new default text box on `selectedLayer` at the keyframe that
    /// governs `selectedFrame`, and selects it. Mirrors the Actions panel's
    /// own rule (see CodeEditorPanel) that content only attaches to an
    /// actual keyframe — if there isn't one yet, this just logs a hint
    /// instead of silently inventing one.
    func placeText(at point: CGPoint) {
        guard let layer = selectedLayer else { return }
        guard let kf = layer.governingKeyframe(at: selectedFrame) else {
            logToConsole("Select or insert a keyframe on \"\(layer.name)\" before placing text.", level: .warn)
            return
        }
        withUndoSnapshot {
            let placement = PlacedText(x: point.x, y: point.y)
            layer.textFrames[kf] = placement
            selectedPlacement = TextPlacementRef(layerID: layer.id, keyframe: kf)
        }
    }

    func deleteSelectedPlacement() {
        guard let ref = selectedPlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        withUndoSnapshot {
            layer.textFrames[ref.keyframe] = nil
            selectedPlacement = nil
        }
    }

    /// A read/write binding straight into the owning layer's dictionary —
    /// same idiom as CodeEditorPanel.scriptBinding(for:). Writes are
    /// undo-coalesced per placement (see `TextPlacementRef.undoToken`), so
    /// this one setter is what makes every Properties-panel field and both
    /// Stage drag gestures on placed text undoable without each needing
    /// its own snapshot call.
    func binding(for ref: TextPlacementRef) -> Binding<PlacedText>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.textFrames[ref.keyframe] ?? PlacedText(x: 0, y: 0) },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.undoToken) { layer.textFrames[ref.keyframe] = newValue }
            }
        )
    }

    /// Arrow-key nudge (see StageView) — moves the selected placement by
    /// (dx, dy) points. A plain, testable method separate from the
    /// KeyPress-handling glue so the actual math has a direct unit test,
    /// not just an end-to-end one. A no-op when nothing's selected.
    func nudgeSelectedPlacement(dx: CGFloat, dy: CGFloat) {
        guard let ref = selectedPlacement, let binding = binding(for: ref) else { return }
        binding.wrappedValue.x += dx
        binding.wrappedValue.y += dy
    }

    // MARK: - Frame labels

    /// A read/write binding onto a keyframe's label — same idiom as
    /// `binding(for:)`/`CodeEditorPanel.scriptBinding(for:)`. Empty string
    /// clears the label (matching how an empty script/text field would
    /// mean "nothing here"), rather than storing `""` as a real label.
    func labelBinding(layer: TLLayer, at frame: Int) -> Binding<String> {
        Binding(
            get: { layer.frameLabels[frame] ?? "" },
            set: { newValue in
                self.withUndoSnapshot(coalesce: "label:\(layer.id)-\(frame)") {
                    layer.frameLabels[frame] = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    /// The frame carrying `label`, searched across every layer in document
    /// order — what `gotoAndPlay("label")`/`gotoAndStop`/`goto` resolve
    /// against (see makeJSContext below and player.js's `resolveFrame`,
    /// which must stay in lockstep with this). nil if no keyframe anywhere
    /// has that exact label.
    func frame(forLabel label: String) -> Int? {
        for layer in layers {
            // Dictionary iteration order is unspecified — sort so a layer
            // with (rare) duplicate labels resolves to its earliest frame,
            // deterministically, rather than whichever the hash table
            // happens to visit first.
            if let match = layer.frameLabels.sorted(by: { $0.key < $1.key }).first(where: { $0.value == label }) {
                return match.key
            }
        }
        return nil
    }

    // MARK: - Copy/paste placed text

    @ObservationIgnored private var copiedPlacedText: PlacedText?

    var hasCopiedText: Bool { copiedPlacedText != nil }

    func copySelectedPlacement() {
        guard let ref = selectedPlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        copiedPlacedText = layer.textFrames[ref.keyframe]
    }

    /// Pastes at `frame` on `layer` — same position/size/font as copied, so
    /// it's a ready-made "B" state: drag it somewhere else and Create Tween
    /// between the two keyframes.
    func pastePlacedText(layer: TLLayer, at frame: Int) {
        guard let copied = copiedPlacedText else { return }
        withUndoSnapshot {
            let kf: Int
            if let existing = layer.governingKeyframe(at: frame), existing == frame {
                kf = existing
            } else {
                insertKeyframe(layer: layer, at: frame, blank: false)
                kf = frame
            }
            layer.textFrames[kf] = copied
            selectedPlacement = TextPlacementRef(layerID: layer.id, keyframe: kf)
        }
    }

    // MARK: - Copy/paste frames
    //
    // Whole-span copy — every frame mark plus whatever content (script,
    // placed text, tween settings, label) each one carries, unlike
    // Copy/Paste Text above which only ever touches one placed text box.
    // Stored relative to the copied range's start, so paste can land
    // anywhere and reproduce the same shape.

    private struct CopiedFrames {
        let marks: [FrameMark]
        let scripts: [Int: String]
        let textFrames: [Int: PlacedText]
        let tweenSettings: [Int: TweenSettings]
        let colorTweenSettings: [Int: TweenSettings]
        let labels: [Int: String]
    }

    @ObservationIgnored private var copiedFrames: CopiedFrames?

    var hasCopiedFrames: Bool { copiedFrames != nil }

    func copySelectedFrames() {
        guard let layer = selectedLayer else { return }
        let range = selectedFrameRange
        var marks: [FrameMark] = []
        var scripts: [Int: String] = [:]
        var textFrames: [Int: PlacedText] = [:]
        var tweenSettings: [Int: TweenSettings] = [:]
        var colorTweenSettings: [Int: TweenSettings] = [:]
        var labels: [Int: String] = [:]
        for (offset, frame) in range.enumerated() {
            marks.append(frame - 1 < layer.frames.count ? layer.frames[frame - 1] : .empty)
            if let v = layer.frameScripts[frame] { scripts[offset] = v }
            if let v = layer.textFrames[frame] { textFrames[offset] = v }
            if let v = layer.tweenSettings[frame] { tweenSettings[offset] = v }
            if let v = layer.colorTweenSettings[frame] { colorTweenSettings[offset] = v }
            if let v = layer.frameLabels[frame] { labels[offset] = v }
        }
        copiedFrames = CopiedFrames(
            marks: marks, scripts: scripts, textFrames: textFrames,
            tweenSettings: tweenSettings, colorTweenSettings: colorTweenSettings, labels: labels
        )
    }

    /// Pastes the copied span starting at `startFrame` on `layer`, growing
    /// capacity to fit and overwriting whatever was already there —
    /// matching Flash's own Paste Frames, which replaces rather than
    /// inserts/shifts.
    func pasteFrames(layer: TLLayer, at startFrame: Int) {
        guard let copied = copiedFrames, !copied.marks.isEmpty else { return }
        withUndoSnapshot {
            growCapacity(to: max(totalFrames, startFrame + copied.marks.count - 1))
            for (offset, mark) in copied.marks.enumerated() {
                layer.frames[startFrame + offset - 1] = mark
            }
            for (offset, v) in copied.scripts { layer.frameScripts[startFrame + offset] = v }
            for (offset, v) in copied.textFrames { layer.textFrames[startFrame + offset] = v }
            for (offset, v) in copied.tweenSettings { layer.tweenSettings[startFrame + offset] = v }
            for (offset, v) in copied.colorTweenSettings { layer.colorTweenSettings[startFrame + offset] = v }
            for (offset, v) in copied.labels { layer.frameLabels[startFrame + offset] = v }
        }
    }

    // MARK: - Motion tween

    /// Turns the keyframe range [startFrame, endFrame] on `layer` into a
    /// motion tween: `endFrame` becomes a keyframe (inheriting the start's
    /// placed text if it doesn't already have its own — e.g. from a paste),
    /// and every frame strictly between the two is marked `.tween`, which
    /// both draws the connecting arrow (TimelineView) and drives the
    /// interpolated render (StageView.StagePlacedTextView).
    func createTween(layer: TLLayer, from startFrame: Int, to endFrame: Int) {
        guard startFrame != endFrame else { return }
        let lo = min(startFrame, endFrame), hi = max(startFrame, endFrame)
        guard layer.isKeyframe(at: lo), layer.textFrames[lo] != nil else {
            logToConsole("Create Tween needs a keyframe with placed text at the start of the range.", level: .warn)
            return
        }
        withUndoSnapshot {
            if !layer.isKeyframe(at: hi) {
                insertKeyframe(layer: layer, at: hi, blank: false)
            }
            if layer.textFrames[hi] == nil {
                layer.textFrames[hi] = layer.textFrames[lo]
            }
            growCapacity(to: max(totalFrames, hi))
            for f in (lo + 1)..<hi {
                layer.frames[f - 1] = .tween
            }
            // Drop the range highlight — otherwise every cell's selection
            // border stays drawn on top of the tween band, reading as a grid
            // instead of the smooth lavender span with a single arrow.
            selectedFrame = lo
            rangeSelectionEnd = nil
            if layer.tweenSettings[lo] == nil {
                layer.tweenSettings[lo] = TweenSettings()
            }
            if layer.colorTweenSettings[lo] == nil {
                layer.colorTweenSettings[lo] = TweenSettings()
            }
        }
    }

    /// Slides a tween's end keyframe from `oldEnd` to `newEnd` on the same
    /// layer — lengthening or shortening the span. `newEnd` must land at
    /// least 2 frames after the tween's start (checked here regardless of
    /// what the caller already clamped to, since this is also the model's
    /// own invariant) — landing right next to the start would leave no
    /// interior `.tween` frame, the model's only signal that two keyframes
    /// are still tween-linked at all. The end keyframe's content (placed
    /// text, script) moves with it; frames newly covered by a longer span
    /// become `.tween`, frames dropped by a shorter one become `.empty`.
    func moveTweenEnd(layer: TLLayer, from oldEnd: Int, to newEnd: Int) {
        guard oldEnd != newEnd,
              let start = layer.governingKeyframe(at: oldEnd - 1),
              layer.tweenTarget(from: start) == oldEnd,
              newEnd > start + 1 else { return }

        withUndoSnapshot {
            growCapacity(to: max(totalFrames, newEnd))
            let movedText = layer.textFrames[oldEnd]
            let movedScript = layer.frameScripts[oldEnd]
            layer.textFrames[oldEnd] = nil
            layer.frameScripts[oldEnd] = nil

            if newEnd > oldEnd {
                for f in oldEnd...(newEnd - 1) { layer.frames[f - 1] = .tween }
            } else {
                for f in (newEnd + 1)...oldEnd { layer.frames[f - 1] = .empty }
            }
            layer.textFrames[newEnd] = movedText
            layer.frameScripts[newEnd] = movedScript
            layer.frames[newEnd - 1] = .keyframe(hasScript: !(movedScript ?? "").isEmpty)

            if selectedFrame == oldEnd { selectedFrame = newEnd }
        }
    }

    /// Reverts a tween span back to plain frames, keeping both keyframes
    /// and their content intact — unlike Clear Frame, which wipes the frame
    /// (and its content) entirely. A no-op if `frame` isn't governed by an
    /// active tween.
    func removeTween(layer: TLLayer, at frame: Int) {
        guard let start = layer.governingKeyframe(at: frame), let end = layer.tweenTarget(from: start) else { return }
        withUndoSnapshot {
            for f in (start + 1)..<end {
                layer.frames[f - 1] = .plain
            }
            layer.tweenSettings[start] = nil
            layer.colorTweenSettings[start] = nil
        }
    }

    /// The tween span (if any) that governs `selectedFrame` on
    /// `selectedLayerID` — what the Properties panel's Tween section binds
    /// to. Distinct from `selectedPlacement`: this tracks a timeline frame
    /// selection, not a stage object selection, so both can be shown at once.
    struct TweenRef: Equatable {
        let layerID: UUID; let startFrame: Int
        // Position/size tweening and color-effect tweening are independent
        // curves on the same span (see TLLayer.colorTweenSettings) — kept
        // as separate coalescing keys so dragging the "Amount" slider in
        // one doesn't merge into the other's undo step.
        var undoToken: String { "tween:\(layerID)-\(startFrame)" }
        var colorUndoToken: String { "colortween:\(layerID)-\(startFrame)" }
    }

    var activeTweenRef: TweenRef? {
        guard let id = selectedLayerID, let layer = layers.first(where: { $0.id == id }) else { return nil }
        guard let kf = layer.governingKeyframe(at: selectedFrame), layer.tweenTarget(from: kf) != nil else { return nil }
        return TweenRef(layerID: id, startFrame: kf)
    }

    func tweenBinding(for ref: TweenRef) -> Binding<TweenSettings>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.tweenSettings[ref.startFrame] ?? TweenSettings() },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.undoToken) { layer.tweenSettings[ref.startFrame] = newValue }
            }
        )
    }

    /// Same idea as `tweenBinding(for:)`, for the independent color/opacity
    /// easing curve (see `TLLayer.colorTweenSettings`).
    func colorTweenBinding(for ref: TweenRef) -> Binding<TweenSettings>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.colorTweenSettings[ref.startFrame] ?? TweenSettings() },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.colorUndoToken) { layer.colorTweenSettings[ref.startFrame] = newValue }
            }
        )
    }

    @ObservationIgnored private var timerSource: DispatchSourceTimer?

    init(layers: [TLLayer], totalFrames: Int) {
        self.layers = layers
        self.totalFrames = totalFrames
        self.selectedLayerID = layers.first?.id
    }

    var elapsedSeconds: Double {
        Double(playhead - 1) / fps
    }

    /// The user-facing Play/Stop transport control. Pressing Play from a
    /// stopped state is "run the program again" — it should get a clean
    /// slate of const/let bindings, not whatever was left over from the
    /// last run. This is deliberately NOT inside play() itself: play() is
    /// also what gotoAndPlay()/the JS `play()` global call internally for
    /// perfectly normal in-run navigation (e.g. a paused menu frame doing
    /// `stop()` then a button handler calling `gotoAndPlay()`), and those
    /// must NOT wipe state — only an explicit user restart should.
    func togglePlay() {
        if isPlaying {
            stop()
        } else {
            resetRuntime()
            playhead = 1
            play()
        }
    }

    /// Starts (or resumes) playback. Runs the current frame's scripts
    /// immediately — entering a frame executes its actions right away in
    /// Flash, not after the first tick's delay — so a `stop()` on frame 1
    /// takes effect before anything visibly advances.
    func play() {
        isPlaying = true
        stepSimulationFrame()
        guard isPlaying else { return } // the frame's own script may have called stop()
        scheduleTimer()
    }

    func stop() {
        isPlaying = false
        timerSource?.cancel()
        timerSource = nil
    }

    /// Runs on a dedicated background queue instead of the main run loop —
    /// a Timer registered there can be silently skipped while the run loop
    /// is in an event-tracking mode (scrolling, dragging), which a
    /// GCD timer on its own queue is immune to. Execution of the frame's
    /// JS still has to hop onto the main actor (JS state isn't thread-safe
    /// to touch concurrently), so this buys triggering precision, not a
    /// hard real-time guarantee — see contentLength/tick for the model.
    private func scheduleTimer() {
        timerSource?.cancel()
        let interval = 1.0 / fps
        let queue = DispatchQueue(label: "flaj.playback-clock", qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        timerSource = source
        source.resume()
    }

    /// The last frame, across any layer, that actually has content — not
    /// the document's addressable capacity (`totalFrames`). A brand new
    /// document with nothing placed anywhere reports 1, which is what keeps
    /// playback parked on frame 1 instead of looping over blank frames.
    var contentLength: Int {
        var last = 1
        for layer in layers {
            for (i, mark) in layer.frames.enumerated() where mark != .empty {
                last = max(last, i + 1)
            }
        }
        return last
    }

    /// One playback step: advance the playhead, then run whatever the newly
    /// entered frame's scripts do (which may itself call stop()/goto*).
    private func tick() {
        guard isPlaying else { return }
        playhead = playhead >= contentLength ? 1 : playhead + 1
        stepSimulationFrame()
    }

    /// Advances any in-flight tweens to the current frame, then runs that
    /// frame's scripts — the two per-frame effects, in the order Flash
    /// itself applies them (motion updates before actions see the result).
    /// Shared by real-time playback (tick) and GIF export's frame-by-frame
    /// simulation, which needs to reproduce the exact same state machine
    /// synchronously rather than in real time.
    func stepSimulationFrame() {
        advanceTweens()
        runScriptsOnCurrentFrame()
    }

    /// Pure playhead navigation for the UI (ruler drag, frame-cell click) —
    /// does NOT execute frame scripts, since scrubbing in the editor isn't
    /// the same as the playhead actually running through the movie.
    func gotoAndStop(_ frame: Int) {
        stop()
        playhead = min(max(frame, 1), totalFrames)
        selectedFrame = playhead
    }

    func gotoAndPlay(_ frame: Int) {
        playhead = min(max(frame, 1), totalFrames)
        play()
    }

    // MARK: - JavaScript runtime

    @ObservationIgnored private lazy var jsContext: JSContext = makeJSContext()

    /// Top-level `const`/`let` names already declared at least once during
    /// this document's runtime lifetime — see preprocessForReentry below.
    @ObservationIgnored private var declaredTopLevelBindings: Set<String> = []

    /// Resolves a `gotoAndStop`/`gotoAndPlay`/`goto` argument, which
    /// JavaScript's dynamic typing lets be either a frame number or a frame
    /// label string. nil (a no-op navigation) on an unrecognized label —
    /// logged as a console warning, same as the other guard-based
    /// navigation misses in this file, rather than silently doing nothing.
    private func resolveFrameArgument(_ value: JSValue) -> Int? {
        if value.isString, let label = value.toString() {
            guard let frame = frame(forLabel: label) else {
                logToConsole("No frame labeled \"\(label)\".", level: .warn)
                return nil
            }
            return frame
        }
        guard value.isNumber else { return nil }
        return Int(value.toInt32())
    }

    private func makeJSContext() -> JSContext {
        let ctx = JSContext()!
        let stopFn: @convention(block) () -> Void = { [weak self] in
            self?.stop()
        }
        let playFn: @convention(block) () -> Void = { [weak self] in
            self?.play()
        }
        // These are the versions frame scripts call — unlike the UI's
        // gotoAndStop/gotoAndPlay above, navigating from script code DOES
        // run the destination frame's actions, matching ActionScript. Each
        // accepts either a frame number or a frame label (see
        // resolveFrameArgument) — JSValue rather than Int so JavaScript's
        // dynamic typing can hand us either.
        let jsGotoAndStop: @convention(block) (JSValue) -> Void = { [weak self] arg in
            guard let self, let frame = self.resolveFrameArgument(arg) else { return }
            self.stop()
            self.playhead = min(max(frame, 1), self.totalFrames)
            self.runScriptsOnCurrentFrame()
        }
        let jsGotoAndPlay: @convention(block) (JSValue) -> Void = { [weak self] arg in
            guard let self, let frame = self.resolveFrameArgument(arg) else { return }
            self.playhead = min(max(frame, 1), self.totalFrames)
            self.play()
        }
        // goto(frame) — unlike gotoAndPlay/gotoAndStop, doesn't force a
        // play-state change; just repositions the playhead. Bounded to
        // [1, contentLength] — the actual keyframe-bounded range — rather
        // than raw document capacity, so an out-of-range call (0, negative,
        // or past the last real keyframe) lands on a valid frame instead of
        // shipping straight to frame 0/blank space.
        let jsGoto: @convention(block) (JSValue) -> Void = { [weak self] arg in
            guard let self, let frame = self.resolveFrameArgument(arg) else { return }
            self.playhead = min(max(frame, 1), self.contentLength)
            self.runScriptsOnCurrentFrame()
        }
        ctx.setObject(stopFn, forKeyedSubscript: "stop" as NSString)
        ctx.setObject(playFn, forKeyedSubscript: "play" as NSString)
        ctx.setObject(jsGotoAndStop, forKeyedSubscript: "gotoAndStop" as NSString)
        ctx.setObject(jsGotoAndPlay, forKeyedSubscript: "gotoAndPlay" as NSString)
        ctx.setObject(jsGoto, forKeyedSubscript: "goto" as NSString)

        // bg.color("#ff0000") — sets the Stage's background color.
        let bgColorFn: @convention(block) (String) -> Void = { [weak self] hex in
            guard let self, let color = TimelineDocument.color(fromHex: hex) else { return }
            self.stageColor = color
        }
        let bgObject = JSValue(newObjectIn: ctx)
        bgObject?.setObject(bgColorFn, forKeyedSubscript: "color" as NSString)
        ctx.setObject(bgObject, forKeyedSubscript: "bg" as NSString)

        // stage.size(w, h) — resizes the Stage, Flash's fixed render surface.
        let stageSizeFn: @convention(block) (Double, Double) -> Void = { [weak self] w, h in
            guard let self else { return }
            self.stageWidth = max(1, CGFloat(w))
            self.stageHeight = max(1, CGFloat(h))
        }

        // stage.addText(id, text, x, y) — creates a text object at (x, y)
        // in Stage pixel space, addressed afterward by `id`.
        let addTextFn: @convention(block) (String, String, Double, Double) -> Void = { [weak self] id, text, x, y in
            self?.addTextObject(id: id, text: text, x: x, y: y)
        }
        // stage.setText(id, text) — updates an existing text object's content.
        let setTextFn: @convention(block) (String, String) -> Void = { [weak self] id, text in
            self?.setText(id: id, text: text)
        }
        // stage.setTransform(id, { x, y, scale, rotation, opacity }) — any
        // subset of properties; omitted ones are left unchanged.
        let setTransformFn: @convention(block) (String, JSValue) -> Void = { [weak self] id, props in
            guard let self else { return }
            func value(_ key: String) -> Double? {
                guard let v = props.forProperty(key), !v.isUndefined else { return nil }
                return v.toDouble()
            }
            self.setTransform(id: id, x: value("x"), y: value("y"), scale: value("scale"),
                               rotation: value("rotation"), opacity: value("opacity"))
        }
        // stage.tween(id, { x, rotation, ... }, frames, "easeInOut") —
        // animates any subset of properties toward the given targets over
        // `frames` frames from now. easing is one of linear/easeIn/easeOut/easeInOut.
        let tweenFn: @convention(block) (String, JSValue, Int, String) -> Void = { [weak self] id, props, frames, easing in
            guard let self else { return }
            for key in ["x", "y", "scale", "rotation", "opacity", "fontSize"] {
                guard let v = props.forProperty(key), !v.isUndefined else { continue }
                self.startTween(id: id, property: key, to: v.toDouble(), frames: frames, easing: easing)
            }
        }

        let stageNamespace = JSValue(newObjectIn: ctx)
        stageNamespace?.setObject(stageSizeFn, forKeyedSubscript: "size" as NSString)
        stageNamespace?.setObject(addTextFn, forKeyedSubscript: "addText" as NSString)
        stageNamespace?.setObject(setTextFn, forKeyedSubscript: "setText" as NSString)
        stageNamespace?.setObject(setTransformFn, forKeyedSubscript: "setTransform" as NSString)
        stageNamespace?.setObject(tweenFn, forKeyedSubscript: "tween" as NSString)
        ctx.setObject(stageNamespace, forKeyedSubscript: "stage" as NSString)

        // console.log/warn/error + trace() — the variadic joining happens in
        // JS itself so the native bridge only ever crosses two Strings,
        // sidestepping Swift blocks' lack of variadic support.
        let nativeLogFn: @convention(block) (String, String) -> Void = { [weak self] level, message in
            let lvl: ConsoleMessage.Level = level == "warn" ? .warn : (level == "error" ? .error : .log)
            self?.logToConsole(message, level: lvl)
        }
        ctx.setObject(nativeLogFn, forKeyedSubscript: "__nativeLog" as NSString)
        ctx.evaluateScript("""
        var console = {
            log: function() { __nativeLog("log", Array.prototype.slice.call(arguments).map(function(a) { return String(a); }).join(" ")); },
            warn: function() { __nativeLog("warn", Array.prototype.slice.call(arguments).map(function(a) { return String(a); }).join(" ")); },
            error: function() { __nativeLog("error", Array.prototype.slice.call(arguments).map(function(a) { return String(a); }).join(" ")); }
        };
        var trace = console.log;
        """)

        ctx.exceptionHandler = { [weak self] _, exception in
            self?.logToConsole(exception?.toString() ?? "Unknown script error", level: .error)
        }
        return ctx
    }

    func logToConsole(_ text: String, level: ConsoleMessage.Level = .log) {
        consoleMessages.append(ConsoleMessage(level: level, text: text, frame: playhead))
    }

    /// Accepts either a CSS named color ("cornflowerblue") or a 6-digit hex
    /// string ("#ff0000") — matches what any web/JS developer already knows.
    private static func color(fromHex hex: String) -> Color? {
        let s = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "transparent" { return Color.white.opacity(0) }
        if let rgb = cssNamedColors[s] { return color(fromRGB: rgb) }
        var hexPart = s
        if hexPart.hasPrefix("#") { hexPart.removeFirst() }
        guard hexPart.count == 6, let rgb = UInt32(hexPart, radix: 16) else { return nil }
        return color(fromRGB: rgb)
    }

    private static func color(fromRGB rgb: UInt32) -> Color {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }

    // The standard CSS/SVG named-color keyword set.
    private static let cssNamedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
        "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000,
        "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A,
        "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
        "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B,
        "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B,
        "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC,
        "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B,
        "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
        "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22,
        "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700,
        "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F,
        "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
        "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
        "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC, "mediumvioletred": 0xC71585,
        "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5,
        "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000,
        "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB,
        "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399,
        "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513,
        "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE,
        "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD,
        "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA, "springgreen": 0x00FF7F,
        "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3,
        "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ]

    /// Evaluates every keyframe script on the current frame, across all
    /// layers — this is what makes `stop()`/`gotoAndPlay()`/etc. in a
    /// frame's code actually reach the runtime.
    private func runScriptsOnCurrentFrame() {
        for layer in layers {
            guard layer.isKeyframe(at: playhead),
                  let script = layer.frameScripts[playhead], !script.isEmpty else { continue }
            jsContext.evaluateScript(preprocessForReentry(script))
        }
    }

    /// A frame's script re-runs every time the playhead re-enters that frame
    /// (loop, gotoAndPlay, etc.), but a top-level `const`/`let` can only be
    /// declared once per JS realm — a second run throws "duplicate variable"
    /// and aborts the rest of that script. This keeps the real declaration
    /// (and its actual immutability) completely intact, and just skips
    /// re-issuing it: the first time a `const`/`let NAME = ...` line runs,
    /// its name is remembered; on every later run that same line is commented
    /// out instead of re-sent to the engine, leaving the original binding
    /// (and whatever later frames may have done with it) untouched.
    ///
    /// Heuristic, not a real parser: matches one `const`/`let NAME = ...`
    /// declaration per source line. Multiple comma-separated declarators or
    /// a declaration split across lines won't be recognized.
    private func preprocessForReentry(_ script: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^([ \t]*)(const|let)\s+([A-Za-z_$][A-Za-z0-9_$]*)\b"#
        ) else { return script }

        var lines = script.components(separatedBy: "\n")
        for i in lines.indices {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 3), in: line) else { continue }
            let name = String(line[nameRange])
            if declaredTopLevelBindings.contains(name) {
                lines[i] = "// (already declared) " + line
            } else {
                declaredTopLevelBindings.insert(name)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Called when loading a different document — a fresh document shouldn't
    /// inherit stale JS globals from whatever was previously open. Also
    /// called on every user-initiated "run again," so a fresh run starts
    /// with a clean Stage too.
    func resetRuntime() {
        jsContext = makeJSContext()
        declaredTopLevelBindings.removeAll()
        stageObjects.removeAll()
        activeTweens.removeAll()
    }

    // MARK: - Stage objects & tweening

    func stageObject(id: String) -> StageObject? {
        stageObjects.first { $0.id == id }
    }

    func addTextObject(id: String, text: String, x: Double, y: Double) {
        guard stageObject(id: id) == nil else { return } // ids are stable handles, not re-creatable
        stageObjects.append(StageObject(id: id, text: text, x: CGFloat(x), y: CGFloat(y)))
    }

    func setText(id: String, text: String) {
        stageObject(id: id)?.text = text
    }

    func setTransform(id: String, x: Double?, y: Double?, scale: Double?, rotation: Double?, opacity: Double?) {
        guard let obj = stageObject(id: id) else { return }
        if let x { obj.x = CGFloat(x) }
        if let y { obj.y = CGFloat(y) }
        if let scale { obj.scale = CGFloat(scale) }
        if let rotation { obj.rotation = rotation }
        if let opacity { obj.opacity = opacity }
    }

    /// Schedules a property interpolation starting at the current frame,
    /// running for `frames` frames. A later call for the same object+
    /// property replaces whatever tween was already running on it.
    func startTween(id: String, property rawProperty: String, to: Double, frames: Int, easing rawEasing: String) {
        guard let obj = stageObject(id: id), let property = TweenableProperty(rawValue: rawProperty) else { return }
        let easing = Easing(rawValue: rawEasing) ?? .linear
        let from = currentValue(of: property, on: obj)
        activeTweens.removeAll { $0.objectID == id && $0.property == property }
        activeTweens.append(ActiveTween(
            objectID: id, property: property, fromValue: from, toValue: to,
            startFrame: playhead, durationFrames: max(1, frames), easing: easing
        ))
    }

    private func currentValue(of property: TweenableProperty, on obj: StageObject) -> Double {
        switch property {
        case .x: return Double(obj.x)
        case .y: return Double(obj.y)
        case .scale: return Double(obj.scale)
        case .rotation: return obj.rotation
        case .opacity: return obj.opacity
        case .fontSize: return Double(obj.fontSize)
        }
    }

    private func apply(_ value: Double, to property: TweenableProperty, on obj: StageObject) {
        switch property {
        case .x: obj.x = CGFloat(value)
        case .y: obj.y = CGFloat(value)
        case .scale: obj.scale = CGFloat(value)
        case .rotation: obj.rotation = value
        case .opacity: obj.opacity = value
        case .fontSize: obj.fontSize = CGFloat(value)
        }
    }

    private func advanceTweens() {
        guard !activeTweens.isEmpty else { return }
        var finishedIndices: [Int] = []
        for (i, tween) in activeTweens.enumerated() {
            guard let obj = stageObject(id: tween.objectID) else { finishedIndices.append(i); continue }
            let rawT = Double(playhead - tween.startFrame) / Double(tween.durationFrames)
            let t = tween.easing.apply(rawT)
            apply(tween.fromValue + (tween.toValue - tween.fromValue) * t, to: tween.property, on: obj)
            if rawT >= 1 { finishedIndices.append(i) }
        }
        for i in finishedIndices.reversed() { activeTweens.remove(at: i) }
    }

    /// Layers with anything nested under a collapsed folder filtered out.
    /// Both the layer panel and the frame grid must iterate this (not
    /// `layers` directly) so collapsing a folder actually hides its rows.
    var visibleLayers: [TLLayer] {
        var result: [TLLayer] = []
        var collapsedAtIndent: Int?
        for layer in layers {
            if let ci = collapsedAtIndent {
                if layer.indent > ci { continue }
                collapsedAtIndent = nil
            }
            result.append(layer)
            if layer.kind == .folder && !layer.expanded {
                collapsedAtIndent = layer.indent
            }
        }
        return result
    }

    func toggleExpanded(_ layer: TLLayer) {
        layer.expanded.toggle()
    }

    // MARK: - Layer management

    func indexOf(_ id: UUID) -> Int? { layers.firstIndex { $0.id == id } }

    func addLayer() {
        withUndoSnapshot {
            let indent = selectedLayerID.flatMap { id in layers.first { $0.id == id }?.indent } ?? 0
            let insertAt = selectedLayerID.flatMap(indexOf) ?? 0
            let newLayer = TLLayer(
                name: "Layer \(layers.count + 1)", swatch: .green, indent: indent,
                frames: [.emptyKeyframe] + Array(repeating: .empty, count: max(0, totalFrames - 1))
            )
            layers.insert(newLayer, at: min(insertAt, layers.count))
            selectedLayerID = newLayer.id
        }
    }

    func addFolder() {
        withUndoSnapshot {
            let insertAt = selectedLayerID.flatMap(indexOf) ?? 0
            let newFolder = TLLayer(
                name: "Folder \(layers.count + 1)", swatch: .cyan, kind: .folder,
                frames: Array(repeating: .empty, count: totalFrames)
            )
            layers.insert(newFolder, at: min(insertAt, layers.count))
            selectedLayerID = newFolder.id
        }
    }

    func deleteSelectedLayer() {
        guard let id = selectedLayerID, let layer = layers.first(where: { $0.id == id }) else { return }
        deleteLayer(layer)
    }

    func deleteLayer(_ layer: TLLayer) {
        guard let idx = indexOf(layer.id) else { return }
        withUndoSnapshot {
            layers.remove(at: idx)
            if selectedLayerID == layer.id {
                selectedLayerID = layers.indices.contains(idx) ? layers[idx].id : layers.last?.id
            }
        }
    }

    var selectedLayer: TLLayer? { layers.first { $0.id == selectedLayerID } }

    // MARK: - Frame editing

    /// Grows every layer's addressable frame capacity, padding with `.empty`.
    func growCapacity(to newTotal: Int) {
        guard newTotal > totalFrames else { return }
        for layer in layers where layer.frames.count < newTotal {
            layer.frames += Array(repeating: .empty, count: newTotal - layer.frames.count)
        }
        totalFrames = newTotal
    }

    /// Fills any `.empty` gap between the nearest preceding keyframe and
    /// `frame` (inclusive) with `.plain` continuation marks. What F5/F6 need
    /// to do before touching `frame` itself — otherwise a keyframe's content
    /// only reaches as far as an earlier F5 happened to extend it, instead
    /// of implicitly continuing all the way to wherever you next press
    /// F5/F6, which is how Flash's own timeline actually behaves. A no-op
    /// if there's no preceding keyframe to bridge from.
    private func extendSpan(layer: TLLayer, upTo frame: Int) {
        guard let priorKeyframe = layer.nearestKeyframe(before: frame) else { return }
        for f in (priorKeyframe + 1)...frame where layer.frames[f - 1] == .empty {
            layer.frames[f - 1] = .plain
        }
    }

    /// F5 in classic Flash — extends content into a blank frame. (Simplified:
    /// marks the frame as continuing prior content rather than shifting
    /// everything after it, since frames don't carry real content yet.)
    func insertFrame(layer: TLLayer, at frame: Int) {
        withUndoSnapshot {
            growCapacity(to: max(totalFrames, frame))
            let idx = frame - 1
            guard layer.frames.indices.contains(idx), layer.frames[idx] == .empty else { return }
            extendSpan(layer: layer, upTo: frame)
            if layer.frames[idx] == .empty { layer.frames[idx] = .plain } // no preceding keyframe to bridge from
        }
    }

    /// F6 (keyframe) / F7 (blank keyframe) in classic Flash. A non-blank
    /// keyframe inherits whatever was actually showing at `frame` — first
    /// bridging any gap back to the nearest keyframe (see `extendSpan`) so
    /// that's true even when jumping straight to a far-off frame that was
    /// never explicitly extended with F5 first, then computing (and
    /// capturing into textFrames) what was actually showing there before
    /// the frame mark changes, since that computation reads the current
    /// span/tween that's about to be split. Splitting a tween this way is
    /// exactly how Flash lets you "freeze" an in-between position into its
    /// own keyframe.
    func insertKeyframe(layer: TLLayer, at frame: Int, blank: Bool) {
        withUndoSnapshot {
            growCapacity(to: max(totalFrames, frame))
            let idx = frame - 1
            guard layer.frames.indices.contains(idx) else { return }
            if !blank {
                extendSpan(layer: layer, upTo: frame)
                if layer.textFrames[frame] == nil, let snapshot = layer.interpolatedPlacedText(at: frame) {
                    layer.textFrames[frame] = snapshot
                }
            }
            layer.frames[idx] = blank ? .emptyKeyframe : .keyframe(hasScript: !(layer.frameScripts[frame] ?? "").isEmpty)
        }
    }

    /// Shift+F5 in classic Flash — removes frames. Removing a keyframe that
    /// sits exactly between two tweens (one ending here, another starting
    /// here — e.g. the shared frame left by splitting a tween via Insert
    /// Keyframe) merges them into a single tween spanning the gap, with the
    /// removed keyframe's own content excluded, rather than leaving a blank
    /// hole that breaks both.
    func clearFrame(layer: TLLayer, at frame: Int) {
        let idx = frame - 1
        guard layer.frames.indices.contains(idx) else { return }

        withUndoSnapshot {
            if layer.isKeyframe(at: frame), frame > 1,
               let incomingStart = layer.governingKeyframe(at: frame - 1),
               layer.tweenTarget(from: incomingStart) == frame,
               layer.tweenTarget(from: frame) != nil {
                layer.frames[idx] = .tween
            } else {
                layer.frames[idx] = .empty
            }
            layer.frameScripts[frame] = nil
            layer.textFrames[frame] = nil
            layer.tweenSettings[frame] = nil
            layer.colorTweenSettings[frame] = nil
            layer.frameLabels[frame] = nil
        }
    }

    func setScript(_ text: String, layer: TLLayer, at frame: Int) {
        layer.frameScripts[frame] = text
        let idx = frame - 1
        guard layer.frames.indices.contains(idx) else { return }
        switch layer.frames[idx] {
        case .keyframe, .emptyKeyframe:
            layer.frames[idx] = .keyframe(hasScript: !text.isEmpty)
        default:
            break // scripts only attach to keyframes, matching Flash's Actions layer rule
        }
    }

    // Convenience wrappers acting on whatever's currently selected — this is
    // what the F5/F6/F7/Shift+F5 keyboard shortcuts call.
    func insertFrameAtSelection() {
        guard let layer = selectedLayer else { return }
        insertFrame(layer: layer, at: playhead)
    }

    func insertKeyframeAtSelection(blank: Bool) {
        guard let layer = selectedLayer else { return }
        insertKeyframe(layer: layer, at: playhead, blank: blank)
    }

    func clearFrameAtSelection() {
        guard let layer = selectedLayer else { return }
        clearFrame(layer: layer, at: playhead)
    }

    /// Reorders `id` to sit directly above `beforeLayerID` (or the end of the
    /// list if nil), adopting the indent of wherever it lands — this is what
    /// lets a plain drag-and-drop pull a layer out of a folder (drop next to
    /// an indent-0 row) or into one (drop next to a child row).
    func moveLayer(id: UUID, beforeLayerID: UUID?, indent: Int) {
        guard let from = indexOf(id) else { return }
        withUndoSnapshot {
            let item = layers.remove(at: from)
            item.indent = indent
            if let beforeID = beforeLayerID, let targetIdx = layers.firstIndex(where: { $0.id == beforeID }) {
                layers.insert(item, at: targetIdx)
            } else {
                layers.append(item)
            }
        }
    }

    /// Drops `id` inside `folder` as its first child.
    func reparent(id: UUID, intoFolder folder: TLLayer) {
        guard id != folder.id, let from = indexOf(id) else { return }
        withUndoSnapshot {
            let item = layers.remove(at: from)
            item.indent = folder.indent + 1
            if let folderIdx = layers.firstIndex(where: { $0.id == folder.id }) {
                layers.insert(item, at: folderIdx + 1)
            } else {
                layers.append(item)
            }
            folder.expanded = true
        }
    }

    static func sample() -> TimelineDocument {
        let total = 70
        var frames: [FrameMark] = Array(repeating: .empty, count: total)
        frames[0] = .keyframe(hasScript: false) // frame 1 is a keyframe by default, ready for code
        let actions = TLLayer(name: "actions", swatch: .yellow, frames: frames)
        return TimelineDocument(layers: [actions], totalFrames: total)
    }
}
