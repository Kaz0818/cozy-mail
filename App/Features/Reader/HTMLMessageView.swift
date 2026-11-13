import AppKit
import SwiftUI
import WebKit

/// HTML メールの表示 (SPEC 7)。
///
/// - JavaScript は動かさない (WebView の設定と、`SafeHTML` の Content-Security-Policy の二重で止める)。
/// - Cookie などは残さない (`nonPersistent`)。
/// - リンクはアプリの中では開かず、ふだん使っているブラウザで開く。それ以外の移動 (フォーム送信など) はすべて止める。
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = SafeHTML.document(for: html, allowsRemoteContent: allowsRemoteContent)
        // 同じ中身を読み直すと、スクロール位置が先頭に戻ってしまうので、変わったときだけ読み込む
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedDocument: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            switch navigationAction.navigationType {
            case .linkActivated:
                if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            case .other where navigationAction.targetFrame?.isMainFrame == true
                && ["about", nil].contains(navigationAction.request.url?.scheme?.lowercased()):
                // loadHTMLString による最初の読み込み (about:blank)。外のページへの移動は許さない
                return .allow
            default:
                return .cancel
            }
        }
    }
}
