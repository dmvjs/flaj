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
            VStack(spacing: 0) {
                VSplitView {
                    HSplitView {
                        ToolbarView(doc: doc)
                            .frame(width: 40)
                        StageView(doc: doc)
                            .frame(minWidth: 320, minHeight: 260, idealHeight: 380)
                        VSplitView {
                            PropertiesPanelView(doc: doc)
                                .frame(minHeight: 260, idealHeight: 420)
                            DebugConsoleView(doc: doc)
                                .frame(minHeight: 100, idealHeight: 120)
                        }
                        .frame(minWidth: 260)
                    }
                    TimelineView(doc: doc)
                        .frame(minHeight: 220, idealHeight: 280)
                    CodeEditorPanel(doc: doc)
                        .frame(minHeight: 100, idealHeight: 140)
                }
            }
            .frame(minWidth: 900, idealWidth: 1600, minHeight: 860, idealHeight: 900)
            .sheet(isPresented: $doc.webExportSheetPresented) {
                WebExportSettingsSheet(doc: doc)
            }
        }
        .windowResizability(.contentSize)
        .commands {
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
        }
    }
}
