import SwiftUI

/// 代理（OpenClash）：功能与旧版一致，只是把信息按
/// 「状态 → 实时状态 → 控制面板 → 配置 → 检查」重排。
/// 流量和内核指标原来是两张卡，v1.28.24 合成一张「实时状态」。
/// 控制面板 v2.0.1 从「状态与操作」卡的下半段拆出来，独立成卡。
struct ProxyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPanel = false
    @State private var showConfigPicker = false
    @State private var isChecking = false

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
                    PageHeader("代理") {
                        HeaderButton("arrow.clockwise") {
                            Task { await model.manualRefresh() }
                        }
                    }
                    heroCard
                    liveCard
                    // 没装插件就不出现这张卡：它只会给一个必然打不开的入口。
                    if oc.installed { panelCard }
                    configCard
                    accessCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Color.clear)
            // 见 OverviewView：标题画在内容里，导航栏整条不要。
            .toolbar(.hidden, for: .navigationBar)
            // 给底栏留白（见 App.swift 的 overlay 说明），最后一行不被玻璃栏遮住。
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: AppTabBar.contentBottomInset)
            }
            .refreshable {
                await model.manualRefresh()
            }
            // 订阅条数要显示在配置卡的副标题里，进页面就先读一次；
            // 刚连上时状态还没到、上面这一次会直接返回，所以再挂一个 onChange 补读。
            .task { await model.loadSubscriptions(silent: true) }
            .onChange(of: model.ocStateLoaded) { _, loaded in
                guard loaded else { return }
                Task { await model.loadSubscriptions(silent: true) }
            }
            .sheet(isPresented: $showPanel) {
                if let url = oc.panelURL {
                    PanelView(url: url)
                }
            }
            .sheet(isPresented: $showConfigPicker) {
                ProxyConfigSheet(configs: oc.configs, applied: oc.config) { name in
                    Task { await model.switchConfig(name); await model.refreshOpenClash() }
                }
                // sheet 不一定继承 EnvironmentObject：显式再注入一次，避免运行时崩。
                .environmentObject(model)
            }
        }
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
    /// 所以再拆出来：标题行交给 `SectionCard`（`accessory` 挂「可打开 / 未就绪」），
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

    private var panelBadge: some View {
        Text(canOpenPanel ? "可打开" : "未就绪")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (canOpenPanel ? Color.green : Color.orange).opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(canOpenPanel ? Color.green : Color.orange)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .plainTile(in: Capsule())
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

                // 这条橙字挂在卡底：它说的是整条内核接口（端口 / 面板密码），
                // 流量和下面四项一起受影响，塞到任何一半下面都只说对一半。
                if oc.running, !metrics.apiReachable {
                    Label("读不到内核接口：端口 \(oc.panelPort) 无响应，或控制面板密码不一致。数字会停在上一次的值。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
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
            VStack(spacing: 10) {
                Button {
                    guard !oc.configs.isEmpty, !model.busy else { return }
                    showConfigPicker = true
                } label: {
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

                        if !model.ocStateLoaded {
                            // 还没读到配置列表：转圈，别先写一句「未找到」把人劝走。
                            ProgressView()
                                .controlSize(.mini)
                        } else if oc.configs.isEmpty {
                            Text("未找到")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Text("管理")
                                    .font(.caption.weight(.medium))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.blue)
                        }
                    }
                    .padding(11)
                    .plainTile(radius: 14)
                    .cardTapShape()
                }
                .buttonStyle(.plain)
                .disabled(oc.configs.isEmpty || model.busy)
            }
        }
    }

    private var configTitle: String {
        guard model.ocStateLoaded else { return "读取中…" }
        guard !oc.config.isEmpty else { return "未选择" }
        return (oc.config as NSString).lastPathComponent
    }

    private var configDetail: String {
        guard model.ocStateLoaded else { return "正在读取配置文件列表" }
        guard !oc.configs.isEmpty else { return "没有可用配置" }
        var text = "共 \(oc.configs.count) 个配置文件"
        // 订阅也在这个弹窗里（v2.1.0 并进来的），顺手把条数带上，
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

/// 配置文件 + 订阅 弹窗。
///
/// v1.28.29 把这里换成和「新建连接」同一套系统表单弹窗：`NavigationStack` + `Form`，
/// 「关闭」在导航栏左上、标题居中，列表是原生分组卡与缩进分隔线。
///
/// v2.1.0 把「订阅」并进来（用户选了 C 方案）：顶部一段分段控件，
/// **不新增入口、不多一层 sheet**；点订阅进编辑页是同一条栈里的 push。
/// 订阅本身存在路由器 UCI 的 `config_subscribe` 段里，这里只做读写与触发更新。
private struct ProxyConfigSheet: View {
    let configs: [String]
    let applied: String
    let onApply: (String) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .configs
    @State private var picked: String
    @State private var editing: ProxySubscription?
    @State private var adding = false
    @State private var pending: UpdateRequest?

    enum Tab: String, CaseIterable, Identifiable {
        case configs = "配置文件"
        case subs = "订阅"
        var id: String { rawValue }
    }

    /// 待确认的一次更新：里面带着「要不要重启内核」。
    struct UpdateRequest: Identifiable {
        let id = UUID()
        let targets: [ProxySubscription]
    }

    init(configs: [String], applied: String, onApply: @escaping (String) -> Void) {
        self.configs = configs
        self.applied = applied
        self.onApply = onApply
        let initial = configs.contains(applied) ? applied : (configs.first ?? "")
        _picked = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { item in
                            Text(sectionTitle(item)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if tab == .configs {
                    configSection
                    applySection
                } else {
                    subscriptionSection
                    updateSection
                }
            }
            .navigationTitle("代理配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if tab == .subs {
                        Button {
                            adding = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加订阅")
                    }
                }
            }
            .navigationDestination(isPresented: $adding) {
                SubscriptionEditView(subscription: nil)
            }
            .navigationDestination(item: $editing) { sub in
                SubscriptionEditView(subscription: sub)
            }
            .task { await model.loadSubscriptions(silent: true) }
        }
        .overlay { confirmLayer }
    }

    private func sectionTitle(_ item: Tab) -> String {
        switch item {
        case .configs: return "配置文件 \(configs.count)"
        case .subs: return "订阅 \(model.subscriptions.count)"
        }
    }

    // MARK: - 配置文件

    private var configSection: some View {
        Section {
            ForEach(configs, id: \.self) { name in
                row(name)
            }
        } header: {
            Text("共 \(configs.count) 个 · 当前用 \(appliedName)")
        } footer: {
            Text("打开开关只是选中，点下方按钮才会真正切换。切换后 OpenClash 会重启内核，正在走的连接会断一下。")
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
        let isApplied = name == applied
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
            .accessibilityLabel("选择 \(name)")
        }
        .padding(.vertical, 6)
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
        applied.isEmpty ? "默认配置" : (applied as NSString).lastPathComponent
    }

    private var canApply: Bool {
        !picked.isEmpty && picked != applied
    }

    private var actionTitle: String {
        canApply ? "应用「\(picked)」" : "已在使用 \(appliedName)"
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
                        Text("点右上角 + 添加一条（名称 + 订阅地址）。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                ForEach(model.subscriptions) { sub in
                    subRow(sub)
                }
            }
        } header: {
            Text(model.subsLoaded
                 ? "\(model.subscriptions.count) 个订阅 · 存在路由器上"
                 : "订阅")
        } footer: {
            Text("点一行可编辑，左滑删除。开关只表示允许它参与「全部更新」，不动当前正在跑的配置。")
        }
    }

    private func subRow(_ sub: ProxySubscription) -> some View {
        let busy = model.subsBusy != nil
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Form 行里的自定义按钮必须 borderless：改用默认/plain 样式，
            // 整行都会变成点击区，点开关附近也会跳走（见交接 7.1）。
            .buttonStyle(.borderless)
            // 不用 .disabled：那会把名字压淡成灰，看着像「这条坏了」。
            .allowsHitTesting(!busy)

            if busy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Toggle("", isOn: Binding {
                    sub.enabled
                } set: { on in
                    Task { await model.setSubscriptionEnabled(sub, on) }
                })
                .labelsHidden()
                .accessibilityLabel("启用 \(sub.name)")
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.deleteSubscription(sub) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
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
        } footer: {
            Text("订阅由路由器上的 OpenClash 下载并转成 Clash 配置，名称就是文件名（如 吹雪云.yaml）。")
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

/// 添加 / 编辑订阅。和列表同在弹窗的导航栈里，push 进来，不另开 sheet。
///
/// 保存写的是一整条 UCI 段（名称、地址、UA、启用），提交后回列表；
/// 下载不在保存时做——「立即更新」与「全部更新」才真正去拉。
private struct SubscriptionEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let subscription: ProxySubscription?

    @State private var name: String
    @State private var address: String
    @State private var ua: String
    @State private var enabled: Bool
    @State private var saving = false

    init(subscription: ProxySubscription?) {
        self.subscription = subscription
        _name = State(initialValue: subscription?.name ?? "")
        _address = State(initialValue: subscription?.address ?? "")
        _ua = State(initialValue: subscription?.ua ?? "clash-verge/v2.4.5")
        _enabled = State(initialValue: subscription?.enabled ?? true)
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

                HStack(spacing: 8) {
                    Text("User-Agent")
                        .frame(width: 96, alignment: .leading)
                    TextField("clash-verge/v2.4.5", text: $ua)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("订阅")
            } footer: {
                Text("一行一个地址。名称会成为配置文件名（如 吹雪云.yaml），不能带引号或斜杠，也不能和已有订阅重名。")
            }

            Section {
                Toggle("启用", isOn: $enabled)
            } footer: {
                Text("关掉只是不参与「全部更新」，已下载的配置和当前运行状态都不受影响。")
            }

            if subscription != nil {
                Section {
                    Button {
                        Task { await saveThenUpdate() }
                    } label: {
                        HStack {
                            Text("立即更新这个订阅")
                            Spacer()
                            if model.subsBusy != nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    .disabled(model.subsBusy != nil || (!canSave && edited))
                } footer: {
                    Text("先保存再下载：从路由器上拉取并转成 Clash 配置，约 10~30 秒。")
                }
            }
        }
        .navigationTitle(subscription == nil ? "添加订阅" : "编辑订阅")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task { await save() }
                }
                .disabled(!canSave || saving)
            }
        }
    }

    // MARK: - 保存

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var edited: Bool {
        guard let subscription else { return true }
        return trimmedName != subscription.name || trimmedAddress != subscription.address
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

    @discardableResult
    private func save(keepOpen: Bool = false) async -> Bool {
        guard canSave, !saving else { return false }
        saving = true
        let ok = await model.saveSubscription(id: subscription?.id, name: trimmedName,
                                              address: trimmedAddress, ua: ua, enabled: enabled)
        saving = false
        if ok && !keepOpen { dismiss() }
        return ok
    }

    /// 「立即更新」用改完的值：先落盘，再从列表里取回这一条（拿到新名字/新地址）再去下载。
    private func saveThenUpdate() async {
        let id = subscription?.id
        guard await save(keepOpen: true) else { return }
        guard let id, let fresh = model.subscriptions.first(where: { $0.id == id }) else { return }
        await model.updateSubscriptions([fresh])
    }
}
