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
/// **按钮一律走蓝色**（本页 `.tint(.blue)` 收在最外层，工具栏与弹出的编辑页都盖到）。
/// 别的页导航栏按钮是黑的（`navBarTint` 的用户要求），但这一页用户明确说「全是黑的」，
/// 所以这里连「保存 / 取消」也不再用 `navBarTint()`。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false
    @State private var reconnecting = false
    @State private var clearingOffline = false
    @State private var editingBand: WifiBandInfo?
    @State private var editingClient: NetClient?
    /// 局域网二级页（点拓扑中间那个路由器、或有线那片叶子进来）。
    @State private var showLan = false
    /// 上网二级页（点拓扑最上面那个出口进来）。
    @State private var showUplink = false

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
                    HeaderButton("arrow.clockwise", tint: Color.blue) {
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
            .navigationDestination(isPresented: $showLan) {
                LanSettingsView()
            }
            // 上网二级页（点拓扑图最上面那个出口进来）。
            .navigationDestination(isPresented: $showUplink) {
                UplinkSettingsView()
            }
            // 底栏在 `MainTabs` 上挂了 `.tint(.primary)`，那是往下传的环境值，
            // 不补这一句整页控件会跟着变黑（v2.1.17 的教训）。
            //
            // ⚠️ 必须放在 `sheet` / `navigationDestination` **之后**：环境值只往下传，
            // 挂在滚动视图上时弹出的编辑页拿不到，里面的开关、选择器、保存按钮全是黑的
            // ——这正是用户 2026-11-15 说的「网络里面所有按钮都是黑色的」。
            .tint(.blue)
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
    /// 每个节点都能点：出口 → 上网二级页（v2.9.1 起，不再是滚到「上网」卡），
    /// 频段 → 编辑页，路由器 / 有线 → 局域网与端口二级页（v2.9.0 起）。
    private func topology(openLan: @escaping () -> Void,
                          openUplink: @escaping () -> Void) -> some View {
        let leaves = leafNodes
        return VStack(spacing: 0) {
            internetNode(openUplink: openUplink)
            connector(ok: info.uplinkOK)
            routerHub(openLan: openLan)
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
            .fill(Color(.secondarySystemGroupedBackground))
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
                Image(systemName: info.uplink == .repeater ? "wifi" : "globe")
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
                Capsule()
                    .fill(Color(.systemBackground))
                    .overlay {
                        Capsule()
                            .strokeBorder((on ? NetPalette.wan : Color(.separator)).opacity(0.35),
                                          lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
            }
        }
        .buttonStyle(.plain)
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

    /// 中心：路由器画成同心圆环（两道淡环 + 白底内圆），下面是名字、局域网地址、
    /// 实时上下行两个胶囊。整张图的视觉重心。
    /// 点进去是局域网与端口二级页（地址池、端口状态、租期都在那儿改）。
    private func routerHub(openLan: @escaping () -> Void) -> some View {
        Button {
            openLan()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(NetPalette.wan.opacity(0.09))
                        .frame(width: 78, height: 78)
                    Circle()
                        .strokeBorder(NetPalette.wan.opacity(0.22), lineWidth: 1)
                        .frame(width: 78, height: 78)
                    Circle()
                        .strokeBorder(NetPalette.wan.opacity(0.12), lineWidth: 0.8)
                        .frame(width: 63, height: 63)
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: 49, height: 49)
                        .shadow(color: Color.black.opacity(0.08), radius: 7, y: 2)
                    Image(systemName: "wifi.router")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(NetPalette.wan)
                    // 右下角一枚小箭头：这一圈能点进去（不然看不出是个入口）。
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: 19, height: 19)
                        .overlay {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(NetPalette.wan)
                        }
                        .overlay {
                            Circle().strokeBorder(NetPalette.wan.opacity(0.25), lineWidth: 0.8)
                        }
                        .offset(x: 27, y: 27)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let upPorts = info.ports.filter(\.up).count
        out.append(TopoLeaf(id: "wired",
                            title: "有线",
                            value: info.wiredOK ? info.bestPortLabel : "未连接",
                            caption: upPorts > 0 ? "\(upPorts) 个端口" : "—",
                            icon: "cable.connector",
                            color: NetPalette.wired,
                            on: info.wiredOK,
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
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
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
                 ("上级网络", info.upstreamSSID.isEmpty ? "—" : info.upstreamSSID, nil)],
                [("IP 地址", info.uplinkIP.isEmpty ? "—" : info.uplinkIP, nil),
                 ("网关", info.uplinkGateway.isEmpty ? "—" : info.uplinkGateway, nil)],
                [("信号", info.upstreamSignal != 0 ? "\(info.upstreamSignal) dBm" : "—",
                  info.upstreamSignal != 0 ? signalColor(info.upstreamSignal) : nil),
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
            divider
            actionRow(reconnecting ? "正在重连…" : "重新连接",
                      symbol: "arrow.triangle.2.circlepath",
                      busy: reconnecting) {
                Task { await reconnect() }
            }
        }
    }

    private func reconnect() async {
        guard !reconnecting else { return }
        reconnecting = true
        let problem = await model.reconnectUplink()
        await model.manualRefresh()
        reconnecting = false
        if let problem {
            model.presentError(problem)
        } else {
            model.notice = Notice(kind: .ok, title: "已重新连接", detail: info.uplinkLabel)
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

    private func signalColor(_ dbm: Int) -> Color {
        if dbm >= -55 { return Color(red: 0.13, green: 0.66, blue: 0.38) }
        if dbm >= -70 { return Color(red: 0.90, green: 0.55, blue: 0.10) }
        return Color(red: 0.85, green: 0.25, blue: 0.22)
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
        // 第二行是「地址 · 接入 · 设备类型」，右侧留给速率与累计流量
        // （在线时才变的那两个数）。设备类型是官方 App 判好的 `gl-client.class`，
        // 没归类就不占位；信号不再显示——官方接口里没有这一项，抓 iwinfo 又对不上 MAC。
        var bits: [String] = []
        if !client.ip.isEmpty { bits.append(client.ip) }
        if !client.iface.isEmpty { bits.append(client.iface) }
        if !client.deviceClass.isEmpty { bits.append(client.classLabel) }
        if !client.reservedIP.isEmpty { bits.append("固定") }
        let detail = bits.isEmpty ? client.mac : bits.joined(separator: " · ")

        return HStack(spacing: 10) {
            Image(systemName: client.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(rowColor(client))
                .frame(width: 28, height: 28)
                .background { Circle().fill(rowColor(client).opacity(0.12)) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(client.displayName)
                        .font(.system(size: 15))
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
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(client.online ? client.rateLabel : "离线")
                    .font(.system(size: 13))
                    .foregroundStyle(client.online ? rowColor(client) : Color.secondary)
                    .monospacedDigit()
                Text(client.trafficLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
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
                        .adaptiveRowBackground()
                    Toggle("启用", isOn: $enabled)
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
            // 弹窗是独立的 NavigationStack，拿不到页面最外层那句 `.tint(.blue)`
            // （环境值只往下传）。不补这一句：开关、选择器、"保存"全是黑的。
            .tint(.blue)
            .navigationTitle(band.bandName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
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

    private let originalName: String

    init(client: NetClient) {
        self.client = client
        let shown = client.name == "*" ? "" : client.name
        self.originalName = shown
        _name = State(initialValue: shown)
        _blocked = State(initialValue: client.blocked)
        _pinned = State(initialValue: !client.reservedIP.isEmpty)
        _address = State(initialValue: client.reservedIP.isEmpty ? client.ip : client.reservedIP)
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
                    HStack {
                        Text("设备类型")
                        Spacer(minLength: 8)
                        Text(client.classLabel)
                            .foregroundStyle(.secondary)
                    }
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
            .tint(.blue)
            .navigationTitle(client.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
                    }
                }
            }
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
