import SwiftUI

/// 网络页（v2.6.5 新增；v2.6.7 顶部换拓扑树；v2.6.8 按官方 App 的字段补全）。
///
/// **只读**：全部字段来自 `PollItem.network` 那一条采集脚本（`ubus` / `uci` / `iwinfo` /
/// `gl-clients`），这一页没有任何写操作。
///
/// 版式与字段都照 GL.iNet 官方 App 的组织来（`intl_zh.arb` 里的 `internet_*` / `client_*` /
/// `eth_*` / `lan_*` 四组就是它的页面结构，不是我自己编的）：
///   - 顶部**拓扑图**：互联网 → 路由器 → 2.4G / 5G / 有线。出口可能是**中继**，
///     不一定是有线 WAN——这台机器当时 WAN 口就空着（v2.6.7 整页「未连接」的根源）；
///   - 「上网」：方式 / 上级网络 / 信号 / 协商速率 / 地址 / 网关 / DNS / 在线时长；
///   - 「在线设备」：名称 / IP / 接入方式 / 累计流量（官方客户端列表那几项）；
///   - 「无线」：每频段 SSID / 信道与频宽 / 加密 / 台数；
///   - 「网络端口」：已连接或未连接 / 协商速率 / 全双工；
///   - 「局域网」：路由器 IP / DHCP 池 / 租期与租约数。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）：卡片里只有「名字 → 值」。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false

    private var info: NetworkInfo { model.network }

    private static let leafSpacing: CGFloat = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    topology
                    uplinkCard
                    clientsCard
                    wifiCard
                    portCard
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
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await model.manualRefresh()
        refreshing = false
    }

    // MARK: - 拓扑

    /// 竖着排的一条链路：互联网 → 路由器 → 分叉 → 叶子。
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
    ///
    /// 中继时是「中继 · @Ruijie-s0051」，有线时是「以太网 · 192.168.1.2」，
    /// 都没通才是「未联网」——不会再出现「WAN 没插线所以整页说没网」那种误判。
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

    /// 互联网 → 路由器 的那一截竖线。断线时变灰并降透明度，不画成虚线
    /// （虚线在 22pt 的高度里看着像没画完）。
    private func trunk(ok: Bool, color: Color) -> some View {
        Rectangle()
            .fill(ok ? color.opacity(0.55) : Color(.systemGray4).opacity(0.8))
            .frame(width: 1.6, height: 22)
    }

    /// 中心节点：型号 / 局域网地址 / 实时下行速率。整页的视觉重心就是这一块。
    private var routerNode: some View {
        let speed = speedParts
        return HStack(spacing: 12) {
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
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(speed.unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    /// 叶子：2.4G / 5G 各一片，最后一片是有线。
    /// 这一层只回答「通不通、几台」，明细都在下面的卡片里。
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

    /// 路由器节点里那两个值：把 `12.4 MB/s` 拆成数字和单位，数字才能用大字号。
    private var speedParts: (value: String, unit: String) {
        let parts = formatBytes(info.rxSpeed).split(separator: " ")
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
            infoRow("方式", info.uplink.title)
            if info.uplink == .repeater {
                if !info.upstreamSSID.isEmpty {
                    hairline
                    infoRow("上级网络", info.upstreamSSID)
                }
                if info.upstreamSignal != 0 {
                    hairline
                    infoRow("信号", "\(info.upstreamSignal) dBm",
                            valueColor: signalColor(info.upstreamSignal))
                }
                if !info.upstreamRate.isEmpty {
                    hairline
                    infoRow("协商速率", info.upstreamRate)
                }
            }
            if !info.uplinkIP.isEmpty {
                hairline
                infoRow("地址", info.uplinkIP)
            }
            if !info.uplinkGateway.isEmpty {
                hairline
                infoRow("网关", info.uplinkGateway)
            }
            // 网关和 DNS 相同时只显示一行：中继上游这两项基本永远是同一个地址。
            if let dns = info.uplinkDNS.first, dns != info.uplinkGateway {
                hairline
                infoRow("DNS", info.uplinkDNS.prefix(2).joined(separator: "  "))
            }
            if info.uplinkUptime > 0 {
                hairline
                infoRow("在线时长", durationLabel(info.uplinkUptime))
            }
            hairline
            infoRow("实时速率", "↓ \(rateText(info.rxSpeed))   ↑ \(rateText(info.txSpeed))")
        }
    }

    private func rateText(_ bytes: Double) -> String {
        formatBytes(max(bytes, 0)) + "/s"
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

    // MARK: - 在线设备

    private var clientsCard: some View {
        card("在线设备", trailing: "\(info.onlineClients.count) 台") {
            let clients = info.onlineClients
            if clients.isEmpty {
                emptyLine
            } else {
                ForEach(clients) { client in
                    if client.id != clients.first?.id { hairline }
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: NetClient) -> some View {
        let wired = client.iface == "有线"
        // 第一行是名字，没名字时退到 IP；这时第二行改显示 MAC，否则两行会一模一样。
        let named = !client.name.trimmingCharacters(in: .whitespaces).isEmpty && client.name != "*"
        let second = named ? (client.ip.isEmpty ? client.mac : client.ip) : client.mac
        return HStack(spacing: 10) {
            Image(systemName: wired ? "cable.connector" : "wifi")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(wired ? NetPalette.wired : NetPalette.wifi)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill((wired ? NetPalette.wired : NetPalette.wifi).opacity(0.12))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Text(second)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(client.iface.isEmpty ? "—" : client.iface)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(client.trafficLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 9)
    }

    // MARK: - 无线

    private var wifiCard: some View {
        card("无线", trailing: info.wifiClients > 0 ? "\(info.wifiClients) 台在线" : "") {
            if info.bands.isEmpty {
                emptyLine
            } else {
                ForEach(info.bands) { band in
                    if band.id != info.bands.first?.id { hairline }
                    bandRow(band)
                }
            }
        }
    }

    private func bandRow(_ band: WifiBandInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(band.bandName)
                    .font(.system(size: 15))
                    .foregroundStyle(band.up ? Color.primary : Color.secondary)
                Spacer(minLength: 8)
                Text(band.channelLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Text(band.ssid.isEmpty ? "—" : band.ssid)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(bandStatus(band))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 10)
    }

    /// 主 SSID 关掉但访客 / IoT / MLO 还在广播是常见操作（这台机器 2.4G 就是这样），
    /// 所以状态按「这条路还通不通」说，而不是按 radio 的开关说。
    private func bandStatus(_ band: WifiBandInfo) -> String {
        guard band.up, band.ssidOn else { return "已关闭" }
        var parts: [String] = []
        if !band.encryption.isEmpty { parts.append(band.securityLabel) }
        parts.append("\(band.clients) 台")
        if band.extraNets > 0 { parts.append("另 \(band.extraNets) 个网络") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 网络端口

    private var portCard: some View {
        card("网络端口", trailing: info.ports.filter(\.up).isEmpty ? "" : "\(info.ports.filter(\.up).count) 个已连接") {
            if info.ports.isEmpty {
                emptyLine
            } else {
                ForEach(info.ports) { port in
                    if port.id != info.ports.first?.id { hairline }
                    portRow(port)
                }
            }
        }
    }

    private func portRow(_ port: NetPortInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(port.up ? Color(red: 0.13, green: 0.66, blue: 0.38) : Color(.systemGray4))
                    .frame(width: 6, height: 6)
                Text(port.role)
                    .font(.system(size: 15))
                Text(port.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(port.detailLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(port.up ? Color.primary : Color.secondary)
                    .monospacedDigit()
            }
            if port.role == "WAN" && !port.up {
                Text(info.wanCable ? "已插网线，未联网" : "未插网线")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - 局域网

    private var lanCard: some View {
        card("局域网", trailing: info.leaseCount > 0 ? "\(info.leaseCount) 个租约" : "") {
            infoRow("路由器", info.lanMask.isEmpty ? info.lanIP : "\(info.lanIP) / \(info.lanMask)")
            if !info.dhcpStart.isEmpty {
                hairline
                infoRow("DHCP 池", dhcpPoolLabel)
            }
            if !info.dhcpLease.isEmpty {
                hairline
                infoRow("租期", info.dhcpLease)
            }
            hairline
            infoRow("客户端", "\(info.onlineClients.count) 台在线 · \(info.clients.count) 台记录")
        }
    }

    /// `dhcp.lan.start=100` + `limit=150` → `192.168.8.100 – 249`。
    /// 直接拼网段的最后一节：池永远是「同网段 + 起止数字」，不需要真的算地址。
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
    /// `trailing` 是标题右侧那一个总览值（「3 台」「12 个租约」）。
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
            .padding(.bottom, 2)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
        }
    }

    private func infoRow(_ title: String, _ value: String,
                         valueColor: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(valueColor ?? Color.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 10)
    }

    private var hairline: some View {
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
