import SwiftUI
import UIKit

/// 设置页：顶部一张「路由器」卡把当前连接、切换、新建、编辑、网页后台全收进去，
/// 采集频率只留一行摘要，细项进二级页。
struct SettingsView: View {
    @Environment(AppModel.self) private var model: AppModel
    // v1.28.26：默认值从 "system" 改成 "light"——「跟随系统」这个选项已经删了，
    // 新装用户不该落在一个界面上不存在的状态上。老用户的 "system" 由 RootView 迁移。
    @AppStorage("themeMode") private var themeMode = "light"
    @State private var confirmLogout = false
    @State private var editorRoute: ConnectionEditorRoute?
    @State private var showRouterWeb = false
    /// 切换连接的半屏选择器（自绘，不再用系统的列表/菜单）。
    @State private var showSwitcher = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    routerCard
                        // 三个弹窗挂在同一个视图上容易互相抢，网页后台这张挂到卡片上。
                        // fullScreenCover（v2.3.5，用户要求全屏）：和代理页控制面板一致。
                        .fullScreenCover(isPresented: $showRouterWeb) {
                            if let url = model.routerWebURL {
                                PanelView(
                                    url: url,
                                    title: "路由器网页后台",
                                    autoLoginUser: model.currentProfile?.user,
                                    autoLoginPassword: model.currentPassword
                                )
                            }
                        }
                    appearanceCard
                    pollingCard
                    aboutCard
                    dangerCard
                }
                .padding(.horizontal, 16)
                // v2.3.3：标题和刷新钮搬进导航栏（见 `pageChrome`），内容从栏下面开始，
                // 这里 14 让第一张卡回到原来的 117pt。
                .padding(.top, 14)
                .padding(.bottom, 32)
                // 滚动手感（见 ScrollTuning.swift，v2.1.18 起）：保留橡皮筋回弹，
                // 只把「内容不到一屏也允许下拉」关掉——那正是「一下弹回去」的来源。
                // 挂在 VStack 的 background 上，不占布局，父链能直接找到滚动视图。
                .background(ScrollBounceTuning())
            }
            // 和上面那句是同一件事的声明式写法（iOS 16.4+）：内容不足一屏时不回弹。
            .scrollBounceBehavior(.basedOnSize)
            // 顶部「滚动边缘效果」（iOS 26）：内容滚到状态栏下面时由系统糊一层，
            // 标题就不会压在时间和信号上。v2.1.16 曾用 `.scrollEdgeEffectHidden(true, for: .top)`
            // 把它关掉（当时以为它能治下拉跳，其实不能），后果是概览页的「概览」直接叠在 15:41 上。
            // v2.1.19 换回显式 `.soft`：锁定用户截图里那种柔和模糊，别用 automatic（随上下文变）。
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 本页内的控件（开关、进度条）仍然走蓝 tint：底栏为了变黑在 MainTabs 上挂了
            // `.tint(.primary)`，那是往下传的环境值，不补一句本页控件会跟着变黑。
            // ⚠️ 这一句**救不到 sheet / push 出来的页面**（v2.1.17 实测：模块设置、离线设备、
            // 订阅编辑、切换连接那几页的开关照样是黑的），那些页面的开关必须各自显式 `.tint(.blue)`。
            .tint(.blue)
            .background(Color.clear)
            // v2.3.3：同概览页，标题和刷新钮搬进导航栏，导航栏常驻（详见 Glass.swift 的 `pageChrome`）。
            // v2.3.14：刷新钮删掉（用户要求）。这一页没有会过期的数据——连接由轮询维护，
            // 间隔在「刷新频率」卡里改，退出登录是独立按钮；那颗刷新键按下去只是白跑一轮采集。
            .pageChrome("设置")
            .sheet(item: $editorRoute) { route in
                ConnectionEditorView(profile: route.profile)
                    .id(route.id)
            }
            .sheet(isPresented: $showSwitcher) {
                RouterSwitcherSheet()
                    .environment(model)
            }
            .confirmationDialog("退出后需要重新输入密码", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("断开并清除密码", role: .destructive) {
                    Task { await model.logout() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 路由器（当前连接 + 三个动作 + 网页后台）

    /// 参照「图标 + 大标题 + 地址」的卡片版式重排：
    /// 上半部分是当前这台路由器是谁，下面一排三个等宽方块按钮，最后是一条整宽主按钮。
    private var routerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                // 状态不再占标题的宽度：参考图里标题是整行铺开的，
                // 右上角再挂一个「已连接」胶囊会把名字和地址挤成省略号。
                // 改成图标右下角一枚小圆点，颜色即状态。
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.blue.opacity(0.10))
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.blue.opacity(0.22), lineWidth: 1)
                        // 与桌面图标同一枚线稿。58pt 的方块里放 26pt 时，
                        // 因为墨迹只有框高的七成，实际看着只有方块的 1/3 大，
                        // 四周空得发虚；38pt 才填到合适的分量。
                        RouterGlyph(size: 38)
                    }
                    .frame(width: 58, height: 58)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle()
                                .strokeBorder(Color(.secondarySystemGroupedBackground),
                                              lineWidth: 2.5)
                        }
                        .offset(x: 2, y: 2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("路由器，\(statusLabel)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(routerTitle)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(routerSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }

            Divider().opacity(0.5)

            HStack(spacing: 9) {
                actionTile("切换连接", icon: "arrow.left.arrow.right",
                           enabled: !model.profiles.isEmpty) {
                    showSwitcher = true
                }
                actionTile("新建连接", icon: "plus") {
                    openEditor(nil)
                }
                actionTile("编辑连接", icon: "pencil",
                           enabled: model.currentProfile != nil) {
                    openEditor(model.currentProfile ?? model.profiles.first)
                }
            }

            Button {
                showRouterWeb = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .semibold))
                    Text("打开路由器网页后台")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    canOpenWeb ? Color.blue : Color.blue.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(canOpenWeb ? Color.white : Color.secondary)
                .cardTapShape()
            }
            .buttonStyle(.plain)
            .disabled(!canOpenWeb)

            // 错误提示：8 秒自动消失，也能点叉立刻收掉。
            // 以前只在「下一次连接成功」时才清，连不上的红字会一直挂在设置页上，
            // 除非退出 App 重进——这就是截图里那行一直不走的报错。
            if let error = model.errorMessage {
                ErrorBanner(text: error) { model.clearError() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var canOpenWeb: Bool {
        model.routerWebURL != nil
    }

    private var routerTitle: String {
        model.currentProfile?.title ?? "还没有连接"
    }

    /// 参考图那行：`root@192.168.8.1:22 · 网页 :8080`。
    private var routerSubtitle: String {
        guard let profile = model.currentProfile else {
            return "点「新建连接」填地址和密码"
        }
        return "\(profile.user)@\(profile.host):\(profile.port) · 网页 :\(profile.webPortValue)"
    }

    /// 三个等宽方块按钮：图标在上、文字在下。
    ///
    /// 以前中间「新建连接」单独用深一档的蓝底 + 蓝字 + 蓝描边当主按钮，
    /// 结果三块里有一块像另一套控件，摆在一起更像被选中了。现在三块完全同色、
    /// 同高、同描边，主次只靠位置（新建排中间）和文案表达。
    private func actionTile(_ title: String, icon: String,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                // 三个图标的「自带高度」并不一样（arrow.left.arrow.right 比 plus 高约 6pt），
                // 不框住的话三个盒子就一高一矮。这里统一给 20pt 的框，高度就一致了。
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    // 一律用 label 色而不是 .primary：白底上要的是纯黑，
                    // `.primary` 在某些容器里会被降级成一级灰。
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .rowTile(radius: 14)
            .cardTapShape()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    /// 图标角标：正在连新连接时旧会话还在，别让绿点骗人。
    private var statusColor: Color {
        if model.connecting { return .blue }
        return model.connected ? .green : .orange
    }

    private var statusLabel: String {
        if model.connecting { return "正在连接" }
        return model.connected ? "已连接" : model.status
    }

    private func openEditor(_ profile: RouterProfile?) {
        editorRoute = profile.map(ConnectionEditorRoute.edit) ?? .new
    }


    // MARK: - 外观

    private struct ThemeOption: Identifiable {
        let id: String
        let title: String
        let icon: String
    }

    /// v1.28.26 起只剩两项（用户：「把外观跟随系统去掉，浅色跟深色加上太阳月亮图标」）。
    ///
    /// 图标固定用实心版，不做「选中实心 / 未选中空心」那套：
    /// `moon` 的轮廓在 15pt 下是一条细弧，看着像个括号，认不出是月亮；
    /// 统一实心之后形状始终一致，选中与否交给底色和文字颜色区分。
    ///
    /// v2.3.8 换了整颗按钮的做法（用户：「这个风格重新设计看看预览」→ 选了无描边胶囊）：
    /// 以前两颗都描边、未选中那颗还有一圈淡蓝边，看着像「都在待命」，分不清当前值；
    /// 现在**去描边**，只靠底色区分——选中浅蓝底 `blue 14%` + 蓝字，
    /// 未选中系统填充灰 `secondarySystemFill` + 次级灰字。
    /// 灰底用语义色，深色模式自动翻，不用写两套。
    private var themeOptions: [ThemeOption] {
        [ThemeOption(id: "light", title: "浅色", icon: "sun.max.fill"),
         ThemeOption(id: "dark", title: "深色", icon: "moon.fill")]
    }

    private var appearanceCard: some View {
        SectionCard("外观", icon: "circle.lefthalf.filled") {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(themeOptions) { option in
                        Button {
                            themeMode = option.id
                        } label: {
                            Label(option.title, systemImage: option.icon)
                                .font(.subheadline.weight(themeMode == option.id ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    themeMode == option.id
                                        ? Color.blue.opacity(0.14)
                                        : Color(uiColor: .secondarySystemFill),
                                    in: Capsule()
                                )
                                .foregroundStyle(themeMode == option.id ? Color.blue : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().opacity(0.5)

                NavigationLink {
                    ModuleSettingsView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.blue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("概览模块").font(.subheadline)
                            Text("显示或隐藏卡片、拖动排序")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 采集与刷新（摘要，细则进二级页）

    private var pollingCard: some View {
        SectionCard("采集与刷新", icon: "clock.arrow.circlepath") {
            NavigationLink {
                PollSettingsView()
            } label: {
                HStack(spacing: 10) {
                    Text("每 \(Int(model.pollSeconds.rounded())) 秒")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(PollItem.allCases.count) 项数据，只采当前页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // 「设备列表」那张卡（自动清理 / 离线时长 / 已隐藏 + 恢复）v2.0.3 已整张搬出设置页，
    // v2.0.4 起在「连接设备」面板右上角齿轮打开的 OfflineSettingsView 里。

    // MARK: - 关于

    /// 平时只留两行：版本 + 连接方式。
    /// 只有真的跑在「兼容窗口」里（系统按旧尺寸排版、四周留黑边）时，
    /// 才临时多出一行说明——不然用户只能看到黑边，却不知道是打包 SDK 的问题。
    private var aboutCard: some View {
        SectionCard("关于", icon: "info.circle") {
            VStack(spacing: 10) {
                infoRow("版本", appVersion)
                Divider().opacity(0.5)
                infoRow("连接方式", "SSH 直连")
                if let note = compatWindowNote {
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: 4) {
                        infoRow("显示适配", "未铺满", color: .orange)
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(Color(.tertiaryLabel))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("系统按打包用的 SDK 决定窗口档位，用 Xcode 27（iOS 27 SDK）重新打包即可铺满。")
                            .font(.caption2)
                            .foregroundStyle(Color(.tertiaryLabel))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// 版本号从包里读，别在界面上再抄一份——抄的那份早晚和工程文件对不上。
    /// 只显示 1.28.x 这种主版本号。build 号（括号里那串）只对开发者有意义，
    /// 「关于」里挂着反而让人以为要跟着它走。
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// 兼容窗口的判断：逻辑尺寸比「原生像素 ÷ 缩放」小一圈，就是被系统塞进旧尺寸窗口了。
    /// 这时屏幕上下（个别机型还有左右）会留黑边，App 自己铺不出去。
    private var compatWindowNote: String? {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen else { return nil }
        let native = screen.nativeBounds.size
        let physical = CGSize(width: native.width / screen.nativeScale,
                              height: native.height / screen.nativeScale)
        let logical = screen.bounds.size
        guard physical.width - logical.width > 1 || physical.height - logical.height > 1 else {
            return nil
        }
        let sdk = (Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String) ?? "未知 SDK"
        return String(
            format: "界面按 %.0f×%.0f 排版，屏幕是 %.0f×%.0f · 打包 %@",
            logical.width, logical.height, physical.width, physical.height, sdk
        )
    }

    private func infoRow(_ title: String, _ value: String,
                         color: Color = .secondary) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var dangerCard: some View {
        VStack(spacing: 10) {
            Button {
                confirmLogout = true
            } label: {
                Text("断开并清除密码")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            Text("清空后需要重新输入密码才能连接，保存的监控设置不会丢。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }
}

// MARK: - 卡片容器

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    /// 标题行右侧的「小挂件」：状态胶囊、开关之类。
    /// 和 `SheetSectionCard` 一样用 AnyView 装——多加一个泛型参数的话，
    /// 每个已有的调用点都要跟着改签名，而它们都不传这个。
    let accessory: AnyView?
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = nil
        self.content = content()
    }

    init<Trailing: View>(_ title: String, icon: String,
                         @ViewBuilder accessory: () -> Trailing,
                         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                if let accessory { accessory }
            }
            content
        }
        .glassCard()
    }
}

// MARK: - 切换连接

/// 已保存的连接列表。
///
/// v1.28.29 换成和「新建连接」同一套系统表单弹窗：`NavigationStack` + `Form`，
/// 导航栏「关闭」在左、标题居中，列表是原生分组卡 + 缩进分隔线，没有拖动条。
/// （用户：「这三个弹出窗口都改成（新建连接）这种的弹窗」）
///
/// 切换动作从「点整行」改成「行尾开关」——一行只有一枚开关亮着，
/// 打开哪一行就切到哪台（用户：「这两个增加切换按钮」）。
/// **当前那台的开关关不掉**：关掉没有语义，`set` 里直接返回，
/// 取值来源是 `profile.id == currentProfileID`，界面会立刻弹回原样。
private struct RouterSwitcherSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 待删除的连接。非 nil 就浮确认卡（自绘，不用系统 confirmationDialog——
    /// 在 sheet 里弹系统对话框，iOS 26 会把它锚到页面半空）。
    @State private var pendingDelete: RouterProfile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.profiles.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.profiles) { profile in
                            row(profile)
                        }
                    }
                } header: {
                    Text(caption)
                } footer: {
                    Text("打开开关即切换，面板会收起并开始连接；删除会一并清掉钥匙串里存的密码。")
                }
            }
            .navigationTitle("切换连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .navBarTint()
                }
            }
        }
        .overlay { deleteConfirm }
    }

    private var caption: String {
        model.profiles.isEmpty ? "还没有保存过连接" : "共 \(model.profiles.count) 个"
    }

    /// 空状态：白卡里居中的图标 + 两行字，不用单独的组件——
    /// 以前那套 `SheetEmptyState` 自带一张白卡，套进 Form 的行里会双层嵌套。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "router")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("还没有保存过连接")
                .font(.subheadline.weight(.medium))
            Text("回到设置页点「新建连接」，填好路由器地址和密码即可")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func row(_ profile: RouterProfile) -> some View {
        let isCurrent = profile.id == model.currentProfileID
        let isConnecting = model.connecting
            && model.attemptTarget?.profile.id == profile.id

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.blue.opacity(0.16) : Color(.tertiarySystemFill))
                    .frame(width: 34, height: 34)
                // 线稿图标没有实心版，靠颜色区分：当前那台给主色，其余降到次要灰。
                RouterGlyph(size: 22, tint: isCurrent ? Color.blue : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(profile.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isConnecting {
                ProgressView().controlSize(.mini)
            }

            Button {
                pendingDelete = profile
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            // Form 的行里必须 borderless：不指定样式的话，点这一枚会把整行当按钮。
            .buttonStyle(.borderless)
            .accessibilityLabel("删除 \(profile.title)")

            Toggle("", isOn: switchBinding(for: profile))
                .labelsHidden()
                .tint(.blue)
                .accessibilityLabel("切换到 \(profile.title)")
        }
        .padding(.vertical, 4)
    }

    /// 开关的取值只有一个来源：是不是当前连接。
    ///
    /// 不另存一份状态——切换成功后 `currentProfileID` 一变，这一列开关自己就跟着挪。
    /// 关掉（`on == false`）一律忽略：当前那台关掉没有语义，
    /// 别的本来也没亮，弹回去就是最直白的反馈。
    private func switchBinding(for profile: RouterProfile) -> Binding<Bool> {
        Binding {
            profile.id == model.currentProfileID
        } set: { on in
            guard on, profile.id != model.currentProfileID, !model.connecting else { return }
            // 先收起面板，让连接弹窗能盖在最上面。
            dismiss()
            Task { await model.switchTo(profile) }
        }
    }

    /// 删除确认：一层遮罩 + 一张卡片，点遮罩取消。
    @ViewBuilder
    private var deleteConfirm: some View {
        if let profile = pendingDelete {
            SheetOverlay(onDismiss: { pendingDelete = nil }) {
                SheetOverlayCard {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("删除「\(profile.title)」？")
                            .font(.headline)
                            .lineLimit(2)
                        Text(profile.id == model.currentProfileID
                             ? "这是当前正在使用的连接，删除后会立即断开，需要重新填写密码。"
                             : "密码会一起从钥匙串里删除，重新添加时要再输一次。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        SheetOverlayButton(title: "取消") { pendingDelete = nil }
                        SheetOverlayButton(title: "删除连接", tint: .red) {
                            model.deleteProfile(profile)
                            pendingDelete = nil
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 连接编辑

/// 编辑器要打开哪一种：新建，还是编辑某一个已保存的连接。
///
/// 之前用 `showEditor` 布尔 + 单独的 `editProfile` 两个状态驱动 `.sheet(isPresented:)`，
/// 点「编辑」时 sheet 的内容闭包可能拿到还没写入的旧值（nil），于是第一次点开
/// 总是「新建连接」。改成用 item 驱动，数据本身决定弹窗，就不会再错位。
private enum ConnectionEditorRoute: Identifiable {
    case new
    case edit(RouterProfile)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let profile): return profile.id.uuidString
        }
    }

    var profile: RouterProfile? {
        switch self {
        case .new: return nil
        case .edit(let profile): return profile
        }
    }
}

private struct ConnectionEditorView: View {
    let profile: RouterProfile?
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var host: String
    @State private var port: String
    @State private var webPort: String
    @State private var user: String
    @State private var password: String

    init(profile: RouterProfile?) {
        self.profile = profile
        _label = State(initialValue: profile?.label ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: String(profile?.port ?? 22))
        _webPort = State(initialValue: String(profile?.webPortValue ?? 80))
        _user = State(initialValue: profile?.user ?? "root")
        _password = State(initialValue: profile.flatMap {
            KeychainStore.loadPassword(account: KeychainStore.passwordAccount(for: $0))
        } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("连接名称（可选）", text: $label)
                    TextField("路由器地址", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("SSH 端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("网页后台端口（LuCI）", text: $webPort)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $user)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                }

                Section {
                    Button {
                        Task {
                            let sshPort = Int(port) ?? 22
                            let web = Int(webPort) ?? 80
                            if let profile {
                                await model.updateProfile(
                                    profile,
                                    host: host,
                                    port: sshPort,
                                    user: user,
                                    password: password,
                                    label: label,
                                    webPort: web
                                )
                            } else {
                                await model.saveNewProfile(
                                    host: host,
                                    port: sshPort,
                                    user: user,
                                    password: password,
                                    label: label,
                                    webPort: web
                                )
                            }
                            // 连上了就收起表单；失败则留在这里让用户改地址，
                            // 上一台连接已经自动恢复，关掉也不会掉线。
                            if model.connected && !model.lastConnectFailed { dismiss() }
                        }
                    } label: {
                        HStack {
                            if model.connecting { ProgressView() }
                            Text(model.connecting ? "正在连接…" : "连接并保存")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(model.connecting || host.isEmpty || password.isEmpty)
                }

                if let error = model.errorMessage {
                    Section {
                        ErrorBanner(text: error) { model.clearError() }
                    }
                }
            }
            .navigationTitle(profile == nil ? "新建连接" : "编辑连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                }
            }
        }
    }
}
