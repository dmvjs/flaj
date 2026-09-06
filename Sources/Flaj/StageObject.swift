import SwiftUI

/// A text object on the Stage — created/controlled from frame scripts via
/// the `stage.addText`/`setText`/`setTransform`/`tween` JS globals.
final class StageObject: Identifiable, ObservableObject {
    let id: String
    @Published var text: String
    @Published var fontSize: CGFloat
    @Published var color: Color
    @Published var x: CGFloat
    @Published var y: CGFloat
    @Published var scale: CGFloat
    @Published var rotation: Double // degrees
    @Published var opacity: Double

    init(id: String, text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat = 24,
         color: Color = .black, scale: CGFloat = 1, rotation: Double = 0, opacity: Double = 1) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.fontSize = fontSize
        self.color = color
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
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
