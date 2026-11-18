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
    @State private var editingBand: WifiBandInfo?
    @State private var editingClient: NetClient?
    /// 无线分组编辑页（v3.0.0）。
    @State private var editingGroup: WifiNetGroup?
    /// 「添加网络」要建的组（访客 / IoT）。
    @State private var creatingKind: WifiNetGroup.Kind?
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
                VStack(spacing: 16) {
                    // 拓扑里的节点：出口进「上网」二级页，频段进编辑页，
                    // 路由器与有线进局域网二级页。
                    topology(openLan: { showLan = true },
                             openUplink: { showUplink = true })
                    wifiCard
                    uplinkCard
                    clientsCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
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
            .sheet(isPresented: Binding(get: { creatingKind != nil },
                                        set: { if !$0 { creatingKind = nil } })) {
                if let kind = creatingKind {
                    WifiGroupCreateSheet(kind: kind)
                        .presentationBackground(Color.clear)
                }
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
                    .font(.system(size: 13.5, weight: .medium))
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
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(info.lanIP.isEmpty ? "—" : info.lanIP)
                .font(.system(size: 11.5))
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
                .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 10.5))
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

    /// 无线四组：主网络 / 访客网络 / IoT 网络 / 多链路，做成**一块块瓦片**摆在
    /// 同一张「无线」卡里。
    ///
    /// 走过的四版，别退回去：
    /// - v3.0.0 每组一张卡，四块白底各带标题铺满一屏（用户：「不要全散落在这个界面」）；
    /// - v3.0.1 合成一张但压成「60pt 灰组名列 + 灰 SSID + 开关」的密表格，
    ///   两层灰叠在一起没层次，主网络第二行还空出一截（用户：「太丑了」）；
    /// - v3.0.2 用 `LazyVGrid` + `.gridCellColumns(2)` 想让主网络占整行——**这个修饰符
    ///   只对 `Grid` 生效，`LazyVGrid` 没有跨列这回事**。结果四块全成半宽：主网络被挤成
    ///   「2.4 GHz …」、SSID 一个字都看不见，右边还空出半块（用户 2026-11-16：
    ///   「实际是这样的很乱」）；
    /// - **v3.0.3 现在这版**：不用网格，直接 VStack 排——主网络整行、访客与 IoT 并排、
    ///   多链路整行。宽度是写死的，不靠网格猜跨列。瓦片底色仍用
    ///   `tertiarySystemGroupedBackground`，比卡片浅一档。
    ///
    /// 分组本身照 GL 官方 App（用户 2026-11-15「全量对齐」），但**不搬它那些灰色
    /// 说明文字**——2026-10-31 定的规矩：页面上不放解释性小字。
    ///
    /// **v3.2.5 起只列开着的网络**（用户 2026-11-18：「只显示已经开启的，没开启的不显示」）。
    /// 关掉的访客 / IoT / 多链路、关着的频段都不再占一行 —— 以前四块瓦片里常有两块写着
    /// 「未启用」，既没有信息量、又把真正在用的挤小。要开要关、要改名称密码，点右上角
    /// 「更多」进 `WifiSettingsView`（无线二级页）。
    ///
    /// 主网络按频段各给一个开关：这台机器常见「5G 开、2.4G 关」，整组一个开关表达不了。
    /// 访客 / IoT / 多链路是整组一个开关，因为它们的 2.4G 与 5G 本来就是同一个名字。
    private var wifiCard: some View {
        let groups = info.wifiGroups
        let total = groups.reduce(0) { $0 + $1.clients }
        let main = groups.first { $0.kind == .main }
        let onBands = (main?.members ?? []).filter { $0.ssidOn }
        let sides = groups.filter { ($0.kind == .guest || $0.kind == .iot) && $0.isOn }
        let mlo = groups.first { $0.kind == .mlo && $0.isOn }
        let nothingOn = onBands.isEmpty && sides.isEmpty && mlo == nil
        return card("无线",
                    trailing: total > 0 ? "\(total) 台 · 更多" : "更多",
                    trailingAction: { showWifi = true }) {
            VStack(spacing: 8) {
                if nothingOn {
                    HStack {
                        Text("无线已关闭")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                } else {
                    if !onBands.isEmpty, let main = main {
                        wifiTile(main, bands: onBands)
                    }
                    if !sides.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(sides) { group in
                                wifiTile(group)
                            }
                        }
                    }
                    if let mlo = mlo {
                        wifiTile(mlo)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    /// 一块瓦片：组名在第一行，开关跟在组名右边（主网络例外——它一行一个开关）。
    @ViewBuilder
    private func wifiTile(_ group: WifiNetGroup, bands: [WifiBandInfo]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.kind.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)

                // 主网络的开关在下面每个频段上，头行只留组名。
                // 台数不在这里重复一遍——卡片标题右上角已经有总数了（v3.0.2 两处都写，
                // 同一个数字讲两遍，看着更乱）。
                if group.kind != .main && !group.members.isEmpty {
                    groupToggle(group)
                }
            }

            if group.members.isEmpty {
                Button {
                    creatingKind = group.kind
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("添加网络")
                            .font(.system(size: 13))
                        Spacer(minLength: 2)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if group.kind == .main {
                // 只画开着的频段（v3.2.5）：关掉的那一条连 SSID 都没有，列出来只是噪音。
                ForEach(bands ?? group.members) { member in
                    tileBandRow(member, group: group)
                }
            } else {
                Button {
                    editingGroup = group
                } label: {
                    HStack(spacing: 6) {
                        Text(group.isOn ? group.ssid : "未启用")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!group.editable)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 瓦片底色比卡片浅一档：卡是 `secondarySystemGroupedBackground`，
        // 瓦片用 `tertiary`，浅色下是淡灰块、深色下是稍亮的一块。
        .background {
            AdaptiveFill(shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                         color: Color(.tertiarySystemGroupedBackground))
        }
        .overlay {
            AdaptiveBorder(shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                           width: 0.5, strength: 0.3)
        }
    }

    /// 主网络瓦片里的一个频段：频段名 + SSID + 独立开关。
    ///
    /// 频段名以前是 `.tertiary` + 46pt 死宽，半宽瓦片里连「2.4 GHz」都放不下、
    /// 名字又淡得快要看不见（v3.0.2 实机截图）。现在改成 `.secondary`、`fixedSize`
    /// 保住频段名不被压，宽度交给 SSID——主网络整行了，SSID 有地方站。
    private func tileBandRow(_ member: WifiBandInfo, group: WifiNetGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                editingGroup = group
            } label: {
                HStack(spacing: 8) {
                    Text(member.bandName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(minWidth: 44, alignment: .leading)
                    Text(member.ssid.isEmpty ? "—" : member.ssid)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!group.editable)

            // 写入期间把开关换成转圈：重启无线要 6~8 秒（见 `reloadWireless`），
            // 只把开关置灰的话看着就是「点了没反应」。
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
        }
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

    private func clientRow(_ client: NetClient) -> some View {
        // 名字下面只留「地址 · 接入」两段，设备类型交给左边那个图标
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

    /// 卡片：白底 + 一条 0.6pt 细边，没有阴影。靠留白分层，不靠色块。
    private func card<Content: View>(_ title: String,
                                     trailing: String = "",
                                     trailingAction: (() -> Void)? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    // 传了动作就是一颗按钮（「更多 ›」）。其余卡片的右上角仍然是纯文字，
                    // 不加箭头——那里本来就没得点。
                    if let trailingAction {
                        Button(action: trailingAction) {
                            HStack(spacing: 2) {
                                Text(trailing)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(trailing)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        // v2.9.6：底色和细边改走 `AdaptiveFill` / `AdaptiveBorder`，跟设置页的
        // 「卡片透明度」滑块一起变透。以前这里是死白
        // `Color(.secondarySystemGroupedBackground)`，壁纸透上来时整页只有这一页的
        // 卡片还实心（用户 2026-11-15：「网络页和他的二级页没有跟着透明度」）。
        .background {
            AdaptiveFill(shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                         color: Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            AdaptiveBorder(shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                           width: 0.6, strength: 0.45)
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
                    .font(.system(size: 14))
                Spacer(minLength: 8)
            }
            .foregroundStyle(NetPalette.wan)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.45))
            .frame(height: 0.5)
    }

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
                    .font(.system(size: 11.5, weight: on ? .medium : .regular))
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
