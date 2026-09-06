import SwiftUI
import AppKit

/// Flash's Properties panel, scoped to what a placed text box actually
/// needs: position/size, character (font/size/style/color), paragraph
/// alignment, and a 9-position quick-align grid against the Stage.
struct PropertiesPanelView: View {
    @ObservedObject var doc: TimelineDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let ref = doc.selectedPlacement, let binding = doc.binding(for: ref) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        textSection(binding)
                        positionSection(binding)
                        characterSection(binding)
                        paragraphSection(binding)
                        alignSection(binding)
                    }
                    .padding(10)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a text box, or pick the Text tool and click the Stage.")
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
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    numberField("X", binding.x)
                    numberField("Y", binding.y)
                }
                HStack(spacing: 8) {
                    numberField("W", binding.width)
                    numberField("H", binding.height)
                }
            }
        }
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
                    ColorPicker("", selection: colorBinding(binding)).labelsHidden()
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
            get: { Color(hex: binding.wrappedValue.colorHex) },
            set: { binding.wrappedValue.colorHex = $0.hexString }
        )
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        return f
    }()

    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()
}
