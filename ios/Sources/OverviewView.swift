import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model: AppModel
    /// 闪存卡的轨道色 / 图例点色要分深浅两档，所以这一页也得读主题。
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAllDevices = false
    /// 风扇控制页（点「风扇」那块打开，见 hardwareSection）。
    /// v1.28.28 起是 push 进来的独立页面，不再是半屏面板。
    @State private var showFanControl = false
    /// 手动刷新的进行中标记。只用来把右上角按钮换成转圈 + 拦住连点，
    /// 不参与数据逻辑（数据真伪一律以 model 为准）。
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // 这里原来是 LazyVStack。卡片一共就 7 张，懒加载省不下什么，
                // 但滑到底部继续往上拖时，LazyVStack 会按估算高度补内容、松手再按真实高度
                // 收回，于是「松手跳一下」。换成 VStack 后高度一次算清，不会再跳。
                VStack(spacing: 14) {
                    header
                    ForEach(model.visibleModules) { module in
                        moduleView(module)
                    }
                }
                .padding(.horizontal, 16)
                // v2.3.3：标题和刷新钮搬进导航栏（见 `pageChrome`），内容从栏下面开始。
                // 原来标题在内容里占到 103pt、第一张卡在 117pt，这里 14 把它顶回原处。
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
            // v2.3.3：标题和刷新钮搬进导航栏，**导航栏必须一直显示**——
            // 根页和二级页的顶部安全区一样大，push/pop 才没有可变的量（详见 Glass.swift 的 `pageChrome`）。
            .pageChrome("概览") {
                // 刷新期间按钮原地换成转圈（尺寸不变，避免标题行左右跳），
                // 同时拦掉连点——连点会让 SSH 串行队列里排满采集任务，
                // 表现就是「点了好几下才动一下」。
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
            // 这里曾经有 `.refreshable`（下拉刷新），v2.1.13 删掉。
            // 和代理页 v2.1.8 同一个根因：导航栏被 `.toolbar(.hidden)` 藏掉之后，
            // 系统的刷新控件没有导航栏可依附，顶部 inset 只能自己估——下拉时整页内容
            // 被推下去约 60pt、松手再弹回，手感就是「卡住又跳一下」。
            // 更糟的是它一下拉就触发一整轮 SSH 采集（`/traffic` 是流式接口，至少一秒才吐第一行），
            // 采集回来又是一次全页重排，正好撞在手指还在拖的那几帧上。
            // 刷新入口保留在导航栏右上角那颗按钮（v2.3.3 起由 `pageChrome` 挂上去），功能不缺。
            .sheet(isPresented: $showAllDevices) {
                DeviceListView()
                    // v2.4.6：sheet 的系统材质底换成清底，壁纸由页内的
                    // `themedFormBackground()` 自己铺，二级页也照得到。
                    .presentationBackground(Color.clear)
            }
            .navigationDestination(isPresented: $showFanControl) {
                // v2.1.16 起二级页**不再** `.toolbar(.hidden, for: .tabBar)`。
                // 之前藏掉底栏，返回时系统要把它重新显示，那一下动画在 iOS 26 的玻璃底栏上
                // 看着就是「闪出来」。让底栏一直存在，就没有出现动画可闪了。
                // 内容不会被压住：滚动视图会自动让出底栏的安全区（以前那句注释是误判）。
                FanControlView()
            }
        }
    }

    /// 右上角刷新按钮的动作：只负责「转圈 + 防连点」。
    /// 采集逻辑全在 `model.manualRefresh()` 里，别在这儿另开一条采集路径。
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await model.manualRefresh()
        refreshing = false
    }

    private var header: some View {
        HStack(spacing: 12) {
            // 这枚线稿的墨迹占满方框宽度、高度只有 70%，所以 28 画出来实际只有 20 高，
            // 比右边两行文字矮一截，看着像「贴上去的小图标」。36 才和两行文字等高。
            RouterGlyph(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.routerInfo.model.isEmpty ? "OpenWrt" : model.routerInfo.model)
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(model.connected ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // v2.3.14：这里原来还会跟一段「· apclii0」（WAN 设备名）。
                    // 用户要删掉：这行是「连上没有」的结论，后面挂个网口名既不是给
                    // 普通人看的，也让这行字变得比路由器型号还长。
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func moduleView(_ module: OverviewModule) -> some View {
        switch module {
        case .speed:
            moduleCard(module) { speedContent }
        case .hardware:
            moduleCard(module) { hardwareContent }
        case .flash:
            moduleCard(module) { flashContent }
        case .devices:
            moduleCard(module) { devicesContent }
        case .system:
            moduleCard(module) { systemContent }
        }
    }

    private func moduleCard<Content: View>(
        _ module: OverviewModule,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(module.title, systemImage: module.icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var speedContent: some View {
        VStack(spacing: 10) {
            HStack {
                speedValue("下载", value: formatSpeed(model.stats.download),
                           color: .blue, icon: "arrow.down.circle.fill")
                Divider().frame(height: 34)
                speedValue("上传", value: formatSpeed(model.stats.upload),
                           color: .purple, icon: "arrow.up.circle.fill")
            }
            SpeedSparkline(points: model.history)
            HStack {
                Text("本次会话 ↓ \(formatBytes(model.stats.sessionDownload))")
                Spacer()
                Text("↑ \(formatBytes(model.stats.sessionUpload))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func speedValue(_ label: String, value: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flashContent: some View {
        let info = model.flashInfo
        return Group {
            if info.hasData {
                VStack(alignment: .leading, spacing: 12) {
                    // 和 CPU / 内存同一套圆环：中间是已用百分比，
                    // 右边只留「已用 / 剩余」两个数字加总容量，
                    // 不再把闪存拆成系统、应用、可用三段去讲。
                    HStack(alignment: .center, spacing: 16) {
                        RingGauge(
                            percent: info.usedFraction * 100,
                            accent: flashTone(info.usedFraction),
                            diameter: 98,
                            caption: "已用",
                            lineWidth: 11,
                            track: flashTrack
                        )

                        VStack(spacing: 11) {
                            flashRow("已用", bytes: info.usedBytes,
                                     color: flashTone(info.usedFraction))
                            flashRow("剩余", bytes: info.available,
                                     color: flashTrackDot)
                            Divider().opacity(0.5)
                            HStack(spacing: 6) {
                                Text("总容量")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Text(formatFlashBytes(info.total))
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                            }
                        }
                    }

                    if info.usedFraction >= 0.9 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(info.usedFraction >= 0.97
                                 ? "闪存已接近写满，建议清理日志或卸载不用的插件"
                                 : "闪存空间偏紧，建议清理日志或卸载不用的插件")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(flashTone(info.usedFraction))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("正在读取闪存信息…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    /// 闪存的一行：色点 → 名称 → 容量数字。
    ///
    /// v1.28.30 起「剩余」不再画空心圈：圆环剩下的那一段是实打实的一块灰，
    /// 图例却是灰色空心圈，两处各画各的（用户：「剩余颜色跟剩余的图例对不上」）。
    /// 现在圆环轨道和这个点共用同一族灰，只按面积差一档（见 flashTrack / flashTrackDot）。
    private func flashRow(_ title: String, bytes: UInt64, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Text(formatFlashBytes(bytes))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 闪存圆环的轨道：中性灰。
    ///
    /// 它同时是「剩余」的那一段，所以必须和图例的灰点对上；
    /// CPU / 内存那两个环没有图例要对应，轨道继续跟着主色走（RingGauge 里 track 传 nil）。
    private var flashTrack: Color {
        colorScheme == .dark ? Color(.systemGray4) : Color(.systemGray5)
    }

    /// 「剩余」的色点：比轨道深一档。
    /// 8pt 的小圆点面积只有轨道的一小截，用轨道的颜色会淡到看不见，
    /// 这是缩小面积后的视觉补偿，不是另起一套颜色。
    private var flashTrackDot: Color {
        colorScheme == .dark ? Color(.systemGray3) : Color(.systemGray4)
    }

    /// 占用低于 90% 用蓝色，90% 起转橙，97% 起转红——和进度条、百分比同一套颜色。
    private func flashTone(_ used: Double) -> Color {
        if used >= 0.97 { return .red }
        if used >= 0.90 { return .orange }
        return .blue
    }

    /// 硬件状态的「两块」：上一排是 CPU 和内存的圆环，
    /// 下一排是温度和风扇的读数格——CPU / 内存本来就是同一块板子上的硬件，
    /// 分成两张卡反而要多一次标题和一圈留白。
    /// 圆环放上面：它是这组里读数最重的两块，第一眼先看到占用率；
    /// 温度和风扇更像「环境量」，压在一排小格子里刚好。
    private var hardwareContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HardwareGauge(
                    title: "CPU",
                    icon: "cpu",
                    // 以前是橙色，和「温度 · 温热」那一档（55~70°C）撞色：
                    // 同一张卡里两块橙，看着像同一个指标。CPU 用主色蓝，
                    // 温度那三档（青/橙/红）就只剩温度自己在用。
                    accent: .blue,
                    percent: model.stats.cpu,
                    note: model.routerInfo.cpuCores > 0
                        ? "\(model.routerInfo.cpuCores) 核" : "-- 核",
                    detail: String(
                        format: "负载 %.2f / %.2f / %.2f",
                        model.stats.load,
                        model.stats.load5,
                        model.stats.load15
                    )
                )
                HardwareGauge(
                    title: "内存",
                    icon: "memorychip",
                    accent: .indigo,
                    percent: model.memoryFraction * 100,
                    note: "可用 \(formatBytes(Double(max(0, model.stats.memoryTotal - model.stats.memoryUsed))))",
                    detail: "\(formatBytes(Double(model.stats.memoryUsed))) / \(formatBytes(Double(model.stats.memoryTotal)))"
                )
            }

            HStack(spacing: 12) {
                hardwareTile(
                    icon: temperatureIcon,
                    title: "温度",
                    value: model.stats.temperature.map { String(format: "%.1f °C", $0) } ?? "无传感器",
                    color: temperatureTone,
                    badge: temperatureBadge
                )
                // 风扇这张可以点开控制面板（gl-fanctrl）。图标静态，不再跟着转速旋转：
                // 一块指甲盖大的图标每秒转半圈，除了抢滚动帧、让眼睛一直瞟到它，
                // 并没有多给出任何信息——转速本来就已经写在旁边了。
                Button {
                    showFanControl = true
                } label: {
                    hardwareTile(
                        icon: "fanblades",
                        title: "风扇",
                        value: model.stats.fanRPM.map { String(format: "%.0f RPM", $0) } ?? "无传感器",
                        color: fanTone,
                        badge: fanBadge,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("风扇 \(model.stats.fanRPM.map { String(format: "%.0f 转", $0) } ?? "无传感器")，点按调整")
            }
        }
    }

    // 温度计图标跟着读数走（低/中/高三档），风扇只换颜色：一眼能看出「凉/热」「静止/高速」，
    // 不用先读数字。

    private var temperatureIcon: String {
        guard let t = model.stats.temperature else { return "thermometer.medium" }
        if t >= 70 { return "thermometer.high" }
        if t <= 40 { return "thermometer.low" }
        return "thermometer.medium"
    }

    private var temperatureTone: Color {
        guard let t = model.stats.temperature else { return Color(.systemGray) }
        if t >= 70 { return .red }
        if t >= 55 { return .orange }
        return .teal
    }

    private var temperatureBadge: String? {
        guard let t = model.stats.temperature else { return nil }
        if t >= 70 { return "偏高" }
        if t >= 55 { return "温热" }
        return nil
    }

    private var fanTone: Color {
        guard let rpm = model.stats.fanRPM, rpm > 0 else { return Color(.systemGray) }
        if rpm >= 2400 { return .orange }
        if rpm >= 1200 { return .teal }
        return .mint
    }

    private var fanBadge: String? {
        guard let rpm = model.stats.fanRPM else { return nil }
        if rpm <= 0 { return "静止" }
        if rpm >= 2400 { return "高速" }
        if rpm >= 1200 { return "中速" }
        return "低速"
    }

    private func hardwareTile(icon: String, title: String, value: String,
                              color: Color, badge: String? = nil,
                              showsChevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // 格子改成白底之后（v1.28.27），这块 18% 主色方底是整格里唯一还带颜色的块面，
                    // 图标不会飘在白色上显得没着落。再淡一点就会糊成一片灰。
                    .fill(color.opacity(0.18))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .plainTile(radius: 12)
    }

    /// 连接设备只给一个概括：总数 + 来源 + 入口。
    /// 概览页不再把设备名一条条铺出来——名字长短不一会把整张卡撑得参差不齐，
    /// 也挡住了下面真正要看的系统信息。明细都留在弹窗里。
    ///
    /// 以前这一行是「44pt 浅蓝圆 + 24pt 亮蓝数字 + 浅蓝胶囊」：三种深浅不同的蓝叠在
    /// 一起，而卡片标题里已经有一枚同样的图标，圆里再画一次纯属重复。
    /// 现在整行是白底 + 一圈细边，数字回归主色文字；右边「查看全部」也不再套浅蓝胶囊，
    /// 只留蓝色文字和箭头 —— 一行里只强调一处，不再靠铺色块做层级。
    private var onlineDeviceCount: Int {
        model.devices.filter { $0.online }.count
    }

    /// 副标题只在「全都离线」这种反常情况多说一句，正常就一句话带过。
    private var devicesCaption: String {
        if model.devices.isEmpty {
            // 清理过离线设备时，这里不能再说「还没有设备」——用户刚点完删除，
            // 看到「暂无设备」会以为整份列表被清空了。
            return model.hiddenDeviceCount > 0
                ? "已清理 \(model.hiddenDeviceCount) 台离线设备"
                : "DHCP 租约里还没有设备"
        }
        if onlineDeviceCount == 0 {
            return "\(model.devices.count) 台只有租约，此刻都没连上"
        }
        return "DHCP 租约 · 点开查看"
    }

    private var devicesContent: some View {
        Button {
            // 列表被清空、但确实隐藏过设备时，这一格还得能点开——
            // 否则用户在概览页看到「0 台在线」，却没有任何入口能进面板恢复。
            guard !model.devices.isEmpty || model.hiddenDeviceCount > 0 else { return }
            showAllDevices = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // 这里以前直接数 model.devices.count，而那是「租约条数」——
                        // 关掉的设备租约还在，数字就一直虚高。现在只数真在线的。
                        Text("\(onlineDeviceCount)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("台在线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(devicesCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if !model.devices.isEmpty || model.hiddenDeviceCount > 0 {
                    HStack(spacing: 3) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    // 用会自己适配深浅的 systemBlue：写死 .blue（#007AFF）
                    // 压在深色卡片上偏暗，几乎和背景糊在一起。
                    .foregroundStyle(Color(.systemBlue))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowTile(radius: 14)
            .cardTapShape()
        }
        .buttonStyle(.plain)
        .disabled(model.devices.isEmpty && model.hiddenDeviceCount == 0)
    }

    private var systemContent: some View {
        VStack(spacing: 0) {
            InfoRow(label: "主机名", value: model.routerInfo.hostname.isEmpty ? "--" : model.routerInfo.hostname)
            Divider()
            InfoRow(label: "型号", value: model.routerInfo.model.isEmpty ? "--" : model.routerInfo.model)
            Divider()
            InfoRow(label: "架构", value: model.routerInfo.architecture.isEmpty ? "--" : model.routerInfo.architecture)
            Divider()
            InfoRow(label: "固件", value: model.routerInfo.firmware.isEmpty ? "--" : model.routerInfo.firmware)
            Divider()
            InfoRow(label: "内核", value: model.routerInfo.kernel.isEmpty ? "--" : model.routerInfo.kernel)
            Divider()
            InfoRow(label: "运行时间", value: formatUptime(model.stats.uptime))
            Divider()
            InfoRow(label: "负载", value: String(format: "%.2f", model.stats.load))
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 9)
    }
}

/// 速度曲线。
///
/// 以前用 Swift Charts：每 2 秒数据一变，整套图表场景图（坐标轴、标度、图例、
/// 动画事务）都要重建一次，是概览页最贵的一块，也是「点一下概览就发热」的主因。
/// 换成一个 Canvas 路径之后只画两条折线 + 一块渐变，成本跟点数线性相关。
private struct SpeedSparkline: View {
    let points: [HistoryPoint]

    /// 峰值只跟数据有关。v2.2.0 从 draw 闭包里提到外面：闭包里算就是
    /// 「每次重绘都做一遍 O(n)」，提到 body 里则跟着数据走（2 秒一次）。
    private var peak: Double {
        max(points.map { max($0.download, $0.upload) }.max() ?? 0, 1)
    }

    var body: some View {
        let peak = self.peak
        return Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            guard points.count > 1 else {
                // 刚连上还没攒够两个点：画一条淡基线，卡片高度不会跳。
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(baseline, with: .color(Color(.separator).opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                return
            }

            // 两条线共用一个峰值，上下行的高低关系才看得出来（peak 在 body 里算好传进来）。
            let stepX = size.width / CGFloat(points.count - 1)
            let height = size.height - 2

            func path(_ value: (HistoryPoint) -> Double) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let ratio = max(0, min(1, value(point) / peak))
                    let point2D = CGPoint(x: CGFloat(index) * stepX,
                                          y: size.height - 1 - CGFloat(ratio) * height)
                    if index == 0 { path.move(to: point2D) } else { path.addLine(to: point2D) }
                }
                return path
            }

            let downloadPath = path { $0.download }
            var area = downloadPath
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Color.blue.opacity(0.20), Color.blue.opacity(0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))

            let line = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            context.stroke(downloadPath, with: .color(.blue), style: line)
            context.stroke(path { $0.upload }, with: .color(.purple), style: line)
        }
        .frame(height: 76)
        // v2.2.0：Canvas 是立即模式——SwiftUI 每次失效都重跑整段 draw 闭包，
        // 滚动时 Content 位移也算失效，于是每帧都在重算两条折线 + 一块渐变。
        // drawingGroup() 把它压成一个 Metal 离屏图层，滚动时只做位移合成。
        // 这里没有文字，不会糊字；点数只有几十个，离屏开销可以忽略。
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

/// CPU / 内存的小圆环块：**白底 + separator 细边**（v1.28.27 起，原来是 5% 主色淡底）。
/// 上面一行是图标底板 + 名称 + 右上角小字，下面是圆环和一行明细。
/// 底色改白之后，颜色只剩三处在说话：圆环的轨道与弧、图标底板、右上角那行小字。
private struct HardwareGauge: View {
    let title: String
    let icon: String
    let accent: Color
    let percent: Double
    let note: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.20))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }

                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            RingGauge(percent: percent, accent: accent, diameter: 88, lineWidth: 10)

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .plainTile(radius: 12)
    }
}

private struct RingGauge: View {
    let percent: Double
    let accent: Color
    var diameter: CGFloat = 112
    var caption: String = "占用"
    var lineWidth: CGFloat = 12
    /// 轨道色。不传就跟着主色走（同一支色的淡版）。
    /// 闪存那一环传中性灰——它的轨道就是「剩余」那一段，得和图例的灰点对上。
    var track: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var value: Double {
        guard percent.isFinite else { return 0 }
        return max(0, min(100, percent))
    }

    var body: some View {
        ZStack {
            // 轨道默认跟着主色走：原来是一条中性灰，和彩色弧线拼在一起像两种风格。
            //
            // 深色下要单独提一档不透明度（v1.28.27）：格子底从「16% 主色淡底」换成中性深灰
            // （#2C2C2E）之后，13% 的主色轨道压上去几乎看不出，圆环就只剩孤零零一段弧，
            // 连「进度到哪儿」都读不出来。34% 是试出来的——能看见轨道，又不至于和弧线抢。
            //
            // v1.28.30 起闪存那一环例外：它有图例要对应，轨道由 track 传进来（中性灰），
            // 不再跟着主色。CPU / 内存两个环照旧。
            Circle()
                .stroke(track ?? accent.opacity(colorScheme == .dark ? 0.34 : 0.13),
                        lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: value / 100)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(String(format: "%.0f%%", value))
                    .font(.system(size: diameter * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

extension View {
    func cardStyle() -> some View {
        glassCard(padding: 14, cornerRadius: 22)
    }
}
