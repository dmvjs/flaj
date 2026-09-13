import SwiftUI
import AppKit

// Classic Flash function-key shortcuts. SwiftUI's KeyEquivalent has no named
// cases for function keys, so these are built from the NSEvent function-key
// Unicode private-use code points directly (F5 = 0xF708, F6 = 0xF709, F7 = 0xF70A).
private extension KeyEquivalent {
    static let f5 = KeyEquivalent(Character(UnicodeScalar(0xF708)!))
    static let f6 = KeyEquivalent(Character(UnicodeScalar(0xF709)!))
    static let f7 = KeyEquivalent(Character(UnicodeScalar(0xF70A)!))
}

// A `swift run`-launched binary has no .app bundle, so macOS doesn't hand it
// keyboard focus automatically — without this, the window opens but the
// terminal stays the active app and keystrokes go there instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct FlajApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var doc = TimelineDocument.sample()

    var body: some Scene {
        WindowGroup("Flaj") {
            HSplitView {
                ToolbarView(doc: doc)
                    .frame(width: 40)
                // Stage and the Timeline/Script/Debug stack share this one
                // column, so they're always exactly as wide as each other —
                // matching Flash's own layout, where the Timeline docks
                // directly under the Stage rather than spanning the whole
                // window (which would run it under the Properties dock too).
                VSplitView {
                    StageView(doc: doc)
                        .frame(minWidth: 320, minHeight: 260, idealHeight: 380)
                    TimelineView(doc: doc)
                        .frame(minHeight: 220, idealHeight: 280)
                    CodeEditorPanel(doc: doc)
                        .frame(minHeight: 100, idealHeight: 140)
                    DebugConsoleView(doc: doc)
                        .frame(minHeight: 100, idealHeight: 120)
                }
                // Higher layout priority than Properties (below) so any
                // extra window width goes here — otherwise HSplitView hands
                // leftover space to the trailing pane by default, which
                // would balloon Properties past its slim ideal width every
                // time the window opens wider than the sum of the panes'
                // minimums.
                .layoutPriority(1)
                // A full-height dock, like Flash's own Properties column,
                // which runs the whole height of the window (alongside the
                // Timeline too, not just the Stage) so its stacked sections
                // — position, character, filters, align, and so on — have
                // room to sit open as a running column instead of fighting
                // over a short shelf next to the Stage alone.
                // idealWidth matches minWidth so the panel opens as slim as
                // it can and the user has to deliberately drag it wider,
                // rather than defaulting to extra width nobody asked for.
                PropertiesPanelView(doc: doc)
                    .frame(minWidth: 260, idealWidth: 260)
            }
            .frame(minWidth: 900, idealWidth: 1600, minHeight: 860, idealHeight: 900)
            .sheet(isPresented: $doc.webExportSheetPresented) {
                WebExportSettingsSheet(doc: doc)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { doc.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!doc.canUndo)
                Button("Redo") { doc.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!doc.canRedo)
            }
            CommandGroup(after: .newItem) {
                Button("Open…") { doc.openDocument() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save") { doc.saveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { doc.saveDocument(forceDialog: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export GIF…") { doc.exportGIF() }
                Button("Export Web Page…") { doc.exportWebPage() }
                Divider()
                Button("Test Movie") { doc.testMovie() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            CommandMenu("Insert") {
                Button("Frame") { doc.insertFrameAtSelection() }
                    .keyboardShortcut(.f5, modifiers: [])
                Button("Keyframe") { doc.insertKeyframeAtSelection(blank: false) }
                    .keyboardShortcut(.f6, modifiers: [])
                Button("Blank Keyframe") { doc.insertKeyframeAtSelection(blank: true) }
                    .keyboardShortcut(.f7, modifiers: [])
                Divider()
                Button("Remove Frames") { doc.clearFrameAtSelection() }
                    .keyboardShortcut(.f5, modifiers: [.shift])
            }
            CommandMenu("View") {
                Toggle("Rulers", isOn: $doc.rulersVisible)
                    .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                Toggle("Show Guides", isOn: $doc.guidesVisible)
                    .keyboardShortcut(";", modifiers: .command)
            }
            CommandMenu("Modify") {
                // Flash/Illustrator's own Group/Ungroup shortcuts.
                Button("Group") { doc.groupSelection() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(doc.selectedPlacements.count < 2)
                Button("Ungroup") { doc.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(doc.selectedGroupPlacement == nil)
            }
        }
    }
}
