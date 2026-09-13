import SwiftUI
import AppKit

/// Flash's Properties panel, scoped to what a placed text box or symbol
/// instance actually needs: position/size, character (font/size/style/
/// color), Filters (Drop Shadow/Glow), paragraph alignment, and a
/// 9-position quick-align grid against the Stage. A symbol instance's own
/// content reuses these same content sections (`textSection`/
/// `characterSection`/`filtersSection`) rather than a parallel copy —
/// editing a symbol's text/character/filters is meant to feel identical to
/// editing a plain text box's, because it's the exact same view code.
struct PropertiesPanelView: View {
    let doc: TimelineDocument

    // Which point of the box the X/Y fields edit — a tool preference, not a
    // property of the text itself (matching Flash's own registration-point
    // picker, which also isn't saved per-object), so this is plain view
    // state rather than anything written into PlacedText/the .flaj format.
    @State private var positionAnchor: NineAnchor = .topLeading

    // The name typed for the next "Convert to Symbol" — plain UI state,
    // not part of the document, same spirit as positionAnchor. Cleared
    // after each conversion.
    @State private var newSymbolName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Text selection (on Stage) and tween selection (on the
            // Timeline) are mutually exclusive contexts — selecting a frame
            // clears the stage selection (see selectFrame), so whichever is
            // still set here is whatever was picked most recently.
            let textBinding = doc.selectedPlacement.flatMap { doc.binding(for: $0) }
            let instanceBinding = textBinding == nil ? doc.selectedSymbolPlacement.flatMap { doc.binding(for: $0) } : nil
            let shapeBinding = (textBinding == nil && instanceBinding == nil) ? doc.selectedShapePlacement.flatMap { doc.binding(for: $0) } : nil
            let noStageSelection = textBinding == nil && instanceBinding == nil && shapeBinding == nil
            let tweenBinding = noStageSelection ? doc.activeTweenRef.flatMap { doc.tweenBinding(for: $0) } : nil
            let colorTweenBinding = noStageSelection ? doc.activeTweenRef.flatMap { doc.colorTweenBinding(for: $0) } : nil
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
                        convertToSymbolRow(binding)
                        positionSection(binding)
                        characterSection(binding)
                        filtersSection(binding)
                        alignSection(binding)
                    } else if let instanceBinding {
                        instanceSection(instanceBinding)
                        let symbolID = instanceBinding.wrappedValue.symbolID
                        if let contentBinding = doc.symbolContentBinding(symbolID) {
                            let symbolName = doc.library.first(where: { $0.id == symbolID })?.name ?? ""
                            symbolContentHeader(symbolName)
                            textSection(contentBinding)
                            characterSection(contentBinding)
                            filtersSection(contentBinding)
                        }
                    } else if let shapeBinding {
                        shapePositionSection(shapeBinding)
                        shapeFillStrokeSection(shapeBinding)
                        shapeAlignSection(shapeBinding)
                    } else if let tweenBinding, let colorTweenBinding {
                        tweenSection(tweenBinding)
                        colorTweenSection(colorTweenBinding)
                    } else {
                        documentTitleRow
                        documentSection
                        librarySection
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
                    Text("FPS").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: Self.fieldLabelWidth, alignment: .leading)
                    TextField("", value: doc.undoableBinding(\.fps, coalesce: "fps"), formatter: Self.fpsFormatter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 46)
                }
                HStack(spacing: 6) {
                    Text("Stage Color").font(.system(size: 11)).foregroundStyle(.secondary)
                    NativeColorWell(color: doc.undoableBinding(\.stageColor, coalesce: "stageColor"))
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

                // Fit/Fill/Actual Size as a vertical radio list (not a
                // segmented control) so it sits comfortably beside the 3x3
                // alignment grid instead of needing its own full-width row —
                // both are narrow enough side by side even at the panel's
                // slim default width, unlike the wider "Page BG" row below
                // (see its own comment for why that one stays stacked).
                HStack(alignment: .top, spacing: 10) {
                    Picker("", selection: doc.undoableBinding(\.webExportFit)) {
                        ForEach(StageFit.allCases, id: \.self) { fit in
                            Text(fit.label).tag(fit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .controlSize(.small)

                    StageAlignmentGrid(selection: doc.undoableBinding(\.webExportAlignment))
                }
                HStack(spacing: 6) {
                    Text("Page BG").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    NativeColorWell(color: doc.webExportPageBackgroundHexBinding)
                    Slider(value: doc.webExportPageBackgroundOpacityBinding, in: 0...1)
                        .controlSize(.small)
                    Text("\(Int((doc.webExportPageBackground.opacityComponent * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Toggle("Minify JS", isOn: doc.undoableBinding(\.webExportMinify))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
        }
    }

    /// The Library — Flash's panel of reusable Symbol definitions, scoped
    /// down to live here rather than as its own panel (see FlajSymbol in
    /// StageObject.swift for what a v0 symbol actually holds). "Place"
    /// drops a new instance on the currently selected layer/frame; renaming
    /// or deleting here affects every instance, since they all just
    /// reference this same symbol by id.
    private var librarySection: some View {
        sectionLabel("Library") {
            VStack(alignment: .leading, spacing: 4) {
                if doc.library.isEmpty {
                    Text("No symbols yet — select a text box and Convert to Symbol.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                ForEach(doc.library) { symbol in
                    HStack(spacing: 6) {
                        TextField("Name", text: symbolNameBinding(symbol.id))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("Place") { doc.placeSymbolInstance(symbol) }
                            .controlSize(.small)
                        Button {
                            doc.deleteSymbol(symbol.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func symbolNameBinding(_ symbolID: UUID) -> Binding<String> {
        Binding(
            get: { doc.library.first(where: { $0.id == symbolID })?.name ?? "" },
            set: { doc.renameSymbol(symbolID, to: $0) }
        )
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

    /// Wraps this text box's content into a new Library symbol and swaps
    /// the Stage placement for an instance of it — see
    /// `TimelineDocument.convertSelectedTextToSymbol`. The name field
    /// defaults to the box's own text if left blank, so a one-click
    /// convert without typing a name still gets something sensible in
    /// the Library list.
    private func convertToSymbolRow(_ binding: Binding<PlacedText>) -> some View {
        HStack(spacing: 6) {
            TextField("Symbol name", text: $newSymbolName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button("Convert to Symbol") {
                let name = newSymbolName.isEmpty ? binding.wrappedValue.text : newSymbolName
                doc.convertSelectedTextToSymbol(name: name)
                newSymbolName = ""
            }
            .controlSize(.small)
        }
    }

    /// A placed symbol instance's own transform — position/size/scale/
    /// rotation/opacity, the same vocabulary `positionSection` edits for
    /// text, minus the registration-anchor picker (kept simple for v0:
    /// x/y always the box's top-left, same as storage).
    private func instanceSection(_ binding: Binding<SymbolInstance>) -> some View {
        sectionLabel("Instance") {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text("Name").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: Self.fieldLabelWidth, alignment: .leading)
                    TextField("Unnamed", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                // Swap Symbol — repoints this one instance at a different
                // Library symbol (TimelineDocument.swapSymbol), keeping
                // everything else about it (position/size/scale/rotation/
                // opacity/name) exactly as it is. Only shown once there's a
                // second symbol to swap to.
                if let ref = doc.selectedSymbolPlacement, doc.library.count > 1 {
                    HStack(spacing: 6) {
                        Text("Symbol").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: Self.fieldLabelWidth, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { binding.wrappedValue.symbolID },
                            set: { doc.swapSymbol(at: ref, to: $0) }
                        )) {
                            ForEach(doc.library) { symbol in
                                Text(symbol.name).tag(symbol.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 6) {
                    numberField("X", binding.x)
                    numberField("Y", binding.y)
                }
                HStack(spacing: 6) {
                    numberField("W", binding.width)
                    numberField("H", binding.height)
                }
                HStack(spacing: 6) {
                    numberField("Scale", binding.scale)
                    numberField("Rotate", binding.rotation)
                }
                HStack(spacing: 6) {
                    // "Opacity" doesn't fit fieldLabelWidth (32pt, sized for
                    // "X"/"Scale"/"Rotate") without wrapping — this row gets
                    // its own wider label, same idiom as easingControls'
                    // "Amount" slider row.
                    Text("Opacity").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Slider(value: binding.opacity, in: 0...1).controlSize(.small)
                    Text("\(Int((binding.wrappedValue.opacity * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    /// A one-line preface before the selected instance's underlying symbol
    /// content — everything actually editable about that content is
    /// `textSection`/`characterSection`/`filtersSection` below this,
    /// reused verbatim rather than a second, slightly-different copy of
    /// each (a prior version of this file had exactly that: its own
    /// TextEditor, its own font/size/color/align row, missing Filters
    /// entirely — three near-duplicates of the same fields is exactly the
    /// kind of drift that made this panel hard to trust). Editing any of
    /// them updates every instance of the symbol at once, since they all
    /// reference this same content by id rather than owning their own copy.
    private func symbolContentHeader(_ symbolName: String) -> some View {
        sectionLabel("Symbol: \(symbolName)") {
            Text("Edits every instance of this symbol.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    /// Position, size, scale and rotation together — all spatial, all
    /// tween start-to-end alongside each other (see
    /// TLLayer.interpolatedPlacedText), not split across separate sections
    /// the way an earlier version of this panel had them.
    private func positionSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Position, Size & Transform") {
            HStack(alignment: .top, spacing: 8) {
                positionAnchorGrid
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        numberField("X", anchoredXBinding(binding))
                        numberField("Y", anchoredYBinding(binding))
                    }
                    HStack(spacing: 6) {
                        numberField("W", binding.width)
                        numberField("H", binding.height)
                    }
                    HStack(spacing: 6) {
                        numberField("Scale", binding.scale)
                        numberField("Rotate", binding.rotation)
                    }
                }
            }
        }
    }

    /// Which point of the box X/Y refers to — top-left (Flash/this app's
    /// storage default) through center to bottom-right, or anywhere between.
    private var positionAnchorGrid: some View {
        nineAnchorGrid(isSelected: { $0 == positionAnchor }) { positionAnchor = $0 }
    }

    /// A 3x3 grid of small dot buttons, one per `NineAnchor` point — shared
    /// by `positionAnchorGrid` (a persistent choice: which point X/Y refer
    /// to, so the current one stays highlighted) and `alignSection` (a
    /// one-shot snap action, nothing is ever "selected" — `isSelected`
    /// defaults to always-false) — one grid, one dot style, instead of two
    /// near-identical copies that could quietly drift apart.
    private func nineAnchorGrid(isSelected: @escaping (NineAnchor) -> Bool = { _ in false }, onTap: @escaping (NineAnchor) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 2), count: 3), spacing: 2) {
            ForEach(NineAnchor.allCases, id: \.self) { anchor in
                Button(action: { onTap(anchor) }) {
                    Circle()
                        .fill(isSelected(anchor) ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .frame(width: 16, height: 16)
                        .background(
                            isSelected(anchor) ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
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
                    numberField("Size", binding.fontSize)
                    Toggle("B", isOn: binding.bold).toggleStyle(.button).font(.system(size: 11, weight: .bold)).controlSize(.small)
                    Toggle("I", isOn: binding.italic).toggleStyle(.button).font(.system(size: 11).italic()).controlSize(.small)
                }

                HStack(spacing: 6) {
                    Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                    NativeColorWell(color: colorBinding(binding))
                    Slider(value: binding.opacity, in: 0...1).controlSize(.small)
                    Text("\(Int((binding.wrappedValue.opacity * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack(spacing: 6) {
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

    /// Flash 8's Filters panel, scoped to Drop Shadow and Glow (see
    /// `PlacedText`'s own doc comment on why just these two — the others
    /// need a vector-rendering engine this app doesn't have yet). Each is
    /// an on/off Toggle that reveals its own controls once enabled, same
    /// idiom System Settings uses for an optional feature's sub-options.
    private func filtersSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Filters") {
            VStack(alignment: .leading, spacing: 8) {
                filterToggle("Drop Shadow", isOn: Binding(
                    get: { binding.wrappedValue.dropShadow != nil },
                    set: { binding.wrappedValue.dropShadow = $0 ? (binding.wrappedValue.dropShadow ?? DropShadowFilter()) : nil }
                )) {
                    let shadow = Binding(
                        get: { binding.wrappedValue.dropShadow ?? DropShadowFilter() },
                        set: { binding.wrappedValue.dropShadow = $0 }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            NativeColorWell(color: filterColorBinding(shadow))
                            Slider(value: shadow.opacity, in: 0...1).controlSize(.small)
                            Text("\(Int((shadow.wrappedValue.opacity * 100).rounded()))%")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                        HStack(spacing: 6) {
                            numberField("Blur", shadow.blur)
                            numberField("X", shadow.offsetX)
                            numberField("Y", shadow.offsetY)
                        }
                    }
                }
                filterToggle("Glow", isOn: Binding(
                    get: { binding.wrappedValue.glow != nil },
                    set: { binding.wrappedValue.glow = $0 ? (binding.wrappedValue.glow ?? GlowFilter()) : nil }
                )) {
                    let glow = Binding(
                        get: { binding.wrappedValue.glow ?? GlowFilter() },
                        set: { binding.wrappedValue.glow = $0 }
                    )
                    HStack(spacing: 6) {
                        NativeColorWell(color: filterColorBinding(glow))
                        Slider(value: glow.opacity, in: 0...1).controlSize(.small)
                        Text("\(Int((glow.wrappedValue.opacity * 100).rounded()))%")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        numberField("Blur", glow.blur)
                    }
                }
            }
        }
    }

    /// A checkbox with its own revealed controls indented beneath it while
    /// on — shared shape for Drop Shadow and Glow above, each of which
    /// otherwise differs only in which fields it exposes.
    private func filterToggle<Content: View>(
        _ title: String, isOn: Binding<Bool>, @ViewBuilder controls: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox).font(.system(size: 11))
            if isOn.wrappedValue {
                controls().padding(.leading, 18)
            }
        }
    }

    /// Hex-only, same idiom as `colorBinding(_:)` above generalized to
    /// `DropShadowFilter`/`GlowFilter` via `ColorFilter` — `binding.opacity`
    /// is shown/edited via its own Slider alongside `NativeColorWell`.
    private func filterColorBinding<F: ColorFilter>(_ binding: Binding<F>) -> Binding<Color> {
        Binding(
            get: { Color(hex: binding.wrappedValue.colorHex) },
            set: { binding.wrappedValue.colorHex = $0.hexString }
        )
    }

    /// A one-off snap action, not a value you'd check back on — lowest
    /// priority of the sections here, so it sits last.
    private func alignSection(_ binding: Binding<PlacedText>) -> some View {
        sectionLabel("Align to Stage") {
            nineAnchorGrid { anchor in
                binding.wrappedValue.x = anchor.fraction.x * (doc.stageWidth - binding.wrappedValue.width)
                binding.wrappedValue.y = anchor.fraction.y * (doc.stageHeight - binding.wrappedValue.height)
            }
        }
    }

    /// A drawn shape's position and size — same anchor-grid idiom as
    /// `positionSection` for text, minus scale/rotation (shapes aren't
    /// tweenable in v1, see `PlacedShape`'s own doc comment, so there's no
    /// transform curve for those to animate along).
    private func shapePositionSection(_ binding: Binding<PlacedShape>) -> some View {
        sectionLabel("Position & Size") {
            HStack(alignment: .top, spacing: 8) {
                positionAnchorGrid
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        numberField("X", anchoredShapeXBinding(binding))
                        numberField("Y", anchoredShapeYBinding(binding))
                    }
                    HStack(spacing: 6) {
                        numberField("W", binding.width)
                        numberField("H", binding.height)
                    }
                }
            }
        }
    }

    private func anchoredShapeXBinding(_ binding: Binding<PlacedShape>) -> Binding<CGFloat> {
        Binding(
            get: { binding.wrappedValue.x + binding.wrappedValue.width * positionAnchor.fraction.x },
            set: { binding.wrappedValue.x = $0 - binding.wrappedValue.width * positionAnchor.fraction.x }
        )
    }

    private func anchoredShapeYBinding(_ binding: Binding<PlacedShape>) -> Binding<CGFloat> {
        Binding(
            get: { binding.wrappedValue.y + binding.wrappedValue.height * positionAnchor.fraction.y },
            set: { binding.wrappedValue.y = $0 - binding.wrappedValue.height * positionAnchor.fraction.y }
        )
    }

    /// Fill and stroke color+opacity plus stroke width and overall opacity —
    /// same color+opacity-in-one-swatch idiom as `characterSection`'s text
    /// color and `filtersSection`'s filter colors (`colorBinding`/
    /// `filterColorBinding`), just for the two colors a shape carries.
    private func shapeFillStrokeSection(_ binding: Binding<PlacedShape>) -> some View {
        sectionLabel("Shape") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Fill").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: Self.fieldLabelWidth, alignment: .leading)
                    NativeColorWell(color: shapeFillBinding(binding))
                    Slider(value: binding.fillOpacity, in: 0...1).controlSize(.small)
                    Text("\(Int((binding.wrappedValue.fillOpacity * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text("Stroke").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: Self.fieldLabelWidth, alignment: .leading)
                    NativeColorWell(color: shapeStrokeBinding(binding))
                    Slider(value: binding.strokeOpacity, in: 0...1).controlSize(.small)
                    Text("\(Int((binding.wrappedValue.strokeOpacity * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Spacer().frame(width: Self.fieldLabelWidth)
                    numberField("Width", binding.strokeWidth)
                    Picker("", selection: binding.strokeStyle) {
                        Text("Solid").tag(StrokeDashStyle.solid)
                        Text("Dashed").tag(StrokeDashStyle.dashed)
                        Text("Dotted").tag(StrokeDashStyle.dotted)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 80)
                    Spacer()
                }
                // Corner radius only means something on a rectangle — an
                // ellipse has no corners to round.
                if binding.wrappedValue.kind == .rectangle {
                    HStack(spacing: 6) {
                        numberField("Corner", binding.cornerRadius)
                        Spacer()
                    }
                }
                HStack(spacing: 6) {
                    Text("Opacity").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Slider(value: binding.opacity, in: 0...1).controlSize(.small)
                    Text("\(Int((binding.wrappedValue.opacity * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    /// Hex-only — `fillOpacity` is its own Slider next to `NativeColorWell`.
    private func shapeFillBinding(_ binding: Binding<PlacedShape>) -> Binding<Color> {
        Binding(
            get: { Color(hex: binding.wrappedValue.fillColorHex) },
            set: { binding.wrappedValue.fillColorHex = $0.hexString }
        )
    }

    /// Hex-only — `strokeOpacity` is its own Slider next to `NativeColorWell`.
    private func shapeStrokeBinding(_ binding: Binding<PlacedShape>) -> Binding<Color> {
        Binding(
            get: { Color(hex: binding.wrappedValue.strokeColorHex) },
            set: { binding.wrappedValue.strokeColorHex = $0.hexString }
        )
    }

    private func shapeAlignSection(_ binding: Binding<PlacedShape>) -> some View {
        sectionLabel("Align to Stage") {
            nineAnchorGrid { anchor in
                binding.wrappedValue.x = anchor.fraction.x * (doc.stageWidth - binding.wrappedValue.width)
                binding.wrappedValue.y = anchor.fraction.y * (doc.stageHeight - binding.wrappedValue.height)
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
            VStack(alignment: .leading, spacing: 4) {
                TextField("Unlabeled", text: doc.labelBinding(layer: layer, at: frame))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                // Type only means anything once there's a label to type —
                // matches Flash, which also greys this menu out until the
                // Name field has text.
                if !doc.labelBinding(layer: layer, at: frame).wrappedValue.isEmpty {
                    Picker("", selection: doc.labelTypeBinding(layer: layer, at: frame)) {
                        Text("Name").tag(FrameLabelType.name)
                        Text("Comment").tag(FrameLabelType.comment)
                        Text("Anchor").tag(FrameLabelType.anchor)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 100)
                }
            }
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

    // MARK: - Helpers

    private func sectionLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// One fixed column width for every field label in the whole panel —
    /// "Rotate"/"Symbol", the longest labels anywhere here, are what it's
    /// sized for. Every section using the same width, always, rather than
    /// each picking its own, is what makes every row across every section
    /// line up as one real grid instead of a collection of ad hoc rows.
    private static let fieldLabelWidth: CGFloat = 32

    private func numberField(_ label: String, _ value: Binding<CGFloat>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: Self.fieldLabelWidth, alignment: .leading)
            TextField("", value: value, formatter: Self.numberFormatter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 46)
        }
    }

    /// Hex-only — `binding.opacity` is shown/edited via its own Slider
    /// alongside `NativeColorWell`, not round-tripped through this Color
    /// (see `NativeColorWell`'s own doc comment on why).
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
