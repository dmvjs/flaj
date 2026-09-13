import SwiftUI
import AppKit
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
    case normal, folder, mask
}

/// Flash's own Frame Label "Type" menu. `.name` is an addressable
/// navigation target (`gotoAndPlay`/`gotoAndStop` by label). `.comment` is
/// documentation only — excluded from label lookup and never drives
/// navigation, matching Flash not compiling comments into the exported
/// movie at all. `.anchor` is also addressable, but additionally updates
/// the exported page's URL fragment when reached — Flaj already had this
/// behavior via a "#"-prefixed label text (see `updateNamedAnchor` in
/// player.js); this type just makes it a real, discoverable Properties
/// panel choice instead of a convention you had to already know to type.
enum FrameLabelType: String, Codable, CaseIterable {
    case name, comment, anchor
}

/// A keyframe's label — Flash calls this a "Frame Label," shown as a small
/// flag on the Timeline. `type` changes how `text` behaves (see
/// `FrameLabelType`) but never how it's stored — an anchor's leading "#" is
/// still literally part of `text`, since that's the actual mechanism
/// `updateNamedAnchor`/`findLabeledFrame` key off of.
struct FrameLabel: Codable, Equatable {
    var text: String
    var type: FrameLabelType = .name
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
    // Whether this layer is clipped by the nearest `.mask`-kind layer
    // above it — see `TimelineDocument.maskingLayer(for:)` for the actual
    // grouping rule (a contiguous run of `masked` layers directly below a
    // mask layer, broken by the first non-masked one). Meaningless on a
    // `.mask`-kind layer itself, which is never masked.
    var masked: Bool = false
    var expanded: Bool = true
    var frames: [FrameMark]
    var frameScripts: [Int: String] = [:]   // 1-based frame number -> JS/TS source
    var textFrames: [Int: PlacedText] = [:] // 1-based keyframe number -> placed text
    // Instances of a Library symbol (see FlajSymbol/SymbolInstance in
    // StageObject.swift) placed on this layer — same one-per-keyframe shape
    // as textFrames, and a given keyframe carries at most one of text/
    // symbol instance/shape (a layer's content is exactly one of the
    // three, never more than one at once).
    var symbolFrames: [Int: SymbolInstance] = [:]
    // A vector-drawing-tool placement (see PlacedShape in StageObject.swift)
    // — same one-per-keyframe shape and mutual exclusivity as textFrames/
    // symbolFrames above.
    var shapeFrames: [Int: PlacedShape] = [:]
    // A grouped bundle of placements (see PlacedGroup in StageObject.swift)
    // — same one-per-keyframe shape and mutual exclusivity as the three
    // above (a layer's content at any keyframe is exactly one of text/
    // symbol instance/shape/group, never more than one at once).
    var groupFrames: [Int: PlacedGroup] = [:]
    // Named keyframes — a navigation target for gotoAndPlay("name")/
    // gotoAndStop("name")/goto("name") from a frame script, matching
    // Flash's own frame labels. Purely a keyframe annotation, same
    // dictionary shape as frameScripts/textFrames.
    var frameLabels: [Int: FrameLabel] = [:]
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
        result.scale = base.scale + (end.scale - base.scale) * t
        result.rotation = base.rotation + (end.rotation - base.rotation) * t
        result.opacity = base.opacity + (end.opacity - base.opacity) * colorT
        result.colorHex = Self.interpolateHex(base.colorHex, end.colorHex, colorT)
        return result
    }

    /// Same idea as `interpolatedPlacedText`, for a symbol instance span —
    /// no colorHex/text to interpolate (that's the symbol's shared content,
    /// not per-instance), just geometry, eased the same way position/size
    /// already are.
    func interpolatedSymbolInstance(at frame: Int) -> SymbolInstance? {
        guard let kf = governingKeyframe(at: frame), let base = symbolFrames[kf] else { return nil }
        guard let endKf = tweenTarget(from: kf), let end = symbolFrames[endKf], endKf > kf else { return base }
        let rawT = Double(frame - kf) / Double(endKf - kf)
        let t = (tweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        let colorT = (colorTweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        var result = base
        result.x = base.x + (end.x - base.x) * t
        result.y = base.y + (end.y - base.y) * t
        result.width = base.width + (end.width - base.width) * t
        result.height = base.height + (end.height - base.height) * t
        result.scale = base.scale + (end.scale - base.scale) * t
        result.rotation = base.rotation + (end.rotation - base.rotation) * t
        result.opacity = base.opacity + (end.opacity - base.opacity) * colorT
        return result
    }

    /// Same idea as `interpolatedPlacedText`/`interpolatedSymbolInstance` —
    /// two independently-eased groups, same split as those two: position/
    /// size (plus `strokeWidth`, geometric rather than a color) on the
    /// position tween's own curve, fill/stroke color and every opacity on
    /// the color tween's own curve. `kind` never interpolates (a rectangle
    /// doesn't morph into an ellipse mid-tween).
    func interpolatedPlacedShape(at frame: Int) -> PlacedShape? {
        guard let kf = governingKeyframe(at: frame), let base = shapeFrames[kf] else { return nil }
        guard let endKf = tweenTarget(from: kf), let end = shapeFrames[endKf], endKf > kf else { return base }
        let rawT = Double(frame - kf) / Double(endKf - kf)
        let t = (tweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        let colorT = (colorTweenSettings[kf] ?? TweenSettings()).easedProgress(rawT)
        var result = base
        result.x = base.x + (end.x - base.x) * t
        result.y = base.y + (end.y - base.y) * t
        result.width = base.width + (end.width - base.width) * t
        result.height = base.height + (end.height - base.height) * t
        result.strokeWidth = base.strokeWidth + (end.strokeWidth - base.strokeWidth) * t
        result.cornerRadius = base.cornerRadius + (end.cornerRadius - base.cornerRadius) * t
        result.fillOpacity = base.fillOpacity + (end.fillOpacity - base.fillOpacity) * colorT
        result.strokeOpacity = base.strokeOpacity + (end.strokeOpacity - base.strokeOpacity) * colorT
        result.opacity = base.opacity + (end.opacity - base.opacity) * colorT
        result.fillColorHex = Self.interpolateHex(base.fillColorHex, end.fillColorHex, colorT)
        result.strokeColorHex = Self.interpolateHex(base.strokeColorHex, end.strokeColorHex, colorT)
        return result
    }

    /// Groups aren't tweenable in v1 (see `PlacedGroup`'s own doc comment
    /// on its scope) — a group's value at any frame in its span is always
    /// just its governing keyframe's own value, unchanged. Same tier
    /// `PlacedShape` itself started at before this session's shape-tween
    /// work existed.
    func interpolatedPlacedGroup(at frame: Int) -> PlacedGroup? {
        guard let kf = governingKeyframe(at: frame) else { return nil }
        return groupFrames[kf]
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
    // The document's own top-level Timeline — always what `layers`/
    // `totalFrames` mean at the root, regardless of `editingPath`. Renamed
    // (from the plain `layers`/`totalFrames` every other type in this file
    // still expects to just read/write "whichever Timeline is on screen")
    // so Persistence.swift's real file save/open can reach the *document's*
    // own Timeline explicitly, never whatever symbol edit-in-place happens
    // to have open at the moment — see `layers`/`totalFrames` below. Not
    // `private`: Swift's `private` is file-scoped, and Persistence.swift's
    // `extension TimelineDocument` needs direct access to these two, not
    // the redirecting computed properties.
    var rootLayers: [TLLayer]
    var rootTotalFrames: Int

    // Edit-in-place: which symbol's Timeline `layers`/`totalFrames` below
    // currently mean, outermost to innermost — empty means the document's
    // own root Timeline (the ordinary, only-ever-true-until-now case).
    // Purely a navigation/UI-mode stack, not an undoable edit in its own
    // right (see Undo.swift's UndoEntry.editingPath) — Cmd+Z inside a
    // symbol undoes edits made there, it doesn't back out of edit-in-place;
    // Escape/the breadcrumb's back button do that instead.
    var editingPath: [UUID] = []

    /// Whichever Timeline `editingPath` currently points at — the
    /// document's own root layers when empty, or the innermost symbol's
    /// own `layers` when editing in place. Every existing reader/writer of
    /// "the" Timeline (Stage rendering, the frame grid, addLayer/
    /// insertKeyframe/etc., undo's own snapshot round-trip) already just
    /// says `layers`, so redirecting it here is what makes edit-in-place
    /// work everywhere at once instead of needing every one of those call
    /// sites taught about symbols individually.
    var layers: [TLLayer] {
        get {
            guard let id = editingPath.last, let idx = library.firstIndex(where: { $0.id == id }) else { return rootLayers }
            return library[idx].layers
        }
        set {
            guard let id = editingPath.last, let idx = library.firstIndex(where: { $0.id == id }) else { rootLayers = newValue; return }
            library[idx].layers = newValue
        }
    }

    var totalFrames: Int {
        get {
            guard let id = editingPath.last, let idx = library.firstIndex(where: { $0.id == id }) else { return rootTotalFrames }
            return library[idx].totalFrames
        }
        set {
            guard let id = editingPath.last, let idx = library.firstIndex(where: { $0.id == id }) else { rootTotalFrames = newValue; return }
            library[idx].totalFrames = newValue
        }
    }

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

    // Whether `selectedFrame` reflects a real click, not just its default
    // value of 1 — a brand new document shouldn't open with frame 1 looking
    // selected in the grid before the user has ever clicked anything.
    // `selectedFrame` itself still defaults to 1 regardless (F5/F6-type
    // actions before any click need a sane frame to act on), so this stays
    // a separate flag rather than making `selectedFrame` optional.
    var hasSelectedFrame: Bool = false

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
    /// behavior. A plain click that lands exactly on a keyframe carrying
    /// placed text also selects that content on the Stage — matching
    /// Flash, where clicking a keyframe on the Timeline highlights
    /// whatever it holds there, showing its Properties fields and Stage
    /// selection box without an extra click on the Stage itself.
    /// Deliberately narrower than "any frame in that content's span": a
    /// frame that's merely inside a tween (not the governing keyframe
    /// itself) leaves the placement selection alone, since that's what
    /// lets `activeTweenRef` drive the Properties panel's Tweening
    /// section for those frames — selecting a placement there would
    /// silently hide it (text and tween sections are mutually exclusive).
    func selectFrame(layer: TLLayer, frame: Int, extend: Bool) {
        hasSelectedFrame = true
        additionalSelectedPlacements.removeAll()
        if extend && selectedLayerID == layer.id {
            clearPrimarySelection()
            rangeSelectionEnd = frame
        } else {
            selectedLayerID = layer.id
            gotoAndStop(frame)
            rangeSelectionEnd = nil
            if layer.textFrames[frame] != nil {
                setPrimarySelection(.text(TextPlacementRef(layerID: layer.id, keyframe: frame)))
            } else if layer.symbolFrames[frame] != nil {
                setPrimarySelection(.symbol(SymbolPlacementRef(layerID: layer.id, keyframe: frame)))
            } else if layer.shapeFrames[frame] != nil {
                setPrimarySelection(.shape(ShapePlacementRef(layerID: layer.id, keyframe: frame)))
            } else if layer.groupFrames[frame] != nil {
                setPrimarySelection(.group(GroupPlacementRef(layerID: layer.id, keyframe: frame)))
            } else {
                clearPrimarySelection()
            }
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

    /// `webExportPageBackground` split into its own hex-only (always
    /// opaque) and opacity bindings — `NativeColorWell` only ever picks an
    /// opaque color (see its own doc comment on why), so a color that
    /// itself carries opacity needs its two components exposed as
    /// separate view-facing bindings, both reading/writing the one
    /// underlying `Color` property rather than the property becoming two
    /// separate stored fields at the model level. Shared by
    /// `PropertiesPanelView.webExportSection` and `WebExportSettingsSheet`
    /// so both stay in sync without duplicating this split.
    var webExportPageBackgroundHexBinding: Binding<Color> {
        Binding(
            get: { Color(hex: self.webExportPageBackground.hexString) },
            set: { newColor in
                let opacity = self.webExportPageBackground.opacityComponent
                self.withUndoSnapshot(coalesce: "webExportPageBackground") {
                    self.webExportPageBackground = newColor.opacity(opacity)
                }
            }
        )
    }

    var webExportPageBackgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { self.webExportPageBackground.opacityComponent },
            set: { newOpacity in
                let hex = self.webExportPageBackground.hexString
                self.withUndoSnapshot(coalesce: "webExportPageBackground") {
                    self.webExportPageBackground = Color(hex: hex).opacity(newOpacity)
                }
            }
        )
    }

    var webExportMinify: Bool = true
    // Drives the settings sheet shown before the save panel — see
    // `exportWebPage()`/`WebExportSettingsSheet` in WebExport.swift.
    // Transient UI state, not part of the saved document.
    var webExportSheetPresented: Bool = false

    var consoleMessages: [ConsoleMessage] = []

    var currentFileURL: URL?

    // The Library — Flash's term for the document's reusable Symbol
    // definitions (see FlajSymbol in StageObject.swift). Placed instances
    // live on individual layers (TLLayer.symbolFrames); this is just the
    // shared content they all point back to.
    var library: [FlajSymbol] = []

    var stageObjects: [StageObject] = []
    @ObservationIgnored private var activeTweens: [ActiveTween] = []

    /// The banner-ad `clickTAG` convention — a frame script sets
    /// `stage.clickTag = "https://…"` and the whole Stage becomes one big
    /// link, opening that URL in a new window when clicked (matches
    /// player.js's identical `stage.clickTag` for the web export). A
    /// plain, freely-assignable JS property, not a method — no setter
    /// hook needed on the JS side; this is just read back from the JS
    /// context after each frame's scripts run (see runScriptsOnCurrentFrame),
    /// same way bg.color()/stage.size() push state the *other* direction.
    /// nil until a script sets it, and reset on every resetRuntime() —
    /// stale from a previous run/document shouldn't linger.
    var clickTagURL: String?

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

    enum StageTool { case selection, text, rectangle, ellipse }
    struct TextPlacementRef: Hashable {
        let layerID: UUID; let keyframe: Int
        /// Undo-coalescing key (see `withUndoSnapshot`) — edits to the same
        /// placement collapse into one undo step regardless of which field
        /// changed (typing, dragging, a color pick), so a burst of edits to
        /// one text box reads as a single Cmd+Z instead of one per keystroke.
        var undoToken: String { "placement:\(layerID)-\(keyframe)" }
    }

    var selectedTool: StageTool = .selection
    var selectedPlacement: TextPlacementRef?

    // MARK: - Symbol instances (Library placements)

    struct SymbolPlacementRef: Hashable {
        let layerID: UUID; let keyframe: Int
        var undoToken: String { "symbolplacement:\(layerID)-\(keyframe)" }
    }

    var selectedSymbolPlacement: SymbolPlacementRef?

    /// Wraps the selected text placement's content in a new Library symbol
    /// and swaps the placement on the Timeline for an instance of it,
    /// keeping the exact same position/size/scale/rotation/opacity so
    /// nothing visibly moves — only what governs it changes, from one-off
    /// text to a reusable, instanceable symbol.
    func convertSelectedTextToSymbol(name: String) {
        guard let ref = selectedPlacement, let layer = layers.first(where: { $0.id == ref.layerID }),
              let text = layer.textFrames[ref.keyframe] else { return }
        withUndoSnapshot {
            let symbol = FlajSymbol(
                name: name, text: text.text, fontName: text.fontName, fontSize: text.fontSize,
                bold: text.bold, italic: text.italic, colorHex: text.colorHex, alignment: text.alignment
            )
            library.append(symbol)
            layer.textFrames[ref.keyframe] = nil
            layer.symbolFrames[ref.keyframe] = SymbolInstance(
                symbolID: symbol.id, x: text.x, y: text.y, width: text.width, height: text.height,
                opacity: text.opacity, scale: text.scale, rotation: text.rotation
            )
            selectedPlacement = nil
            selectedSymbolPlacement = SymbolPlacementRef(layerID: layer.id, keyframe: ref.keyframe)
        }
    }

    /// Drops a new instance of `symbol` onto `selectedLayer` at the
    /// keyframe governing `selectedFrame`, centered on the Stage — same
    /// "needs an actual keyframe" rule as `placeText`. Selects the new
    /// instance so it's immediately draggable into position.
    func placeSymbolInstance(_ symbol: FlajSymbol) {
        guard let layer = selectedLayer else { return }
        guard let kf = layer.governingKeyframe(at: selectedFrame) else {
            logToConsole("Select or insert a keyframe on \"\(layer.name)\" before placing an instance.", level: .warn)
            return
        }
        withUndoSnapshot {
            let width: CGFloat = 160, height: CGFloat = 40
            let instance = SymbolInstance(
                symbolID: symbol.id, x: (stageWidth - width) / 2, y: (stageHeight - height) / 2,
                width: width, height: height
            )
            layer.symbolFrames[kf] = instance
            layer.textFrames[kf] = nil
            layer.shapeFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedPlacement = nil
            selectedSymbolPlacement = SymbolPlacementRef(layerID: layer.id, keyframe: kf)
            selectedShapePlacement = nil
            selectedGroupPlacement = nil
        }
    }

    func deleteSelectedSymbolPlacement() {
        guard let ref = selectedSymbolPlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        withUndoSnapshot {
            layer.symbolFrames[ref.keyframe] = nil
            selectedSymbolPlacement = nil
        }
    }

    /// Same idiom as `binding(for:)` for text placements — the `?? ...`
    /// fallback is only ever hit if `ref` outlives its own placement (same
    /// defensive default `binding(for: TextPlacementRef)` has).
    func binding(for ref: SymbolPlacementRef) -> Binding<SymbolInstance>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.symbolFrames[ref.keyframe] ?? SymbolInstance(symbolID: UUID(), x: 0, y: 0) },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.undoToken) { layer.symbolFrames[ref.keyframe] = newValue }
            }
        )
    }

    /// Swap Symbol — repoints one placed instance at a different Library
    /// symbol, keeping everything else about it (position/size/scale/
    /// rotation/opacity/name) untouched. Flash's own Swap Symbol does the
    /// same: it's a per-*instance* operation, not a Library-wide rename —
    /// every other instance of the original symbol is completely
    /// unaffected. Rendering (native and web export alike) already
    /// resolves `SymbolInstance.symbolID` against `doc.library` fresh every
    /// time, so this needs no rendering-side changes at all — it's purely
    /// which id this one instance carries.
    func swapSymbol(at ref: SymbolPlacementRef, to newSymbolID: UUID) {
        guard let layer = layers.first(where: { $0.id == ref.layerID }),
              var instance = layer.symbolFrames[ref.keyframe],
              library.contains(where: { $0.id == newSymbolID })
        else { return }
        withUndoSnapshot {
            instance.symbolID = newSymbolID
            layer.symbolFrames[ref.keyframe] = instance
        }
    }

    /// Same arrow-key nudge as `nudgeSelectedPlacement`, for a selected
    /// symbol instance.
    func nudgeSelectedSymbolPlacement(dx: CGFloat, dy: CGFloat) {
        guard let ref = selectedSymbolPlacement, let binding = binding(for: ref) else { return }
        binding.wrappedValue.x += dx
        binding.wrappedValue.y += dy
    }

    @ObservationIgnored private var copiedSymbolInstance: SymbolInstance?

    var hasCopiedSymbolInstance: Bool { copiedSymbolInstance != nil }

    func copySelectedSymbolPlacement() {
        guard let ref = selectedSymbolPlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        copiedSymbolInstance = layer.symbolFrames[ref.keyframe]
    }

    /// Same idiom as `pastePlacedText`.
    func pasteSymbolInstance(layer: TLLayer, at frame: Int) {
        guard let copied = copiedSymbolInstance else { return }
        withUndoSnapshot {
            let kf: Int
            if let existing = layer.governingKeyframe(at: frame), existing == frame {
                kf = existing
            } else {
                insertKeyframe(layer: layer, at: frame, blank: false)
                kf = frame
            }
            layer.symbolFrames[kf] = copied
            layer.textFrames[kf] = nil
            layer.shapeFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedSymbolPlacement = SymbolPlacementRef(layerID: layer.id, keyframe: kf)
            selectedPlacement = nil
            selectedShapePlacement = nil
            selectedGroupPlacement = nil
        }
    }

    func renameSymbol(_ symbolID: UUID, to name: String) {
        guard let idx = library.firstIndex(where: { $0.id == symbolID }) else { return }
        withUndoSnapshot(coalesce: "symbolname:\(symbolID)") { library[idx].name = name }
    }

    /// A read/write binding onto a Library symbol's frame-1 content — same
    /// idiom as `binding(for:)`, edits ripple to every instance since every
    /// instance just references this same `symbolID`. Scoped to the
    /// value-type `PlacedText` itself (the symbol's frame-1 content) rather
    /// than the whole `FlajSymbol` — `FlajSymbol.layers` holds `TLLayer`
    /// class instances, so a `Binding<FlajSymbol>` mutated via a computed
    /// property would write straight through to the shared layer the
    /// instant it's touched, ahead of this method's own `withUndoSnapshot`,
    /// corrupting undo; a `Binding<PlacedText>` round-trips a genuine value
    /// copy through `set`, exactly like every other content edit here.
    func symbolContentBinding(_ symbolID: UUID) -> Binding<PlacedText>? {
        guard let symbol = library.first(where: { $0.id == symbolID }), let layer = symbol.layers.first else { return nil }
        return Binding(
            get: { layer.textFrames[1] ?? PlacedText(text: "", x: 0, y: 0) },
            set: { newValue in
                self.withUndoSnapshot(coalesce: "symbolcontent:\(symbolID)") { layer.textFrames[1] = newValue }
            }
        )
    }

    /// Removes a symbol from the Library along with every instance of it
    /// across every layer/frame — an orphaned instance (symbolID pointing
    /// at nothing) would just render blank, so this keeps the document
    /// consistent instead of leaving that dangling.
    func deleteSymbol(_ symbolID: UUID) {
        guard let idx = library.firstIndex(where: { $0.id == symbolID }) else { return }
        // Deleting a symbol currently open in edit-in-place (or an
        // ancestor of the one currently open) would otherwise leave
        // `editingPath` pointing at a now-nonexistent library entry —
        // `layers` above falls back to the document root harmlessly, but
        // the breadcrumb would keep showing a dangling name. Back out to
        // wherever's still valid instead.
        if let cut = editingPath.firstIndex(of: symbolID) {
            editingPath.removeSubrange(cut...)
        }
        withUndoSnapshot {
            library.remove(at: idx)
            for layer in rootLayers {
                for (frame, instance) in layer.symbolFrames where instance.symbolID == symbolID {
                    layer.symbolFrames[frame] = nil
                }
            }
            for symbol in library {
                for layer in symbol.layers {
                    for (frame, instance) in layer.symbolFrames where instance.symbolID == symbolID {
                        layer.symbolFrames[frame] = nil
                    }
                }
            }
            if let ref = selectedSymbolPlacement, layers.first(where: { $0.id == ref.layerID })?.symbolFrames[ref.keyframe] == nil {
                selectedSymbolPlacement = nil
            }
        }
    }

    // MARK: - Shape tool (vector drawing)

    struct ShapePlacementRef: Hashable {
        let layerID: UUID; let keyframe: Int
        var undoToken: String { "shapeplacement:\(layerID)-\(keyframe)" }
    }

    var selectedShapePlacement: ShapePlacementRef?

    // MARK: - Groups

    struct GroupPlacementRef: Hashable {
        let layerID: UUID; let keyframe: Int
        var undoToken: String { "groupplacement:\(layerID)-\(keyframe)" }
    }

    var selectedGroupPlacement: GroupPlacementRef?

    // MARK: - Multi-select

    /// A type-erased reference to any one selectable Stage object,
    /// regardless of content kind — what `selectedPlacements` (below) is a
    /// `Set` of, since Swift has no way to put four unrelated struct
    /// types in one collection otherwise.
    enum StagePlacementRef: Hashable {
        case text(TextPlacementRef)
        case symbol(SymbolPlacementRef)
        case shape(ShapePlacementRef)
        case group(GroupPlacementRef)
    }

    // `selectedPlacement`/`selectedSymbolPlacement`/`selectedShapePlacement`
    // above (plus `selectedGroupPlacement`, added alongside PlacedGroup)
    // remain the single "primary" selection every existing call site
    // already reads/writes directly — Properties panel single-object
    // editing, creation, paste, and undo restore all keep working exactly
    // as before, untouched by anything below. Shift/Cmd-click adds
    // *additional* placements on top of that primary one, tracked here
    // rather than replacing the whole selection model — a much smaller,
    // lower-risk change than retrofitting every existing single-selection
    // call site to go through a new unified path.
    // Not `private`: Undo.swift (a separate file, same module) needs to
    // reset this directly on restore — see its own doc comment there on
    // why a multi-selection isn't otherwise validated/restored.
    @ObservationIgnored var additionalSelectedPlacements: Set<StagePlacementRef> = []

    /// The full current selection — the primary single ref(s) above plus
    /// anything Shift/Cmd-clicked on top. Empty for no selection, exactly
    /// one member for an ordinary single selection, more for a real
    /// multi-select.
    var selectedPlacements: Set<StagePlacementRef> {
        var result = additionalSelectedPlacements
        if let ref = selectedPlacement { result.insert(.text(ref)) }
        if let ref = selectedSymbolPlacement { result.insert(.symbol(ref)) }
        if let ref = selectedShapePlacement { result.insert(.shape(ref)) }
        if let ref = selectedGroupPlacement { result.insert(.group(ref)) }
        return result
    }

    /// Shift/Cmd-clicked an object — adds it to the selection if it wasn't
    /// already part of it, or removes it if it was (the standard modifier-
    /// click convention). The most recently *added* ref also becomes the
    /// new primary selection (so Properties panel editing tracks whichever
    /// object was just clicked), unless this click removed the primary
    /// selection itself, in which case an arbitrary remaining member (if
    /// any) is promoted to primary so the selection never silently keeps a
    /// dangling primary ref.
    func toggleSelection(_ ref: StagePlacementRef) {
        if selectedPlacements.contains(ref) {
            let wasPrimary = primaryRef == ref
            removeFromSelection(ref)
            if wasPrimary, let promoted = selectedPlacements.first {
                setPrimarySelection(promoted)
            }
        } else {
            // Each content kind has only one "primary" storage slot
            // (selectedPlacement/selectedSymbolPlacement/etc.) —
            // setPrimarySelection below would silently overwrite whatever
            // was already primary if it happens to be the same kind as
            // `ref` (e.g. selecting a second shape), so the old primary
            // needs to move into `additionalSelectedPlacements` first to
            // survive that overwrite.
            if let oldPrimary = primaryRef {
                additionalSelectedPlacements.insert(oldPrimary)
            }
            setPrimarySelection(ref)
        }
    }

    /// A plain (non-modifier) click/tap — replaces the whole selection
    /// with just `ref`.
    func selectOnly(_ ref: StagePlacementRef) {
        additionalSelectedPlacements.removeAll()
        setPrimarySelection(ref)
    }

    func clearAllSelection() {
        additionalSelectedPlacements.removeAll()
        clearPrimarySelection()
    }

    /// The one entry point every placed-object tap gesture should call —
    /// centralizes the Shift/Cmd-click-adds-to-selection convention so
    /// each of StagePlacedTextView/StagePlacedShapeView/
    /// StageSymbolInstanceView's own tap handler doesn't need to inspect
    /// modifier keys itself.
    func handleStageClick(_ ref: StagePlacementRef) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            toggleSelection(ref)
        } else {
            selectOnly(ref)
        }
    }

    /// The x/y of any one placement kind, type-erased — used only by a
    /// multi-select drag (see StagePlacedTextView/StagePlacedShapeView/
    /// StageSymbolInstanceView's own `moveGesture`) to snapshot where
    /// every *other* selected object started before the drag began.
    func positionOfPlacement(_ ref: StagePlacementRef) -> CGPoint? {
        switch ref {
        case .text(let r): return binding(for: r).map { CGPoint(x: $0.wrappedValue.x, y: $0.wrappedValue.y) }
        case .symbol(let r): return binding(for: r).map { CGPoint(x: $0.wrappedValue.x, y: $0.wrappedValue.y) }
        case .shape(let r): return binding(for: r).map { CGPoint(x: $0.wrappedValue.x, y: $0.wrappedValue.y) }
        case .group(let r): return binding(for: r).map { CGPoint(x: $0.wrappedValue.x, y: $0.wrappedValue.y) }
        }
    }

    /// Nudges any one placement kind by (dx, dy) — the generic form of
    /// `nudgeSelectedPlacement`/`nudgeSelectedSymbolPlacement`/
    /// `nudgeSelectedShapePlacement`, each of which only ever nudges its
    /// own single primary ref. Used for a multi-selection's arrow-key
    /// nudge (see `nudgeSelection` in StageView.swift), where every
    /// selected object needs to move, not just the primary one.
    func nudgePlacement(_ ref: StagePlacementRef, dx: CGFloat, dy: CGFloat) {
        switch ref {
        case .text(let r):
            guard let b = binding(for: r) else { return }
            b.wrappedValue.x += dx; b.wrappedValue.y += dy
        case .symbol(let r):
            guard let b = binding(for: r) else { return }
            b.wrappedValue.x += dx; b.wrappedValue.y += dy
        case .shape(let r):
            guard let b = binding(for: r) else { return }
            b.wrappedValue.x += dx; b.wrappedValue.y += dy
        case .group(let r):
            guard let b = binding(for: r) else { return }
            b.wrappedValue.x += dx; b.wrappedValue.y += dy
        }
    }

    /// Deletes any one placement kind — the generic form of
    /// `deleteSelectedPlacement`/`deleteSelectedSymbolPlacement`/
    /// `deleteSelectedShapePlacement`, for a multi-selection's Delete key.
    func deletePlacement(_ ref: StagePlacementRef) {
        switch ref {
        case .text(let r):
            guard let layer = layers.first(where: { $0.id == r.layerID }) else { return }
            withUndoSnapshot { layer.textFrames[r.keyframe] = nil }
            if selectedPlacement == r { selectedPlacement = nil }
        case .symbol(let r):
            guard let layer = layers.first(where: { $0.id == r.layerID }) else { return }
            withUndoSnapshot { layer.symbolFrames[r.keyframe] = nil }
            if selectedSymbolPlacement == r { selectedSymbolPlacement = nil }
        case .shape(let r):
            guard let layer = layers.first(where: { $0.id == r.layerID }) else { return }
            withUndoSnapshot { layer.shapeFrames[r.keyframe] = nil }
            if selectedShapePlacement == r { selectedShapePlacement = nil }
        case .group(let r):
            guard let layer = layers.first(where: { $0.id == r.layerID }) else { return }
            withUndoSnapshot { layer.groupFrames[r.keyframe] = nil }
            if selectedGroupPlacement == r { selectedGroupPlacement = nil }
        }
        additionalSelectedPlacements.remove(ref)
    }

    /// Moves every `(ref, startPosition)` pair to `startPosition + (dx,
    /// dy)` — called every tick of a multi-select drag for every selected
    /// object *other* than the one actually being dragged (that one keeps
    /// using its own view's existing local liveDrag/onEnded-commit
    /// pattern, untouched). Writing straight to the model on each tick
    /// (rather than through a local preview) is what gives these other
    /// objects live visual feedback for free — their own views already
    /// just read this same model state reactively. Coalesced under one
    /// shared undo token so the whole multi-drag's "everyone else" moves
    /// collapse into a single undo step (the primary dragged object's own
    /// final commit still lands as its own separate step — a known, minor
    /// v1 imperfection rather than a correctness issue).
    func moveOtherSelectedPlacements(_ starts: [StagePlacementRef: CGPoint], dx: CGFloat, dy: CGFloat) {
        for (ref, start) in starts {
            let newPosition = CGPoint(x: start.x + dx, y: start.y + dy)
            withUndoSnapshot(coalesce: "multiselect-drag") {
                switch ref {
                case .text(let r): binding(for: r)?.wrappedValue.x = newPosition.x; binding(for: r)?.wrappedValue.y = newPosition.y
                case .symbol(let r): binding(for: r)?.wrappedValue.x = newPosition.x; binding(for: r)?.wrappedValue.y = newPosition.y
                case .shape(let r): binding(for: r)?.wrappedValue.x = newPosition.x; binding(for: r)?.wrappedValue.y = newPosition.y
                case .group(let r): binding(for: r)?.wrappedValue.x = newPosition.x; binding(for: r)?.wrappedValue.y = newPosition.y
                }
            }
        }
    }

    private var primaryRef: StagePlacementRef? {
        if let ref = selectedPlacement { return .text(ref) }
        if let ref = selectedSymbolPlacement { return .symbol(ref) }
        if let ref = selectedShapePlacement { return .shape(ref) }
        if let ref = selectedGroupPlacement { return .group(ref) }
        return nil
    }

    private func setPrimarySelection(_ ref: StagePlacementRef) {
        additionalSelectedPlacements.remove(ref)
        switch ref {
        case .text(let r):
            selectedPlacement = r; selectedSymbolPlacement = nil; selectedShapePlacement = nil; selectedGroupPlacement = nil
        case .symbol(let r):
            selectedSymbolPlacement = r; selectedPlacement = nil; selectedShapePlacement = nil; selectedGroupPlacement = nil
        case .shape(let r):
            selectedShapePlacement = r; selectedPlacement = nil; selectedSymbolPlacement = nil; selectedGroupPlacement = nil
        case .group(let r):
            selectedGroupPlacement = r; selectedPlacement = nil; selectedSymbolPlacement = nil; selectedShapePlacement = nil
        }
    }

    private func clearPrimarySelection() {
        selectedPlacement = nil
        selectedSymbolPlacement = nil
        selectedShapePlacement = nil
        selectedGroupPlacement = nil
    }

    private func removeFromSelection(_ ref: StagePlacementRef) {
        additionalSelectedPlacements.remove(ref)
        if primaryRef == ref { clearPrimarySelection() }
    }

    /// Bundles every currently selected object (2+; Flash requires at
    /// least two to Group) into one new `PlacedGroup` — see its own doc
    /// comment for why this is a genuinely separate concept from a
    /// Symbol. Each selected object is necessarily on a different layer
    /// (only one placement per layer is ever visible/selectable at a
    /// given frame), so the group lands on whichever contributing layer
    /// sits topmost in the Timeline list; every other contributing
    /// layer's content at that frame is cleared. A group nested inside
    /// the selection (grouping an already-selected group) is skipped —
    /// nested groups aren't supported in v1.
    func groupSelection() {
        struct Resolved {
            let layerIndex: Int
            let keyframe: Int
            var text: PlacedText?
            var shape: PlacedShape?
            var symbol: SymbolInstance?
            var x: CGFloat { text?.x ?? shape?.x ?? symbol?.x ?? 0 }
            var y: CGFloat { text?.y ?? shape?.y ?? symbol?.y ?? 0 }
            var width: CGFloat { text?.width ?? shape?.width ?? symbol?.width ?? 0 }
            var height: CGFloat { text?.height ?? shape?.height ?? symbol?.height ?? 0 }
        }

        var resolved: [Resolved] = []
        for ref in selectedPlacements {
            switch ref {
            case .text(let r):
                guard let idx = layers.firstIndex(where: { $0.id == r.layerID }), let content = layers[idx].textFrames[r.keyframe] else { continue }
                resolved.append(Resolved(layerIndex: idx, keyframe: r.keyframe, text: content, shape: nil, symbol: nil))
            case .shape(let r):
                guard let idx = layers.firstIndex(where: { $0.id == r.layerID }), let content = layers[idx].shapeFrames[r.keyframe] else { continue }
                resolved.append(Resolved(layerIndex: idx, keyframe: r.keyframe, text: nil, shape: content, symbol: nil))
            case .symbol(let r):
                guard let idx = layers.firstIndex(where: { $0.id == r.layerID }), let content = layers[idx].symbolFrames[r.keyframe] else { continue }
                resolved.append(Resolved(layerIndex: idx, keyframe: r.keyframe, text: nil, shape: nil, symbol: content))
            case .group:
                continue
            }
        }
        guard resolved.count >= 2 else { return }

        let landing = resolved.min(by: { $0.layerIndex < $1.layerIndex })!
        let landingLayer = layers[landing.layerIndex]
        let landingKeyframe = landing.keyframe

        let minX = resolved.map(\.x).min()!
        let minY = resolved.map(\.y).min()!
        let maxX = resolved.map { $0.x + $0.width }.max()!
        let maxY = resolved.map { $0.y + $0.height }.max()!

        withUndoSnapshot {
            var texts: [PlacedText] = []
            var shapes: [PlacedShape] = []
            var symbols: [SymbolInstance] = []
            for item in resolved {
                let contributingLayer = layers[item.layerIndex]
                if var t = item.text {
                    t.x -= minX; t.y -= minY
                    texts.append(t)
                    contributingLayer.textFrames[item.keyframe] = nil
                } else if var s = item.shape {
                    s.x -= minX; s.y -= minY
                    shapes.append(s)
                    contributingLayer.shapeFrames[item.keyframe] = nil
                } else if var sym = item.symbol {
                    sym.x -= minX; sym.y -= minY
                    symbols.append(sym)
                    contributingLayer.symbolFrames[item.keyframe] = nil
                }
            }
            let group = PlacedGroup(x: minX, y: minY, width: maxX - minX, height: maxY - minY, texts: texts, shapes: shapes, symbols: symbols)
            landingLayer.groupFrames[landingKeyframe] = group
            additionalSelectedPlacements.removeAll()
            setPrimarySelection(.group(GroupPlacementRef(layerID: landingLayer.id, keyframe: landingKeyframe)))
        }
    }

    /// Dissolves the selected `PlacedGroup` back into its constituent
    /// objects, each restored at its absolute Stage position — the
    /// reverse of `groupSelection`. The first child reuses the group's own
    /// (layer, keyframe) slot; every additional child gets a brand-new
    /// layer at that same frame, since a single (layer, keyframe) slot
    /// can only ever hold one content item. Every restored object's
    /// *original* layer isn't preserved — a reasonable v1 simplification,
    /// since nothing records "which layer each child used to be on" once
    /// they're bundled into the group.
    func ungroupSelection() {
        guard let ref = selectedGroupPlacement,
              let layerIndex = layers.firstIndex(where: { $0.id == ref.layerID }),
              let group = layers[layerIndex].groupFrames[ref.keyframe] else { return }

        withUndoSnapshot {
            let landingLayer = layers[layerIndex]
            landingLayer.groupFrames[ref.keyframe] = nil

            var members: [(PlacedText?, PlacedShape?, SymbolInstance?)] = []
            for t in group.texts { members.append((t, nil, nil)) }
            for s in group.shapes { members.append((nil, s, nil)) }
            for sym in group.symbols { members.append((nil, nil, sym)) }

            var newRefs: [StagePlacementRef] = []
            for (index, member) in members.enumerated() {
                let targetLayer: TLLayer
                if index == 0 {
                    targetLayer = landingLayer
                } else {
                    var frames = Array(repeating: FrameMark.empty, count: totalFrames)
                    frames[ref.keyframe - 1] = .keyframe(hasScript: false)
                    targetLayer = TLLayer(name: "\(landingLayer.name) \(index + 1)", swatch: landingLayer.swatch, frames: frames)
                    layers.insert(targetLayer, at: layerIndex + index)
                }
                if var t = member.0 {
                    t.x += group.x; t.y += group.y
                    targetLayer.textFrames[ref.keyframe] = t
                    newRefs.append(.text(TextPlacementRef(layerID: targetLayer.id, keyframe: ref.keyframe)))
                } else if var s = member.1 {
                    s.x += group.x; s.y += group.y
                    targetLayer.shapeFrames[ref.keyframe] = s
                    newRefs.append(.shape(ShapePlacementRef(layerID: targetLayer.id, keyframe: ref.keyframe)))
                } else if var sym = member.2 {
                    sym.x += group.x; sym.y += group.y
                    targetLayer.symbolFrames[ref.keyframe] = sym
                    newRefs.append(.symbol(SymbolPlacementRef(layerID: targetLayer.id, keyframe: ref.keyframe)))
                }
            }

            clearPrimarySelection()
            additionalSelectedPlacements = Set(newRefs)
            if let first = newRefs.first { setPrimarySelection(first) }
        }
    }

    /// Drops a new shape at `rect` (Stage pixel coordinates, already
    /// normalized to a positive width/height — see StageView's drag-to-draw
    /// gesture, which is what actually determines the rect the user drew,
    /// Shift-constrained to a square/circle or not) on `selectedLayer` at
    /// the keyframe governing `selectedFrame` — same "needs an actual
    /// keyframe" rule as `placeText`/`placeSymbolInstance`.
    func placeShape(kind: ShapeKind, rect: CGRect) {
        guard let layer = selectedLayer else { return }
        guard let kf = layer.governingKeyframe(at: selectedFrame) else {
            logToConsole("Select or insert a keyframe on \"\(layer.name)\" before drawing a shape.", level: .warn)
            return
        }
        withUndoSnapshot {
            let shape = PlacedShape(kind: kind, x: rect.minX, y: rect.minY, width: max(1, rect.width), height: max(1, rect.height))
            layer.shapeFrames[kf] = shape
            layer.textFrames[kf] = nil
            layer.symbolFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedShapePlacement = ShapePlacementRef(layerID: layer.id, keyframe: kf)
            selectedPlacement = nil
            selectedSymbolPlacement = nil
            selectedGroupPlacement = nil
        }
    }

    func deleteSelectedShapePlacement() {
        guard let ref = selectedShapePlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        withUndoSnapshot {
            layer.shapeFrames[ref.keyframe] = nil
            selectedShapePlacement = nil
        }
    }

    /// Same idiom as `binding(for: TextPlacementRef)`.
    func binding(for ref: ShapePlacementRef) -> Binding<PlacedShape>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.shapeFrames[ref.keyframe] ?? PlacedShape(x: 0, y: 0) },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.undoToken) { layer.shapeFrames[ref.keyframe] = newValue }
            }
        )
    }

    /// Same idiom as `binding(for: ShapePlacementRef)`.
    func binding(for ref: GroupPlacementRef) -> Binding<PlacedGroup>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.groupFrames[ref.keyframe] ?? PlacedGroup(x: 0, y: 0, width: 1, height: 1) },
            set: { newValue in
                self.withUndoSnapshot(coalesce: ref.undoToken) { layer.groupFrames[ref.keyframe] = newValue }
            }
        )
    }

    /// Same arrow-key nudge as `nudgeSelectedPlacement`, for a selected shape.
    func nudgeSelectedShapePlacement(dx: CGFloat, dy: CGFloat) {
        guard let ref = selectedShapePlacement, let binding = binding(for: ref) else { return }
        binding.wrappedValue.x += dx
        binding.wrappedValue.y += dy
    }

    @ObservationIgnored private var copiedShape: PlacedShape?

    var hasCopiedShape: Bool { copiedShape != nil }

    func copySelectedShapePlacement() {
        guard let ref = selectedShapePlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        copiedShape = layer.shapeFrames[ref.keyframe]
    }

    /// Same idiom as `pastePlacedText`/`pasteSymbolInstance`.
    func pasteShape(layer: TLLayer, at frame: Int) {
        guard let copied = copiedShape else { return }
        withUndoSnapshot {
            let kf: Int
            if let existing = layer.governingKeyframe(at: frame), existing == frame {
                kf = existing
            } else {
                insertKeyframe(layer: layer, at: frame, blank: false)
                kf = frame
            }
            layer.shapeFrames[kf] = copied
            layer.textFrames[kf] = nil
            layer.symbolFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedShapePlacement = ShapePlacementRef(layerID: layer.id, keyframe: kf)
            selectedPlacement = nil
            selectedSymbolPlacement = nil
            selectedGroupPlacement = nil
        }
    }

    // MARK: - Edit-in-place: entering/leaving a symbol's own Timeline

    /// Enters a symbol's own Timeline for editing — double-clicking a
    /// placed instance on Stage enters the symbol it's an instance of,
    /// after which `layers`/`totalFrames` above transparently mean *this*
    /// symbol's content instead of the document's root, everywhere (Stage,
    /// frame grid, addLayer/insertKeyframe/etc.) without any of those
    /// needing to know edit-in-place exists at all. Nests: entering an
    /// instance placed *inside* the symbol already being edited pushes a
    /// second level, same as Flash's own Edit in Place lets you drill into
    /// a nested Movie Clip.
    func enterSymbolEditing(_ symbolID: UUID) {
        guard library.contains(where: { $0.id == symbolID }) else { return }
        editingPath.append(symbolID)
        resetSelectionForNewEditingScope()
    }

    /// Backs out one level of edit-in-place — the innermost symbol first —
    /// matching Flash's Escape-key convention (call again to keep backing
    /// out, all the way to the document's own root Timeline).
    func exitSymbolEditing() {
        exitSymbolEditing(toDepth: editingPath.count - 1)
    }

    /// Jumps straight back to the document's own root Timeline from any
    /// depth — the breadcrumb's leftmost "Scene 1" crumb.
    func exitAllSymbolEditing() {
        exitSymbolEditing(toDepth: 0)
    }

    /// Jumps to an arbitrary depth in `editingPath` in one step — the
    /// breadcrumb's general case, of which `exitSymbolEditing()` (depth
    /// `editingPath.count - 1`) and `exitAllSymbolEditing()` (depth 0) are
    /// just the two most common instances. A no-op if already at `depth`.
    func exitSymbolEditing(toDepth depth: Int) {
        let clamped = min(max(depth, 0), editingPath.count)
        guard clamped != editingPath.count else { return }
        editingPath.removeLast(editingPath.count - clamped)
        resetSelectionForNewEditingScope()
    }

    /// Whatever was selected belonged to the Timeline we just left, not the
    /// one now in view — same reset `load(from:)` already does when
    /// opening a whole new document, since switching which Timeline
    /// `layers` means is exactly that, just scoped to one symbol instead
    /// of the whole file.
    private func resetSelectionForNewEditingScope() {
        selectedLayerID = layers.first?.id
        playhead = 1
        selectedFrame = 1
        hasSelectedFrame = false
        rangeSelectionEnd = nil
        additionalSelectedPlacements.removeAll()
        selectedPlacement = nil
        selectedSymbolPlacement = nil
        selectedShapePlacement = nil
        selectedGroupPlacement = nil
    }

    /// The breadcrumb trail's labels, outermost to innermost — "Scene 1"
    /// for the document's own root Timeline (Flash's own name for it),
    /// plus one entry per nested symbol currently being edited in place.
    var editingBreadcrumb: [String] {
        ["Scene 1"] + editingPath.compactMap { id in library.first(where: { $0.id == id })?.name }
    }

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

    // MARK: - Rulers & guides

    // Rulers are purely an editor overlay (see StageView's ruler views) —
    // never saved, same as onionSkinEnabled above, and for the same
    // reason: nothing about them belongs to the document's actual content.
    var rulersVisible: Bool = true
    // Guides themselves (`guides` below) DO belong to the document — a
    // deliberately placed layout aid the user built up, the same tier as
    // stageWidth/stageColor — but whether they're currently drawn is a
    // separate, transient view preference (Flash's own View > Guides >
    // Show Guides toggle doesn't delete anything either), so it lives here
    // ungoverned by undo/persistence, same as rulersVisible.
    var guidesVisible: Bool = true

    /// The document's ruler guides — Flash's dragged-from-the-ruler layout
    /// lines. Persisted (see Persistence.swift), unlike `guidesVisible`/
    /// `rulersVisible` above.
    var guides: [Guide] = []

    /// Drops a new guide at `position` (Stage-space y for a horizontal
    /// guide, x for a vertical one) — StageView's ruler-drag gesture is
    /// what actually determines this, mirroring `placeShape`'s own
    /// "caller already resolved the real-world coordinates" split.
    func addGuide(orientation: GuideOrientation, position: CGFloat) {
        withUndoSnapshot {
            guides.append(Guide(orientation: orientation, position: position))
        }
    }

    /// Slides an existing guide to `position` — called continuously while
    /// dragging (coalesced into one undo step per drag) and once more on
    /// drop.
    func moveGuide(id: UUID, to position: CGFloat) {
        guard let index = guides.firstIndex(where: { $0.id == id }) else { return }
        withUndoSnapshot(coalesce: "guide:\(id)") {
            guides[index].position = position
        }
    }

    func removeGuide(id: UUID) {
        guard guides.contains(where: { $0.id == id }) else { return }
        withUndoSnapshot {
            guides.removeAll { $0.id == id }
        }
    }

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
            layer.symbolFrames[kf] = nil
            layer.shapeFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedPlacement = TextPlacementRef(layerID: layer.id, keyframe: kf)
            selectedSymbolPlacement = nil
            selectedShapePlacement = nil
            selectedGroupPlacement = nil
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

    /// A read/write binding onto a keyframe's label text — same idiom as
    /// `binding(for:)`/`CodeEditorPanel.scriptBinding(for:)`. Empty string
    /// clears the label (matching how an empty script/text field would
    /// mean "nothing here"), rather than storing `""` as a real label.
    /// New labels start as `.name`; use `labelTypeBinding` to change that.
    func labelBinding(layer: TLLayer, at frame: Int) -> Binding<String> {
        Binding(
            get: { layer.frameLabels[frame]?.text ?? "" },
            set: { newValue in
                self.withUndoSnapshot(coalesce: "label:\(layer.id)-\(frame)") {
                    if newValue.isEmpty {
                        layer.frameLabels[frame] = nil
                    } else {
                        layer.frameLabels[frame, default: FrameLabel(text: "")].text = newValue
                    }
                }
            }
        )
    }

    /// A read/write binding onto a keyframe's label Type (Name/Comment/
    /// Anchor) — only meaningful once the label has text (see
    /// `labelBinding`); a no-op get/set when there's nothing there yet.
    /// Switching to/from `.anchor` adds/removes the leading "#" its
    /// behavior actually keys off, so choosing it from the picker works
    /// without the user needing to type the convention by hand.
    func labelTypeBinding(layer: TLLayer, at frame: Int) -> Binding<FrameLabelType> {
        Binding(
            get: { layer.frameLabels[frame]?.type ?? .name },
            set: { newType in
                guard var label = layer.frameLabels[frame] else { return }
                self.withUndoSnapshot {
                    if newType == .anchor, !label.text.hasPrefix("#") {
                        label.text = "#" + label.text
                    } else if label.type == .anchor, newType != .anchor, label.text.hasPrefix("#") {
                        label.text.removeFirst()
                    }
                    label.type = newType
                    layer.frameLabels[frame] = label
                }
            }
        )
    }

    /// The frame carrying `label`, searched across every layer in document
    /// order — what `gotoAndPlay("label")`/`gotoAndStop`/`goto` resolve
    /// against (see makeJSContext below and player.js's `resolveFrame`,
    /// which must stay in lockstep with this). nil if no keyframe anywhere
    /// has that exact label. Comment-type labels are documentation only —
    /// excluded here the same way Flash never compiles them into anything
    /// addressable.
    func frame(forLabel label: String) -> Int? {
        for layer in layers {
            // Dictionary iteration order is unspecified — sort so a layer
            // with (rare) duplicate labels resolves to its earliest frame,
            // deterministically, rather than whichever the hash table
            // happens to visit first.
            if let match = layer.frameLabels.sorted(by: { $0.key < $1.key })
                .first(where: { $0.value.type != .comment && $0.value.text == label }) {
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
            layer.symbolFrames[kf] = nil
            layer.shapeFrames[kf] = nil
            layer.groupFrames[kf] = nil
            selectedPlacement = TextPlacementRef(layerID: layer.id, keyframe: kf)
            selectedSymbolPlacement = nil
            selectedShapePlacement = nil
            selectedGroupPlacement = nil
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
        let symbolFrames: [Int: SymbolInstance]
        let shapeFrames: [Int: PlacedShape]
        let groupFrames: [Int: PlacedGroup]
        let tweenSettings: [Int: TweenSettings]
        let colorTweenSettings: [Int: TweenSettings]
        let labels: [Int: FrameLabel]
    }

    @ObservationIgnored private var copiedFrames: CopiedFrames?

    var hasCopiedFrames: Bool { copiedFrames != nil }

    /// Select All Frames (Flash's Edit menu) — selects every frame on the
    /// current layer as one range, same shape `copySelectedFrames`/
    /// `reverseFrames`/`cutSelectedFrames` already expect from `selectFrame`
    /// with `extend: true`.
    func selectAllFrames() {
        guard let layer = selectedLayer else { return }
        hasSelectedFrame = true
        selectedFrame = 1
        rangeSelectionEnd = layer.frames.count
    }

    /// Swaps the value at frame `a` with the value at frame `b` in a
    /// per-frame dictionary — `nil` on either side removes that key rather
    /// than storing an optional, so a swap against an unoccupied frame
    /// correctly clears the occupied one. Shared by `reverseFrames`.
    private func swapFrameEntry<T>(_ dict: inout [Int: T], _ a: Int, _ b: Int) {
        let valueAtA = dict[a]
        dict[a] = dict[b]
        dict[b] = valueAtA
    }

    /// Reverse Frames (Flash's own frame-range command) — mirrors the
    /// marks and every per-frame content association within `range` on
    /// `layer` around its center, so the span plays back in reverse.
    /// Deliberately leaves `tweenSettings`/`colorTweenSettings` keyed
    /// where they were: a tween's easing belongs to whichever frame is
    /// numerically its span's start, which reversal doesn't change (a
    /// span between the same two positions is still that same span) —
    /// only which content sits at each end does. Left untouched, a
    /// reversed tween plays the same curve shape from the old end's
    /// content to the old start's, which is exactly what "reverse" should
    /// mean for a tween.
    func reverseFrames(layer: TLLayer, range: ClosedRange<Int>) {
        guard range.count > 1 else { return }
        withUndoSnapshot {
            let lo = range.lowerBound, hi = range.upperBound
            for offset in 0..<(range.count / 2) {
                let a = lo + offset
                let b = hi - offset
                layer.frames.swapAt(a - 1, b - 1)
                swapFrameEntry(&layer.frameScripts, a, b)
                swapFrameEntry(&layer.textFrames, a, b)
                swapFrameEntry(&layer.symbolFrames, a, b)
                swapFrameEntry(&layer.shapeFrames, a, b)
                swapFrameEntry(&layer.groupFrames, a, b)
                swapFrameEntry(&layer.frameLabels, a, b)
            }
        }
    }

    /// Cut Frames (Flash's own frame-range command) — Copy Frames followed
    /// by clearing the cut range's content in place, same as `clearFrame`
    /// does for one frame at a time (no shifting; a later Paste Frames
    /// fills the gap back in, matching Flash's own Cut/Paste Frames pair).
    func cutSelectedFrames() {
        guard let layer = selectedLayer else { return }
        copySelectedFrames()
        withUndoSnapshot {
            for frame in selectedFrameRange {
                clearFrame(layer: layer, at: frame)
            }
        }
    }

    func copySelectedFrames() {
        guard let layer = selectedLayer else { return }
        let range = selectedFrameRange
        var marks: [FrameMark] = []
        var scripts: [Int: String] = [:]
        var textFrames: [Int: PlacedText] = [:]
        var symbolFrames: [Int: SymbolInstance] = [:]
        var shapeFrames: [Int: PlacedShape] = [:]
        var groupFrames: [Int: PlacedGroup] = [:]
        var tweenSettings: [Int: TweenSettings] = [:]
        var colorTweenSettings: [Int: TweenSettings] = [:]
        var labels: [Int: FrameLabel] = [:]
        for (offset, frame) in range.enumerated() {
            marks.append(frame - 1 < layer.frames.count ? layer.frames[frame - 1] : .empty)
            if let v = layer.frameScripts[frame] { scripts[offset] = v }
            if let v = layer.textFrames[frame] { textFrames[offset] = v }
            if let v = layer.symbolFrames[frame] { symbolFrames[offset] = v }
            if let v = layer.shapeFrames[frame] { shapeFrames[offset] = v }
            if let v = layer.groupFrames[frame] { groupFrames[offset] = v }
            if let v = layer.tweenSettings[frame] { tweenSettings[offset] = v }
            if let v = layer.colorTweenSettings[frame] { colorTweenSettings[offset] = v }
            if let v = layer.frameLabels[frame] { labels[offset] = v }
        }
        copiedFrames = CopiedFrames(
            marks: marks, scripts: scripts, textFrames: textFrames, symbolFrames: symbolFrames, shapeFrames: shapeFrames,
            groupFrames: groupFrames, tweenSettings: tweenSettings, colorTweenSettings: colorTweenSettings, labels: labels
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
            for (offset, v) in copied.symbolFrames { layer.symbolFrames[startFrame + offset] = v }
            for (offset, v) in copied.shapeFrames { layer.shapeFrames[startFrame + offset] = v }
            for (offset, v) in copied.groupFrames { layer.groupFrames[startFrame + offset] = v }
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
        // Groups aren't tweenable in v1 (see `PlacedGroup`'s own doc
        // comment) — same as shapes weren't at first, a group-only
        // keyframe deliberately can't start Create Tween.
        guard layer.isKeyframe(at: lo),
              layer.textFrames[lo] != nil || layer.symbolFrames[lo] != nil || layer.shapeFrames[lo] != nil else {
            logToConsole("Create Tween needs a keyframe with content at the start of the range.", level: .warn)
            return
        }
        withUndoSnapshot {
            if !layer.isKeyframe(at: hi) {
                insertKeyframe(layer: layer, at: hi, blank: false)
            }
            if layer.textFrames[hi] == nil && layer.symbolFrames[hi] == nil && layer.shapeFrames[hi] == nil && layer.groupFrames[hi] == nil {
                layer.textFrames[hi] = layer.textFrames[lo]
                layer.symbolFrames[hi] = layer.symbolFrames[lo]
                layer.shapeFrames[hi] = layer.shapeFrames[lo]
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
            let movedSymbol = layer.symbolFrames[oldEnd]
            let movedShape = layer.shapeFrames[oldEnd]
            let movedGroup = layer.groupFrames[oldEnd]
            let movedScript = layer.frameScripts[oldEnd]
            layer.textFrames[oldEnd] = nil
            layer.symbolFrames[oldEnd] = nil
            layer.shapeFrames[oldEnd] = nil
            layer.groupFrames[oldEnd] = nil
            layer.frameScripts[oldEnd] = nil

            if newEnd > oldEnd {
                for f in oldEnd...(newEnd - 1) { layer.frames[f - 1] = .tween }
            } else {
                for f in (newEnd + 1)...oldEnd { layer.frames[f - 1] = .empty }
            }
            layer.textFrames[newEnd] = movedText
            layer.symbolFrames[newEnd] = movedSymbol
            layer.shapeFrames[newEnd] = movedShape
            layer.groupFrames[newEnd] = movedGroup
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

    /// Repositions a plain, non-tween keyframe — the classic Flash drag,
    /// separate from `moveTweenEnd`'s span-resize because the two need
    /// different guards: a tween's start keyframe isn't handled here at
    /// all (moving it would leave the span it anchors dangling), and there's
    /// no "must stay N frames from something" minimum the way a tween end
    /// has. Overwrites whatever was already at `to`, same as `moveTweenEnd`/
    /// `pasteFrames` — this codebase doesn't do insert-and-shift.
    func moveKeyframe(layer: TLLayer, from: Int, to: Int) {
        guard from != to, to >= 1,
              layer.isKeyframe(at: from),
              layer.tweenTarget(from: from) == nil else { return }
        withUndoSnapshot {
            growCapacity(to: max(totalFrames, to))
            let mark = layer.frames[from - 1]
            let script = layer.frameScripts[from]
            let text = layer.textFrames[from]
            let symbol = layer.symbolFrames[from]
            let shape = layer.shapeFrames[from]
            let group = layer.groupFrames[from]
            let label = layer.frameLabels[from]

            layer.frames[from - 1] = .empty
            layer.frameScripts[from] = nil
            layer.textFrames[from] = nil
            layer.symbolFrames[from] = nil
            layer.shapeFrames[from] = nil
            layer.groupFrames[from] = nil
            layer.frameLabels[from] = nil
            // Any `.plain` continuation this keyframe was governing is now
            // ungoverned (nothing behind it to continue from) — clear it
            // back to `.empty` rather than leaving a dangling span.
            var trailing = from
            while trailing < layer.frames.count, layer.frames[trailing] == .plain {
                layer.frames[trailing] = .empty
                trailing += 1
            }

            layer.frames[to - 1] = mark
            layer.frameScripts[to] = script
            layer.textFrames[to] = text
            layer.symbolFrames[to] = symbol
            layer.shapeFrames[to] = shape
            layer.groupFrames[to] = group
            layer.frameLabels[to] = label

            if selectedFrame == from { selectedFrame = to }
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
        self.rootLayers = layers
        self.rootTotalFrames = totalFrames
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
        spawnNamedInstances()
        for layer in layers {
            guard layer.isKeyframe(at: playhead),
                  let script = layer.frameScripts[playhead], !script.isEmpty else { continue }
            jsContext.evaluateScript(preprocessForReentry(script))
        }
        // `stage` is a persistent JS object (not recreated per frame), so
        // clickTag naturally stays set across frames the way real clickTag
        // usage expects (set once, valid for the whole movie) — this just
        // mirrors its current value onto the native side after every run,
        // whether or not *this* frame's scripts touched it.
        let value = jsContext.objectForKeyedSubscript("stage")?.objectForKeyedSubscript("clickTag")
        clickTagURL = (value?.isString == true) ? value?.toString() : nil
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
        clickTagURL = nil
    }

    // MARK: - Stage objects & tweening

    func stageObject(id: String) -> StageObject? {
        stageObjects.first { $0.id == id }
    }

    /// For every layer whose governing keyframe at the current `playhead`
    /// is a named `SymbolInstance` not already spawned, creates a
    /// `StageObject` from it — same as if a script had just called
    /// `stage.addText` with that name. Runs once per frame, before that
    /// frame's own scripts (see `runScriptsOnCurrentFrame`), so a frame-1
    /// script can address an instance placed on frame 1 immediately, the
    /// same way Flash's own instance creation happens before that frame's
    /// actions run. `stageObject(id:) == nil` both guards against
    /// re-spawning every frame while the span is current and means a
    /// script's own `stage.addText` with a colliding name correctly no-ops
    /// against an already-spawned instance, exactly like two `addText`
    /// calls with the same id already do.
    ///
    /// Deliberately a one-time snapshot, not a live mirror: once spawned,
    /// the instance is a plain, independent StageObject from then on —
    /// further edits to the Library symbol or the Timeline placement don't
    /// retroactively change it, matching how the object model treats
    /// "authored" (Properties panel, always reflects current symbol
    /// content) and "running" (script-controlled, frozen at spawn time)
    /// as two different lifetimes.
    private func spawnNamedInstances() {
        for layer in layers {
            guard layer.isKeyframe(at: playhead),
                  let instance = layer.symbolFrames[playhead], !instance.name.isEmpty,
                  stageObject(id: instance.name) == nil,
                  let symbol = library.first(where: { $0.id == instance.symbolID })
            else { continue }
            stageObjects.append(StageObject(
                id: instance.name, text: symbol.text,
                x: instance.x + instance.width / 2, y: instance.y + instance.height / 2,
                fontSize: symbol.fontSize, color: Color(hex: symbol.colorHex),
                scale: instance.scale, rotation: Double(instance.rotation), opacity: instance.opacity,
                fontName: symbol.fontName, bold: symbol.bold, italic: symbol.italic
            ))
        }
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

    // MARK: - Masking
    //
    // Flash's mask layers: a `.mask`-kind layer's own content is never
    // drawn directly on Stage — it's only used as a clip stencil for the
    // contiguous run of `masked` layers directly below it in the Timeline
    // list, the same grouping Flash's own layer panel shows via
    // indentation. A non-masked layer breaks the run; a later `.mask`
    // layer starts a new one.

    /// Turns `layer` into a mask layer, or back into a normal one — a
    /// layer already carrying `masked = true` can't itself become a mask
    /// (a mask can't be masked), same as Flash's own rule.
    func toggleLayerMask(_ layer: TLLayer) {
        guard !layer.masked else { return }
        withUndoSnapshot {
            layer.kind = layer.kind == .mask ? .normal : .mask
        }
    }

    /// Marks/unmarks `layer` as clipped by the mask above it. Meaningless
    /// (and left alone) on a mask layer itself.
    func toggleLayerMasked(_ layer: TLLayer) {
        guard layer.kind != .mask else { return }
        withUndoSnapshot {
            layer.masked.toggle()
        }
    }

    /// The mask layer currently clipping `target`, walking `layers` in
    /// their real Timeline order (not Stage stacking order, which is a
    /// separate concern `StageContentView`'s own render loop already
    /// handles) — `nil` for a mask layer itself, for `masked == false`, or
    /// once a non-masked layer has broken the run back to the nearest
    /// mask above.
    func maskingLayer(for target: TLLayer) -> TLLayer? {
        var activeMask: TLLayer?
        for layer in layers {
            if layer.kind == .mask {
                activeMask = layer
            } else if !layer.masked {
                activeMask = nil
            }
            if layer.id == target.id {
                return layer.kind == .mask ? nil : activeMask
            }
        }
        return nil
    }

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
        // `nearestKeyframe(before:)` is actually "at or before" (see its own
        // doc comment) — when `frame` itself is already a keyframe it
        // returns `frame`, and (priorKeyframe + 1)...frame would then be an
        // invalid, crashing range with nothing to bridge anyway.
        guard let priorKeyframe = layer.nearestKeyframe(before: frame), priorKeyframe < frame else { return }
        for f in (priorKeyframe + 1)...frame where layer.frames[f - 1] == .empty {
            layer.frames[f - 1] = .plain
        }
    }

    /// Re-keys every per-frame dictionary on `layer` so content at or after
    /// `frame` moves one frame later — `layer.frames` itself is a plain
    /// array and shifts for free via `Array.insert`, but the dictionaries
    /// (keyed by frame number, not index) need their keys moved by hand.
    /// Building a fresh dictionary sidesteps any in-place-overwrite
    /// ordering hazard entirely. Shared by `insertFrame` only — `moveKeyframe`
    /// and friends deliberately don't do this (see moveKeyframe's own doc
    /// comment) since until now nothing needed to renumber more than one
    /// frame at a time.
    private func shiftFrameContentKeysForInsert(layer: TLLayer, at frame: Int) {
        func shifted<T>(_ dict: [Int: T]) -> [Int: T] {
            var result: [Int: T] = [:]
            for (key, value) in dict { result[key >= frame ? key + 1 : key] = value }
            return result
        }
        layer.frameScripts = shifted(layer.frameScripts)
        layer.textFrames = shifted(layer.textFrames)
        layer.symbolFrames = shifted(layer.symbolFrames)
        layer.shapeFrames = shifted(layer.shapeFrames)
        layer.groupFrames = shifted(layer.groupFrames)
        layer.frameLabels = shifted(layer.frameLabels)
        layer.tweenSettings = shifted(layer.tweenSettings)
        layer.colorTweenSettings = shifted(layer.colorTweenSettings)
    }

    /// The `removeFrames` counterpart — content exactly at `frame` is
    /// dropped (that frame no longer exists), and everything after moves
    /// one frame earlier.
    private func shiftFrameContentKeysForRemove(layer: TLLayer, at frame: Int) {
        func shifted<T>(_ dict: [Int: T]) -> [Int: T] {
            var result: [Int: T] = [:]
            for (key, value) in dict {
                if key == frame { continue }
                result[key > frame ? key - 1 : key] = value
            }
            return result
        }
        layer.frameScripts = shifted(layer.frameScripts)
        layer.textFrames = shifted(layer.textFrames)
        layer.symbolFrames = shifted(layer.symbolFrames)
        layer.shapeFrames = shifted(layer.shapeFrames)
        layer.groupFrames = shifted(layer.groupFrames)
        layer.frameLabels = shifted(layer.frameLabels)
        layer.tweenSettings = shifted(layer.tweenSettings)
        layer.colorTweenSettings = shifted(layer.colorTweenSettings)
    }

    /// F5 in classic Flash — inserts a frame at `frame` on `layer`. Two
    /// cases, matching what F5 has always meant in Flaj plus what the
    /// audit found missing:
    ///  - Nothing at or after `frame` yet (the common case: jumping ahead
    ///    on an otherwise-empty layer): bridges the whole gap back to the
    ///    nearest keyframe with continuation frames, same convenience
    ///    Flaj has always had here (see `extendSpan`) — there's nothing
    ///    to shift since it's all `.empty` anyway.
    ///  - Real content already sits at or after `frame`: a true insert,
    ///    shifting that keyframe (and its content/scripts/labels/tweens)
    ///    and everything after it one frame later, the way Flash's own
    ///    Insert Frame actually works. Scoped to this one layer, matching
    ///    Flash's own behavior when only a single layer's frame cell is
    ///    selected (a synchronized whole-timeline insert across every
    ///    layer at once isn't implemented).
    func insertFrame(layer: TLLayer, at frame: Int) {
        guard frame >= 1 else { return }
        withUndoSnapshot {
            growCapacity(to: max(totalFrames, frame))
            let hasContentAtOrAfter = layer.frames[(frame - 1)...].contains { $0 != .empty }
            if !hasContentAtOrAfter {
                extendSpan(layer: layer, upTo: frame)
                if layer.frames[frame - 1] == .empty { layer.frames[frame - 1] = .plain }
                return
            }
            let continuing = frame > 1 && layer.governingKeyframe(at: frame - 1) != nil
            layer.frames.insert(continuing ? .plain : .empty, at: frame - 1)
            shiftFrameContentKeysForInsert(layer: layer, at: frame)
            // This layer is now one frame longer than every other — pad
            // the rest and widen the document's own frame count to match,
            // same as Flash showing a longer layer's own row extend the
            // whole ruler.
            growCapacity(to: layer.frames.count)
        }
    }

    /// Shift+F5 in classic Flash — removes the frame at `frame` on `layer`,
    /// shifting every later keyframe (and its content/scripts/labels/
    /// tweens) one frame earlier. Scoped to this one layer, same as
    /// `insertFrame`. Distinct from Clear Frame (`clearFrame` below), which
    /// empties a frame's content in place without moving anything else —
    /// Flash keeps these as two separate commands, and so does Flaj.
    func removeFrames(layer: TLLayer, at frame: Int) {
        let idx = frame - 1
        guard layer.frames.indices.contains(idx) else { return }
        withUndoSnapshot {
            layer.frames.remove(at: idx)
            layer.frames.append(.empty) // keeps this layer's length == totalFrames
            shiftFrameContentKeysForRemove(layer: layer, at: frame)
            if selectedLayerID == layer.id, selectedFrame > frame {
                selectedFrame -= 1
            }
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
                if layer.symbolFrames[frame] == nil, let snapshot = layer.interpolatedSymbolInstance(at: frame) {
                    layer.symbolFrames[frame] = snapshot
                }
                if layer.shapeFrames[frame] == nil, let snapshot = layer.interpolatedPlacedShape(at: frame) {
                    layer.shapeFrames[frame] = snapshot
                }
                if layer.groupFrames[frame] == nil, let snapshot = layer.interpolatedPlacedGroup(at: frame) {
                    layer.groupFrames[frame] = snapshot
                }
            }
            layer.frames[idx] = blank ? .emptyKeyframe : .keyframe(hasScript: !(layer.frameScripts[frame] ?? "").isEmpty)
        }
    }

    /// Clear Frame(s)/Clear Keyframe in classic Flash — empties a frame's
    /// content in place without moving anything else on the layer (see
    /// `removeFrames` above for Shift+F5, which does shift). Removing a
    /// keyframe that sits exactly between two tweens (one ending here,
    /// another starting here — e.g. the shared frame left by splitting a
    /// tween via Insert Keyframe) merges them into a single tween spanning
    /// the gap, with the removed keyframe's own content excluded, rather
    /// than leaving a blank hole that breaks both.
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
            layer.symbolFrames[frame] = nil
            layer.shapeFrames[frame] = nil
            layer.groupFrames[frame] = nil
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

    func removeFramesAtSelection() {
        guard let layer = selectedLayer else { return }
        removeFrames(layer: layer, at: playhead)
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
