import WebKit

/// Loads an exported page into a real WKWebView and lets tests evaluate JS
/// against it — the only way to actually verify `Resources/player.js` runs
/// correctly, since it's plain JS with no Swift-side equivalent to call.
@MainActor
final class WebViewHarness: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        super.init()
        webView.navigationDelegate = self
    }

    func load(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }

    @discardableResult
    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
