import SwiftUI

/// 网络页（v2.6.5 新增；v2.6.6 按用户要求换成 C 版：细线分层 + 状态环）。
///
/// **只读**：全部字段来自 `PollItem.network` 那条采集脚本（`uci` / `ubus` / `iwinfo`），
/// 这一页没有任何写操作。
///
/// 版式的取舍：
///   - 顶部不是卡片，是一个**三段弧的状态环**。三段分别对应 WAN、无线、有线，
///     哪一路不通哪一段就淡下去——不合成总分，因为合成分数一旦算错，
///     用户第一反应就是「数据有问题」，而三段各自都能在下面找到对应的一行去核对。
///   - 环心是**当前下行速率**（每秒更新，是本页唯一持续变化的值）；
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
                    statusBlock
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

    // MARK: - 状态环

    private var statusBlock: some View {
        let speed = speedParts
        return VStack(spacing: 14) {
            ZStack {
                StatusArcs(wan: info.wanOK, wifi: info.wifiOK, wired: info.wiredOK)
                VStack(spacing: 1) {
                    Text(speed.value)
                        .font(.system(size: 46, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(speed.unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 34)
            }
            .frame(height: 198)
            .padding(.top, 8)

            Text(deviceName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 18) {
                legendDot("WAN", on: info.wanOK, color: StatusArcs.wanColor)
                legendDot("无线", on: info.wifiOK, color: StatusArcs.wifiColor)
                legendDot("有线", on: info.wiredOK, color: StatusArcs.wiredColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 环心那两个值：把 `12.4 MB/s` 拆成数字和单位，数字才能用大字号。
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

    private func legendDot(_ title: String, on: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? color : Color(.systemGray4))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
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

/// 状态环：三段弧，每段 108°、间隙 4°，从正上方顺时针排。
///
/// 用 `Canvas` 一次画完（纯装饰线条 + 渐变），外层 `.drawingGroup()` 压成离屏图层——
/// 滚动时只做位移合成，不会每帧重跑这段绘制（同 `SpeedSparkline`，见 v2.2.0）。
private struct StatusArcs: View {
    let wan: Bool
    let wifi: Bool
    let wired: Bool

    static let wanColor = Color(red: 0.16, green: 0.45, blue: 0.95)
    static let wifiColor = Color(red: 0.09, green: 0.60, blue: 0.72)
    static let wiredColor = Color(red: 0.45, green: 0.35, blue: 0.88)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 13
            guard radius > 20 else { return }

            let lineWidth: CGFloat = 12
            let gap = CGFloat.pi * 2 / 90
            let span = (CGFloat.pi * 2 - gap * 3) / 3

            // 底环：三段全断的时候页面不至于只剩中间一串数字。
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(Color.primary.opacity(0.045)),
                style: StrokeStyle(lineWidth: lineWidth)
            )

            let segments: [(on: Bool, color: Color)] = [
                (wan, Self.wanColor),
                (wifi, Self.wifiColor),
                (wired, Self.wiredColor)
            ]

            for (index, segment) in segments.enumerated() {
                let start = -CGFloat.pi / 2 + CGFloat(index) * (span + gap)
                var arc = Path()
                arc.addArc(center: center,
                           radius: radius,
                           startAngle: .radians(Double(start)),
                           endAngle: .radians(Double(start + span)),
                           clockwise: false)

                guard segment.on else {
                    context.stroke(arc,
                                   with: .color(segment.color.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    continue
                }

                // 先画一圈同色更宽更淡的，远看像弧在发光；再用渐变把弧本身提亮。
                context.stroke(arc,
                               with: .color(segment.color.opacity(0.12)),
                               style: StrokeStyle(lineWidth: lineWidth + 10, lineCap: .round))
                context.stroke(arc,
                               with: .linearGradient(
                                   Gradient(colors: [segment.color.opacity(0.70), segment.color]),
                                   startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                                   endPoint: CGPoint(x: center.x + radius, y: center.y + radius)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}
