import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

extension TimelineDocument {
    func exportGIF() {
        stop()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "Untitled.gif"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                self.performGIFExport(to: url)
            }
        }
    }

    /// Simulates the whole movie synchronously, frame by frame, rendering
    /// and capturing the Stage at each step — this has to replay from frame
    /// 1 rather than jump to arbitrary frames, because playback state
    /// (tweens, script-created objects) is only ever computed forward.
    ///
    /// Internal rather than private so tests can drive it directly against a
    /// known `TimelineDocument`, bypassing the NSSavePanel in `exportGIF()`.
    func performGIFExport(to url: URL) {
        resetRuntime()
        playhead = 1
        stepSimulationFrame()

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, contentLength, nil
        ) else {
            logToConsole("GIF export failed: couldn't create \(url.lastPathComponent)", level: .error)
            return
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
        ] as CFDictionary

        for frame in 1...contentLength {
            if frame > 1 {
                playhead = frame
                stepSimulationFrame()
            }
            if let image = renderStageImage() {
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }

        if CGImageDestinationFinalize(destination) {
            logToConsole("Exported \(contentLength) frames to \(url.lastPathComponent)", level: .log)
        } else {
            logToConsole("GIF export failed to finalize \(url.lastPathComponent)", level: .error)
        }
    }

    private func renderStageImage() -> CGImage? {
        let renderer = ImageRenderer(content: StageContentView(doc: self, scale: 1))
        renderer.scale = 1
        return renderer.cgImage
    }
}
