import SwiftUI

/// 网络页（v2.6.5 新增；v2.6.7 顶部换拓扑树；v2.6.8 按官方 App 补字段；
/// v2.7.0 这一页可写；v2.8.0 补实时速率 / 累计流量 / 会话数，并把可改的项补全）。
///
/// **数据来自 `PollItem.network` 那一条采集脚本**（`ubus` / `uci` / `iwinfo` /
/// `gl-clients`），字段组织照 GL.iNet 官方 App 的 `internet_*` / `client_*` / `eth_*` /
/// `lan_*` 四组来，不是自己编的。
///
/// **能改的六件事**（都写路由器自己的配置，和官方 App 同一套通道）：
///   - 无线：名称 / 密码 / 隐藏 / 启用 / 信道 / 频宽 / 发射功率（`uci wireless` + `wifi reload`）；
///   - 频段开关（列表里那个 Toggle，一步到位不弹窗）；
///   - 设备：改名（`gl-client.alias`）、固定地址（`dhcp` 的 host 段）、阻止入网（GL 黑名单）；
///   - 清掉离线记录（`gl-clients remove_offline`）；
///   - 出口重连（中继先 `repeater reload`，再 `ifdown/ifup`）。
///
/// **版式四块**：拓扑 → 上网 → 无线 → 设备 → 局域网与端口。
/// 被动信息进多列网格（标签在上、值在下），只有能点的地方才排成整行。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false
    @State private var reconnecting = false
    @State private var clearingOffline = false
    @State private var editingBand: WifiBandInfo?
    @State private var editingClient: NetClient?
    @State private var togglingBand: String?

    private var info: NetworkInfo { model.network }

    private static let leafSpacing: CGFloat = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    topology
                    uplinkCard
                    wifiCard
                    clientsCard
                    lanCard
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
            // 底栏在 `MainTabs` 上挂了 `.tint(.primary)`，那是往下传的环境值，
            // 不补这一句整页控件会跟着变黑（v2.1.17 的教训）。
            .tint(.blue)
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
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await model.manualRefresh()
        refreshing = false
    }

    // MARK: - 拓扑

    /// 竖着排的一条链路：出口 → 路由器 → 分叉 → 叶子。
    /// 连线由 `trunk` / `TopoFork` 画，节点各自是独立的小卡片，
    /// 这样断线只要把那一节变灰，不用重算整张图。
    private var topology: some View {
        let leaves = leafNodes
        return VStack(spacing: 0) {
            internetNode
            trunk(ok: info.uplinkOK, color: NetPalette.wan)
            routerNode
            if !leaves.isEmpty {
                TopoFork(leaves: leaves, spacing: Self.leafSpacing)
                HStack(alignment: .top, spacing: Self.leafSpacing) {
                    ForEach(leaves) { leaf in
                        leafNode(leaf)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// 出口那一个胶囊：走什么方式、上级是谁、什么协议。
    private var internetNode: some View {
        let on = info.uplinkOK
        return HStack(spacing: 8) {
            Image(systemName: info.uplink == .repeater ? "wifi" : "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? NetPalette.wan : Color.secondary)
            Text(info.uplinkLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(info.uplink == .none ? "—" : info.protoLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? NetPalette.wan : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill((on ? NetPalette.wan : Color.secondary).opacity(0.12))
                }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background { nodeBackground(radius: 15) }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 出口 → 路由器 的那一截竖线。断线时变灰，不画成虚线
    /// （虚线在 22pt 的高度里看着像没画完）。
    private func trunk(ok: Bool, color: Color) -> some View {
        Rectangle()
            .fill(ok ? color.opacity(0.55) : Color(.systemGray4).opacity(0.8))
            .frame(width: 1.6, height: 22)
    }

    /// 中心节点：型号 / 局域网地址 / 实时上下行。整页的视觉重心就是这一块。
    private var routerNode: some View {
        HStack(spacing: 12) {
            Image(systemName: "router")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background { Circle().fill(Color.primary.opacity(0.055)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(info.lanIP.isEmpty ? "—" : info.lanIP)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                rateLine("arrow.down", info.rxSpeed)
                rateLine("arrow.up", info.txSpeed)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.6)
        }
    }

    /// 路由器节点右侧一行速率：小箭头 + 数字 + 单位。上下行各一行。
    private func rateLine(_ symbol: String, _ bytes: Double) -> some View {
        let parts = speedParts(bytes)
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(parts.value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
            Text(parts.unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// 叶子：2.4G / 5G 各一片，最后一片是有线。
    private var leafNodes: [TopoLeaf] {
        var out: [TopoLeaf] = []
        for band in info.bands.prefix(2) {
            let value: String
            if !band.up || !band.ssidOn {
                value = "已关闭"
            } else if band.channel > 0 {
                value = "\(band.clients) 台 · CH \(band.channel)"
            } else {
                value = "\(band.clients) 台"
            }
            out.append(TopoLeaf(id: band.id,
                                title: band.bandName,
                                value: value,
                                icon: "wifi",
                                color: NetPalette.wifi,
                                on: band.up && band.ssidOn))
        }
        out.append(TopoLeaf(id: "wired",
                            title: "有线",
                            value: info.wiredOK ? info.bestPortLabel : "未连接",
                            icon: "cable.connector",
                            color: NetPalette.wired,
                            on: info.wiredOK))
        return out
    }

    private func leafNode(_ leaf: TopoLeaf) -> some View {
        VStack(spacing: 5) {
            Image(systemName: leaf.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(leaf.on ? leaf.color : Color(.systemGray3))
            Text(leaf.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(leaf.on ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(leaf.value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background { nodeBackground(radius: 14) }
    }

    /// 节点底：白底 + 一条细边，与下面几张卡片同一套语言（只是没有阴影）。
    private func nodeBackground(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
            }
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

    private var uplinkCard: some View {
        card("上网", trailing: info.uplink == .none ? "未联网" : info.protoLabel) {
            // 每行都必须是 3 格：`metricGrid` 按 HStack 等分，行内格数不同就会
            // 和上下行错开半个身位（两格各占一半、三格各占三分之一）。
            metricGrid([
                [("方式", info.uplink.title, nil),
                 ("上级网络", info.upstreamSSID.isEmpty ? "—" : info.upstreamSSID, nil),
                 ("信号", info.upstreamSignal != 0 ? "\(info.upstreamSignal) dBm" : "—",
                  info.upstreamSignal != 0 ? signalColor(info.upstreamSignal) : nil)],
                [("地址", info.uplinkIP.isEmpty ? "—" : info.uplinkIP, nil),
                 ("网关", info.uplinkGateway.isEmpty ? "—" : info.uplinkGateway, nil),
                 ("在线时长", info.uplinkUptime > 0 ? durationLabel(info.uplinkUptime) : "—", nil)],
                [("协商速率", info.upstreamRate.isEmpty ? "—" : info.upstreamRate, nil),
                 ("会话", info.connections > 0 ? "\(info.connections)" : "—", nil),
                 ("累计", trafficLabel, nil)]
            ])
            divider
            // DNS 常常两条、一条十几个字符，塞进三分之一宽只会被截成「192.16…」，
            // 所以单独占一整行。
            metricGrid([[("DNS", info.uplinkDNS.isEmpty ? "—" : info.uplinkDNS.prefix(2).joined(separator: "  "), nil)]])
            divider
            actionRow(reconnecting ? "正在重连…" : "重新连接",
                      symbol: "arrow.triangle.2.circlepath",
                      busy: reconnecting) {
                Task { await reconnect() }
            }
        }
    }

    /// 出口网口自开机以来的累计流量，两个方向挤在一格里（`↓ 392 GB ↑ 67 GB`）。
    private var trafficLabel: String {
        guard info.wanRxTotal + info.wanTxTotal > 0 else { return "—" }
        return "↓ \(formatBytes(info.wanRxTotal))  ↑ \(formatBytes(info.wanTxTotal))"
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

    // MARK: - 无线

    private var wifiCard: some View {
        card("无线") {
            if info.bands.isEmpty {
                emptyLine
            } else {
                ForEach(info.bands) { band in
                    if band.id != info.bands.first?.id { divider }
                    bandRow(band)
                }
            }
        }
    }

    /// 一行一个频段：左半边点了进编辑，右边是开关。
    /// 开关直接写配置（不弹窗），因为「关掉 2.4G」是高频动作，不值得两步走。
    private func bandRow(_ band: WifiBandInfo) -> some View {
        let live = band.up && band.ssidOn
        return HStack(spacing: 10) {
            Button {
                editingBand = band
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(live ? NetPalette.wifi : Color(.systemGray3))
                        .frame(width: 28, height: 28)
                        .background {
                            Circle().fill((live ? NetPalette.wifi : Color(.systemGray4)).opacity(0.12))
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(band.bandName)
                                .font(.system(size: 15))
                                .foregroundStyle(live ? Color.primary : Color.secondary)
                            Text(band.ssid.isEmpty ? "—" : band.ssid)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // 第二行：信道 · 频宽 · 功率 · 加密 · 台数。挤在一行是为了
                        // 让「无线」这一块只有两行高，但该看的数一个不少。
                        Text(bandDetail(band))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 6)
                    Text(band.clients > 0 ? "\(band.clients) 台" : "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!band.editable || togglingBand != nil)

            Toggle("", isOn: Binding(
                get: { band.ssidOn },
                set: { on in Task { await toggle(band, on) } }
            ))
            .labelsHidden()
            .disabled(!band.editable || togglingBand != nil)
        }
        .padding(.vertical, 9)
    }

    /// 频段第二行：`CH 56 · 80 MHz · 100% · WPA3 混合`。关闭时只写「已关闭」。
    private func bandDetail(_ band: WifiBandInfo) -> String {
        guard band.up, band.ssidOn else { return "已关闭" }
        var parts: [String] = []
        if band.channel > 0 { parts.append("CH \(band.channel)") }
        if !band.width.isEmpty { parts.append("\(band.width) MHz") }
        if band.txPowerPercent > 0 { parts.append("\(band.txPowerPercent)%") }
        if !band.encryption.isEmpty { parts.append(band.securityLabel) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func toggle(_ band: WifiBandInfo, _ on: Bool) async {
        guard togglingBand == nil else { return }
        togglingBand = band.id
        let problem = await model.setBandEnabled(band, on)
        await model.manualRefresh()
        togglingBand = nil
        if let problem {
            model.presentError(problem)
        } else {
            model.notice = Notice(kind: .ok,
                                  title: on ? "\(band.bandName) 已开启" : "\(band.bandName) 已关闭",
                                  detail: band.ssid)
        }
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

    // MARK: - 局域网与端口

    private var lanCard: some View {
        card("局域网与端口", trailing: info.ports.filter(\.up).isEmpty ? "" : "\(info.ports.filter(\.up).count) 个已连接") {
            // 这一卡统一两列：网口名 + 协商速率那一格要放「1000 Mbps 全双工」，
            // 挤成三分之一宽会被截断。
            metricGrid([
                portCells,
                [("路由器", info.lanMask.isEmpty ? info.lanIP : "\(info.lanIP) / \(info.lanMask)", nil),
                 ("DHCP 池", dhcpPoolLabel.isEmpty ? "—" : dhcpPoolLabel, nil)],
                [("租期", info.dhcpLease.isEmpty ? "—" : info.dhcpLease, nil),
                 ("租约", info.leaseCount > 0 ? "\(info.leaseCount) 个" : "—", nil)]
            ])
        }
    }

    /// 网口那两格：WAN 和 LAN 各一格，值直接说「通没通 + 协商速率」。
    /// WAN 没插线时值写「未插网线」——比「未连接」多一个有用的判断。
    private var portCells: [(String, String, Color?)] {
        var cells: [(String, String, Color?)] = []
        for port in info.ports.prefix(2) {
            let label = port.name.isEmpty ? port.role : "\(port.role) \(port.name)"
            var value = port.detailLabel
            if port.role == "WAN" && !port.up {
                value = info.wanCable ? "已插网线，未联网" : "未插网线"
            }
            cells.append((label, value, port.up ? nil : Color.secondary))
        }
        while cells.count < 2 { cells.append(("端口", "—", nil)) }
        return cells
    }

    /// `dhcp.lan.start=100` + `limit=150` → `192.168.8.100 – 249`。
    private var dhcpPoolLabel: String {
        guard let start = Int(info.dhcpStart), let limit = Int(info.dhcpLimit), limit > 0 else {
            return info.dhcpStart
        }
        let prefix = info.lanIP.split(separator: ".").dropLast().joined(separator: ".")
        let end = start + limit - 1
        return prefix.isEmpty ? "\(start) – \(end)" : "\(prefix).\(start) – \(end)"
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(color ?? Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
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
                            .navBarTint()
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
                            .navBarTint()
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
    let value: String
    let icon: String
    let color: Color
    /// 这一路通不通：不通则图标、标题、连线一起变灰。
    let on: Bool
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
