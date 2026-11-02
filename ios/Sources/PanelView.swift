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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PanelWebView(
                    url: url,
                    progress: $progress,
                    error: $error,
                    autoLoginUser: autoLoginUser,
                    autoLoginPassword: autoLoginPassword
                )
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .panelReload, object: nil)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let panelReload = Notification.Name("OpenWrtPanelReload")
}

private struct PanelWebView: UIViewRepresentable {
    let url: URL
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
        context.coordinator.webView = webView
        context.coordinator.observe()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let progress: Binding<Double>
        private let error: Binding<String?>
        private let autoLoginUser: String?
        private let autoLoginPassword: String?
        weak var webView: WKWebView?
        private var observer: NSObjectProtocol?
        private var autoLoginAttempts = 0

        init(_ parent: PanelWebView) {
            self.progress = parent.$progress
            self.error = parent.$error
            self.autoLoginUser = parent.autoLoginUser
            self.autoLoginPassword = parent.autoLoginPassword
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
        }
    }
}
