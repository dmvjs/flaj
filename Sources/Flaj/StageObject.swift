import SwiftUI
import Observation

/// A text object on the Stage — created/controlled from frame scripts via
/// the `stage.addText`/`setText`/`setTransform`/`tween` JS globals. Also
/// what a named `SymbolInstance` becomes the moment its governing keyframe
/// is reached during playback (see `TimelineDocument.spawnNamedInstances`)
/// — one object model, one API, whether a script created it or the
/// Timeline placed it. `fontName`/`bold`/`italic` default to match exactly
/// what `stage.addText` already produced before those fields existed, so
/// existing script-created objects are unaffected.
@Observable
final class StageObject: Identifiable {
    let id: String
    var text: String
    var fontSize: CGFloat
    var color: Color
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
    var rotation: Double // degrees
    var opacity: Double
    var fontName: String
    var bold: Bool
    var italic: Bool

    init(id: String, text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat = 24,
         color: Color = .black, scale: CGFloat = 1, rotation: Double = 0, opacity: Double = 1,
         fontName: String = "Helvetica", bold: Bool = false, italic: Bool = false) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.fontSize = fontSize
        self.color = color
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.fontName = fontName
        self.bold = bold
        self.italic = italic
    }
}

/// Text authored directly on the Stage with the Text tool, tied to a
/// specific (layer, keyframe) — distinct from `StageObject`, which is
/// created/driven by frame scripts at runtime. `x`/`y` are the top-left
/// corner in Stage pixel space (matching Flash's Properties panel), not a
/// center point.
struct PlacedText: Codable, Equatable {
    var text: String = "Text"
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 160
    var height: CGFloat = 40
    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 24
    var bold: Bool = false
    var italic: Bool = false
    var colorHex: String = "#000000"
    var alignment: TextHAlign = .leading
    var opacity: Double = 1
    var scale: CGFloat = 1
    /// Degrees — the box's own base rotation, tweened start-to-end like x/y
    /// (see TLLayer.interpolatedPlacedText). Independent of, and additive
    /// with, TweenSettings.rotate/rotateTimes's "spin N extra times over
    /// the span" effect (StageView.StagePlacedTextView combines the two).
    var rotation: CGFloat = 0

    // Flash 8's Filters panel, scoped to the two that map cleanly onto both
    // SwiftUI (.shadow()) and CSS (text-shadow) with no vector-rendering
    // engine required — Bevel/Gradient Glow/Adjust Color would need one.
    // Static per span, like bold/italic/fontName/alignment above (see
    // TLLayer.interpolatedPlacedText's own doc comment on why those don't
    // interpolate either) — a filter can still change keyframe to keyframe,
    // it just jumps rather than eases within a span. nil means off; there's
    // no "zero-strength" filter value, so Optional is the honest way to
    // model "not applied" rather than a magic zero-blur/zero-opacity struct.
    var dropShadow: DropShadowFilter? = nil
    var glow: GlowFilter? = nil

    init(text: String = "Text", x: CGFloat, y: CGFloat, width: CGFloat = 160, height: CGFloat = 40,
         fontName: String = "Helvetica", fontSize: CGFloat = 24, bold: Bool = false, italic: Bool = false,
         colorHex: String = "#000000", alignment: TextHAlign = .leading, opacity: Double = 1,
         scale: CGFloat = 1, rotation: CGFloat = 0, dropShadow: DropShadowFilter? = nil, glow: GlowFilter? = nil) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.colorHex = colorHex
        self.alignment = alignment
        self.opacity = opacity
        self.scale = scale
        self.rotation = rotation
        self.dropShadow = dropShadow
        self.glow = glow
    }

    private enum CodingKeys: String, CodingKey {
        case text, x, y, width, height, fontName, fontSize, bold, italic, colorHex, alignment, opacity,
             scale, rotation, dropShadow, glow
    }

    // Custom decode so .flaj files saved before `opacity`/`scale`/`rotation`
    // existed still open — decodeIfPresent with each field's own declared
    // default throughout, not just the newest fields, so this stays correct
    // regardless of which fields existed when a given file was written.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? "Text"
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 160
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 40
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 24
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#000000"
        alignment = try c.decodeIfPresent(TextHAlign.self, forKey: .alignment) ?? .leading
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        dropShadow = try c.decodeIfPresent(DropShadowFilter.self, forKey: .dropShadow)
        glow = try c.decodeIfPresent(GlowFilter.self, forKey: .glow)
    }
}

/// Shared shape for `DropShadowFilter`/`GlowFilter` — both are just a color
/// plus that color's own alpha, so the Properties panel can offer one
/// generic `ColorPicker`-backed binding (see `PropertiesPanelView.
/// filterColorBinding`) instead of one per filter type.
protocol ColorFilter {
    var colorHex: String { get set }
    var opacity: Double { get set }
}

/// Flash's Drop Shadow filter — a colored, offset, blurred copy of the
/// content behind it. `opacity` is the shadow's own alpha, independent of
/// the content's own `PlacedText.opacity`.
struct DropShadowFilter: Codable, Equatable, ColorFilter {
    var colorHex: String = "#000000"
    var blur: CGFloat = 4
    var offsetX: CGFloat = 2
    var offsetY: CGFloat = 2
    var opacity: Double = 0.5
}

/// Flash's Glow filter — Drop Shadow with the offset fixed at zero, glowing
/// evenly outward on every side instead of casting to one. Modeled as its
/// own type rather than "just a DropShadowFilter with offset 0/0" so a
/// filter's *kind* is unambiguous from which optional field is non-nil,
/// not from inspecting a shadow's offset to guess whether it's "really" a
/// glow — matching how the Properties panel and Flash's own Filters list
/// present them as two distinct filters, not one parameterized either way.
struct GlowFilter: Codable, Equatable, ColorFilter {
    var colorHex: String = "#FFFFFF"
    var blur: CGFloat = 8
    var opacity: Double = 0.8
}

enum ShapeKind: String, Codable, CaseIterable {
    case rectangle, ellipse
}

/// A rectangle's stroke dash pattern — real Flash's Stroke Style menu has
/// six variable-width styles plus Hairline; scoped here to the two
/// cheapest, most commonly used ones (solid stays the default). Named
/// `StrokeDashStyle` rather than `StrokeStyle` to avoid colliding with
/// SwiftUI's own `StrokeStyle` type, which every rendering call site here
/// also needs to reference directly (for the actual dash-array values).
enum StrokeDashStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted
}

/// A vector-drawing-tool placement — Rectangle/Ellipse for now (see
/// ToolbarView's own doc comment on why just these two), tied to a
/// specific (layer, keyframe) exactly like `PlacedText`, and just as
/// independent an object: this app's shapes never merge or cut into each
/// other the way Flash's own classic fill/stroke drawing model does —
/// each is always one discrete, always-selectable-as-a-unit placement,
/// same object model `PlacedText`/`SymbolInstance` already use.
///
/// Tweenable like `PlacedText`/`SymbolInstance` — see `TLLayer.
/// interpolatedPlacedShape` for the two independently-eased groups
/// (position/size/strokeWidth/cornerRadius vs. fill/stroke color and
/// every opacity). `kind` and `strokeStyle` never interpolate — a
/// rectangle doesn't morph into an ellipse mid-tween, and a dash pattern
/// has no meaningful "halfway" state the way a numeric value does.
struct PlacedShape: Codable, Equatable {
    var kind: ShapeKind = .rectangle
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 100
    var height: CGFloat = 100
    var fillColorHex: String = "#3399FF"
    var fillOpacity: Double = 1
    var strokeColorHex: String = "#000000"
    var strokeOpacity: Double = 1
    var strokeWidth: CGFloat = 2
    var strokeStyle: StrokeDashStyle = .solid
    /// Only meaningful when `kind == .rectangle` (an ellipse has no
    /// corners) — real Flash's Rectangle Primitive tool's adjustable
    /// per-corner radius, simplified here to one radius for all four
    /// corners rather than four independent ones.
    var cornerRadius: CGFloat = 0
    /// The whole shape's own opacity — independent of, and compounds
    /// with, fill/stroke's own opacity, same relationship `PlacedText.
    /// opacity` has to nothing-in-particular (it has no separate fill/
    /// stroke to compound with) but symbol content's opacity has to an
    /// instance's (see StageSymbolInstanceView's own doc comment on why
    /// that compounding exists at all).
    var opacity: Double = 1

    init(kind: ShapeKind = .rectangle, x: CGFloat, y: CGFloat, width: CGFloat = 100, height: CGFloat = 100,
         fillColorHex: String = "#3399FF", fillOpacity: Double = 1, strokeColorHex: String = "#000000",
         strokeOpacity: Double = 1, strokeWidth: CGFloat = 2, strokeStyle: StrokeDashStyle = .solid,
         cornerRadius: CGFloat = 0, opacity: Double = 1) {
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fillColorHex = fillColorHex
        self.fillOpacity = fillOpacity
        self.strokeColorHex = strokeColorHex
        self.strokeOpacity = strokeOpacity
        self.strokeWidth = strokeWidth
        self.strokeStyle = strokeStyle
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case kind, x, y, width, height, fillColorHex, fillOpacity, strokeColorHex, strokeOpacity, strokeWidth,
             strokeStyle, cornerRadius, opacity
    }

    // Same decodeIfPresent-with-each-field's-own-default idiom as
    // PlacedText's custom decoder — keeps older .flaj files (saved before
    // strokeStyle/cornerRadius existed) opening exactly as they did.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ShapeKind.self, forKey: .kind) ?? .rectangle
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 100
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 100
        fillColorHex = try c.decodeIfPresent(String.self, forKey: .fillColorHex) ?? "#3399FF"
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 1
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#000000"
        strokeOpacity = try c.decodeIfPresent(Double.self, forKey: .strokeOpacity) ?? 1
        strokeWidth = try c.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 2
        strokeStyle = try c.decodeIfPresent(StrokeDashStyle.self, forKey: .strokeStyle) ?? .solid
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

/// Illustrator/Flash's Group — genuinely distinct from a Symbol: a
/// lightweight, non-reusable bundle of placements that just moves/resizes
/// as one unit, not a Library asset with its own independent Timeline
/// (compare `FlajSymbol` below). `texts`/`shapes`/`symbols` each carry
/// their own full feature set unchanged (filters, color, per-symbol
/// transform, etc.) — only their `x`/`y` mean something different here:
/// relative to the group's own (0,0) origin (its own `x`/`y`), not
/// absolute Stage coordinates.
///
/// v1 is deliberately an opaque unit once grouped: there's no
/// double-click-to-enter-and-edit-one-member mode the way a symbol has
/// edit-in-place — that would need a genuinely separate "flat, no nested
/// Timeline" editing scope, real but sizable scope beyond move/resize/
/// Ungroup. Editing one member for now means Ungroup, edit, re-group.
/// Resizing scales every child's own x/y/width/height (and a shape's
/// strokeWidth) directly, by the same ratio as the group's own box —
/// not a separate multiplicative `scale` factor the way `SymbolInstance`
/// has one, since that would need distinguishing "design size" from
/// "current size" for no real benefit at this scope. `rotation`/`opacity`
/// stay as simple whole-group modifiers, same idiom `SymbolInstance`
/// already uses for those two.
struct PlacedGroup: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat = 0
    var opacity: Double = 1
    var texts: [PlacedText] = []
    var shapes: [PlacedShape] = []
    var symbols: [SymbolInstance] = []

    private enum CodingKeys: String, CodingKey {
        case x, y, width, height, rotation, opacity, texts, shapes, symbols
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rotation: CGFloat = 0, opacity: Double = 1,
         texts: [PlacedText] = [], shapes: [PlacedShape] = [], symbols: [SymbolInstance] = []) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.opacity = opacity
        self.texts = texts
        self.shapes = shapes
        self.symbols = symbols
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decode(CGFloat.self, forKey: .width)
        height = try c.decode(CGFloat.self, forKey: .height)
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        texts = try c.decodeIfPresent([PlacedText].self, forKey: .texts) ?? []
        shapes = try c.decodeIfPresent([PlacedShape].self, forKey: .shapes) ?? []
        symbols = try c.decodeIfPresent([SymbolInstance].self, forKey: .symbols) ?? []
    }
}

enum GuideOrientation: String, Codable {
    case horizontal, vertical
}

/// Flash's ruler guides — a single infinite line, dragged out from the
/// horizontal or vertical ruler, that sits on the Stage as a layout aid.
/// `position` is a Stage-space coordinate along the axis the guide is
/// perpendicular to: the y-coordinate a horizontal guide sits at, or the
/// x-coordinate a vertical one sits at (a horizontal guide's own "height"
/// and a vertical one's "width" are meaningless — it always spans the
/// Stage's full width/height, drawn that way by StageView, not stored
/// here). Purely a visual placement aid in v1 — nothing snaps to a guide
/// yet, same "most basic first" scope PlacedShape started at.
struct Guide: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var orientation: GuideOrientation
    var position: CGFloat

    private enum CodingKeys: String, CodingKey { case id, orientation, position }

    init(id: UUID = UUID(), orientation: GuideOrientation, position: CGFloat) {
        self.id = id
        self.orientation = orientation
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        orientation = try c.decode(GuideOrientation.self, forKey: .orientation)
        position = try c.decode(CGFloat.self, forKey: .position)
    }
}

/// A reusable Library entry — Flash's Symbol concept: a small Timeline of
/// its own (`layers`/`totalFrames`, the exact same shape a `TimelineDocument`
/// itself has), not just a flat blob of text/font/style. Editing a symbol's
/// content (via `TimelineDocument.symbolContentBinding`) updates every
/// instance at once; each instance still gets its own independent
/// position/size/scale/rotation/opacity (and can still be tweened across
/// keyframes, exactly like `PlacedText`).
///
/// A placed instance plays this Timeline independently of the parent —
/// Flash's actual Movie Clip behavior: once placed, it loops its own
/// frames continuously on its own internal clock, never waiting for or
/// synced to the parent Timeline's playhead (see `localFrame`/
/// `content(atLocalFrame:)`, used by `StageSymbolInstanceView` and
/// player.js's `resolvePlacement`).
struct FlajSymbol: Identifiable {
    let id: UUID
    var name: String
    var layers: [TLLayer]
    var totalFrames: Int

    init(id: UUID = UUID(), name: String, layers: [TLLayer], totalFrames: Int) {
        self.id = id
        self.name = name
        self.layers = layers
        self.totalFrames = totalFrames
    }

    /// Convenience matching the old flat-symbol shape: every existing call
    /// site (Convert to Symbol, tests, fixtures) just wants "a symbol
    /// wrapping this one text box," so this synthesizes the one-layer/
    /// one-frame Timeline underneath rather than making every call site
    /// build a `TLLayer` by hand.
    init(id: UUID = UUID(), name: String, text: String = "Text", fontName: String = "Helvetica",
         fontSize: CGFloat = 24, bold: Bool = false, italic: Bool = false, colorHex: String = "#000000",
         alignment: TextHAlign = .leading) {
        let layer = TLLayer(name: "Layer 1", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(
            text: text, x: 0, y: 0, fontName: fontName, fontSize: fontSize,
            bold: bold, italic: italic, colorHex: colorHex, alignment: alignment
        )
        self.init(id: id, name: name, layers: [layer], totalFrames: 1)
    }

    /// The symbol's displayed content at frame 1 of its first layer —
    /// what the Properties panel's "Symbol" section edits (a symbol's
    /// content is authored one frame at a time, same as the document's own
    /// Timeline; frame 1 is simply the natural default target for a quick
    /// edit), and the fallback for a single-frame symbol. nil only for a
    /// pathologically empty symbol (its one layer/frame deleted out from
    /// under it), which nothing in the UI currently allows.
    var content: PlacedText? { layers.first?.textFrames[1] }

    /// Which of this symbol's own frames an instance shows right now,
    /// given how many frames the *parent* Timeline has been showing that
    /// instance's governing keyframe (`parentFrame - governingKeyframe`) —
    /// not wall-clock time, so playback stays fully deterministic across
    /// the live Stage, GIF export, and the web export alike, the same
    /// guarantee every other tween/animation in this app already relies
    /// on. Loops every `totalFrames`, same as a real Flash Movie Clip
    /// instance plays continuously and independently of whatever's
    /// happening on the timeline it's placed on. A `totalFrames` of 1 (the
    /// only value a symbol has ever had before this) always resolves to 1,
    /// so this is a no-op for every symbol that hasn't been extended to
    /// more than one frame via edit-in-place.
    func localFrame(atParentFrame parentFrame: Int, governingKeyframe: Int) -> Int {
        let span = max(totalFrames, 1)
        let elapsed = parentFrame - governingKeyframe
        return (((elapsed % span) + span) % span) + 1
    }

    /// The content shown at a given frame of this symbol's own Timeline —
    /// eased across a tween span exactly like a plain `PlacedText` box
    /// would be, via its first layer's own `interpolatedPlacedText`.
    /// `content` (`content(atLocalFrame: 1)`) is just this at the frame
    /// every symbol starts on.
    func content(atLocalFrame localFrame: Int) -> PlacedText? {
        layers.first?.interpolatedPlacedText(at: localFrame)
    }

    // Flat read-only passthroughs so call sites that only ever display a
    // symbol's look (StageSymbolInstanceView, the onion-skin ghost, the web
    // export) don't need to reach into `layers` themselves. Deliberately
    // read-only: a computed *setter* here would mutate the shared `TLLayer`
    // the instant a caller wrote through it — including through a
    // `Binding<FlajSymbol>`'s own copy-mutate-writeback dance, which would
    // apply the change before whatever `withUndoSnapshot` wraps that write
    // ever takes its "before" snapshot, silently corrupting undo. Editing
    // goes through `TimelineDocument.symbolContentBinding` instead, which
    // is scoped to the value-type `PlacedText` itself and stays inside the
    // same withUndoSnapshot idiom every other content edit here already uses.
    var text: String { content?.text ?? "" }
    var fontName: String { content?.fontName ?? "Helvetica" }
    var fontSize: CGFloat { content?.fontSize ?? 24 }
    var bold: Bool { content?.bold ?? false }
    var italic: Bool { content?.italic ?? false }
    var colorHex: String { content?.colorHex ?? "#000000" }
    var alignment: TextHAlign { content?.alignment ?? .leading }
}

/// One placement of a `FlajSymbol` on the Stage — tied to a specific
/// (layer, keyframe), same as `PlacedText`. Carries only the geometry a
/// single instance needs independently of the symbol's shared content:
/// where it sits, how big its box is, and its own scale/rotation/opacity.
/// `x`/`y` are the box's top-left corner in Stage pixel space, matching
/// `PlacedText`.
struct SymbolInstance: Codable, Equatable {
    var symbolID: UUID
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 160
    var height: CGFloat = 40
    var opacity: Double = 1
    var scale: CGFloat = 1
    var rotation: CGFloat = 0
    // Flash's "instance name" — empty means unnamed/unaddressable (the
    // default; matches how an empty frame label means "no label", see
    // TLLayer.frameLabels). Once non-empty, the moment this instance's
    // governing keyframe is reached during playback it spawns into
    // `TimelineDocument.stageObjects` under this name (see
    // `spawnNamedInstances`) and becomes addressable from frame scripts via
    // the exact same stage.setTransform/tween/setText a script-created
    // object already uses — no separate API for Timeline-placed vs.
    // script-created objects.
    var name: String = ""

    init(symbolID: UUID, x: CGFloat, y: CGFloat, width: CGFloat = 160, height: CGFloat = 40,
         opacity: Double = 1, scale: CGFloat = 1, rotation: CGFloat = 0, name: String = "") {
        self.symbolID = symbolID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.opacity = opacity
        self.scale = scale
        self.rotation = rotation
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case symbolID, x, y, width, height, opacity, scale, rotation, name }

    // Custom decode so .flaj files saved before `name` (or the earlier
    // width/height/opacity/scale/rotation) existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbolID = try c.decode(UUID.self, forKey: .symbolID)
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 160
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 40
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

enum TextHAlign: String, Codable, CaseIterable {
    case leading, center, trailing

    var swiftUIAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}

/// Classic-tween-span settings — Flash's Ease (-100 = ease in/slow start,
/// 100 = ease out/slow end, 0 = linear) and Rotate (spin CW/CCW some number
/// of extra times over the span, independent of the start/end position).
/// Keyed per-span on TLLayer.tweenSettings, by the span's start keyframe.
struct TweenSettings: Codable, Equatable {
    var family: EaseFamily = .linear
    var direction: EaseDirection = .easeInOut
    // Blends the curve's strength, 0 (linear, no easing) ... 100 (the family's
    // full shape) — generalizes Flash's single Ease slider across every
    // family instead of just one fixed power curve.
    var amount: Double = 100
    var rotate: RotateDirection = .none
    var rotateTimes: Int = 0

    private enum CodingKeys: String, CodingKey { case family, direction, amount, rotate, rotateTimes }

    init(family: EaseFamily = .linear, direction: EaseDirection = .easeInOut, amount: Double = 100,
         rotate: RotateDirection = .none, rotateTimes: Int = 0) {
        self.family = family
        self.direction = direction
        self.amount = amount
        self.rotate = rotate
        self.rotateTimes = rotateTimes
    }

    // Custom decode so tweenSettings saved before `amount` existed still open,
    // defaulting to 100 (full curve strength) — the behavior they already had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decode(EaseFamily.self, forKey: .family)
        direction = try c.decode(EaseDirection.self, forKey: .direction)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        rotate = try c.decode(RotateDirection.self, forKey: .rotate)
        rotateTimes = try c.decode(Int.self, forKey: .rotateTimes)
    }

    /// Combines `family`'s shape with `direction` (In/Out/InOut) — the
    /// standard Penner-equation pattern: every family only defines its own
    /// "ease in" curve (`EaseFamily.easeIn`), and Out/InOut are derived from
    /// that one function generically — then blends toward that shape by
    /// `amount`, so a low amount reads as barely-eased and 100 is the full
    /// curve, matching how Flash's classic Ease slider felt at every value.
    func easedProgress(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        guard family != .linear else { return clamped }
        let curved: Double
        switch direction {
        case .easeIn:
            curved = family.easeIn(clamped)
        case .easeOut:
            curved = 1 - family.easeIn(1 - clamped)
        case .easeInOut:
            curved = clamped < 0.5
                ? family.easeIn(clamped * 2) / 2
                : 1 - family.easeIn((1 - clamped) * 2) / 2
        }
        let blend = min(max(amount, 0), 100) / 100
        return clamped + (curved - clamped) * blend
    }

    /// Extra rotation (degrees) contributed by Rotate at progress `t`.
    func spinDegrees(at t: Double) -> Double {
        let direction: Double
        switch rotate {
        case .none: return 0
        case .cw: direction = 1
        case .ccw: direction = -1
        }
        return direction * 360 * Double(rotateTimes) * easedProgress(t)
    }
}

/// A curve shape, à la Penner/GSAP — crossed with `EaseDirection` (In/Out/
/// InOut) to give the full easing matrix Flash's later Motion Editor (and
/// every modern animation library) offers.
enum EaseFamily: String, Codable, CaseIterable {
    case linear, sine, quad, cubic, back, elastic, bounce

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .sine: return "Sine"
        case .quad: return "Quad"
        case .cubic: return "Cubic"
        case .back: return "Back"
        case .elastic: return "Elastic"
        case .bounce: return "Bounce"
        }
    }

    /// This family's "ease in" shape only — t and result both 0...1. Out and
    /// InOut are derived from this by TweenSettings.easedProgress.
    func easeIn(_ t: Double) -> Double {
        switch self {
        case .linear:
            return t
        case .sine:
            return 1 - cos(t * .pi / 2)
        case .quad:
            return t * t
        case .cubic:
            return t * t * t
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return c3 * t * t * t - c1 * t * t
        case .elastic:
            guard t > 0, t < 1 else { return t }
            let c4 = (2 * Double.pi) / 3
            return -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * c4)
        case .bounce:
            return 1 - Self.bounceOut(1 - t)
        }
    }

    /// Penner's bounceOut — a ball dropping and settling, four decreasing
    /// bounces packed into 0...1. bounceIn (used above) is just this run
    /// backwards and flipped, the standard trick for deriving one Penner
    /// direction from another.
    private static func bounceOut(_ t: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        var t = t
        if t < 1 / d1 {
            return n1 * t * t
        } else if t < 2 / d1 {
            t -= 1.5 / d1
            return n1 * t * t + 0.75
        } else if t < 2.5 / d1 {
            t -= 2.25 / d1
            return n1 * t * t + 0.9375
        } else {
            t -= 2.625 / d1
            return n1 * t * t + 0.984375
        }
    }
}

enum EaseDirection: String, Codable, CaseIterable {
    case easeIn, easeOut, easeInOut

    var label: String {
        switch self {
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In Out"
        }
    }
}

enum RotateDirection: String, Codable, CaseIterable {
    case none, cw, ccw
}

enum TweenableProperty: String {
    case x, y, scale, rotation, opacity, fontSize
}

/// Standard easing curves — matches the vocabulary most JS animation
/// libraries (and Flash's own motion tween editor) already use.
enum Easing: String {
    case linear, easeIn, easeOut, easeInOut

    func apply(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        switch self {
        case .linear: return c
        case .easeIn: return c * c
        case .easeOut: return 1 - (1 - c) * (1 - c)
        case .easeInOut: return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
        }
    }
}

/// One in-flight property interpolation. `startFrame` is an absolute frame
/// number, so a tween spanning a loop boundary (playhead wraps back to 1
/// mid-tween) is a known, unhandled edge case — the value just holds at its
/// start until the playhead catches back up, rather than being tracked as
/// wall-clock elapsed time.
struct ActiveTween {
    let objectID: String
    let property: TweenableProperty
    let fromValue: Double
    let toValue: Double
    let startFrame: Int
    let durationFrames: Int
    let easing: Easing
}
