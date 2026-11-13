import SwiftUI
import WebKit
import Foundation

struct PanelView: View {
    let url: URL
    var title: String = "控制面板"
    var autoLoginUser: String? = nil
    var autoLoginPassword: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var error: String?
    /// 清除网页数据的确认浮层（v2.5.5）。
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            // v2.5.6：网页铺满整屏，改用 contentInset 把网页内容推到玻璃栏下面。
            // 这样导航栏背后是网页自己的背景，白栏那条硬边就没了。
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    PanelWebView(
                        url: url,
                        topInset: proxy.safeAreaInsets.top,
                        progress: $progress,
                        error: $error,
                        autoLoginUser: autoLoginUser,
                        autoLoginPassword: autoLoginPassword
                    )
                    // v2.3.6：铺到屏幕最底。原来全屏后 WebView 只到「Home 指示条上沿」，
                    // 网页自己的底栏（代理/连接/日志/规则/设置）贴着那条线，下面留一条白带。
                    // 底栏是网页画的，不归 SwiftUI 管，所以只能把视口拉满、让它自己贴到底。
                    // v2.5.6：顶边也一起拉满（见上面的 topInset）。
                    .ignoresSafeArea(.container)
                    if progress > 0 && progress < 1 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    }
                    if let error {
                        VStack(spacing: 10) {
                            Text("页面加载失败").font(.headline)
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试") {
                                NotificationCenter.default.post(name: .panelReload, object: nil)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // v2.5.6：栏底色从「不透明白」换成毛玻璃，网页从它底下穿过。
            // 白底在网页灰顶栏上方会切出一条硬边（用户 2026-11-14 指的就是这条线）。
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .navBarTint()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .navBarTint()
                    .accessibilityLabel("清除网页数据")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .panelReload, object: nil)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .navBarTint()
                }
            }
        }
        // v2.5.5：清除网页数据的确认浮层。用自绘的 `SheetOverlay` 而不是系统
        // `confirmationDialog`——iOS 26 会把那个气泡锚到页面顶端，和 FanControl、
        // 设备面板同一个毛病。挂在 NavigationStack 外面，遮罩才会连导航栏一起压暗。
        .overlay {
            if confirmClear {
                SheetOverlay(onDismiss: { confirmClear = false }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("清除网页数据？")
                                .font(.headline)
                            Text("会清掉这个面板的缓存、Cookie 和登录状态，重新载入后需要再登录一次。路由器本身的设置不会受影响。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { confirmClear = false }
                            SheetOverlayButton(title: "清除并重载", tint: .red) {
                                confirmClear = false
                                NotificationCenter.default.post(name: .panelClearData, object: nil)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let panelReload = Notification.Name("OpenWrtPanelReload")
    /// 清空 `WKWebsiteDataStore` 之后重新载入（v2.5.5）。
    static let panelClearData = Notification.Name("OpenWrtPanelClearData")
}

private struct PanelWebView: UIViewRepresentable {
    let url: URL
    /// 导航栏占掉的高度（状态栏 + 栏本身）。
    ///
    /// v2.5.6 起网页铺满整屏，靠这个内边距把网页内容顶到玻璃栏下面：
    /// 栏背后露出的是网页自己的背景，不再有「白栏一刀切」的那条边。
    /// 不能改成把网页硬顶到最上沿——这一页自带「面板 / 地址 / 搜索」那一行，
    /// 会整行躲到状态栏后面，用户就点不到面板切换了。
    var topInset: CGFloat = 0
    @Binding var progress: Double
    @Binding var error: String?
    var autoLoginUser: String?
    var autoLoginPassword: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 不让 WKWebView 自己再叠一层安全区内边距：SwiftUI 那边已经把视口拉到底，
        // .automatic 会再缩一次，网页底栏就又浮起来、底下重新露出底色（v2.3.6）。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // v2.5.6：底色透明，玻璃栏才能透出网页自己的背景。不透明的话栏背后
        // 永远是那块白，换什么材质都还是白的。
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView
        context.coordinator.observe()
        applyTopInset(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        applyTopInset(to: webView)
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    /// 只动 top：底部要留 0，网页自己的底栏才能贴到屏幕最下沿（v2.3.6）。
    ///
    /// 用「网页顶边在窗口里的实际 y」反推该空多少：真铺满了（y≈0）就空一整条栏，
    /// 万一 `ignoresSafeArea` 没生效（y 已经等于栏高），就空 0——这样不会出现
    /// 「栏下面又空一条」的双重留白。两处都靠这个自校正，不靠猜。
    private func applyTopInset(to webView: WKWebView) {
        let originY = webView.window == nil ? 0 : webView.convert(CGPoint.zero, to: nil).y
        let top = max(0, topInset - max(0, originY))
        if abs(webView.scrollView.contentInset.top - top) > 0.5 {
            var inset = webView.scrollView.contentInset
            inset.top = top
            webView.scrollView.contentInset = inset
        }
        if abs(webView.scrollView.verticalScrollIndicatorInsets.top - top) > 0.5 {
            var indicator = webView.scrollView.verticalScrollIndicatorInsets
            indicator.top = top
            webView.scrollView.verticalScrollIndicatorInsets = indicator
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let progress: Binding<Double>
        private let error: Binding<String?>
        private let autoLoginUser: String?
        private let autoLoginPassword: String?
        weak var webView: WKWebView?
        private var observer: NSObjectProtocol?
        private var clearObserver: NSObjectProtocol?
        private var autoLoginAttempts = 0
        /// 首次请求的地址：网页加载失败时 `webView.url` 是 nil，清除后还得有处可回。
        private let initialURL: URL

        init(_ parent: PanelWebView) {
            self.progress = parent.$progress
            self.error = parent.$error
            self.autoLoginUser = parent.autoLoginUser
            self.autoLoginPassword = parent.autoLoginPassword
            self.initialURL = parent.url
        }

        func observe() {
            observer = NotificationCenter.default.addObserver(
                forName: .panelReload, object: nil, queue: .main
            ) { [weak self] _ in
                self?.error.wrappedValue = nil
                guard let self, let webView = self.webView,
                      let url = webView.url else { return }
                webView.load(URLRequest(url: url))
            }
            clearObserver = NotificationCenter.default.addObserver(
                forName: .panelClearData, object: nil, queue: .main
            ) { [weak self] _ in
                self?.clearWebsiteData()
            }
        }

        /// 清空 WebKit 落盘的一切（缓存、Cookie、localStorage、IndexedDB、Service Worker），
        /// 然后跳过缓存重新载入。
        ///
        /// 只删文件不够：`URLRequest` 默认的缓存策略还会让 WebView 直接吃内存里的
        /// 那份 CSS/JS 和登录态，所以重载时显式要求忽略本地缓存，
        /// 相当于一次「硬刷新」。路由器本身的数据一点没动，清掉的只是这台手机上
        /// 关于这个网页的痕迹。
        private func clearWebsiteData() {
            progress.wrappedValue = 0.02
            error.wrappedValue = nil
            autoLoginAttempts = 0
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)

            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, let webView = self.webView else { return }
                    let target = webView.url ?? self.initialURL
                    webView.load(URLRequest(
                        url: target,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 30
                    ))
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            error.wrappedValue = nil
            progress.wrappedValue = 0.05
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            progress.wrappedValue = 1
            attemptAutoLogin()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.error.wrappedValue = error.localizedDescription
            progress.wrappedValue = 0
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.error.wrappedValue = error.localizedDescription
            progress.wrappedValue = 0
        }

        private func attemptAutoLogin() {
            guard let webView,
                  let user = autoLoginUser, !user.isEmpty,
                  let password = autoLoginPassword, !password.isEmpty,
                  autoLoginAttempts < 2 else { return }
            autoLoginAttempts += 1

            let delay = 0.35 * Double(autoLoginAttempts)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
                let script = """
                (function(){
                  var u=document.querySelector('input[name="luci_username"]')||document.querySelector('input[name="username"]');
                  var p=document.querySelector('input[name="luci_password"]')||document.querySelector('input[name="password"]');
                  if(!u||!p||!u.form){return false;}
                  u.value=\(Self.jsString(user));
                  p.value=\(Self.jsString(password));
                  u.form.submit();
                  return true;
                })();
                """
                webView.evaluateJavaScript(script) { result, _ in
                    if (result as? Bool) != true {
                        self.attemptAutoLogin()
                    }
                }
            }
        }

        private static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: [value],
                options: []
            ), let json = String(data: data, encoding: .utf8),
               json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let clearObserver {
                NotificationCenter.default.removeObserver(clearObserver)
            }
        }
    }
}
