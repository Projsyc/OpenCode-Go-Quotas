import SwiftUI
import WebKit

/// 轻量 WKWebView 封装:暴露 webView 给父视图配置导航代理;
/// 会话使用独立的 `nonPersistent()` 存储(隔离,登录结束后可全清,不留痕)。
struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView

    /// 独立非持久会话配置:不共享主会话的任何 Cookie/缓存
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        return config
    }

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
