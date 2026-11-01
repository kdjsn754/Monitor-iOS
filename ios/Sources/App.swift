import SwiftUI
import UIKit

@main
@MainActor
struct OpenWrtMonitorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    // v1.28.26：默认值从 "system" 改成 "light"——「跟随系统」选项已删，
    // 新装用户不该落在一个界面上根本不存在的状态上。
    @AppStorage("themeMode") private var themeMode = "light"

    // 连接弹窗：只在“发起连接”时出现，成功后自动收起，失败给重试。
    @State private var popupPhase: ConnectionPhase?
    @State private var connectStartedAt: Date?

    var body: some View {
        ZStack {
            AppBackground()
            Group {
                if model.connected {
                    MainTabs()
                } else {
                    LoginView()
                }
            }
            // 连接弹窗盖着的时候，底下的页面一律不吃点击。
            // 否则能在「正在连接」的弹窗背后把路由器的「…」菜单点开，两个浮层叠在一起。
            .allowsHitTesting(popupPhase == nil
                              && !model.reconnecting
                              && model.activityTitle == nil)
            if let phase = popupPhase {
                ConnectionPopupView(
                    phase: phase,
                    routerTitle: popupTarget?.title ?? "路由器",
                    routerSubtitle: popupTarget?.subtitle ?? "",
                    startedAt: connectStartedAt,
                    onDismiss: { dismissPopup() },
                    onRetry: { retryConnect() },
                    onCancel: { cancelConnect() }
                )
                .zIndex(2)
            }
            if model.reconnecting || model.activityTitle != nil {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.blue)
                        Text(model.reconnecting
                             ? "正在恢复连接"
                             : (model.activityTitle ?? "正在处理"))
                            .font(.headline)
                        Text(model.reconnecting
                             ? "正在重新建立 SSH 会话…"
                             : (model.activitySubtitle ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 230)
                    .padding(.vertical, 22)
                    .glassCard(padding: 0, cornerRadius: 22)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(colorScheme)
        .tint(.blue)
        .animation(.easeInOut(duration: 0.2), value: popupPhase)
        .onAppear { migrateThemeModeIfNeeded() }
        .onChange(of: model.connecting) { _, isConnecting in
            if isConnecting {
                connectStartedAt = Date()
                popupPhase = .connecting
            } else if popupPhase?.isConnecting == true {
                // 先看「这次是否失败」：失败后上一台连接可能已经被恢复（connected 为真），
                // 那就不能按成功来演。
                if model.lastConnectFailed, let message = model.errorMessage {
                    popupPhase = .failed(message)
                } else if model.connected {
                    finishPopup()
                } else {
                    dismissPopup()
                }
            }
        }
        .onChange(of: model.connected) { _, isConnected in
            if isConnected, popupPhase?.isConnecting == true {
                finishPopup()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.resumeAfterForeground() }
            case .background:
                // 退到后台立刻停掉轮询，别让路由器替一个看不见的界面干活。
                model.pausePolling()
            default:
                break
            }
        }
    }

    /// 弹窗上要显示的「这次在连哪一台」。
    /// 失败回滚之后 currentProfile 已经退回上一台，所以优先用这次尝试的目标。
    private var popupTarget: RouterProfile? {
        model.attemptTarget?.profile ?? model.currentProfile
    }

    /// 连上了：先让弹窗停一下显示成功，再自己收起来。
    private func finishPopup() {
        popupPhase = .connected
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if popupPhase?.isConnected == true {
                withAnimation { popupPhase = nil }
            }
        }
    }

    private func dismissPopup() {
        withAnimation { popupPhase = nil }
        connectStartedAt = nil
    }

    /// 用户主动停止：先收弹窗再让 model 收尾，
    /// 这样 connected 回落时不会被上面的 onChange 误判成「连接成功」。
    private func cancelConnect() {
        withAnimation { popupPhase = nil }
        connectStartedAt = nil
        model.cancelConnect()
    }

    private func retryConnect() {
        // 用这次尝试的目标重试。失败回滚后 currentProfile 已经变回上一台，
        // 用它重试会莫名其妙去连另一台路由器。
        guard let target = model.attemptTarget else {
            dismissPopup()
            return
        }
        connectStartedAt = Date()
        popupPhase = .connecting
        Task { await model.connect(profile: target.profile, password: target.password) }
    }

    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        // 理论上到不了这儿：默认值是 "light"，老值在 onAppear 里就被迁移成具体项了。
        // 留 nil（= 跟随系统）只是为了在迁移跑起来之前别把界面强行掰成浅色。
        default: return nil
        }
    }

    /// 「跟随系统」在 v1.28.26 被删掉了，但老用户的 UserDefaults 里还存着 "system"。
    /// 不处理的话会卡在两个坑里：`colorScheme` 返回 nil 让他们永久跟随系统（界面上根本没有这个选项），
    /// 设置页两个胶囊也都不高亮（两个都不等于 "system"）。
    ///
    /// 所以第一次进来时按**当前**系统外观落成 light / dark 并写回，之后系统换外观就不再偷偷跟着变。
    /// 用 `UITraitCollection` 而不是 `@Environment(\.colorScheme)`：这里要的是「本次启动时窗口真实的样子」，
    /// 而环境里的 colorScheme 会被上面那个 `.preferredColorScheme(colorScheme)` 影响，读到的是我们自己的设定。
    private func migrateThemeModeIfNeeded() {
        guard themeMode != "light", themeMode != "dark" else { return }
        themeMode = UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
    }
}

struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = 0

    var body: some View {
        // v2.1.6 起直接用系统原生底栏（iOS 26 自带液态玻璃与形变动画）。
        // 之前的自绘胶囊（AppTabBar 274x62 + TabBarGlass）整套删掉，
        // 想找回旧样子：备份在 E:/WorkBuddyJob/tmp/backup-tabbar-b87。
        // 图标走自绘路径渲染的 UIImage（TabGlyphImage）：未选中空心、选中实心，
        // 和旧自绘底栏同一套图形。b89 用 SF Symbol fill 变体被否了——那是另一套
        // 形状，不是原来的空心→填充。原生 tabItem 只认 Image，所以把旧 TabGlyph
        // 的 Path 画进 UIImage（.alwaysTemplate），颜色交给系统底栏上。
        TabView(selection: $selection) {
            OverviewView()
                .tag(0)
                .tabItem {
                    Label {
                        Text("概览")
                    } icon: {
                        Image(uiImage: TabGlyphImage.image(.overview, selected: selection == 0))
                    }
                }
            ProxyView()
                .tag(1)
                .tabItem {
                    Label {
                        Text("代理")
                    } icon: {
                        Image(uiImage: TabGlyphImage.image(.proxy, selected: selection == 1))
                    }
                }
            SettingsView()
                .tag(2)
                .tabItem {
                    Label {
                        Text("设置")
                    } icon: {
                        Image(uiImage: TabGlyphImage.image(.settings, selected: selection == 2))
                    }
                }
        }
        // 采集跟着页面走：切到哪一页就只采那一页要用的数据，设置页完全不采。
        .onChange(of: selection) { _, value in
            model.setActivePage(AppPage(tab: value))
        }
        .onAppear {
            model.setActivePage(AppPage(tab: selection))
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var label = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var webPort = "80"
    @State private var user = "root"
    @State private var password = ""
    @State private var revealPassword = false
    @State private var didAutoConnect = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case label, host, port, webPort, user, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                credentialsCard
                connectButton

                if let error = model.errorMessage {
                    ErrorBanner(text: error) { model.clearError() }
                }

                Text("请确认路由器已启用 SSH，并允许局域网访问")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 46)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .task {
            guard !didAutoConnect else { return }
            didAutoConnect = true
            LocalNetworkPermission.shared.request()
            if let profile = model.currentProfile {
                label = profile.label
                host = profile.host
                port = String(profile.port)
                webPort = String(profile.webPortValue)
                user = profile.user
                password = KeychainStore.loadPassword(
                    account: KeychainStore.passwordAccount(for: profile)
                ) ?? ""
            }
            await model.autoConnectIfPossible()
        }
    }

    // MARK: - 头部

    /// 图标 + 名字居中，像「登录一个服务」而不是「填一张表单」。
    private var header: some View {
        VStack(spacing: 14) {
            RouterGlyph(size: 42)
                .frame(width: 86, height: 86)
                .softTile(.blue, in: Circle())

            VStack(spacing: 5) {
                Text("OpenWrt 监控")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                Text("SSH 直连 · 数据仅在本机处理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    // MARK: - 表单

    /// 一整张卡片装下全部输入项，行与行之间用缩进分隔线。
    ///
    /// 原来每个输入框头顶都挂一行「路由器地址 / SSH 端口」的小标题，
    /// 五个控件五个标题，纵向被切成五段，视线每填一格就要重新落一次。
    /// 改成「左边标签、右边输入」的一行一项后，标签列是齐的，眼睛只往下扫。
    ///
    /// 标签原来用 `subheadline` + 次要色，在白卡上又小又灰，扫视时要凑近看；
    /// 现在换成 16pt 中等粗细的正常文字色，标签是「项名」不是「提示」。
    private var credentialsCard: some View {
        VStack(spacing: 0) {
            inputRow("名称") {
                TextField("可选，例如 客厅路由器", text: $label)
                    .submitLabel(.next)
                    .focused($focused, equals: .label)
                    .onSubmit { focused = .host }
            }
            formDivider

            inputRow("路由器地址") {
                TextField("192.168.1.1", text: $host)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focused, equals: .host)
                    .onSubmit { focused = .port }
            }
            formDivider

            inputRow("SSH 端口") {
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                    .submitLabel(.next)
                    .focused($focused, equals: .port)
                    .onSubmit { focused = .webPort }
            }
            formDivider

            // 网页后台的端口（LuCI）。和 SSH 端口分开：GL 固件常把 LuCI 挪到 8080，
            // 之前只能在「编辑连接」里改，登录页填完连上之后还打不开网页后台。
            inputRow("网页端口") {
                TextField("80", text: $webPort)
                    .keyboardType(.numberPad)
                    .submitLabel(.next)
                    .focused($focused, equals: .webPort)
                    .onSubmit { focused = .user }
            }
            formDivider

            inputRow("用户名") {
                TextField("root", text: $user)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focused, equals: .user)
                    .onSubmit { focused = .password }
            }
            formDivider

            inputRow("密码") {
                HStack(spacing: 10) {
                    Group {
                        if revealPassword {
                            TextField("路由器 root 密码", text: $password)
                        } else {
                            SecureField("路由器 root 密码", text: $password)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused, equals: .password)
                    .onSubmit { connect() }

                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
                }
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
    }

    /// 一行：左边是固定宽度的标签，右边是右对齐的输入。
    ///
    /// 标签给了 88pt 的固定列宽（最长的「路由器地址」也放得下），
    /// 五个输入框的右边缘因此从同一条线起步；直接 `.fixedSize()` 的话
    /// 「名称」和「路由器地址」两种行里的输入起点会差出三四十 pt。
    private func inputRow<Content: View>(_ title: String,
                                         @ViewBuilder field: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            field()
                .font(.system(size: 16))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// 卡片里的分隔线：从标签列开始，不顶到卡片左右边。
    private var formDivider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    // MARK: - 动作

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                if model.connecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.connecting ? "正在连接…" : "连接路由器")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        // 玻璃按钮自带内边距与高度，这里不再写 frame(height:)，也不再手动压 opacity
        // 表示禁用——`.disabled()` 之后玻璃自己会变灰（见 Glass.swift 的注释）。
        .glassPrimaryButton()
        .controlSize(.large)
        .disabled(model.connecting)
        .padding(.top, 4)
    }

    private func connect() {
        focused = nil
        LocalNetworkPermission.shared.request()
        // 端口留空或乱填都按默认走：SSH 22 / 网页 80。越界值在这里夹掉，
        // 免得写进 profile 之后网页后台拼出一个打不开的 URL。
        let sshPort = min(max(Int(port) ?? 22, 1), 65535)
        let luciPort = min(max(Int(webPort) ?? 80, 1), 65535)
        Task {
            await model.connect(
                host: host,
                port: sshPort,
                user: user.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                webPort: luciPort
            )
        }
    }
}
