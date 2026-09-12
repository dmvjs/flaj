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

    init(text: String = "Text", x: CGFloat, y: CGFloat, width: CGFloat = 160, height: CGFloat = 40,
         fontName: String = "Helvetica", fontSize: CGFloat = 24, bold: Bool = false, italic: Bool = false,
         colorHex: String = "#000000", alignment: TextHAlign = .leading, opacity: Double = 1,
         scale: CGFloat = 1, rotation: CGFloat = 0) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case text, x, y, width, height, fontName, fontSize, bold, italic, colorHex, alignment, opacity,
             scale, rotation
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
    }
}

/// A reusable Library entry — Flash's Symbol concept, scoped down to a
/// single frame: no nested timeline of its own, just the text/font/style
/// content shared by every `SymbolInstance` placed from it. Editing a
/// symbol's content here updates every instance at once; each instance
/// still gets its own independent position/size/scale/rotation/opacity
/// (and can still be tweened across keyframes, exactly like `PlacedText`).
struct FlajSymbol: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var bold: Bool
    var italic: Bool
    var colorHex: String
    var alignment: TextHAlign

    init(id: UUID = UUID(), name: String, text: String = "Text", fontName: String = "Helvetica",
         fontSize: CGFloat = 24, bold: Bool = false, italic: Bool = false, colorHex: String = "#000000",
         alignment: TextHAlign = .leading) {
        self.id = id
        self.name = name
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.colorHex = colorHex
        self.alignment = alignment
    }
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
