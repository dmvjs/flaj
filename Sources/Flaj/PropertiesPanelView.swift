import SwiftUI
import AppKit

/// Flash's Properties panel, scoped to what a placed text box actually
/// needs: position/size, character (font/size/style/color), paragraph
/// alignment, and a 9-position quick-align grid against the Stage.
struct PropertiesPanelView: View {
    let doc: TimelineDocument

    // Which point of the box the X/Y fields edit — a tool preference, not a
    // property of the text itself (matching Flash's own registration-point
    // picker, which also isn't saved per-object), so this is plain view
    // state rather than anything written into PlacedText/the .flaj format.
    @State private var positionAnchor: NineAnchor = .topLeading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Text selection (on Stage) and tween selection (on the
            // Timeline) are mutually exclusive contexts — selecting a frame
            // clears the stage selection (see selectFrame), so whichever is
            // still set here is whatever was picked most recently.
            let textBinding = doc.selectedPlacement.flatMap { doc.binding(for: $0) }
            let tweenBinding = textBinding == nil ? doc.activeTweenRef.flatMap { doc.tweenBinding(for: $0) } : nil
            let colorTweenBinding = textBinding == nil ? doc.activeTweenRef.flatMap { doc.colorTweenBinding(for: $0) } : nil
            // Independent of text/tween selection, not a third mutually
            // exclusive case — a keyframe that also starts a tween (or
            // carries placed text) can still carry its own label, so this
            // shows alongside whichever of those two is active, not only
            // when neither is.
            let labelTarget: (layer: TLLayer, frame: Int)? = doc.selectedLayer.flatMap { layer in
                layer.governingKeyframe(at: doc.selectedFrame).map { (layer, $0) }
            }
            // labelTarget is nearly always non-nil — some layer/frame is
            // selected from the moment the document loads, well before any
            // deliberate click — so it must never gate which of these two
            // shows; it's a prefix section within whichever one does, not
            // a competing branch. Without that, Movie (the case this
            // matters for) would be unreachable in practice: frame 1 of
            // the initially-selected layer is a keyframe by default, so
            // "nothing selected" would show the frame label alone forever.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let labelTarget {
                        labelSection(layer: labelTarget.layer, frame: labelTarget.frame)
                    }
                    if let binding = textBinding {
                        textSection(binding)
                        positionSection(binding)
                        characterSection(binding)
                        alignSection(binding)
                    } else if let tweenBinding, let colorTweenBinding {
                        tweenSection(tweenBinding)
                        colorTweenSection(colorTweenBinding)
                    } else {
                        documentTitleRow
                        documentSection
                        webExportSection
                        HStack(spacing: 8) {
                            Button("Export GIF…") { doc.exportGIF() }
                            Button("Export Web Page…") { doc.exportWebPage() }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 10))
            Text("Properties").font(.system(size: 11, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Movie (no text/tween selected)
    //
    // Flash's own behavior: with nothing on the Stage or Timeline selected
    // for editing, the Properties panel falls back to document-level
    // settings instead of a placeholder — frame rate, Stage size/color
    // (moved here from the Timeline's bottom bar, where Flash never had
    // them either), and the Web Export settings (shared bindings with
    // WebExportSettingsSheet, so editing either place changes the same
    // thing), plus one-click access to both export paths. Shown inline in
    // `body`'s ScrollView, not its own wrapper — see the comment there for
    // why this can't be a competing branch against text/tween content.

    private var documentTitleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(doc.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    private var documentSection: some View {
        sectionLabel("Document") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    numberField("W", doc.undoableBinding(\.stageWidth, coalesce: "stageWidth"))
                    numberField("H", doc.undoableBinding(\.stageHeight, coalesce: "stageHeight"))
                }
                HStack(spacing: 6) {
                    Text("FPS").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    TextField("", value: doc.undoableBinding(\.fps, coalesce: "fps"), formatter: Self.fpsFormatter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 46)
                }
                HStack(spacing: 6) {
                    Text("Stage Color").font(.system(size: 11)).foregroundStyle(.secondary)
                    ColorPicker("", selection: doc.undoableBinding(\.stageColor, coalesce: "stageColor")).labelsHidden()
                    Spacer()
                }
            }
        }
    }

    /// Same settings WebExportSettingsSheet has, and the same underlying
    /// `doc.webExport*` bindings — this doesn't replace that sheet (still
    /// needed to actually pick a save location), it just makes the
    /// settings visible/editable without opening it first.
    private var webExportSection: some View {
        sectionLabel("Web Export") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Untitled", text: doc.undoableBinding(\.webExportTitle, coalesce: "webExportTitle"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Picker("", selection: doc.undoableBinding(\.webExportFit)) {
                    ForEach(StageFit.allCases, id: \.self) { fit in
                        Text(fit.label).tag(fit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                HStack(alignment: .top, spacing: 8) {
                    StageAlignmentGrid(selection: doc.undoableBinding(\.webExportAlignment))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Page BG").font(.system(size: 11)).foregroundStyle(.secondary)
                            ColorPicker(
                                "", selection: doc.undoableBinding(\.webExportPageBackground, coalesce: "webExportPageBackground"),
                                supportsOpacity: true
                            )
                            .labelsHidden()
                        }
                        Toggle("Minify JS", isOn: doc.undoableBinding(\.webExportMinify))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private func textSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Text") {
            TextEditor(text: binding.text)
                .font(.system(size: 11))
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }

    /// Position, size, scale and rotation together — all spatial, all
    /// tween start-to-end alongside each other (see
    /// TLLayer.interpolatedPlacedText), not split across separate sections
    /// the way an earlier version of this panel had them. One consistent
    /// `labelWidth` across every row (wide enough for "Rotate", the
    /// longest) so the fields line up as a real grid instead of each row
    /// finding its own width.
    private func positionSection(_ binding: Binding<PlacedText>) -> some View {
        let fieldLabelWidth: CGFloat = 32
        return sectionLabel("Position, Size & Transform") {
            HStack(alignment: .top, spacing: 8) {
                positionAnchorGrid
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        numberField("X", anchoredXBinding(binding), labelWidth: fieldLabelWidth)
                        numberField("Y", anchoredYBinding(binding), labelWidth: fieldLabelWidth)
                    }
                    HStack(spacing: 6) {
                        numberField("W", binding.width, labelWidth: fieldLabelWidth)
                        numberField("H", binding.height, labelWidth: fieldLabelWidth)
                    }
                    HStack(spacing: 6) {
                        numberField("Scale", binding.scale, labelWidth: fieldLabelWidth)
                        numberField("Rotate", binding.rotation, labelWidth: fieldLabelWidth)
                    }
                }
            }
        }
    }

    /// Which point of the box X/Y refers to — top-left (Flash/this app's
    /// storage default) through center to bottom-right, or anywhere between.
    private var positionAnchorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 2), count: 3), spacing: 2) {
            ForEach(NineAnchor.allCases, id: \.self) { anchor in
                Button(action: { positionAnchor = anchor }) {
                    Circle()
                        .fill(positionAnchor == anchor ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .frame(width: 16, height: 16)
                        .background(
                            positionAnchor == anchor ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `PlacedText.x`/`.y` always stay top-left in storage — these bindings
    /// just translate through whichever point `positionAnchor` currently
    /// has selected, so typing into X/Y (or reading it back) is relative to
    /// that point without changing what's actually persisted.
    private func anchoredXBinding(_ binding: Binding<PlacedText>) -> Binding<CGFloat> {
        Binding(
            get: { binding.wrappedValue.x + binding.wrappedValue.width * positionAnchor.fraction.x },
            set: { binding.wrappedValue.x = $0 - binding.wrappedValue.width * positionAnchor.fraction.x }
        )
    }

    private func anchoredYBinding(_ binding: Binding<PlacedText>) -> Binding<CGFloat> {
        Binding(
            get: { binding.wrappedValue.y + binding.wrappedValue.height * positionAnchor.fraction.y },
            set: { binding.wrappedValue.y = $0 - binding.wrappedValue.height * positionAnchor.fraction.y }
        )
    }

    /// Font, size/style, color, and paragraph alignment together — all
    /// typography, all touched at roughly the same time when styling a
    /// text box. Paragraph alignment used to be its own section (one
    /// segmented control under its own uppercase header); folding it in
    /// here cuts a whole section for something that's really just one more
    /// Character row.
    private func characterSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Character") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: binding.fontName) {
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                HStack(spacing: 6) {
                    numberField("Size", binding.fontSize, labelWidth: 28)
                    Toggle("B", isOn: binding.bold).toggleStyle(.button).font(.system(size: 11, weight: .bold)).controlSize(.small)
                    Toggle("I", isOn: binding.italic).toggleStyle(.button).font(.system(size: 11).italic()).controlSize(.small)
                }

                HStack(spacing: 6) {
                    Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                    ColorPicker("", selection: colorBinding(binding), supportsOpacity: true).labelsHidden()
                    Picker("", selection: binding.alignment) {
                        Image(systemName: "text.alignleft").tag(TextHAlign.leading)
                        Image(systemName: "text.aligncenter").tag(TextHAlign.center)
                        Image(systemName: "text.alignright").tag(TextHAlign.trailing)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 90)
                    Spacer()
                }
            }
        }
    }

    /// A one-off snap action, not a value you'd check back on — lowest
    /// priority of the sections here, so it sits last.
    private func alignSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Align to Stage") {
            let anchors: [(CGFloat, CGFloat)] = [
                (0, 0), (0.5, 0), (1, 0),
                (0, 0.5), (0.5, 0.5), (1, 0.5),
                (0, 1), (0.5, 1), (1, 1)
            ]
            // Same compact size as positionAnchorGrid above — no reason
            // this one's targets should be 2.25x the area for the same
            // kind of 9-point picker.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 2), count: 3), spacing: 2) {
                ForEach(anchors.indices, id: \.self) { i in
                    Button(action: { applyAnchor(anchors[i], binding) }) {
                        Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                            .frame(width: 16, height: 16)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Position/size tweening and color-effect tweening are independent —
    // separate TweenSettings, separate easing curves (see
    // TLLayer.colorTweenSettings) — but share this exact same picker/slider
    // layout, matching how Flash's own Properties panel keeps "Position and
    // Size" and "Color Effect" as visually parallel, separately-eased groups.
    private func tweenSection(_ binding: Binding<TweenSettings>) -> some View {
        sectionLabel("Tweening") { easingControls(binding) }
    }

    private func colorTweenSection(_ binding: Binding<TweenSettings>) -> some View {
        sectionLabel("Color Effect") { easingControls(binding) }
    }

    /// A named navigation target for `gotoAndPlay("name")`/`gotoAndStop`/
    /// `goto` in frame scripts (see docs/SCRIPTING.md) — Flash's own frame
    /// labels, shown on the Timeline as a small red flag (TimelineView.
    /// frameLabelFlags).
    private func labelSection(layer: TLLayer, frame: Int) -> some View {
        sectionLabel("Frame Label") {
            TextField("Unlabeled", text: doc.labelBinding(layer: layer, at: frame))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    private func easingControls(_ binding: Binding<TweenSettings>) -> some View {
        let isLinear = binding.wrappedValue.family == .linear
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Ease").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Picker("", selection: binding.family) {
                    ForEach(EaseFamily.allCases, id: \.self) { family in
                        Text(family.label).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 84)

                // Direction only means something once a curve family is
                // picked (linear has nothing to be "in"/"out" about), but
                // stays on-screen and just disables — so it's always
                // findable instead of appearing/disappearing.
                Picker("", selection: binding.direction) {
                    ForEach(EaseDirection.allCases, id: \.self) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(isLinear)
            }
            HStack(spacing: 6) {
                Text("Amount").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Slider(value: binding.amount, in: 0...100)
                    .controlSize(.small)
                    .disabled(isLinear)
                Text("\(Int(binding.wrappedValue.amount.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private func applyAnchor(_ anchor: (CGFloat, CGFloat), _ binding: Binding<PlacedText>) {
        binding.wrappedValue.x = anchor.0 * (doc.stageWidth - binding.wrappedValue.width)
        binding.wrappedValue.y = anchor.1 * (doc.stageHeight - binding.wrappedValue.height)
    }

    // MARK: - Helpers

    private func sectionLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// `labelWidth` defaults to fit a single letter (X/Y/W/H) — pass a wider
    /// value for a longer label (e.g. "Scale"/"Rotate" in transformSection)
    /// so it doesn't wrap letter-by-letter in that fixed-width column.
    private func numberField(_ label: String, _ value: Binding<CGFloat>, labelWidth: CGFloat = 12) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
            TextField("", value: value, formatter: Self.numberFormatter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 46)
        }
    }

    private func colorBinding(_ binding: Binding<PlacedText>) -> Binding<Color> {
        Binding(
            get: { Color(hex: binding.wrappedValue.colorHex).opacity(binding.wrappedValue.opacity) },
            set: { newColor in
                binding.wrappedValue.colorHex = newColor.hexString
                binding.wrappedValue.opacity = newColor.opacityComponent
            }
        )
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        return f
    }()

    private static let fpsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        return f
    }()

    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()
}

/// A 3x3 registration point within a box — 0 is the leading/top edge, 1 the
/// trailing/bottom edge, matching CSS/Flash's usual normalized-anchor
/// convention. Only used to translate the Properties panel's X/Y fields
/// (see `PropertiesPanelView.anchoredXBinding`); `PlacedText` itself always
/// stores top-left.
private enum NineAnchor: CaseIterable, Hashable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    var fraction: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeading: return (0, 0)
        case .top: return (0.5, 0)
        case .topTrailing: return (1, 0)
        case .leading: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .trailing: return (1, 0.5)
        case .bottomLeading: return (0, 1)
        case .bottom: return (0.5, 1)
        case .bottomTrailing: return (1, 1)
        }
    }
}
