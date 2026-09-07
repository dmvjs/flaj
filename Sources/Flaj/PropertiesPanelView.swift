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
            if textBinding != nil || tweenBinding != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let binding = textBinding {
                            textSection(binding)
                            positionSection(binding)
                            characterSection(binding)
                            paragraphSection(binding)
                            alignSection(binding)
                        } else if let tweenBinding, let colorTweenBinding {
                            tweenSection(tweenBinding)
                            colorTweenSection(colorTweenBinding)
                        }
                    }
                    .padding(10)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a text box on the Stage, or a frame within a tween on the Timeline.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

    // MARK: - Sections

    private func textSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Text") {
            TextEditor(text: binding.text)
                .font(.system(size: 11))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func positionSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Position and Size") {
            HStack(alignment: .top, spacing: 10) {
                positionAnchorGrid
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        numberField("X", anchoredXBinding(binding))
                        numberField("Y", anchoredYBinding(binding))
                    }
                    HStack(spacing: 8) {
                        numberField("W", binding.width)
                        numberField("H", binding.height)
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

    private func characterSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Character") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: binding.fontName) {
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    numberField("Size", binding.fontSize)
                    Toggle("B", isOn: binding.bold).toggleStyle(.button).font(.system(size: 11, weight: .bold))
                    Toggle("I", isOn: binding.italic).toggleStyle(.button).font(.system(size: 11).italic())
                }

                HStack(spacing: 8) {
                    Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                    ColorPicker("", selection: colorBinding(binding), supportsOpacity: true).labelsHidden()
                    Spacer()
                }
            }
        }
    }

    private func paragraphSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Paragraph") {
            Picker("", selection: binding.alignment) {
                Image(systemName: "text.alignleft").tag(TextHAlign.leading)
                Image(systemName: "text.aligncenter").tag(TextHAlign.center)
                Image(systemName: "text.alignright").tag(TextHAlign.trailing)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    private func alignSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Align to Stage") {
            let anchors: [(CGFloat, CGFloat)] = [
                (0, 0), (0.5, 0), (1, 0),
                (0, 0.5), (0.5, 0.5), (1, 0.5),
                (0, 1), (0.5, 1), (1, 1)
            ]
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 3), spacing: 4) {
                ForEach(anchors.indices, id: \.self) { i in
                    Button(action: { applyAnchor(anchors[i], binding) }) {
                        Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
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

    private func easingControls(_ binding: Binding<TweenSettings>) -> some View {
        let isLinear = binding.wrappedValue.family == .linear
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ease").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                Picker("", selection: binding.family) {
                    ForEach(EaseFamily.allCases, id: \.self) { family in
                        Text(family.label).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)

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
                .disabled(isLinear)
            }
            HStack(spacing: 8) {
                Text("Amount").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                Slider(value: binding.amount, in: 0...100)
                    .disabled(isLinear)
                Text("\(Int(binding.wrappedValue.amount.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func applyAnchor(_ anchor: (CGFloat, CGFloat), _ binding: Binding<PlacedText>) {
        binding.wrappedValue.x = anchor.0 * (doc.stageWidth - binding.wrappedValue.width)
        binding.wrappedValue.y = anchor.1 * (doc.stageHeight - binding.wrappedValue.height)
    }

    // MARK: - Helpers

    private func sectionLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func numberField(_ label: String, _ value: Binding<CGFloat>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            TextField("", value: value, formatter: Self.numberFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
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
