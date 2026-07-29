// OPTIONAL — the zero-effort alternative to the native port.
//
// This wraps the finished JavaScript game (hoyo-game.html) in a WKWebView,
// so the app plays the exact same game as the browser version. To use it:
//   1. Drag hoyo-game.html into the Xcode project (check "Copy if needed"
//      and make sure it's added to the app target).
//   2. In HoyoApp.swift, replace `ContentView()` with `WebGameView()`.
//   3. Delete (or just don't reference) the native GameScene files.

import SwiftUI
import WebKit

struct WebGameView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black

        if let url = Bundle.main.url(forResource: "hoyo-game", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
