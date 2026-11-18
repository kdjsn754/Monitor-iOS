import SwiftUI

/// 网络页（v2.6.5 新增；v2.6.7 顶部换拓扑树；v2.6.8 按官方 App 补字段；
/// v2.7.0 这一页可写；v2.8.0 补实时速率 / 累计流量 / 会话数；
/// v2.8.1 设备信息只走官方接口；v2.8.2 拓扑图重画并把「无线」卡并进图里）。
///
/// **数据来自 `PollItem.network` 那一条采集脚本**（`ubus` / `uci` / `iwinfo` /
/// `gl-clients`），字段组织照 GL.iNet 官方 App 的 `internet_*` / `client_*` / `eth_*` /
/// `lan_*` 四组来，不是自己编的。
///
/// **能改的六件事**（都写路由器自己的配置，和官方 App 同一套通道）：
///   - 无线：名称 / 密码 / 隐藏 / 启用 / 信道 / 频宽 / 发射功率（`uci wireless` + `wifi reload`）；
///   - 设备：改名（`gl-client.alias`）、固定地址（`dhcp` 的 host 段）、阻止入网（GL 黑名单）；
///   - 清掉离线记录（`gl-clients remove_offline`）；
///   - 出口重连（中继先 `repeater reload`，再 `ifdown/ifup`）。
///
/// **版式**：拓扑 → 上网 → 设备。
/// 「无线」不再是单独一张卡：频段节点长在拓扑图上（名称、信道、频宽、台数），
/// 点节点进编辑页，启用开关也在那一页。
/// 「局域网与端口」也不再占一卡：点拓扑中间的路由器（或有线那片叶子）进二级页，
/// 端口状态与 DHCP 地址池都在那儿改（v2.9.0，用户 2026-11-15）。
/// 被动信息进多列网格（标签在上、值在下），只有能点的地方才排成整行。
///
/// **按钮与开关**：开关蓝、其余按钮黑字，规则见 `ButtonStyles.swift`。
/// v2.9.0 曾把整页 `.tint(.blue)`（连导航栏「保存 / 取消」都蓝），
/// 用户 2026-11-15 退回：「我要的是开关那种蓝色，不是所有按钮都蓝」。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false
    @State private var clearingOffline = false
    /// 长按离线设备后要删的那一条（v3.2.7）。非 nil 就是确认浮层开着。
    @State private var pendingDeleteClient: NetClient?
    @State private var deletingClient = false
    @State private var editingBand: WifiBandInfo?
    @State private var editingClient: NetClient?
    /// 无线分组编辑页（v3.0.0）。
    @State private var editingGroup: WifiNetGroup?
    /// 正在切开关的组，切的过程中把开关按住，避免连点写出两次相反的值。
    @State private var busyGroups: Set<String> = []
    /// 局域网二级页（点拓扑中间那个路由器、或有线那片叶子进来）。
    @State private var showLan = false
    /// 上网二级页（点拓扑最上面那个出口进来）。
    @State private var showUplink = false
    /// 无线二级页（点「无线」卡右上角「更多」进来，v3.2.5）。
    @State private var showWifi = false

    private var info: NetworkInfo { model.network }

    private static let leafSpacing: CGFloat = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    // 拓扑里的节点：出口进「上网」二级页，频段进编辑页，
                    // 路由器与有线进局域网二级页。
                    topology(openLan: { showLan = true },
                             openUplink: { showUplink = true })
                    wifiCard
                    uplinkCard
                    clientsCard
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 30)
                // 滚动手感与另外三个根页一致（见 ScrollTuning.swift 与 7.1）：
                // 长页正常回弹、短页拉不动，都不碰下拉刷新。
                .background(ScrollBounceTuning())
            }
            .scrollBounceBehavior(.basedOnSize)
            // 标题滑到状态栏下面时由系统糊一层，否则硬叠在时间上。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background { AppBackground() }
            .pageChrome("网络") {
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
            .sheet(item: $editingBand) { band in
                BandEditorSheet(band: band)
                    .presentationBackground(Color.clear)
            }
            .sheet(item: $editingClient) { client in
                ClientEditorSheet(client: client)
                    .presentationBackground(Color.clear)
            }
            .sheet(item: $editingGroup) { group in
                WifiGroupEditorSheet(group: group)
                    .presentationBackground(Color.clear)
            }
            .navigationDestination(isPresented: $showLan) {
                LanSettingsView()
            }
            // 上网二级页（点拓扑图最上面那个出口进来）。
            .navigationDestination(isPresented: $showUplink) {
                UplinkSettingsView()
            }
            // 无线二级页（「无线」卡右上角「更多」）。
            .navigationDestination(isPresented: $showWifi) {
                WifiSettingsView()
            }
            // 底栏在 `MainTabs` 上挂着 `.tint(.primary)`，那是往下传的环境值。
            // 这一页不再整页染蓝（v2.9.2）：按钮文字一律主色，只有开关是蓝的，
            // 见 `ButtonStyles.swift`。推上来的「上网 / 局域网」和两个编辑页
            // 各自带 `primaryButtons()`，开关各自带 `blueSwitch()`。
            .primaryButtons()
            // 删单条离线记录的确认（v3.2.7）。和全 App 一样用自绘浮层——
            // 系统 `alert` / `confirmationDialog` 在 iOS 26 上会贴到页面上方。
            .overlay {
                if let victim = pendingDeleteClient {
                    SheetOverlay(onDismiss: { pendingDeleteClient = nil }) {
                        SheetOverlayCard {
                            Text("删除这条离线记录？")
                                .font(.system(size: 17, weight: .semibold))
                            Text("只删路由器上留下的这条记录，不影响这台设备；它再连上来会重新出现。")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                SheetOverlayButton(title: "取消") { pendingDeleteClient = nil }
                                SheetOverlayButton(title: "删除", tint: .red) {
                                    Task { await deleteOffline(victim) }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await model.manualRefresh()
        refreshing = false
    }

    // MARK: - 拓扑

    /// 一张图读完「出口 → 路由器 → 三路」。
    ///
    /// **v2.8.2 重画**：原来是三块彼此独立的小卡片加一条直线，看着像列表不像图；
    /// 这次把原来单独一张「无线」卡也收了进来——频段的名称、信道、台数直接长在
    /// 叶子节点上，点进去就是那个频段的编辑页（启用开关也在那一页）。
    ///
    /// 结构：出口胶囊 → 竖线 → 路由器圆环 → 分叉 → 2.4G / 5G / 有线三片叶子。
    /// 能点的只有两处：出口 → 上网二级页（v2.9.1 起），
    /// 频段 → 编辑页、有线 → 局域网与端口二级页。
    /// 中间那圈路由器是**纯展示**（v2.9.5 起去掉跳转，理由见 `routerHub`）。
    private func topology(openLan: @escaping () -> Void,
                          openUplink: @escaping () -> Void) -> some View {
        let leaves = leafNodes
        return VStack(spacing: 0) {
            internetNode(openUplink: openUplink)
            connector(ok: info.uplinkOK)
            routerHub
            if !leaves.isEmpty {
                TopoFork(leaves: leaves, spacing: Self.leafSpacing)
                HStack(alignment: .top, spacing: Self.leafSpacing) {
                    ForEach(leaves) { leaf in
                        leafNode(leaf, openLan: openLan)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background { topologyPanel }
    }

    /// 图的底：一张圆角卡 + 一层从蓝到青的极淡渐变。
    /// 有了这层底色，整块读起来是「一张图」，而不是三张并排的白卡。
    private var topologyPanel: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.clear)
            .background {
                // 底板跟透明度；那层蓝→青的极淡渐变是图的一部分，留着。
                AdaptiveFill(shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                             color: Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [NetPalette.wan.opacity(0.12),
                                     NetPalette.wifi.opacity(0.07),
                                     Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
            }
    }

    /// 出口：一个胶囊，点了进「上网」二级页（v2.9.1）。
    ///
    /// 官方 App 的 Internet 页就在这一层：中继 / 以太网 / 蜂窝三个页签，
    /// 上级网络、MAC 模式、伪装、切换策略都在那儿改。入口放在拓扑图最上面
    /// 那个节点最顺——**它本来就是「出口」这一层**。
    private func internetNode(openUplink: @escaping () -> Void) -> some View {
        let on = info.uplinkOK
        return Button {
            openUplink()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: uplinkNodeIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(info.uplinkLabel)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(info.uplink == .none ? "—" : info.protoLabel)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill((on ? NetPalette.wan : Color.secondary).opacity(0.14))
                    }
                // 右上角一枚小箭头：和路由器那颗一样，告诉人这里能点进去。
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(on ? NetPalette.wan : Color.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                AdaptiveFill(shape: Capsule(), color: Color(.systemBackground))
                    .overlay {
                        // 描边颜色照旧跟着「通没通」走（在线蓝、断开灰），只把不透明度交给滑块。
                        AdaptiveBorder(shape: Capsule(),
                                       color: on ? NetPalette.wan : Color(.separator),
                                       width: 0.8, strength: 0.35)
                    }
                    .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
            }
        }
        .buttonStyle(.plain)
    }

    /// 出口那个胶囊左边的小图标。热点共享单独给一个手机图标——它既不是无线中继，
    /// 也不是网线（v3.2.2）。
    private var uplinkNodeIcon: String {
        switch info.uplink {
        case .repeater: return "wifi"
        case .wired: return "globe"
        case .tethering: return "personalhotspot"
        case .none: return "globe"
        }
    }

    /// 出口 → 路由器 的那一截竖线：上深下浅，像光从出口流进路由器；断线整段变灰。
    private func connector(ok: Bool) -> some View {
        let stops: [Color] = ok
            ? [NetPalette.wan.opacity(0.55), NetPalette.wan.opacity(0.10)]
            : [Color(.systemGray4), Color(.systemGray5)]
        return Capsule()
            .fill(LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom))
            .frame(width: 2, height: 20)
    }

    /// 中心：同心圆环（两道淡环 + 白底内圆），圈里是**这台机器的官方线稿**——固件
    /// `/www/model.svg` 那张，官方 App 用的也是它（用户 2026-11-16：「官方软件有这样的
    /// 实图用官方软件的」）。以前这里是 `wifi.router` 那个通用符号（塔架 + 信号弧），
    /// 跟 GL-MT3600BE 完全不像。圆环从 78/63 放大到 88/74、内圆 49→66，才装得下那张图。
    /// 下面是名字、局域网地址、实时上下行两个胶囊。整张图的视觉重心。
    ///
    /// **v2.9.5 起这一圈不再能点**（用户 2026-11-15：「拓扑图中间的路由器图标去掉
    /// 点击跳转到局域网页面，只保留有线的」）。原来它右下角挂着一枚小箭头，
    /// 点它和点最下面那片「有线」都进同一个「局域网与端口」页——同一个入口画两遍，
    /// 反而让人以为中间那圈是另一件事。现在入口只有「有线」那一片：
    /// 那片叶子本来就是「局域网」这一侧，点它进局域网页最自然。
    private var routerHub: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(NetPalette.wan.opacity(0.09))
                    .frame(width: 88, height: 88)
                Circle()
                    .strokeBorder(NetPalette.wan.opacity(0.22), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Circle()
                    .strokeBorder(NetPalette.wan.opacity(0.12), lineWidth: 0.8)
                    .frame(width: 74, height: 74)
                // **圈里不放白底**（v3.0.8，用户 03:09 看实机截图：「不要路由器图标的白底」）。
                // 原来是 `AdaptiveFill(Circle, systemBackground)` 66pt + 柔和阴影，缩在淡蓝环里
                // 像贴了一块膏药，也把线稿周围压出一圈硬边。现在线稿直接坐在淡蓝圆上。
                RouterModelGlyph(width: 56, tint: NetPalette.wan)
            }
            .padding(.bottom, 3)
            Text(deviceName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(info.lanIP.isEmpty ? "—" : info.lanIP)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 8) {
                speedChip("arrow.down", info.rxSpeed, NetPalette.wan)
                speedChip("arrow.up", info.txSpeed, NetPalette.wifi)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// 一个方向的实时速率：小箭头 + 数字 + 单位，套一层同色淡底。
    private func speedChip(_ symbol: String, _ bytes: Double, _ color: Color) -> some View {
        let parts = speedParts(bytes)
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(parts.value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(parts.unit)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { Capsule().fill(color.opacity(0.10)) }
    }

    /// 叶子：2.4G / 5G 各一片，最后一片是有线。
    ///
    /// 频段那两片就是原来「无线」卡里的一行——名称、信道、台数长在节点上，
    /// 开关收进编辑页（点节点进去，里面本来就有「启用」）。
    private var leafNodes: [TopoLeaf] {
        var out: [TopoLeaf] = []
        for band in info.bands.prefix(2) {
            let live = band.up && band.ssidOn
            var caption: [String] = []
            if live, band.channel > 0 { caption.append("CH \(band.channel)") }
            if live, !band.width.isEmpty { caption.append("\(band.width)M") }
            if live { caption.append("\(band.clients) 台") }
            out.append(TopoLeaf(id: band.id,
                                title: band.bandName,
                                value: band.ssid.isEmpty ? "—" : band.ssid,
                                caption: caption.isEmpty ? "已关闭" : caption.joined(separator: " · "),
                                icon: "wifi",
                                color: NetPalette.wifi,
                                on: live,
                                band: band))
        }
        // 有线这一片说的是**局域网侧**（LAN 口接着几台设备），不是「以太网出口」。
        // v2.9.2 用 `wiredOK`（只看 WAN 口）画它，结果 WAN 口空着、LAN 口明明接著
        // 一台千兆设备，这片叶子却写「未连接」，底下一行又写「1 个端口」——
        // 自相矛盾，用户 2026-11-15 说的「有线显示逻辑还是有问题」。
        //
        // **v2.9.5 换掉这两行字**：用户又提「拓扑有线展示的信息看着很懵」。
        // 原来大字是 `1G`、小字是「1 个端口」，两个数字挨着放，谁大谁小、
        // 哪个是速率哪个是数量全靠猜；`1G` 还容易被读成「1 代 / 1 个 G」。
        // 现在大字说**几根线在用**（「1 个口在用」），小字说**这条线多快**
        // （「1Gbps」），数字后面都带单位，不用再猜。
        let lanUp = info.lanUpPorts
        out.append(TopoLeaf(id: "wired",
                            title: "有线",
                            value: lanUp.isEmpty ? "未接网线" : "\(lanUp.count) 个口在用",
                            caption: lanUp.isEmpty ? "点开看端口" : "\(info.lanSpeedLabel)bps",
                            icon: "cable.connector",
                            color: NetPalette.wired,
                            on: info.lanOK,
                            band: nil))
        return out
    }

    /// 一片叶子：彩色圆底图标 + 名称 + 值 + 底下一行小数字。
    /// 频段点开是编辑页，有线点开是局域网与端口二级页（端口状态在那儿）。
    private func leafNode(_ leaf: TopoLeaf, openLan: @escaping () -> Void) -> some View {
        Button {
            if let band = leaf.band {
                editingBand = band
            } else {
                openLan()
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(leaf.color.opacity(leaf.on ? 0.15 : 0.07))
                        .frame(width: 34, height: 34)
                    Image(systemName: leaf.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(leaf.on ? leaf.color : Color(.systemGray3))
                }
                .padding(.bottom, 2)
                Text(leaf.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(leaf.on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(leaf.value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(leaf.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 4)
            .background {
                AdaptiveFill(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                             color: Color(.systemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(leaf.on ? leaf.color.opacity(0.28) : Color(.separator).opacity(0.4),
                                          lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(0.04), radius: 5, y: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 把 `12.4 MB/s` 拆成数字和单位，数字才能用大字号。
    private func speedParts(_ bytes: Double) -> (value: String, unit: String) {
        let parts = formatBytes(max(bytes, 0)).split(separator: " ")
        let value = parts.first.map(String.init) ?? "0"
        let unit = parts.count > 1 ? String(parts[1]) : "B"
        return (value, unit + "/s")
    }

    /// 型号：路由器自己报的拿不到时，退到界面上的连接名
    /// （`connectionName` 本身是「备注 → 设备名 → IP」三级回落，见 v2.5.5）。
    private var deviceName: String {
        let reported = model.routerInfo.model.trimmingCharacters(in: .whitespaces)
        if !reported.isEmpty { return reported }
        guard let profile = model.currentProfile else { return "OpenWrt" }
        return model.connectionName(for: profile)
    }

    // MARK: - 上网

    /// 上网卡：这一页的「现在是怎么上网的」。
    ///
    /// **版式 v2.9.1 重做**。原来这里是三列网格，值一长就被截：
    /// 「144.1 MBit/s」挤进三分之一宽要缩到 0.7 倍才放得下，
    /// 「↓ 366.0 GB ↑ 62.9 GB」更是被截成「↓ 366.0…↑ 62.9 GB」——
    /// 同一张卡里字号忽大忽小，就是这么来的（用户 2026-11-15：「有点字体大有点小，
    /// 有的又显示不全」）。
    ///
    /// 现在：**两列网格 + 整行项**。两列各占一半宽，标签 12pt、值 15pt，
    /// 一个字号到底；放不下的（DNS、累计流量）单独占一整行。
    private var uplinkCard: some View {
        card("上网", trailing: info.uplink == .none ? "未联网" : info.protoLabel) {
            metricGrid([
                [("方式", info.uplink.title, nil),
                 ("上级网络", upstreamName, nil)],
                [("IP 地址", info.uplinkIP.isEmpty ? "—" : info.uplinkIP, nil),
                 ("网关", info.uplinkGateway.isEmpty ? "—" : info.uplinkGateway, nil)],
                [("信号", signalText(info.upstreamSignal), nil),
                 ("协商速率", info.upstreamRate.isEmpty ? "—" : info.upstreamRate, nil)],
                [("在线时长", info.uplinkUptime > 0 ? durationLabel(info.uplinkUptime) : "—", nil),
                 ("会话", info.connections > 0 ? "\(info.connections)" : "—", nil)]
            ])
            divider
            // DNS 常常两条、一条十几个字符，两列各占一半还是紧，所以单独占一整行。
            metricGrid([[("DNS", info.uplinkDNS.isEmpty ? "—" : info.uplinkDNS.prefix(2).joined(separator: "  "), nil)]])
            divider
            // 累计流量两个方向分开摆：挤在一格里必然被截。
            metricGrid([
                [("↓ 下载", info.wanRxTotal > 0 ? formatBytes(info.wanRxTotal) : "—", nil),
                 ("↑ 上传", info.wanTxTotal > 0 ? formatBytes(info.wanTxTotal) : "—", nil)]
            ])
            // **v2.9.5 去掉「重新连接」**（用户 2026-11-15：「去掉上网瓦片的重新连接按钮」）。
            // 它一直是这一卡里唯一的动作，和下面「设备」区的操作挤在一起看着像两套东西；
            // 真要重连，断开再把中继切一下也能做到，不值得在这一卡里留一颗按钮。
        }
    }

    /// 「上级网络」那一格：中继是 SSID，热点共享是手机型号。
    ///
    /// 以前这一格只认 `upstreamSSID`，热点共享上网时它会空着写「—」，
    /// 而「方式」那一格明明写着「热点共享」——同一行自相矛盾（v3.2.2）。
    private var upstreamName: String {
        switch info.uplink {
        case .tethering:
            let model = info.repeater.usbUplink?.label ?? ""
            return model.isEmpty ? "—" : model
        case .repeater:
            return info.upstreamSSID.isEmpty ? "—" : info.upstreamSSID
        case .wired, .none:
            return "—"
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    /// 「信号」那一格：`-58 dBm · 强`。
    ///
    /// **v3.0.8 改**（用户 2026-11-16 03:05：「信号的字体不要颜色，加上强中弱」）：
    /// 原来数值按强度上绿/橙/红，一屏里就那三个数字最跳，和「只有开关是蓝的」那套规矩也冲突。
    /// 现在值一律走默认色，强弱改用文字说。阈值沿用上色时的分界：
    /// **≥ -55 强 / ≥ -70 中 / 其余弱**，别改数值——用户已经按这三档认了。
    private func signalText(_ dbm: Int) -> String {
        guard dbm != 0 else { return "—" }
        return "\(dbm) dBm · \(signalGrade(dbm))"
    }

    private func signalGrade(_ dbm: Int) -> String {
        if dbm >= -55 { return "强" }
        if dbm >= -70 { return "中" }
        return "弱"
    }

    // MARK: - 无线（v3.0.0）

    /// 无线：一行一个网络，开着关着都在卡上。
    ///
    /// **v3.3.0 重排**（用户 2026-11-18 22:02：「都丑……网络页各模块的布局都重做一下」）。
    /// 上一版把频段名挤在 SSID 左边当小灰字、详情又挂在频段名底下，三行字的左边缘
    /// 各在不同位置，扫下来全是断的；关掉的网络收成卡底一行 12pt 灰字，
    /// 像一句被丢掉的话。现在：
    ///
    /// ```
    /// 无线                                     1 台 ›
    /// ─────────────────────────────────────────────
    /// Catmint                                   [开关]
    /// 5 GHz · CH 56 · 3 台
    /// ─────────────────────────────────────────────
    /// Catmint                                   [开关]
    /// 2.4 GHz · 未开启
    /// ```
    ///
    /// 规则：
    ///   - **卡上只列开着的**（用户 2026-11-18 22:14 定：「关掉的不显示」）。
    ///     关掉的频段 / 网络整行不出现，底部也不留灰字提示；要开就点「更多」进二级页，
    ///     那里有全部开关；
    ///   - 主网络按频段一行（这台常年 5G 开、2.4G 关，整组一个开关表达不了），
    ///     只列 `ssidOn && !radioOff` 的频段；
    ///   - 访客 / IoT / 多链路整组一行，只列开着的、且配置过（有 interface）的组；
    ///   - 第一行永远是 SSID（15 半粗），第二行永远是「频段 · 详情」（12 灰）——
    ///     和「设备」卡的名字 + 副标题是同一套语法，两页读起来才像一家人；
    ///   - SSID 超长中间省略，不让它把开关挤出去；
    ///   - 一个都没开：一行「无线已关闭」+「去开启」，不是空白卡。
    ///
    /// 分组本身照 GL 官方 App（用户 2026-11-15「全量对齐」），但**不搬它那些灰色
    /// 说明文字**——2026-10-31 定的规矩：页面上不放解释性小字。
    private var wifiCard: some View {
        let groups = info.wifiGroups
        let total = groups.reduce(0) { $0 + $1.clients }
        let rows = wifiRows(groups)
        return card("无线",
                    trailing: total > 0 ? "\(total) 台" : "更多",
                    trailingAction: { showWifi = true }) {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    HStack(spacing: 8) {
                        Text("无线已关闭")
                            .font(UI.row())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("去开启") { showWifi = true }
                            .font(UI.row(.medium))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { CardRule() }
                        wifiRowView(row)
                    }
                }
            }
        }
    }

    /// 卡上的一行。`member` 有值的是主网络的某个频段（开关写那一条 `wifi-iface`），
    /// 为 nil 的是整组（一个开关管整组）。
    private struct WifiRow: Identifiable {
        let id: String
        let ssid: String
        let detail: String
        let group: WifiNetGroup
        let member: WifiBandInfo?
    }

    /// 只挑开着的出行。关掉的一律不进列表——卡面干净，开启统一去二级页。
    private func wifiRows(_ groups: [WifiNetGroup]) -> [WifiRow] {
        var rows: [WifiRow] = []
        for group in groups {
            if group.kind == .main {
                for member in group.members where member.ssidOn && !member.radioOff {
                    var parts: [String] = [member.bandName]
                    if member.channel > 0 { parts.append("CH \(member.channel)") }
                    if member.clients > 0 { parts.append("\(member.clients) 台") }
                    rows.append(WifiRow(id: member.id,
                                        ssid: member.ssid,
                                        detail: parts.joined(separator: " · "),
                                        group: group,
                                        member: member))
                }
            } else if group.isOn && !group.members.isEmpty {
                // 组：几个频段共用一个 SSID，所以频段短名要跟在第二行里说清楚。
                var parts: [String] = [shortKindLabel(group.kind)]
                let bands = group.onBandShort
                if !bands.isEmpty { parts.append(bands) }
                if group.clients > 0 { parts.append("\(group.clients) 台") }
                rows.append(WifiRow(id: group.id,
                                    ssid: group.ssid,
                                    detail: parts.joined(separator: " · "),
                                    group: group,
                                    member: nil))
            }
        }
        return rows
    }

    /// 组在卡上的短名。主网络不出现在这里（它的行用频段名）。
    private func shortKindLabel(_ kind: WifiNetGroup.Kind) -> String {
        switch kind {
        case .main: return "主网络"
        case .guest: return "访客"
        case .iot: return "IoT"
        case .mlo: return "多链路"
        }
    }

    private func wifiRowView(_ row: WifiRow) -> some View {
        HStack(spacing: 12) {
            Button {
                editingGroup = row.group
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.ssid.isEmpty ? "—" : row.ssid)
                        .font(UI.row(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.detail)
                        .font(UI.label())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.group.editable)

            // 写入期间把开关换成转圈：重启无线要 6~8 秒（见 `reloadWireless`），
            // 只把开关置灰的话看着就是「点了没反应」。
            if let member = row.member {
                if busyGroups.contains(member.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 51, height: 31)
                } else {
                    Toggle("", isOn: memberBinding(member))
                        .labelsHidden()
                        .blueSwitch()
                        .disabled(!member.editable)
                }
            } else {
                groupToggle(row.group)
            }
        }
        .padding(.vertical, UI.rowPadding)
    }

    private func groupToggle(_ group: WifiNetGroup) -> some View {
        Group {
            if busyGroups.contains(group.kind.rawValue) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: groupBinding(group))
                    .labelsHidden()
                    .blueSwitch()
                    .disabled(!group.editable)
            }
        }
    }

    /// 组开关的绑定：先按住开关（`busyGroups`），写完刷新再放开。
    /// 不按住的话连点两下会写出两次相反的值，最后落在哪个取决于谁先回来。
    private func groupBinding(_ group: WifiNetGroup) -> Binding<Bool> {
        Binding(get: { group.isOn }, set: { value in
            guard !busyGroups.contains(group.kind.rawValue) else { return }
            busyGroups.insert(group.kind.rawValue)
            Task {
                let problem = await model.setWifiGroup(group, on: value)
                busyGroups.remove(group.kind.rawValue)
                if let problem {
                    model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
                } else {
                    await model.manualRefresh()
                }
            }
        })
    }

    /// 单个频段（主网络那一行）的开关：走 `saveBand`，其余字段原样传，只动启用位。
    private func memberBinding(_ member: WifiBandInfo) -> Binding<Bool> {
        Binding(get: { member.ssidOn }, set: { value in
            guard !busyGroups.contains(member.id) else { return }
            busyGroups.insert(member.id)
            Task {
                let problem = await model.saveBand(member, ssid: member.ssid, key: member.key,
                                                   hidden: member.hidden, enabled: value)
                busyGroups.remove(member.id)
                if let problem {
                    model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
                } else {
                    await model.manualRefresh()
                }
            }
        })
    }

    // MARK: - 设备

    private var clientsCard: some View {
        let online = info.onlineClients
        let offline = info.offlineClients
        return card("设备", trailing: clientsSummary(online: online.count, offline: offline.count)) {
            if info.clients.isEmpty {
                emptyLine
            } else {
                ForEach(info.clients) { client in
                    if client.id != info.clients.first?.id { divider }
                    Button {
                        editingClient = client
                    } label: {
                        clientRow(client)
                    }
                    .buttonStyle(.plain)
                    // 单条删除（v3.2.7）：只给离线设备挂，在线的那台删了也会被下一轮
                    // 扫描写回来。长按是快捷入口，编辑页底部还有一个同样的。
                    .contextMenu {
                        if !client.online {
                            Button(role: .destructive) {
                                pendingDeleteClient = client
                            } label: {
                                Label("删除这条记录", systemImage: "trash")
                            }
                        }
                    }
                }
                if !offline.isEmpty {
                    divider
                    actionRow(clearingOffline ? "正在清除…" : "清除离线记录",
                              symbol: "trash",
                              busy: clearingOffline) {
                        Task { await clearOffline() }
                    }
                }
            }
        }
    }

    private func clientsSummary(online: Int, offline: Int) -> String {
        if online == 0 && offline == 0 { return "" }
        var parts = ["\(online) 在线"]
        if offline > 0 { parts.append("\(offline) 离线") }
        return parts.joined(separator: " · ")
    }

    private func clearOffline() async {
        guard !clearingOffline else { return }
        clearingOffline = true
        let problem = await model.clearOfflineClients()
        await model.manualRefresh()
        clearingOffline = false
        if let problem {
            model.presentError(problem)
        } else {
            model.notice = Notice(kind: .ok, title: "离线记录已清除", detail: "")
        }
    }

    /// 删一条离线记录。长按菜单和编辑页底部两个入口都走这里。
    ///
    /// 后端会把 `gl_clients_update` 杀掉让 procd 重启（见 `deleteOfflineClient`），
    /// 所以删完要等它起来再采——立刻采会拿到一份空的客户端列表。
    private func deleteOffline(_ client: NetClient) async {
        guard !deletingClient else { return }
        pendingDeleteClient = nil
        deletingClient = true
        let problem = await model.deleteOfflineClient(mac: client.mac)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await model.manualRefresh()
        deletingClient = false
        if let problem {
            model.presentError(problem)
        } else {
            model.notice = Notice(kind: .ok,
                                  title: "记录已删除",
                                  detail: client.displayName)
        }
    }

    private func clientRow(_ client: NetClient) -> some View {        // 名字下面只留「地址 · 接入」两段，设备类型交给左边那个图标
        // （`ClientBadgeIcon` 按 `gl-client.class` 画图标，再写一遍纯占长度）。
        // 右侧两行数字走 `ClientMetricColumn`，和概览的「连接设备」是同一个视图；
        // 它 `.fixedSize()`，宁可让名字截断也不让数字折行。
        return HStack(spacing: 10) {
            ClientBadgeIcon(client: client, tint: rowColor(client))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(client.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(client.online ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if client.blocked {
                        Text("已拦截")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background {
                                Capsule().fill(Color(red: 0.85, green: 0.25, blue: 0.22).opacity(0.12))
                            }
                    }
                }
                ClientDetailLine(client: client)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ClientMetricColumn(client: client)
                .padding(.trailing, 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.vertical, 9)
        .opacity(client.online ? 1 : 0.6)
        .contentShape(Rectangle())
    }

    /// 设备行的着色：拦截（红）> 网线（紫）> 无线（青）。
    private func rowColor(_ client: NetClient) -> Color {
        if client.blocked { return Color(red: 0.85, green: 0.25, blue: 0.22) }
        return client.wired ? NetPalette.wired : NetPalette.wifi
    }

    // MARK: - 小组件

    /// 卡片：外壳统一走 `CardPanel`（v3.3.0），这一页不再自己拼圆角和内边距。
    ///
    /// 以前这里 radius 18、水平 16、上 14、下 8，而概览是 22、设置/代理是 18 + 16，
    /// 同一个 App 四套数值。现在四个根页共用 `UI` 那一份（见 DesignSystem.swift）。
    private func card<Content: View>(_ title: String,
                                     trailing: String = "",
                                     trailingAction: (() -> Void)? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        CardPanel(title, trailing: trailing, action: trailingAction) {
            content()
        }
    }

    /// 多列数据网格：标签小字在上、值在下。比「标题 …… 值」省一半高度，
    /// 而且同一列的值左边缘齐平，扫起来不跳。列数由每行的元素个数决定。
    ///
    /// **字号统一**（v2.9.1）：标签 12pt、值 15pt，一个尺寸到底。
    /// 值放不下时最多缩到 0.85 倍，并且从**尾部**截断——原来从中间截，
    /// 「↓ 366.0…↑ 62.9 GB」那种半截数字最让人看不懂。
    private func metricGrid(_ rows: [[(String, String, Color?)]]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                if index > 0 { divider }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row.indices, id: \.self) { column in
                        metricCell(row[column].0, row[column].1, row[column].2)
                    }
                }
                .padding(.vertical, 9)
            }
        }
    }

    private func metricCell(_ label: String, _ value: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(color ?? Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 卡片底部的动作行：左图标 + 文字，整行可点，忙的时候转圈。
    private func actionRow(_ title: String, symbol: String, busy: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(title)
                    .font(UI.row())
                Spacer(minLength: 8)
            }
            .foregroundStyle(NetPalette.wan)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// 卡里的分隔线统一走 `CardRule`（v3.3.0），别再手搓 0.5pt 的 Rectangle。
    private var divider: some View { CardRule() }

    private var emptyLine: some View {
        Text("—")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

// MARK: - 编辑 Wi-Fi

/// 一个频段的编辑页：名称 / 密码 / 隐藏 / 启用 / 信道 / 频宽 / 发射功率。
///
/// 版式跟「连接设备」「切换连接」那几个弹窗一致：`Form` + 右上角保存。
/// 保存成功后自己关掉并让上一页刷新；失败就把原因留在表单里，不关窗——
/// 关掉再弹提示，用户还得重新点进来一次。
private struct BandEditorSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let band: WifiBandInfo

    @State private var ssid: String
    @State private var key: String
    @State private var hidden: Bool
    @State private var enabled: Bool
    @State private var channel: String
    @State private var width: String
    @State private var power: Int
    @State private var busy = false
    @State private var errorText: String?

    init(band: WifiBandInfo) {
        self.band = band
        _ssid = State(initialValue: band.ssid)
        _key = State(initialValue: band.key)
        _hidden = State(initialValue: band.hidden)
        _enabled = State(initialValue: band.ssidOn)
        _channel = State(initialValue: band.channelMode.isEmpty ? "auto" : band.channelMode)
        let current = band.width.isEmpty ? (band.band == "2.4" ? "40" : "80") : band.width
        _width = State(initialValue: current)
        _power = State(initialValue: band.txPowerPercent > 0 ? band.txPowerPercent : 100)
    }

    /// 有密码的加密方式才显示密码行（`none` 时写了也没意义）。
    private var needsKey: Bool {
        !band.encryption.isEmpty && band.encryption != "none"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("名称")
                        TextField("", text: $ssid)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .adaptiveRowBackground()

                    if needsKey {
                        HStack {
                            Text("密码")
                            SecureField("", text: $key)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .adaptiveRowBackground()
                    }

                    Toggle("隐藏网络", isOn: $hidden)
                        .blueSwitch()
                        .adaptiveRowBackground()
                    Toggle("启用", isOn: $enabled)
                        .blueSwitch()
                        .adaptiveRowBackground()
                }

                Section {
                    Picker("信道", selection: $channel) {
                        Text("自动").tag("auto")
                        ForEach(band.channelOptions, id: \.self) { value in
                            Text("CH \(value)").tag(String(value))
                        }
                    }
                    .pickerStyle(.menu)
                    .adaptiveRowBackground()

                    Picker("频宽", selection: $width) {
                        ForEach(band.widthOptions, id: \.self) { value in
                            Text("\(value) MHz").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .adaptiveRowBackground()

                    Picker("发射功率", selection: $power) {
                        ForEach([100, 75, 50, 25], id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .adaptiveRowBackground()
                    .disabled(!enabled)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                            .adaptiveRowBackground()
                    }
                }
            }
            .themedFormBackground()
            // 弹窗是独立的 NavigationStack，环境值只往下传，这里要自己说一遍：
            // 按钮文字主色、开关蓝（`ButtonStyles.swift` 的四类）。
            .primaryButtons()
            .navigationTitle(band.bandName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
                            .navBarTint()
                    }
                }
            }
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.saveBand(band,
                                           ssid: ssid,
                                           key: key,
                                           hidden: hidden,
                                           enabled: enabled,
                                           channel: channel,
                                           width: width,
                                           power: power)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok,
                                  title: "\(band.bandName) 已保存",
                                  detail: ssid)
            dismiss()
            await model.manualRefresh()
            return
        }
        errorText = problem
    }
}

// MARK: - 设备操作

/// 一台设备的操作页：改名 / 固定地址 / 阻止入网。
/// 三件事分开写、按「便宜的在前」提交：改名 → 固定地址 → 网络权限。
private struct ClientEditorSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let client: NetClient

    @State private var name: String
    @State private var blocked: Bool
    @State private var pinned: Bool
    @State private var address: String
    @State private var busy = false
    @State private var errorText: String?
    /// 设备类型是**点一下就直接写**的，不跟「保存」走：官方 App 也是单独一个弹窗，
    /// 选完立即生效。写成功才更新这里，失败保持原值。
    @State private var classValue: String
    @State private var pickingClass = false
    @State private var savingClass = false
    /// 删除这条记录前的自绘确认浮层（v3.2.7）。
    @State private var confirmingDelete = false

    private let originalName: String

    init(client: NetClient) {
        self.client = client
        let shown = client.name == "*" ? "" : client.name
        self.originalName = shown
        _name = State(initialValue: shown)
        _blocked = State(initialValue: client.blocked)
        _pinned = State(initialValue: !client.reservedIP.isEmpty)
        _address = State(initialValue: client.reservedIP.isEmpty ? client.ip : client.reservedIP)
        _classValue = State(initialValue: client.deviceClass)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("名称")
                        TextField("", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .adaptiveRowBackground()

                    Toggle("固定地址", isOn: $pinned)
                        .blueSwitch()
                        .adaptiveRowBackground()

                    if pinned {
                        HStack {
                            Text("地址")
                            TextField("", text: $address)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .monospacedDigit()
                        }
                        .adaptiveRowBackground()
                    }

                    Toggle("阻止入网", isOn: $blocked)
                        .blueSwitch()
                        .adaptiveRowBackground()
                }

                Section {
                    HStack {
                        Text("IP")
                        Spacer(minLength: 8)
                        Text(client.ip.isEmpty ? "—" : client.ip)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                    HStack {
                        Text("接入")
                        Spacer(minLength: 8)
                        Text(client.iface.isEmpty ? "—" : client.iface)
                            .foregroundStyle(.secondary)
                    }
                    .adaptiveRowBackground()
                    Button {
                        pickingClass = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("设备类型")
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            if savingClass {
                                ProgressView().controlSize(.small)
                            } else {
                                DeviceGlyph(kind: ClientClass(rawValue: classValue), size: 19)
                                    .foregroundStyle(.secondary)
                                Text(shownClass)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(savingClass)
                    .adaptiveRowBackground()
                    HStack {
                        Text("MAC")
                        Spacer(minLength: 8)
                        Text(client.mac)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                }

                Section {
                    HStack {
                        Text("下载速率")
                        Spacer(minLength: 8)
                        Text(client.downRateLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                    HStack {
                        Text("上传速率")
                        Spacer(minLength: 8)
                        Text(client.upRateLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                    HStack {
                        Text("下载流量")
                        Spacer(minLength: 8)
                        Text(client.totalRx > 0 ? formatBytes(client.totalRx) : "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                    HStack {
                        Text("上传流量")
                        Spacer(minLength: 8)
                        Text(client.totalTx > 0 ? formatBytes(client.totalTx) : "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                }

                // 单条删除（v3.2.7）：只给离线设备。在线的删了也会被下一轮扫描写回来，
                // 与其点了没用，不如不显示。
                if !client.online {
                    Section {
                        Button {
                            confirmingDelete = true
                        } label: {
                            HStack {
                                Spacer(minLength: 0)
                                Text("删除这条记录")
                                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                                Spacer(minLength: 0)
                            }
                        }
                        .disabled(busy)
                        .adaptiveRowBackground()
                    } footer: {
                        Text("只删路由器上留下的这条记录，不影响这台设备；它再连上来会重新出现。")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                            .adaptiveRowBackground()
                    }
                }
            }
            .themedFormBackground()
            .primaryButtons()
            .navigationTitle(client.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
                            .navBarTint()
                    }
                }
            }
        }
        // 删除确认：自绘浮层（系统 alert 在 iOS 26 会贴到页面上方，见 Glass.swift 第 576 行）。
        .overlay {
            if confirmingDelete {
                SheetOverlay(onDismiss: { confirmingDelete = false }) {
                    SheetOverlayCard {
                        Text("删除这条离线记录？")
                            .font(.system(size: 17, weight: .semibold))
                        Text("只删路由器上留下的这条记录，不影响这台设备；它再连上来会重新出现。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { confirmingDelete = false }
                            SheetOverlayButton(title: "删除", tint: .red) {
                                Task { await removeRecord() }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .sheet(isPresented: $pickingClass) {
            ClientClassSheet(current: classValue) { picked in
                pickingClass = false
                Task { await applyClass(picked) }
            }
        }
    }

    /// 行里显示的类型名：认得的走官方文案，认不得（设备还没类型）就说有线 / 无线。
    private var shownClass: String {
        if let known = ClientClass(rawValue: classValue) { return known.title }
        return client.classLabel
    }

    /// 选完立刻写，不走「保存」——类型是独立的配置，跟名称/地址那几项没有先后关系。
    ///
    /// **先改本地值再去写**：以前是等写成功再赋 `classValue`，于是点了类型之后
    /// 这一行还是旧值，要退出重进才变（用户 2026-11-16 报的就是这个）。
    /// 现在点击当场换掉，写失败再退回去并报错——反正整段写回只用几十毫秒，
    /// 真失败了把值恢复原样也不会留下错的显示。
    private func applyClass(_ value: String) async {
        guard !savingClass, value != classValue else { return }
        let previous = classValue
        classValue = value
        savingClass = true
        errorText = nil
        let problem = await model.setClientClass(mac: client.mac, value: value)
        savingClass = false
        if let problem {
            classValue = previous
            errorText = problem
        } else {
            await model.manualRefresh()
        }
    }

    /// 删掉这条记录（v3.2.7）。后端会顺手把 `gl_clients_update` 重启，
    /// 所以要等它起来再刷新，否则客户端列表会空一拍。
    private func removeRecord() async {
        guard !busy else { return }
        confirmingDelete = false
        busy = true
        errorText = nil
        let problem = await model.deleteOfflineClient(mac: client.mac)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        busy = false
        if let problem {
            errorText = problem
            return
        }
        model.notice = Notice(kind: .ok,
                              title: "记录已删除",
                              detail: client.displayName)
        dismiss()
        await model.manualRefresh()
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != originalName,
           let problem = await model.renameClient(mac: client.mac, name: trimmed) {
            busy = false
            errorText = problem
            return
        }

        let target = pinned ? address.trimmingCharacters(in: .whitespaces) : ""
        if target != client.reservedIP,
           let problem = await model.setReservedIP(mac: client.mac, ip: target) {
            busy = false
            errorText = problem
            return
        }

        if blocked != client.blocked,
           let problem = await model.setClientBlocked(mac: client.mac, blocked: blocked) {
            busy = false
            errorText = problem
            return
        }

        busy = false
        model.notice = Notice(kind: .ok,
                              title: blocked != client.blocked
                              ? (blocked ? "已禁止上网" : "已允许上网")
                              : "已保存",
                              detail: trimmed.isEmpty ? client.displayName : trimmed)
        dismiss()
        await model.manualRefresh()
    }
}

/// 「设备类型」选择器。
///
/// 照官方 App（用户 2026-11-16 给了截图）：**三列九宫格**，每格一张白卡，卡里一个
/// 圆形底 + 类型图标，下面一行名字，选中的那个圆变蓝、图标变白。
///
/// 以前是一列 `Form` 行、图标只有 18pt —— 线条图标缩到这个尺寸细节全糊，
/// 一列七行也看不出「一批类型」这件事（用户：「自绘的图标小的太丑了」）。
/// 现在图标 34pt 放在 56pt 的圆里，笔画的粗细才站得住。
///
/// 点一下直接写回，不等详情页那个「保存」——类型和名称/地址是各自独立的配置。
private struct ClientClassSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: String
    let pick: (String) -> Void

    /// 三列等宽，间距 12。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ClientClass.pickerOrder, id: \.rawValue) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .themedScrollBackground()
            .navigationTitle("设备类型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                }
            }
        }
    }

    /// 一格：圆底图标 + 名字。选中时圆底是主题蓝、图标转白、名字回主色。
    private func cell(_ item: ClientClass) -> some View {
        let on = item.rawValue == current
        return Button {
            pick(item.rawValue)
        } label: {
            VStack(spacing: 9) {
                ZStack {
                    // `systemGray4`：浅色下是 #D1D1D6（和官方那个灰团一个调子），
                    // 深色下是 #3A3A3C，比卡片底亮一档——用 `systemGray5/6` 会跟卡片同色，
                    // 圆整个看不见。
                    Circle()
                        .fill(on ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 56, height: 56)
                    DeviceGlyph(kind: item, size: 34)
                        .foregroundStyle(on ? Color.white : Color(.systemGray))
                }
                Text(item.title)
                    .font(.system(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
            .plainTile(radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 拓扑图的三色：蓝=联网 / 出口，青=无线，紫=有线。
/// 单独放一个 enum，是为了卡片里的圆点、叶子图标、连线全用同一组值（改色只改一处）。
enum NetPalette {
    static let wan = Color(red: 0.16, green: 0.45, blue: 0.95)
    static let wifi = Color(red: 0.09, green: 0.60, blue: 0.72)
    static let wired = Color(red: 0.45, green: 0.35, blue: 0.88)
}

/// 拓扑树最下面一排的节点数据。
struct TopoLeaf: Identifiable {
    let id: String
    let title: String
    /// 主值：频段是 SSID，有线是协商速率。
    let value: String
    /// 底下一行：`CH 56 · 2 台` / `3 个端口` / `已关闭`。
    let caption: String
    let icon: String
    let color: Color
    /// 这一路通不通：不通则图标、标题、连线一起变灰。
    let on: Bool
    /// 频段节点带着自己的数据，点开就是它的编辑页；有线为 nil（点了滚到局域网卡）。
    let band: WifiBandInfo?
}

/// 路由器节点下面那三条分叉线。
///
/// 三列的宽度和间距必须和上面 `HStack(spacing:)` 完全一致，否则线会歪到节点外面——
/// 所以 `spacing` 由调用方传进来，两边共用一个常量。
/// 用 `Canvas` 一次画完再 `.drawingGroup()` 压成离屏图层，滚动时只做位移合成
/// （同 `SpeedSparkline`，见 v2.2.0）。
private struct TopoFork: View {
    let leaves: [TopoLeaf]
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            guard !leaves.isEmpty, size.width > 1 else { return }
            let count = CGFloat(leaves.count)
            let column = (size.width - spacing * (count - 1)) / count
            let midX = size.width / 2
            let branchY = size.height * 0.42

            // 主干：从路由器底部走到分叉点。
            var trunk = Path()
            trunk.move(to: CGPoint(x: midX, y: 0))
            trunk.addLine(to: CGPoint(x: midX, y: branchY))
            context.stroke(trunk,
                           with: .color(Color.primary.opacity(0.13)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            for (index, leaf) in leaves.enumerated() {
                let cx = column * CGFloat(index) + spacing * CGFloat(index) + column / 2
                var branch = Path()
                branch.move(to: CGPoint(x: midX, y: branchY))
                branch.addQuadCurve(to: CGPoint(x: cx, y: size.height),
                                    control: CGPoint(x: cx,
                                                     y: branchY + (size.height - branchY) * 0.62))
                let color = leaf.on ? leaf.color : Color(.systemGray4)
                context.stroke(branch,
                               with: .color(color.opacity(leaf.on ? 0.55 : 0.9)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .drawingGroup()
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}
