import Foundation

enum TemporaryFile {
    /// A fresh, not-yet-existing path under the system temp directory —
    /// callers write to it and are responsible for removing it afterward.
    static func url(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FlajTests-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
