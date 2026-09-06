import SwiftUI
import Combine
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

enum LayerKind: Codable {
    case normal, folder, mask, maskedGuide, guide
}

/// One line in the debug console — Flash's Output panel equivalent.
struct ConsoleMessage: Identifiable {
    enum Level { case log, warn, error }
    let id = UUID()
    let level: Level
    let text: String
    let frame: Int
}

final class TLLayer: Identifiable, ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published var swatch: Color
    @Published var kind: LayerKind
    @Published var indent: Int
    @Published var locked: Bool
    @Published var hidden: Bool
    @Published var expanded: Bool = true
    @Published var frames: [FrameMark]
    @Published var frameScripts: [Int: String] = [:]   // 1-based frame number -> JS/TS source
    @Published var textFrames: [Int: PlacedText] = [:] // 1-based keyframe number -> placed text

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

    init(name: String, swatch: Color, kind: LayerKind = .normal, indent: Int = 0,
         locked: Bool = false, hidden: Bool = false, frames: [FrameMark],
         textFrames: [Int: PlacedText] = [:]) {
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
final class TimelineDocument: ObservableObject {
    @Published var layers: [TLLayer]
    @Published var totalFrames: Int
    @Published var playhead: Int = 1

    // Grounded in reality: below 1fps the playback math degenerates and
    // there's nothing meaningfully "animated"; above 120fps you're asking
    // for a rate no common display can even show (120Hz/ProMotion is the
    // practical ceiling), and a run-loop timer stops being reliable well
    // before that anyway.
    static let minFPS: Double = 1
    static let maxFPS: Double = 120
    @Published var fps: Double = 12.0 {
        didSet {
            let clamped = min(max(fps, Self.minFPS), Self.maxFPS)
            if clamped != fps { fps = clamped }
        }
    }
    @Published var isPlaying: Bool = false
    @Published var selectedLayerID: UUID?

    // The frame shown in the Actions panel / highlighted in the grid.
    // Deliberately separate from `playhead`: while playing, `playhead`
    // advances every tick, but the code editor and selection box should
    // stay put on whatever frame was last explicitly clicked, not flicker
    // through every frame as the movie runs.
    @Published var selectedFrame: Int = 1

    // The Stage — Flash's term for the fixed-size render surface, scriptable
    // from frame code via the `stage`/`bg` JS globals below.
    @Published var stageWidth: CGFloat = 550
    @Published var stageHeight: CGFloat = 400
    @Published var stageColor: Color = .white

    @Published var consoleMessages: [ConsoleMessage] = []

    @Published var currentFileURL: URL?

    @Published var stageObjects: [StageObject] = []
    private var activeTweens: [ActiveTween] = []

    // MARK: - Text tool

    enum StageTool { case selection, text }
    struct TextPlacementRef: Equatable { let layerID: UUID; let keyframe: Int }

    @Published var selectedTool: StageTool = .selection
    @Published var selectedPlacement: TextPlacementRef?

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
        let placement = PlacedText(x: point.x, y: point.y)
        layer.textFrames[kf] = placement
        selectedPlacement = TextPlacementRef(layerID: layer.id, keyframe: kf)
    }

    func deleteSelectedPlacement() {
        guard let ref = selectedPlacement, let layer = layers.first(where: { $0.id == ref.layerID }) else { return }
        layer.textFrames[ref.keyframe] = nil
        selectedPlacement = nil
    }

    /// A read/write binding straight into the owning layer's dictionary —
    /// same idiom as CodeEditorPanel.scriptBinding(for:).
    func binding(for ref: TextPlacementRef) -> Binding<PlacedText>? {
        guard let layer = layers.first(where: { $0.id == ref.layerID }) else { return nil }
        return Binding(
            get: { layer.textFrames[ref.keyframe] ?? PlacedText(x: 0, y: 0) },
            set: { layer.textFrames[ref.keyframe] = $0 }
        )
    }

    private var timerSource: DispatchSourceTimer?

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

    private lazy var jsContext: JSContext = makeJSContext()

    /// Top-level `const`/`let` names already declared at least once during
    /// this document's runtime lifetime — see preprocessForReentry below.
    private var declaredTopLevelBindings: Set<String> = []

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
        // run the destination frame's actions, matching ActionScript.
        let jsGotoAndStop: @convention(block) (Int) -> Void = { [weak self] frame in
            guard let self else { return }
            self.stop()
            self.playhead = min(max(frame, 1), self.totalFrames)
            self.runScriptsOnCurrentFrame()
        }
        let jsGotoAndPlay: @convention(block) (Int) -> Void = { [weak self] frame in
            guard let self else { return }
            self.playhead = min(max(frame, 1), self.totalFrames)
            self.play()
        }
        // goto(frame) — unlike gotoAndPlay/gotoAndStop, doesn't force a
        // play-state change; just repositions the playhead. Bounded to
        // [1, contentLength] — the actual keyframe-bounded range — rather
        // than raw document capacity, so an out-of-range call (0, negative,
        // or past the last real keyframe) lands on a valid frame instead of
        // shipping straight to frame 0/blank space.
        let jsGoto: @convention(block) (Int) -> Void = { [weak self] frame in
            guard let self else { return }
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
        objectWillChange.send()
    }

    // MARK: - Layer management

    func indexOf(_ id: UUID) -> Int? { layers.firstIndex { $0.id == id } }

    func addLayer() {
        let indent = selectedLayerID.flatMap { id in layers.first { $0.id == id }?.indent } ?? 0
        let insertAt = selectedLayerID.flatMap(indexOf) ?? 0
        let newLayer = TLLayer(
            name: "Layer \(layers.count + 1)", swatch: .green, indent: indent,
            frames: [.emptyKeyframe] + Array(repeating: .empty, count: max(0, totalFrames - 1))
        )
        layers.insert(newLayer, at: min(insertAt, layers.count))
        selectedLayerID = newLayer.id
    }

    func addFolder() {
        let insertAt = selectedLayerID.flatMap(indexOf) ?? 0
        let newFolder = TLLayer(
            name: "Folder \(layers.count + 1)", swatch: .cyan, kind: .folder,
            frames: Array(repeating: .empty, count: totalFrames)
        )
        layers.insert(newFolder, at: min(insertAt, layers.count))
        selectedLayerID = newFolder.id
    }

    func deleteSelectedLayer() {
        guard let id = selectedLayerID, let layer = layers.first(where: { $0.id == id }) else { return }
        deleteLayer(layer)
    }

    func deleteLayer(_ layer: TLLayer) {
        guard let idx = indexOf(layer.id) else { return }
        layers.remove(at: idx)
        if selectedLayerID == layer.id {
            selectedLayerID = layers.indices.contains(idx) ? layers[idx].id : layers.last?.id
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

    /// F5 in classic Flash — extends content into a blank frame. (Simplified:
    /// marks the frame as continuing prior content rather than shifting
    /// everything after it, since frames don't carry real content yet.)
    func insertFrame(layer: TLLayer, at frame: Int) {
        growCapacity(to: max(totalFrames, frame))
        let idx = frame - 1
        guard layer.frames.indices.contains(idx), layer.frames[idx] == .empty else { return }
        layer.frames[idx] = .plain
    }

    /// F6 (keyframe) / F7 (blank keyframe) in classic Flash.
    func insertKeyframe(layer: TLLayer, at frame: Int, blank: Bool) {
        growCapacity(to: max(totalFrames, frame))
        let idx = frame - 1
        guard layer.frames.indices.contains(idx) else { return }
        layer.frames[idx] = blank ? .emptyKeyframe : .keyframe(hasScript: !(layer.frameScripts[frame] ?? "").isEmpty)
    }

    /// Shift+F5 in classic Flash — removes frames.
    func clearFrame(layer: TLLayer, at frame: Int) {
        let idx = frame - 1
        guard layer.frames.indices.contains(idx) else { return }
        layer.frames[idx] = .empty
        layer.frameScripts[frame] = nil
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
        let item = layers.remove(at: from)
        item.indent = indent
        if let beforeID = beforeLayerID, let targetIdx = layers.firstIndex(where: { $0.id == beforeID }) {
            layers.insert(item, at: targetIdx)
        } else {
            layers.append(item)
        }
    }

    /// Drops `id` inside `folder` as its first child.
    func reparent(id: UUID, intoFolder folder: TLLayer) {
        guard id != folder.id, let from = indexOf(id) else { return }
        let item = layers.remove(at: from)
        item.indent = folder.indent + 1
        if let folderIdx = layers.firstIndex(where: { $0.id == folder.id }) {
            layers.insert(item, at: folderIdx + 1)
        } else {
            layers.append(item)
        }
        folder.expanded = true
    }

    static func sample() -> TimelineDocument {
        let total = 70
        var frames: [FrameMark] = Array(repeating: .empty, count: total)
        frames[0] = .keyframe(hasScript: false) // frame 1 is a keyframe by default, ready for code
        let actions = TLLayer(name: "actions", swatch: .yellow, frames: frames)
        return TimelineDocument(layers: [actions], totalFrames: total)
    }
}
