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
    /// 概览页 push 出二级页（风扇控制）时把底栏收掉。
    /// 底栏是浮在 TabView 上的 overlay，不收的话会压在「应用到路由器」上面，
    /// 而且一级页的导航栏出现在二级页本来就说不通。
    @State private var hidesTabBar = false

    var body: some View {
        // 系统 TabView 只当作「页面容器」用：它负责保留每一页的滚动位置和弹窗状态，
        // 但底下那条栏由我们自绘（见 AppTabBar），这样才能做到
        // 「选中后图标变实心」—— 系统的 .tabItem 只有一种图，给不了选中态。
        TabView(selection: $selection) {
            OverviewView(hidesTabBar: $hidesTabBar)
                .tag(0)
                .toolbar(.hidden, for: .tabBar)
            ProxyView()
                .tag(1)
                .toolbar(.hidden, for: .tabBar)
            SettingsView()
                .tag(2)
                .toolbar(.hidden, for: .tabBar)
        }
        // 底栏用 overlay 浮在内容之上：滚动时卡片会滑到栏底下被玻璃模糊掉，
        // 既能看到「下面还有内容」又不会被硬切断——这正是液态玻璃想要的效果。
        // 「最后一行不被栏压住」由每一页 ScrollView 自己的 `.safeAreaInset(edge: .bottom)`
        // 留白来保证，不依赖 TabView 的 inset 向下传播（实测部分 iOS 版本上传不进子页，
        // 会导致最底行被盖住，正是之前截图里看到的现象）。
        .overlay(alignment: .bottom) {
            if !hidesTabBar {
                AppTabBar(selection: $selection)
                    .padding(.bottom, AppTabBar.bottomPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hidesTabBar)
        // 采集跟着页面走：切到哪一页就只采那一页要用的数据，设置页完全不采。
        .onChange(of: selection) { _, value in
            model.setActivePage(AppPage(tab: value))
        }
        .onAppear {
            model.setActivePage(AppPage(tab: selection))
        }
    }
}

/// 自绘的底部导航栏。
///
/// 尺寸是按另一款系统级 App 的底栏截图量出来的（402pt 宽的机器上）：
/// 胶囊宽 274、高 62、离屏幕物理底边 21、内边距 4、三格等分；
/// 选中项铺一块 `systemFill` 胶囊，图标换实心、文字加粗——
/// 也就是系统 App 那种「只有一个选中项有底色」的写法，不再给图标上蓝色。
struct AppTabBar: View {    @Binding var selection: Int

    private enum Metrics {
        static let width: CGFloat = 274      // 胶囊总宽
        static let height: CGFloat = 62      // 胶囊总高
        static let inset: CGFloat = 4        // 胶囊内边距（选中胶囊离外框的距离）
        static let icon: CGFloat = 26        // 图标框（墨迹约 23，和系统底栏的图标一样大）
        static let label: CGFloat = 10       // 标签字号
        static let bottomGap: CGFloat = 21   // 栏底到屏幕物理底边
    }

    private let items: [(glyph: TabGlyphKind, title: String)] = [
        (.overview, "概览"),
        (.proxy, "代理"),
        (.settings, "设置")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                itemView(index: index, item: item)
            }
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.width, height: Metrics.height)
        .modifier(TabBarGlass())
        .animation(.easeOut(duration: 0.16), value: selection)
    }

    private func itemView(index: Int, item: (glyph: TabGlyphKind, title: String)) -> some View {
        let isSelected = selection == index
        return Button {
            guard !isSelected else { return }
            selection = index
        } label: {
            VStack(spacing: 4) {
                // 图标和文字都用「具体的黑/白」而不是 `.primary`：玻璃底栏会把
                // 层级色降级渲染，选中项的实心图标曾经因此变成 tertiary 那一档的灰。
                TabGlyph(kind: item.glyph,
                         filled: isSelected,
                         tint: Color(uiColor: .label))
                    .frame(width: Metrics.icon, height: Metrics.icon)
                Text(item.title)
                    .font(.system(size: Metrics.label, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(Color(uiColor: .label))
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.height - Metrics.inset * 2)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color(.systemFill))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TabBarButtonStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

/// 底栏按钮：按下时只轻微缩小，**不变淡**。
///
/// `.plain` 在按下时会把 label 整体压低不透明度，黑色图标于是变成灰的——
/// 底栏图标本来就小，一淡就像「没选中」或「被禁用」，切换的那一下观感很差。
private struct TabBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension AppTabBar {
    /// home indicator 那一截的高度（没有的机型为 0）。
    @MainActor
    private static var safeBottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.bottom ?? 34
    }

    /// 让栏底落在离屏幕物理底边 21pt 的位置。
    ///
    /// 底栏是挂在 TabView 下沿的 overlay 上的，而 TabView 的边界是**安全区**边界
    /// （底部让出了 home indicator 那 34pt）。所以要往下压 34-21=13pt，
    /// 这里算成内边距就是负数；没有 home indicator 的机型（inset 为 0）会自然退回 21。
    @MainActor
    static var bottomPadding: CGFloat {
        Metrics.bottomGap - safeBottomInset
    }

    /// 各页 ScrollView 底部要给底栏留的高度。
    ///
    /// = 栏高 + 栏底到屏幕底的距离 + 6 的一点余量 - 页面自己已经让出的安全区。
    /// 写死 84 的话，栏往下压了 23pt 之后底部会多出一大块空白。
    @MainActor
    static var contentBottomInset: CGFloat {
        Metrics.height + 6 + bottomPadding
    }
}

/// 导航栏的玻璃底：iOS 26 用系统「液态玻璃」(`glassEffect`)，
/// 胶囊会实时把背后的页面渐变、卡片折进玻璃里，滑动时内容滑到栏下会被自然模糊，
/// 既看得到「底下还有东西」，又不会被硬生生切断。
/// 最低版本即 iOS 26，不再为低版本做毛玻璃退回。
struct TabBarGlass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: Capsule(style: .continuous))
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
                        .tint(.white)
                }
                Text(model.connecting ? "正在连接…" : "连接路由器")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(GlassProminentButtonStyle())
        .disabled(model.connecting)
        .opacity(model.connecting ? 0.65 : 1)
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
