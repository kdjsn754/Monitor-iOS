import SwiftUI

/// 网络页（v2.6.5 新增；v2.6.6 按用户要求换成 C 版：细线分层 + 状态环）。
///
/// **只读**：全部字段来自 `PollItem.network` 那条采集脚本（`uci` / `ubus` / `iwinfo`），
/// 这一页没有任何写操作。
///
/// 版式的取舍（v2.6.7 用户「太丑了顶部改成拓扑图」→ 三段弧换成拓扑树）：
///   - 顶部是一张**拓扑图**：互联网 → WAN → 路由器 → 三个叶子（2.4G / 5G / 有线）。
///     哪一路不通，那一节节点和连线一起变灰——不合成总分，因为合成分数一旦算错，
///     用户第一反应就是「数据有问题」，而每一节都能在下面找到对应的行去核对。
///   - 路由器节点里放**当前下行速率**（每秒更新，是本页唯一持续变化的值）和型号；
///   - 下面三张细线卡片：无线（2.4G / 5G 各一行）、有线（WAN / LAN 各一行）、地址。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）：卡片里只有「名字 → 值」。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false

    private var info: NetworkInfo { model.network }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    topology
                    wifiCard
                    portCard
                    addressCard
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

    /// 竖着排的一条链路：互联网 → WAN → 路由器 → 分叉 → 叶子。
    /// 连线由 `trunk` / `TopoFork` 画，节点各自是独立的小卡片，
    /// 这样断线只要把那一节变灰，不用重算整张图。
    private var topology: some View {
        let leaves = leafNodes
        return VStack(spacing: 0) {
            internetNode
            trunk(ok: info.wanOK, color: NetPalette.wan)
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

    private static let leafSpacing: CGFloat = 8

    /// 公网那一个胶囊：只有「地址 + 连接方式」两个事实，没有别的话。
    private var internetNode: some View {
        let on = info.wanOK
        let address = info.wanIP.isEmpty ? (on ? "已连接" : "未连接") : info.wanIP
        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? NetPalette.wan : Color.secondary)
            Text(address)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .lineLimit(1)
            Text(info.wanProtoLabel)
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

    /// 中心节点：型号 / 局域网地址 / 下行速率。整页的视觉重心就是这一块。
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

    /// 叶子：2.4G / 5G 各一个，最后一个是有线（不分 WAN、LAN，速率取最快的那个口）。
    private var leafNodes: [TopoLeaf] {
        var out: [TopoLeaf] = []
        for band in info.bands.prefix(2) {
            let value: String
            if !band.up {
                value = "已关闭"
            } else if band.channel > 0 {
                value = "CH \(band.channel)"
            } else {
                value = "\(band.clients) 台"
            }
            out.append(TopoLeaf(id: band.id,
                                title: band.bandName,
                                value: value,
                                icon: "wifi",
                                color: NetPalette.wifi,
                                on: band.up))
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
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background { nodeBackground(radius: 14) }
    }

    /// 节点底：白底 + 一条细边，与下面三张卡片同一套语言（只是没有阴影）。
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
        let parts = formatBytes(model.stats.download).split(separator: " ")
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

    // MARK: - 无线

    private var wifiCard: some View {
        card("无线") {
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
                Text(bandMeta(band))
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
                Text(band.up ? "\(band.clients) 台" : "已关闭")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
    }

    private func bandMeta(_ band: WifiBandInfo) -> String {
        var parts: [String] = []
        if band.channel > 0 { parts.append("CH \(band.channel)") }
        if !band.width.isEmpty { parts.append("\(band.width)M") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: - 有线

    private var portCard: some View {
        card("有线") {
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
                Spacer(minLength: 8)
                Text(port.speedLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(port.up ? Color.primary : Color.secondary)
                    .monospacedDigit()
            }
            Text(portDetail(port))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
    }

    /// WAN 那行后面跟「连接方式 · 公网地址」，LAN 那行跟路由器地址。
    /// 网口本身的名字（`eth0`）不显示：这一行要回答的是「这条线通不通、有多快」。
    private func portDetail(_ port: NetPortInfo) -> String {
        if port.role == "WAN" { return info.wanLabel }
        return info.lanIP.isEmpty ? "—" : info.lanIP
    }

    // MARK: - 地址

    private var addressCard: some View {
        card("地址") {
            infoRow("公网", info.wanOK ? (info.wanIP.isEmpty ? "—" : info.wanIP) : "未连接")
            if !info.wanGateway.isEmpty {
                hairline
                infoRow("网关", info.wanGateway)
            }
            if !info.dns.isEmpty {
                hairline
                infoRow("DNS", info.dns.prefix(2).joined(separator: "  "))
            }
            if !info.lanIP.isEmpty {
                hairline
                infoRow("局域网", info.lanIP)
            }
            if !info.dhcpStart.isEmpty {
                hairline
                infoRow("DHCP 池", info.dhcpLimit.isEmpty
                        ? info.dhcpStart
                        : "\(info.dhcpStart) · \(info.dhcpLimit)")
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 小组件

    /// C 版的卡片：白底 + 一条 0.6pt 细边，没有阴影。靠留白分层，不靠色块。
    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
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

/// 拓扑图的三色：蓝=WAN、青=无线、紫=有线。
/// 单独放一个 enum，是为了下面卡片里的圆点、叶子图标、连线全用同一组值，
/// 改色只改这一处（v2.6.6 之前散在 `StatusArcs` 的 static 里）。
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
