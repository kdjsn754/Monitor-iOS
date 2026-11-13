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
    /// v2.5.10：顶边那条亮带已经用注入样式的方式按掉了，正常这里永远是空字符串。
    /// 只有哪天它又冒出来（主题改名、规则被覆盖）才写一句「它还在、长什么样」，
    /// 贴在页面底部，截一张图就能定位。
    @State private var probe = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PanelWebView(
                    url: url,
                    progress: $progress,
                    error: $error,
                    probe: $probe,
                    autoLoginUser: autoLoginUser,
                    autoLoginPassword: autoLoginPassword
                )
                // v2.3.6：铺到屏幕最底。原来全屏后 WebView 只到「Home 指示条上沿」，
                // 网页自己的底栏（代理/连接/日志/规则/设置）贴着那条线，下面留一条白带。
                // 底栏是网页画的，不归 SwiftUI 管，所以只能把视口拉满、让它自己贴到底。
                .ignoresSafeArea(.container, edges: .bottom)
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
                // v2.5.10：只有「注入的样式没生效、亮带还在」时才会有内容。平时
                // 这块小字根本不出现，不影响界面上任何东西。
                if !probe.isEmpty {
                    Text(probe)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
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

/// 去掉滚动视图顶边那层系统「边缘薄雾」。
///
/// iOS 26 会给贴边滚动的视图顶部叠一层 10pt 上下的浅色模糊（liquid glass 的边缘效果）。
/// 控制面板里它就表现成导航栏下面多出**一条更亮的横带**。v2.5.6 把网页铺到栏下面时这层雾
/// 被放大到一百多点，更明显。
///
/// 系统的这个视图没有公开 API 可以关，只能在布局时按类名把它找出来隐藏。不引用任何
/// 版本相关的类型：老系统里根本没有这类子视图，找不到就什么也不做。已经隐藏过的不再
/// 重复写，避免 `setNeedsLayout` 打转。
///
/// v2.5.10 实锤：那条 12pt 亮带其实是**网页自己画的**（zashboard 的 `.status-bar-tint`），
/// 不是这层系统雾——所以下面这段留着当保险即可，真正修掉它的是 `cssFixScript`。
private final class EdgeFreeWebView: WKWebView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // 先在自己身上找（这层雾平时挂在滚动视图上）；一个都没找到，再看一眼外面那层
        // 容器——有的系统版本把效果视图放在宿主视图里，不扫就漏。
        if hideEdgeEffects(in: scrollView, depth: 3) == 0, let container = superview {
            hideEdgeEffects(in: container, depth: 2)
        }
    }

    @discardableResult
    private func hideEdgeEffects(in view: UIView, depth: Int) -> Int {
        guard depth >= 0 else { return 0 }
        var hidden = 0
        for sub in view.subviews where !sub.isHidden {
            let name = String(describing: type(of: sub))
            if name.contains("EdgeEffect") || name.contains("ScrollEdge") {
                sub.isHidden = true
                hidden += 1
            } else {
                hidden += hideEdgeEffects(in: sub, depth: depth - 1)
            }
        }
        return hidden
    }
}

private struct PanelWebView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    @Binding var error: String?
    /// v2.5.10：亮带的自检结果（空 = 已经没了，界面上不显示任何东西）。
    @Binding var probe: String
    var autoLoginUser: String?
    var autoLoginPassword: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // v2.5.10：那条 12pt 亮带是 zashboard 的 `.status-bar-tint`——一条
        // `position:fixed; top:0; height:12px; opacity:.12` 的白色薄膜，本来只给
        // Safari/PWA 铺到状态栏下面时染色用。它默认 `display:none`，靠
        // `@supports (-webkit-touch-callout:none)` 才在 iOS 上变成可见，所以别的
        // 平台看是好的，只有手机会多这么一条。
        //
        // 在**文档开始**时就挂一条 `!important` 规则盖掉它，而不是等加载完再删：
        // 那条规则什么时候被应用说不准（v2.5.9 就是等 `didFinish` 去量元素，那会儿
        // 它还是 `display:none`、高度 0，被当成「没有」跳过了，结果一直没修掉）。
        // 样式表按 `!important` 盖，先挂后挂都算数，也不会先闪一下亮带。
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.cssFixScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = EdgeFreeWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 不让 WKWebView 自己再叠一层安全区内边距：SwiftUI 那边已经把视口拉到底，
        // .automatic 会再缩一次，网页底栏就又浮起来、底下重新露出底色（v2.3.6）。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        context.coordinator.webView = webView
        context.coordinator.observe()
        webView.load(URLRequest(url: url))
        return webView
    }

    /// 盖掉 zashboard 那条 12pt「状态栏染色膜」（v2.5.10）。
    ///
    /// 只在文档开始时执行一次：把 `<style id="owmPanelCssFix">` 尽早塞进 `<head>`，
    /// 之后无论那条 `@supports` 规则什么时候生效，`.status-bar-tint` 都被压成
    /// `display:none!important`。文档刚开始时 `<head>` 可能还没建出来，所以先
    /// 试一次、没成就盯住 `documentElement` 的子节点变化再补，补上进就收手。
    static let cssFixScript = #"""
    (function(){
      var CSS = '.status-bar-tint{display:none!important}';
      var ID = 'owmPanelCssFix';
      var obs = null;
      function ensure(){
        var head = document.head || document.documentElement;
        if (!head) return false;
        var el = document.getElementById(ID);
        if (el) {
          if (el.parentNode !== head) head.appendChild(el);
          return true;
        }
        el = document.createElement('style');
        el.id = ID;
        el.textContent = CSS;
        head.appendChild(el);
        return true;
      }
      function boot(){
        if (ensure()) {
          if (obs) { obs.disconnect(); obs = null; }
          return;
        }
        if (!document.documentElement) { setTimeout(boot, 10); return; }
        if (!obs) {
          obs = new MutationObserver(boot);
          obs.observe(document.documentElement, {childList: true, subtree: false});
        }
      }
      boot();
      document.addEventListener('DOMContentLoaded', ensure);
      window.addEventListener('load', ensure);
    })();
    """#

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let progress: Binding<Double>
        private let error: Binding<String?>
        private let probe: Binding<String>
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
            self.probe = parent.$probe
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
            probe.wrappedValue = ""
            progress.wrappedValue = 0.05
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            progress.wrappedValue = 1
            verifyTopBand()
            attemptAutoLogin()
        }

        /// 确认那条亮带真的没了（v2.5.10）。
        ///
        /// 正常情况下 `.status-bar-tint` 已经被 `cssFixScript` 压成 `display:none`，
        /// 这里一个字符都不返回，界面上不会多出任何东西。万一哪天主题改了类名、
        /// 或者有别的样式把它顶回可见，就现场再按一次，并把「它还在、多高、什么
        /// 定位、我们的样式有没有注进去」写进底部小字——只有出问题时才看得到。
        private func verifyTopBand() {
            guard let webView else { return }
            webView.evaluateJavaScript(Self.checkScript) { [weak self] result, _ in
                guard let self, let text = result as? String, !text.isEmpty else { return }
                DispatchQueue.main.async { self.probe.wrappedValue = text }
            }
        }

        /// 只看那条薄膜还在不在。被 `<style>` 压成 `display:none` 就什么也不返回。
        private static let checkScript = #"""
        (function(){
          var els = document.querySelectorAll('.status-bar-tint');
          if (!els.length) return '';
          var out = [];
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var st = getComputedStyle(el);
            if (st.display === 'none' || st.visibility === 'hidden') continue;
            var r = el.getBoundingClientRect();
            out.push('h' + Math.round(r.height) + ' ' + st.position + ' op' + st.opacity);
            el.style.setProperty('display', 'none', 'important');
          }
          if (!out.length) return '';
          var fix = document.getElementById('owmPanelCssFix') ? 'css=ok' : 'css=missing';
          return 'tint 还在 ' + out.join(' / ') + ' ; ' + fix;
        })();
        """#

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
