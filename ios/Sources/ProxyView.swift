import SwiftUI

/// 代理（OpenClash）：功能与旧版一致，只是把信息按
/// 「状态 → 实时状态 → 控制面板 → 配置 → 检查」重排。
/// 流量和内核指标原来是两张卡，v1.28.24 合成一张「实时状态」。
/// 控制面板 v2.0.1 从「状态与操作」卡的下半段拆出来，独立成卡。
struct ProxyView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var showPanel = false
    @State private var showConfigPicker = false
    @State private var showAddSubscription = false
    @State private var isChecking = false
    /// 右上角刷新的进行中标记：只用来把按钮换成转圈、拦住连点，不参与任何数据逻辑。
    @State private var refreshing = false

    private var oc: OpenClashInfo { model.openClash }
    private var metrics: OpenClashMetrics { model.ocMetrics }
    /// 只要确认装着就按运行状态上色；其余情况一律灰色（不能给「没装」和「没读过」配色）。
    private var accent: Color {
        guard oc.installed else { return .gray }
        return oc.running ? .green : .orange
    }

    /// 还在读的时候说「读取中」，读完才敢下「未检测到插件」这种结论。
    private var statusText: String {
        if oc.installed { return oc.running ? "运行中" : "已停止" }
        return model.ocStateLoaded ? "未检测到插件" : "读取中"
    }

    private var statusDetail: String {
        if !oc.installed {
            return model.ocStateLoaded ? "未检测到 OpenClash" : "正在读取 OpenClash 状态…"
        }
        if !oc.running { return "服务已停止，启动后可查看流量" }
        // 面板地址在「控制面板」卡里，这里改说「当前跑的是哪份配置」，
        // 不再重复一遍端口号。
        let name = oc.config.isEmpty ? "" : (oc.config as NSString).lastPathComponent
        return name.isEmpty ? "运行中" : "配置 \(name)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    liveCard
                    // 没装插件就不出现这张卡：它只会给一个必然打不开的入口。
                    if oc.installed { panelCard }
                    configCard
                    accessCard
                }
                .padding(.horizontal, 16)
                // v2.3.3：标题和刷新钮搬进导航栏（见 `pageChrome`），内容从栏下面开始，
                // 这里 14 让第一张卡回到原来的 117pt。
                .padding(.top, 14)
                .padding(.bottom, 28)
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
            // v2.4.4：背景层必须挂在本页的视图树里。以前只挂在 RootView 的 ZStack 最底层，
            // 被原生 TabView / NavigationStack 那层不透明的系统容器整个盖住——图存进去了、
            // 开关也是开的，页面却一点都看不到。挂在这里才在容器之上、卡片之下。
            .background { AppBackground() }
            // v2.3.3：同概览页，标题和刷新钮搬进导航栏，导航栏常驻（详见 Glass.swift 的 `pageChrome`）。
            .pageChrome("代理") {
                // v2.3.14：刷新期间按钮原地换成转圈。以前这里按下去什么都不动——
                // 因为代理页那几项（流量 / 连接数）本来就每 2 秒自己刷，界面看不出变化，
                // 用户的原话是「点了没反应」。
                if refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 38, height: 38)
                } else {
                    HeaderButton("arrow.clockwise") {
                        Task { await refresh() }
                    }
                }
            }
            // 不挂 .refreshable（v2.1.8）：导航栏整条被隐藏之后，系统下拉刷新控件
            // 没有导航栏可以依附，顶部 inset 只能由滚动视图自己估，于是下拉时内容
            // 被推下去约 60pt、松手再弹回，观感就是「页面跳一下」。这一页顶部本来
            // 就有一颗刷新按钮（PageHeader 的 arrow.clockwise），下拉是重复入口。
            // 刷新只在右上角按钮里做。
            // 订阅条数要显示在配置卡的副标题里，进页面就先读一次；
            // 刚连上时状态还没到、上面这一次会直接返回，所以再挂一个 onChange 补读。
            .task { await model.loadSubscriptions(silent: true) }
            .onChange(of: model.ocStateLoaded) { _, loaded in
                guard loaded else { return }
                Task { await model.loadSubscriptions(silent: true) }
            }
            // 控制面板改 fullScreenCover（v2.3.5，用户要求全屏）：WebView 自带导航栏
            // 和「关闭」钮，盖住底栏反而更像「进了面板」；半屏 sheet 会露出底下的页面。
            .fullScreenCover(isPresented: $showPanel) {
                if let url = oc.panelURL {
                    PanelView(url: url)
                }
            }
            // 两个弹窗都改成 push 独立页（v2.1.7）：本页本来就跑在自己的 NavigationStack 里，
            // 弹窗会把底栏整个盖住，也让「返回」多一层圆角卡片的边界感。
            // 目的地必须挂在本 NavigationStack 内部这一层，否则点了没反应（交接 7.1）。
            .navigationDestination(isPresented: $showConfigPicker) {
                ProxyConfigView(configs: oc.configs, applied: oc.config) { name in
                    Task { await model.switchConfig(name); await model.refreshOpenClash() }
                }
            }
            .navigationDestination(isPresented: $showAddSubscription) {
                // 「添加」是独立的一页，不再藏在管理页的右上角：
                // 两件事（看/改已有的、加新的）从入口就分开。
                SubscriptionEditView(subscription: nil)
            }
        }
    }

    // MARK: - 刷新

    /// 右上角刷新：把「连接 → 当前页采集 → OpenClash 状态」整条走一遍。
    ///
    /// v2.3.14 修「点了没反应」：以前这里只调 `model.manualRefresh()`，而它跑的是当前页的
    /// 采集项——代理页那几项（内核指标、连接数）本来就每 2 秒自己刷，所以按下去界面上
    /// **一点变化都看不见**，既没有转圈也没数字跳。三处一起补：
    /// ① 按钮原地换成转圈（`refreshing`），先让人看见「点到了」；
    /// ② 采完再接一次 `refreshOpenClash()`——运行状态、配置文件名、面板端口这些
    ///    **不是周期项**（`PollItem.clashState` 的 `isPeriodic == false`），只有进页面那一次才读，
    ///    手动刷新正好补这一拍，也是最容易看出变化的一处；
    /// ③ `refreshing` 顺手拦掉连点，免得 SSH 串行队列里排满采集任务。
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // 先跑 manualRefresh：状态过期时它内部会强制重连并直接返回，
        // 那时再读 OpenClash 才是新会话上的数据。
        await model.manualRefresh()
        await model.refreshOpenClash()
    }

    // MARK: - 状态、操作与控制面板

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenClash")
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)
                statusPill
            }

            if oc.installed {
                HStack(spacing: 6) {
                    modeButton("规则", value: "rule")
                    modeButton("全局", value: "global")
                    modeButton("直连", value: "direct")
                }
                .disabled(model.busy || !oc.running)
                .opacity(oc.running ? 1 : 0.55)

                HStack(spacing: 8) {
                    actionChip("启动", icon: "play.fill", color: .blue) {
                        await model.startOpenClash()
                    }
                    actionChip("关闭", icon: "stop.fill", color: .red) {
                        await model.stopOpenClash()
                    }
                    actionChip("重启", icon: "arrow.clockwise", color: .blue) {
                        await model.restartOpenClash()
                    }
                }
                .disabled(model.busy)
                .opacity(model.busy ? 0.55 : 1)
            } else if !model.ocStateLoaded {
                // 第一拍还没回来：给一条「正在读取」，别把这块留白，也别急着下结论。
                // 以前这里直接按「没装」渲染，于是进页面先看到一句
                // 「未检测到插件」，几秒后按钮才整排蹦出来。
                loadingRow
            } else {
                Text("确认路由器已安装 OpenClash 插件，且 SSH 账号有权限读取 /etc/config/openclash。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取模式与配置…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .plainTile(radius: 12)
    }

    // MARK: - 控制面板

    /// 控制面板独立成卡，紧跟「实时状态」。
    ///
    /// 它本来自己占一张卡，后来并进「状态与操作」当卡内下半段（理由是两边标题、图标、
    /// 状态几乎是重复的）。并进去之后那张卡同时管三件事——模式切换、启停重启、面板入口，
    /// 上下两半各自带按钮，读起来像两张卡被一条细线粘在一起；而且面板入口和
    /// 「实时状态 / 代理配置 / 访问检查」一样是在回答「东西在哪儿看」，跟启停不是一类动作。
    /// 所以再拆出来：标题行交给 `SectionCard`（`accessory` 挂「可打开 / 未运行」），
    /// 卡里只剩地址和一枚整宽主按钮。
    private var panelCard: some View {
        SectionCard("控制面板", icon: "rectangle.on.rectangle",
                    accessory: { panelBadge }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(panelAddress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // 面板不通时把原因写在这里（v2.3.9，从「实时状态」卡搬过来）：
                // 右上角那枚「未运行」只说结论，这里补一句是端口没响应还是密码不对，
                // 顺带点明页面上的数字为什么停着不动。
                if showsPanelWarning {
                    Label("面板端口 \(oc.panelPort) 无响应，或面板密码不一致，数字停在旧值。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    showPanel = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("打开控制面板")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        canOpenPanel ? Color.blue : Color.blue.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .foregroundStyle(canOpenPanel ? Color.white : Color.secondary)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canOpenPanel)
            }
        }
    }

    /// 右上角那枚徽标：面板这条路现在走到哪一步。
    ///
    /// 四种显示（v2.3.11，用户指定）——「连接中」负责两段等待，「未运行」负责两段确定：
    /// · 状态还没读到 —— 「连接中」（灰点）：还在读，先别说结论；
    /// · 内核没在跑 —— 「未运行」（橙点）：这是确定的事实；
    /// · 在跑、但面板指标第一拍还没回来 —— 「连接中」（灰点）：正在探端口；
    /// · 指标读过、端口也应了 —— 「可打开」（绿点）。
    /// 兜底（在跑、指标也读过、端口就是不应）—— 「未运行」（橙点）。
    ///
    /// 两种「连接中」都只是过渡态，不会停在那儿；灰点而不是橙点，是不想让人误以为已经坏了。
    /// 样式跟上面「状态与操作」卡右边那枚运行中徽标是同一套——小圆点 + 灰字 + 白底胶囊，
    /// 两个徽标在同一条竖线上，看上去是同一类信息。
    @ViewBuilder
    private var panelBadge: some View {
        if !model.ocStateLoaded {
            panelBadgeLabel("连接中", tone: .gray)
        } else if !oc.running {
            panelBadgeLabel("未运行", tone: .orange)
        } else if !model.ocMetricsLoaded {
            panelBadgeLabel("连接中", tone: .gray)
        } else if canOpenPanel, metrics.apiReachable {
            panelBadgeLabel("可打开", tone: .green)
        } else {
            panelBadgeLabel("未运行", tone: .orange)
        }
    }

    /// 和 `statusPill` 同款：圆点表状态 + 灰字。
    ///
    /// v2.3.13：底和边一起去掉（用户「不要底色，不要让它看起来像个按钮」）。
    /// 它只是「一行状态说明」，不是能点的东西；之前套着胶囊，深色下像颗按钮。
    private func panelBadgeLabel(_ title: String, tone: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// 「未运行」底下那句解释，只在「内核在跑、只是面板这条路不通」时给。
    /// 内核本来就停着的话，上面那张状态卡已经写了「已停止」，再解释一遍是重复。
    private var showsPanelWarning: Bool {
        oc.running && model.ocMetricsLoaded && !metrics.apiReachable
    }

    /// 状态徽标：圆点 + 文字，不套底、不套边（v2.3.13，和控制面板那枚同一套）。
    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func modeButton(_ title: String, value: String) -> some View {
        let selected = oc.mode == value
        return Button {
            Task {
                await model.switchMode(value)
                await model.refreshOpenClash()
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.blue.opacity(0.16) : Color.blue.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            selected ? Color.blue.opacity(0.55) : Color.blue.opacity(0.15),
                            lineWidth: 1
                        )
                }
                .foregroundStyle(selected ? Color.blue : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func actionChip(_ title: String, icon: String, color: Color,
                            action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 实时状态（流量 + 内核）

    /// 流量和内核指标以前是上下两张卡（「实时流量」「内核状态」），v1.28.24 合成一张；
    /// v1.28.25 又把它收了一遍，原因是上一版「速率 → 两块累计格 → 2×2 指标格」是
    /// **六块同色小底**：底色一样，选不出主次；而累计那行的箭头和上面下载/上传的箭头
    /// 是同样的符号，等于把方向说了两遍。
    ///
    /// 现在：
    /// · 累计折进速率列——「哪个方向 / 多少速率 / 本次共走多少」竖着读完，箭头只出现一次；
    /// · 六块小底全去掉，改用一横一竖两条 Divider 分格，卡里只剩颜色、没有色块；
    /// · 顺序不换：流量在上，它是这页唯一每 2 秒变一次、真正「会动」的数。
    private var liveCard: some View {
        SectionCard("实时状态", icon: "waveform.path.ecg") {
            VStack(spacing: 0) {
                trafficRow
                    .padding(.bottom, 13)

                Divider()

                statsGrid
                    .padding(.top, 12)

                // v2.3.9：这条提示搬到「控制面板」卡里去了（用户要求）。
                // 它说的是面板那条路通不通，挂在实时状态卡底看着像「这些数字坏了」，
                // 而真正该被质疑的是面板入口——现在那里右上角也直接写「未运行」。
            }
        }
    }

    /// 上半：两列速率，各自下面挂「本次累计」。
    /// 中间那条竖线用 `Divider()`——它自己会撑到两边内容的高度，不用手算线段长度。
    private var trafficRow: some View {
        HStack(spacing: 0) {
            rateColumn("下载", value: formatSpeed(metrics.download),
                       total: formatBytes(Double(metrics.downloadTotal)),
                       icon: "arrow.down.circle.fill", color: .blue)

            Divider()

            rateColumn("上传", value: formatSpeed(metrics.upload),
                       total: formatBytes(Double(metrics.uploadTotal)),
                       icon: "arrow.up.circle.fill", color: .purple)
                .padding(.leading, 14)
        }
    }

    private func rateColumn(_ label: String, value: String, total: String,
                            icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 23, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("累计 \(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 下半：2×2 指标表。格子没有底色，只靠一横一竖两条细线分格，
    /// 高度和重量都比上面的速率低一档——它本来就是「顺带看一眼」的信息。
    private var statsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                statCell("连接数", "\(metrics.connections)",
                         icon: "point.3.connected.trianglepath.dotted", color: .teal)
                Divider()
                statCell("内存", formatBytes(Double(metrics.memory)),
                         icon: "memorychip", color: .indigo)
                    .padding(.leading, 14)
            }
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                // CPU 和概览页的 CPU 圆环用同一个主色蓝，不再用橙——橙色留给温度和告警。
                statCell("CPU", String(format: "%.1f%%", metrics.cpu),
                         icon: "cpu", color: .blue)
                Divider()
                statCell("负载", String(format: "%.1f%%", metrics.load),
                         icon: "speedometer", color: .purple)
                    .padding(.leading, 14)
            }
            .padding(.vertical, 8)
        }
    }

    /// 一格指标：小图标 + 「名称 / 数值」两行，没有底也没有边。
    private func statCell(_ label: String, _ value: String,
                          icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 配置

    /// 以前这一块是「一行标题 + 一个系统的 Menu 胶囊」。Menu 弹的是系统浮层：
    /// 灰底、系统字体、跟界面的圆角卡片完全不是一套，列表长了还得滚动整个系统面板。
    /// 现在改成一张可点的配置条 + 自绘的半屏选择器，全部用同一套卡片/胶囊样式。
    private var configCard: some View {
        SectionCard("代理配置", icon: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                // 上半段：图标 + 三行文字，右侧不再塞按钮，副标题不会再被压。
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前配置文件")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(configTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                        Text(configDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if model.subUsageLoading || !model.ocStateLoaded {
                        // 还没读到配置列表 / 正在拉流量：转圈，别先写一句「未找到」把人劝走。
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        // v2.4.21：这里原本什么都没有，现在放刷新钮——点一次先重读配置
                        // 与订阅列表，再只拉**当前这一条**订阅的流量（不再遍历全部）。
                        Button {
                            Task { await model.refreshCurrentSubscriptionUsage() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.blue.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("刷新订阅信息")
                        .disabled(model.busy)
                    }
                }

                if model.ocStateLoaded { configUsageBlock }

                // 下半段：两个动作并排放到文字下面，各占一半宽，尺寸加大。
                // v2.3.8 起两个统一成「管理」那套浅蓝底 + 蓝字（用户要求），
                // 主次只靠图标和文字区分，不再一个实色一个浅底。
                if model.ocStateLoaded {
                    HStack(spacing: 10) {
                        cardAction("添加", icon: "plus", dimmed: model.busy) {
                            showAddSubscription = true
                        }
                        cardAction("管理", icon: "list.bullet",
                                   dimmed: oc.configs.isEmpty || model.busy) {
                            guard !oc.configs.isEmpty, !model.busy else { return }
                            showConfigPicker = true
                        }
                    }
                }
            }
            .padding(11)
            .plainTile(radius: 14)
        }
    }

    /// 当前配置文件所属订阅的流量与到期（v2.4.21）。
    ///
    /// 数据来自机场响应头 `subscription-userinfo`，只有「配置文件确实由订阅生成」时才有——
    /// 手动丢进 `/etc/openclash/config` 的 yaml 没有订阅可问，这一块就不出现。
    ///
    /// 四种状态都要有交代：
    /// ① 有数据 → 条 + `已用 / 总量（百分比）` + `剩 N 天`；
    /// ② 读取中 → 同高度的空条 + 「正在读取流量…」，读完高度不跳；
    /// ③ 失败 → 橙色一行说明（机场没给这个头 / 没 curl / 超时），提示点右上角重试；
    /// ④ 还没有数据也还没开始读 → 淡色一行「点右上角刷新」。
    @ViewBuilder
    private var configUsageBlock: some View {
        if let sub = model.currentConfigSubscription {
            if let usage = sub.usage {
                VStack(alignment: .leading, spacing: 5) {
                    usageBar(usage)
                    HStack(spacing: 6) {
                        Text(usage.amountText + (usage.percentText.map { "（\($0)）" } ?? ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if let expire = usage.shortExpireText {
                            Text(expire)
                                .font(.caption2)
                                .foregroundStyle(expireColor(usage))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
            } else if model.subUsageLoading {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(height: 5)
                    Text("正在读取流量…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let error = model.subUsageError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("点右上角刷新读取流量")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 配置卡下方的并排操作钮：浅蓝底、蓝字、图标 + 文字，各占一半宽。
    ///
    /// 抽出来是因为两个必须长得一模一样——尺寸、圆角、内边距只在这里定义一次，
    /// 以后调高度也不会漏改一边。
    private func cardAction(_ title: String,
                            icon: String,
                            dimmed: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
    }

    private var configTitle: String {
        guard model.ocStateLoaded else { return "读取中…" }
        guard !oc.config.isEmpty else { return "未选择" }
        return (oc.config as NSString).lastPathComponent
    }

    private var configDetail: String {
        guard model.ocStateLoaded else { return "正在读取配置文件列表" }
        guard !oc.configs.isEmpty else { return "没有可用配置" }
        var text = "\(oc.configs.count) 个配置文件"
        // 订阅也在一起（v2.1.0 并进来的），顺手把条数带上，
        // 否则外面看不出里面还有东西。
        if !model.subscriptions.isEmpty {
            text += " · \(model.subscriptions.count) 个订阅"
        }
        return text
    }

    private var canOpenPanel: Bool {
        oc.running && oc.panelURL != nil
    }

    private var panelAddress: String {
        guard let host = model.currentProfile?.host else { return "未获取到地址" }
        let base = "\(host):\(oc.panelPort)"
        return oc.dashboard.isEmpty ? base : "\(base) · \(oc.dashboard)"
    }

    // MARK: - 访问检查

    private var accessCard: some View {
        SectionCard("访问检查", icon: "globe.asia.australia") {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(lastCheckText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if testedCount > 0 {
                        Text("\(okCount)/\(testedCount) 可达")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(okCount == testedCount ? Color.green : Color.orange)
                    }
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(model.accessChecks) { check in
                        accessTile(check)
                    }
                }

                Button {
                    Task {
                        isChecking = true
                        await model.checkAccess()
                        isChecking = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isChecking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isChecking ? "检测中…" : "重新检测")
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .plainTile(in: Capsule())
                    .foregroundStyle(.blue)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isChecking || model.busy)
            }
        }
    }

    private var testedCount: Int {
        model.accessChecks.filter(\.tested).count
    }

    private var okCount: Int {
        model.accessChecks.filter { $0.tested && $0.success }.count
    }

    private var lastCheckText: String {
        guard let date = model.lastAccessCheckAt else { return "还没有检测结果" }
        return "最近检测 " + Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 一个站点一格：右上角一枚小圆点，颜色就是延迟档位；下面是保留的延迟数值。
    ///
    /// 圆点以前只有「通 = 绿 / 不通 = 红」两档，延迟条又只有 3pt 高、看不出快慢。
    /// 现在把档位直接搬到圆点上（绿 ≤150 / 蓝 ≤400 / 橙 ≤800 / 红更慢或超时），
    /// 数值放大到 17pt 圆体，四格更矮更整齐，也不用再多画一条进度条。
    private func accessTile(_ check: AccessCheck) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(check.site.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                statusDot(check)
            }

            Text(latencyText(check))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(latencyColor(check))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .plainTile(radius: 12)
    }

    /// 小圆点：里面实心 8pt，外面一层同色淡光晕，颜色即延迟档位。
    private func statusDot(_ check: AccessCheck) -> some View {
        let color = dotColor(check)
        return ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 16, height: 16)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .accessibilityLabel(dotLabel(check))
    }

    /// 绿 ≤150ms、蓝 ≤400ms、橙 ≤800ms、红 >800ms 或超时；没测过是灰的。
    private func dotColor(_ check: AccessCheck) -> Color {
        guard check.tested else { return Color(.systemGray3) }
        guard check.success else { return .red }
        if check.latency <= 150 { return .green }
        if check.latency <= 400 { return .blue }
        if check.latency <= 800 { return .orange }
        return .red
    }

    private func dotLabel(_ check: AccessCheck) -> String {
        guard check.tested else { return "还没有检测" }
        return check.success ? "延迟 \(check.latency) 毫秒" : "超时"
    }

    private func latencyText(_ check: AccessCheck) -> String {
        guard check.tested else { return "--" }
        return check.success ? "\(check.latency) ms" : "超时"
    }

    private func latencyColor(_ check: AccessCheck) -> Color {
        guard check.tested else { return .secondary }
        return check.success ? Color.primary : Color.red
    }
}

/// 代理配置页：只管配置文件。
///
/// 演变：v1.28.29 从自绘弹窗换成系统 `Form`；v2.1.0 把订阅并进来做成分段；
/// v2.1.7 把分段固定到导航栏下面、两页用 `TabView(.page)` 左右滑；
/// **v2.1.8 又把订阅整页拆出去**（用户：「订阅移到这个页面的右上角成按钮」）。
/// 现在这一页只有一件事——选一份配置并应用；订阅在右上角的按钮里。
/// 分段、`TabView(.page)`、`Tab` 枚举、`sectionTitle` 全部删掉：拿掉横向分页之后，
/// 页面结构比上一版简单，也不必再为翻页手避让行内手势。
private struct ProxyConfigView: View {
    @State private var configs: [String]
    private let applied: String
    private let onApply: (String) -> Void

    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var picked: String

    init(configs: [String], applied: String, onApply: @escaping (String) -> Void) {
        _configs = State(initialValue: configs)
        self.applied = applied
        self.onApply = onApply
        let initial = configs.contains(applied) ? applied : (configs.first ?? "")
        _picked = State(initialValue: initial)
    }

    var body: some View {
        Form {
            noticeSection
            configSection
            applySection
        }
        // v2.4.6：二级页也吃同一套壁纸 / 透明度。
        .themedFormBackground()
        .listSectionSpacing(.compact)
        .navigationTitle("代理配置")
        .navigationBarTitleDisplayMode(.inline)
        // 代理页把整条导航栏藏了，push 进来的页必须自己显式要回来，
        // 否则会被上层的隐藏状态带下去（交接 7.1）。
        .toolbar(.visible, for: .navigationBar)
        // 不藏底栏（v2.1.16）：藏了再显示，返回时那一闪止不住，见 OverviewView 里的注释。
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 用 NavigationLink 而不是再挂一个 navigationDestination(isPresented:)：
                // 同一层挂两个 destination 有「点一个两个都跳」的隐患（交接 7.1）。
                // 订阅页返回箭头上会写「代理配置」，不需要额外设标题。
                NavigationLink {
                    SubscriptionListView()
                } label: {
                    Text("订阅")
                }
                .navBarTint()
            }
        }
        .task { model.clearNotice() }
    }

    /// 操作结果条：这条结果属于哪一页，就在哪一页出现。
    @ViewBuilder
    private var noticeSection: some View {
        if let notice = model.notice {
            Section {
                NoticeRow(notice: notice)
                    // 结果条自带底色胶囊，行底让开，否则外面又包一层白方板。
                    .clearRowBackground()
            }
        }
    }

    // MARK: - 配置文件

    private var configSection: some View {
        Section {
            ForEach(configs, id: \.self) { name in
                row(name)
                    // v2.4.10：行底逐行挂，`.themedFormBackground()` 里那句不传递。
                    .adaptiveRowBackground()
            }
        } header: {
            Text("当前用 \(appliedName)")
        } footer: {
            Text("切换会重启内核，正在走的连接会断一下。长按一行可删除。")
        }
    }

    // 整宽胶囊放在表单里，形状和「连接并保存」那颗一致；
    // 没得可应用时是灰底灰字（`GlassProminentButtonStyle(dimmed:)`）。
    private var applySection: some View {
        Section {
            Button {
                apply()
            } label: {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(GlassProminentButtonStyle(dimmed: !canApply))
            .disabled(!canApply)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    private func row(_ name: String) -> some View {
        let isApplied = name == liveApplied
        return HStack(spacing: 10) {
            Text(name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            // 「使用中」并到名字右边，所有行都是单行等高。
            if isApplied {
                Text("使用中")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 4)

            // 单选：打开任意一行就把别的关掉，关掉自己则忽略（总得有一份被选中）。
            Toggle("", isOn: Binding {
                picked == name
            } set: { on in
                if on { picked = name }
            })
            .labelsHidden()
            .tint(.blue)
            .accessibilityLabel("选择 \(name)")
        }
        .padding(.vertical, 6)
        // 长按菜单（v2.1.7）：行内左滑删除和「左右滑翻页」抢同一个横向手势，
        // 手指落在行上永远被删除吃掉，翻页只能从空白处起手。改成按住一行出菜单。
        // 配置文件没有编辑页，所以这里给的是「设为使用中」而不是「编辑」。
        .contextMenu {
            if !isApplied {
                Button {
                    picked = name
                } label: {
                    Label("设为使用中", systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive) {
                Task { await remove(name) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 删掉路由器上的这份配置。列表是本页自己的快照，删完得手动摘掉一行，
    /// 否则要退出这一页再进来才看不到它。
    private func remove(_ name: String) async {
        await model.deleteConfigFile(name)
        // 没删成功（权限、网络）时详情条里是红的，这一行就别动。
        guard model.notice?.kind == .ok else { return }
        configs.removeAll { $0 == name }
        if picked == name { picked = configs.first ?? "" }
    }

    /// 实时取「现在跑的是哪份」。`applied` 是打开弹窗那一刻的快照，
    /// 切过或删过之后它就过期了，界面上会出现「使用中」和实际不一致。
    private var liveApplied: String {
        let live = model.currentConfigName
        return live.isEmpty ? applied : live
    }

    private func apply() {
        guard !picked.isEmpty else {
            dismiss()
            return
        }
        onApply(picked)
        dismiss()
    }

    private var appliedName: String {
        liveApplied.isEmpty ? "默认配置" : (liveApplied as NSString).lastPathComponent
    }

    private var canApply: Bool {
        !picked.isEmpty && picked != liveApplied
    }

    private var actionTitle: String {
        canApply ? "应用「\(picked)」" : "已在使用 \(appliedName)"
    }

}

/// 订阅列表页（v2.1.8 从「代理配置」的分段里拆出来）。
///
/// 入口在代理配置页导航栏右上角的「订阅」，这一页右上再放「添加」进编辑页。
/// 订阅存在路由器 UCI 的 `config_subscribe` 段里，这里只做读写与触发更新。
///
/// 删除仍然只在长按菜单里，没有左滑：左滑和系统边缘返回手势同一侧，
/// 误触代价比长按高一档；这一页也不是高频删除的地方。
private struct SubscriptionListView: View {
    @Environment(AppModel.self) private var model: AppModel

    @State private var editing: ProxySubscription?
    @State private var pending: UpdateRequest?

    /// 待确认的一次更新：里面带着「要不要重启内核」。
    struct UpdateRequest: Identifiable {
        let id = UUID()
        let targets: [ProxySubscription]
    }

    var body: some View {
        Form {
            noticeSection
            subscriptionSection
            updateSection
        }
        .themedFormBackground()
        .listSectionSpacing(.compact)
        .navigationTitle("订阅")
        .navigationBarTitleDisplayMode(.inline)
        // 上层都设过 .toolbar(.visible)，这里再写一次是不依赖调用顺序；
        // 底栏同样保持显示（v2.1.16）。
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SubscriptionEditView(subscription: nil)
                } label: {
                    Text("添加")
                }
                .navBarTint()
            }
        }
        .navigationDestination(item: $editing) { sub in
            SubscriptionEditView(subscription: sub)
        }
        .task {
            model.clearNotice()
            await model.loadSubscriptions(silent: true)
            // 列表先出来，流量后补：这一步要挨个打机场接口（并发，最多 8 秒）。
            await model.loadSubscriptionUsages()
        }
        .overlay { confirmLayer }
    }

    /// 操作结果条：这条结果属于哪一页，就在哪一页出现。
    @ViewBuilder
    private var noticeSection: some View {
        if let notice = model.notice {
            Section {
                NoticeRow(notice: notice)
                    // 结果条自带底色胶囊，行底让开，否则外面又包一层白方板。
                    .clearRowBackground()
            }
        }
    }

    // MARK: - 订阅

    private var subscriptionSection: some View {
        Section {
            if model.subscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.subsLoaded ? "还没有订阅" : "正在读取订阅…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if model.subsLoaded {
                        Text("要新建，点右上角「添加」。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .adaptiveRowBackground()
            } else {
                ForEach(model.subscriptions) { sub in
                    subRow(sub)
                        .adaptiveRowBackground()
                }
            }
        } header: {
            Text(model.subsLoaded
                 ? "存在路由器上"
                 : "订阅")
        } footer: {
            Text("点一行编辑，长按可编辑或删除。")
        }
    }

    private func subRow(_ sub: ProxySubscription) -> some View {
        let anyBusy = model.subsBusy != nil
        // 转圈只转正在下的那一条：全部更新是逐条跑的，四条一起转等于看不出进度。
        let rowBusy = model.subsBusy == sub.name
        return HStack(spacing: 10) {
            // 只有名字这一块能点进编辑：整行做成按钮会跟右边的开关抢点击。
            Button {
                editing = sub
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sub.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Color(uiColor: .label))
                    Text(sub.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    usageBlock(for: sub)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Form 行里的自定义按钮必须 borderless：改用默认/plain 样式，
            // 整行都会变成点击区，点开关附近也会跳走（见交接 7.1）。
            .buttonStyle(.borderless)
            // 不用 .disabled：那会把名字压淡成灰，看着像「这条坏了」。
            .allowsHitTesting(!anyBusy)

            if rowBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Toggle("", isOn: Binding {
                    sub.enabled
                } set: { on in
                    Task { await model.setSubscriptionEnabled(sub, on) }
                })
                .labelsHidden()
                .tint(.blue)
                .accessibilityLabel("启用 \(sub.name)")
            }
        }
        .padding(.vertical, 4)
        // 长按菜单：编辑 / 删除。左滑删除已取消（见 configSection 那行的说明）。
        .contextMenu {
            Button {
                editing = sub
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                Task { await model.deleteSubscription(sub) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 流量 / 到期（v2.4.19）

    /// 一行订阅底部的用量块：一条进度 + 一行「已用 / 总量（百分比）」+ 到期。
    ///
    /// 三态：
    /// ① 有数据 → 条 + 文字；
    /// ② 正在读 → 空条 + 「正在读取流量…」，高度和 ① 一样，读完不跳；
    /// ③ 读不到 / 机场不给这个头 → 整块不出现，不留一条 0 B 的假条。
    @ViewBuilder
    private func usageBlock(for sub: ProxySubscription) -> some View {
        if let usage = sub.usage {
            VStack(alignment: .leading, spacing: 5) {
                usageBar(usage)
                    .padding(.top, 3)
                HStack(spacing: 6) {
                    Text(usage.amountText + (usage.percentText.map { "（\($0)）" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    if let expire = usage.expireText {
                        Text(expire)
                            .font(.caption2)
                            .foregroundStyle(expireColor(usage))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
        } else if model.subUsageLoading && sub.id == model.currentConfigSubscription?.id {
            // 只有当前配置那条在拉：其余订阅没有数据就是没有，别一起转圈。
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 5)
                    .padding(.top, 3)
                Text("正在读取流量…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 用量条：宽度按**已用**比例走（和网页后台那张卡一致），不限量时只画一段淡色。
    private func usageBar(_ usage: SubscriptionUsage) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                Capsule()
                    .fill(usageTint(usage))
                    .frame(width: max(4, proxy.size.width * (usage.fraction ?? 0)))
            }
        }
        .frame(height: 5)
    }

    /// 绿 → 橙 → 红：和网页后台的高/中/低三档同一个意思，阈值按已用比例。
    private func usageTint(_ usage: SubscriptionUsage) -> Color {
        guard let fraction = usage.fraction else { return .blue }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .green
    }

    /// 到期时间：一周内变橙，过期变红，其余用次级灰。
    private func expireColor(_ usage: SubscriptionUsage) -> Color {
        guard let left = usage.daysLeft() else { return .secondary }
        if left == 0 { return .red }
        if left <= 7 { return .orange }
        return .secondary
    }

    private var updateSection: some View {
        Section {
            Button {
                startUpdate()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    if model.subsBusy != nil {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.subsBusy == nil ? "全部更新" : "正在更新…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .disabled(model.subsBusy != nil || !model.subscriptions.contains(where: \.enabled))
            .adaptiveRowBackground()
        } footer: {
            Text("下载后转成 Clash 配置，名称就是文件名。")
        }
    }

    private func startUpdate() {
        let targets = model.subscriptions.filter(\.enabled)
        guard !targets.isEmpty, model.subsBusy == nil else { return }
        let active = model.currentConfigName
        if !active.isEmpty, targets.contains(where: { "\($0.name).yaml" == active }) {
            pending = UpdateRequest(targets: targets)
        } else {
            Task { await model.updateSubscriptions(targets) }
        }
    }

    /// sheet 里不能用系统 `alert`：锚点会算错，有时干脆不显示（v1.28.21 踩过）。
    @ViewBuilder
    private var confirmLayer: some View {
        if let request = pending {
            SheetOverlay(onDismiss: { pending = nil }) {
                SheetOverlayCard {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("会重启内核")
                            .font(.headline)
                        Text("正在用的配置在这一批里。更新后会重启 OpenClash，正在走的连接会断一下（约 5 秒）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        SheetOverlayButton(title: "取消") { pending = nil }
                        SheetOverlayButton(title: "仍然更新", tint: .blue) {
                            let targets = request.targets
                            pending = nil
                            Task { await model.updateSubscriptions(targets, restart: true) }
                        }
                    }
                }
            }
        }
    }
}

/// 添加 / 编辑订阅。v2.1.7 起两个入口都是 push 进来的独立页（原来是弹窗），
/// 左上角交给系统返回箭头，不再自绘「取消」。
///
/// 保存写的是一整条 UCI 段（名称、地址、UA、启用），提交后回列表；
/// 下载不在保存时做——「立即更新」与「全部更新」才真正去拉。
private struct SubscriptionEditView: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let subscription: ProxySubscription?

    @State private var name: String
    @State private var address: String
    @State private var ua: String
    @State private var enabled: Bool
    @State private var keywords: String
    @State private var excludeKeywords: String
    @State private var saving = false

    init(subscription: ProxySubscription?) {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
        _address = State(initialValue: subscription?.address ?? "")
        _ua = State(initialValue: subscription?.ua ?? "clash-verge/v2.4.5")
        _enabled = State(initialValue: subscription?.enabled ?? true)
        _keywords = State(initialValue: (subscription?.keywords ?? []).joined(separator: "\n"))
        _excludeKeywords = State(initialValue: (subscription?.excludeKeywords ?? []).joined(separator: "\n"))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("名称")
                        .frame(width: 72, alignment: .leading)
                    TextField("例如 吹雪云", text: $name)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .adaptiveRowBackground()

                VStack(alignment: .leading, spacing: 6) {
                    Text("订阅地址")
                    TextEditor(text: $address)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 76)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if address.isEmpty {
                                Text("一行一个地址")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .adaptiveRowBackground()

                HStack(spacing: 8) {
                    Text("User-Agent")
                        .frame(width: 96, alignment: .leading)
                    TextField("clash-verge/v2.4.5", text: $ua)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .adaptiveRowBackground()
            } header: {
                Text("订阅")
            } footer: {
                Text("一行一个地址。名称会成为配置文件名（如 吹雪云.yaml），不能带引号或斜杠，也不能和已有订阅重名。")
            }

            // 节点筛选：关键词可能写三四行，塞在编辑页里只能看见两行，所以单独一页。
            Section {
                NavigationLink {
                    KeywordEditor(title: "包含关键词",
                                  hint: "命中才保留。留空就是不筛，所有节点都留下。",
                                  placeholder: "每行一个，例如 香港",
                                  text: $keywords)
                } label: {
                    summary("包含关键词", keywords)
                }
                .adaptiveRowBackground()
                NavigationLink {
                    KeywordEditor(title: "排除关键词",
                                  hint: "命中就丢掉。留空就是不排除。",
                                  placeholder: "每行一个，例如 过期",
                                  text: $excludeKeywords)
                } label: {
                    summary("排除关键词", excludeKeywords)
                }
                .adaptiveRowBackground()
            } header: {
                Text("节点筛选")
            } footer: {
                Text("一行一个关键词；用 & 连接表示必须同时包含（新加坡&奈飞）；多行之间是「或」，不区分大小写。"
                     + "筛选发生在路由器下载完之后，所以要重新更新一次订阅才看得到效果。")
            }

            Section {
                Toggle("启用", isOn: $enabled)
                    .tint(.blue)
                    .adaptiveRowBackground()
            } footer: {
                Text("关掉只是不参与「全部更新」，已下载的配置和当前运行状态都不受影响。"
                     + "点右上角「" + (subscription == nil ? "添加" : "保存")
                     + "」后会立刻从路由器下载一次，约 10~30 秒。")
            }

            if subscription != nil {
                Section {
                    Button {
                        Task { await saveAndUpdate(keepOpen: true) }
                    } label: {
                        HStack {
                            Text(model.subsBusy != nil ? "正在从路由器下载…" : "重新下载一次")
                            Spacer()
                            if model.subsBusy != nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    .disabled(model.subsBusy != nil || saving || !canSave)
                    .adaptiveRowBackground()
                } footer: {
                    Text("改完不点右上角也行：这里同样会先保存再下载。约 10~30 秒。")
                }
            }

            if let notice = model.notice {
                Section {
                    NoticeRow(notice: notice)
                        .clearRowBackground()
                }
            }
        }
        .themedFormBackground()
        .navigationTitle(subscription == nil ? "添加订阅" : "编辑订阅")
        .navigationBarTitleDisplayMode(.inline)
        // 与「代理配置」页同样两件事：把被上层藏起来的导航栏要回来（右滑返回才在），
        // 底栏保持显示（v2.1.16）。
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 新添加的那条：这个按钮同时会把配置下载下来，叫「添加」更贴近实际动作。
                Button(subscription == nil ? "添加" : "保存") {
                    Task { await saveAndUpdate(keepOpen: false) }
                }
                .disabled(!canSave || saving || model.subsBusy != nil)
                .navBarTint()
            }
        }
        .onAppear { model.clearNotice() }
    }

    /// 筛选摘要：右侧只给条数，不下拉一长串关键词——那一列太窄，写不下也看不清。
    private func summary(_ title: String, _ text: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(countLabel(text))
                .foregroundStyle(.secondary)
        }
    }

    private func countLabel(_ text: String) -> String {
        let n = keywordLines(text).count
        return n == 0 ? "空" : "\(n) 条"
    }

    // MARK: - 保存

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keywordLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 名称的三个硬条件：非空、不带引号斜杠、不和别的订阅重名。
    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return "名称不能为空" }
        if trimmedName.contains("'") || trimmedName.contains("/") || trimmedName.contains("\\") {
            return "名称不能带引号或斜杠"
        }
        if model.subscriptionNameTaken(trimmedName, excluding: subscription?.id) {
            return "已经有同名订阅"
        }
        return nil
    }

    private var canSave: Bool {
        nameProblem == nil && !trimmedAddress.isEmpty
    }

    /// 保存并立刻重新下载一次。
    ///
    /// 用户定的规矩是「保存后就自动重新下载」，因为筛的是下载下来的节点：
    /// 只写进 UCI 不下载，界面上什么都看不出变化——这正是 v2.1.0「点了没反应」的观感。
    /// 保存成功就关页面回列表（列表里能看到「刚刚更新」）；失败则留在本页，把原因摊在下面。
    private func saveAndUpdate(keepOpen: Bool) async {
        guard canSave, !saving else { return }
        saving = true
        let saved = await model.saveSubscription(
            id: subscription?.id, name: trimmedName, address: trimmedAddress,
            ua: ua, enabled: enabled,
            keywords: keywordLines(keywords), excludeKeywords: keywordLines(excludeKeywords)
        )
        saving = false
        guard let saved else { return }

        // 替换的正是当前在跑的那份：不重启内核等于白更新。
        let isActive = "\(saved.name).yaml" == model.currentConfigName
        await model.updateSubscriptions([saved], restart: isActive)
        // 注意：走到这里订阅已经写进路由器了，红字说的是「下载」这一步没成。
        // 以前保留原样，用户看到「更新失败」就以为整条没加上，于是反复重填。
        if model.notice?.kind == .fail, let current = model.notice {
            model.notice = Notice(
                kind: .fail,
                title: "已保存「\(saved.name)」，但下载失败",
                detail: current.detail + " —— 回列表点「全部更新」可以重试，条目不会丢。"
            )
            return
        }
        if !keepOpen { dismiss() }
    }
}

/// 关键词编辑页：整页一个大输入框，够写、看得清。
private struct KeywordEditor: View {
    let title: String
    let hint: String
    let placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .adaptiveRowBackground()
            } header: {
                Text(title)
            } footer: {
                Text(hint)
            }

            Section {
                Text("新加坡&奈飞")
                    .font(.callout.monospaced())
                    .adaptiveRowBackground()
                Text("名字里同时有这两个词，才保留")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .adaptiveRowBackground()
            } header: {
                Text("写法")
            } footer: {
                Text("多行之间是「或」。改完点返回，再点上一页的「保存」才会写进路由器。")
            }
        }
        .themedFormBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }
}

/// 弹窗里的结果条。不用系统 alert / 横幅：sheet 里锚点会算错，而且它盖不住键盘。
struct NoticeRow: View {
    let notice: Notice

    private var tint: Color {
        switch notice.kind {
        case .ok: return .green
        case .fail: return .red
        case .info: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(notice.title)
                    .font(.footnote.weight(.semibold))
            } icon: {
                Image(systemName: notice.symbol)
                    .font(.footnote)
            }
            .foregroundStyle(tint)

            if !notice.detail.isEmpty {
                Text(notice.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
