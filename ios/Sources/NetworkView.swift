import SwiftUI

/// 网络页（v2.6.5 新增，用户 2026-11-15：「在代理和设置中间增加一页网络设置，
/// 页面风格要大气华丽的图形界面」）。
///
/// **只读**：全部字段来自 `PollItem.network` 那条采集脚本（`uci show` /
/// `ubus call network.interface…` / `iw dev`），这一页没有任何写操作。
///
/// 版式按用户选定的「拓扑头图」方案：
///   - 顶部一块深蓝渐变卡，画「互联网 → 路由器 → 设备」的拓扑，底边三枚胶囊给
///     有线速率 / 无线频宽 / 无线客户端数；
///   - 「无线」卡：一个 AP 接口一行（2.4 GHz / 5 GHz），行尾是信道、频宽、台数；
///   - 「有线」卡：一个物理网口一行，WAN 那行带连接方式与公网地址，行尾是握手速率。
///
/// **没有一行说明性小字**（用户 2026-10-31 定的规矩）：卡片里只有「名字 → 值」，
/// 拓扑图本身负责解释关系，不加脚注、不加副标题。
struct NetworkView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var refreshing = false

    private var info: NetworkInfo { model.network }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    wifiCard
                    portCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
                // 滚动手感跟另外两个根页完全一致（见 ScrollTuning.swift 与 7.1）：
                // 长页正常回弹、短页拉不动，都不碰下拉刷新。
                .background(ScrollBounceTuning())
            }
            .scrollBounceBehavior(.basedOnSize)
            // 顶部滚动边缘效果：标题滑到状态栏下面时由系统糊一层，否则硬叠在时间上。
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 本页控件（进度圈、按钮）保持蓝：底栏在 `MainTabs` 上挂了 `.tint(.primary)`，
            // 那是往下传的环境值，不补这一句整页控件会跟着变黑（v2.1.17 的教训）。
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

    // MARK: - 头图

    /// 深色渐变卡。渐变和拓扑是这张卡的「壳」，`drawingGroup()` 把它压成一个离屏图层：
    /// 滚动时只做图层位移，不再每帧重画一圈圈的弧（跟 `SpeedSparkline` 同一招，见 v2.2.0）。
    private var hero: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.039, green: 0.145, blue: 0.251), location: 0),
                    .init(color: Color(red: 0.071, green: 0.243, blue: 0.388), location: 0.55),
                    .init(color: Color(red: 0.106, green: 0.400, blue: 0.565), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HeroTopology()
                .frame(height: 168)
                .drawingGroup()

            VStack(spacing: 10) {
                Text(info.loaded ? deviceName : " ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.56, green: 0.78, blue: 0.92))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    heroPill("\(info.bestPortLabel) 有线")
                    heroPill("\(info.widestBandLabel) 频宽")
                    heroPill("\(info.wifiClients) 台无线")
                }
            }
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// 头图中间那行型号。`routerInfo.model` 要等 `refreshInfo` 回来才有，
    /// 拿不到就退到界面上的连接名（`connectionName` 本身是「备注 → 设备名 → IP」三级回落，见 v2.5.5）。
    private var deviceName: String {
        let reported = model.routerInfo.model.trimmingCharacters(in: .whitespaces)
        if !reported.isEmpty { return reported }
        guard let profile = model.currentProfile else { return "OpenWrt" }
        return model.connectionName(for: profile)
    }

    private func heroPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 0.92, green: 0.96, blue: 1.0))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.13), in: Capsule())
    }

    // MARK: - 无线

    private var wifiCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("无线")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(info.wifiClients) 台")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            if info.bands.isEmpty {
                placeholderRow
            } else {
                ForEach(info.bands) { band in
                    if band.id != info.bands.first?.id { hairline }
                    bandRow(band)
                }
            }
        }
        .glassCard(padding: 16, cornerRadius: 20)
    }

    private func bandRow(_ band: WifiBandInfo) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(band.bandName)
                    .font(.system(size: 15))
                Text(band.ssid.isEmpty ? "—" : band.ssid)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if band.channel > 0 {
                chip("CH \(band.channel)")
            }
            if !band.width.isEmpty {
                chip("\(band.width)M")
            }
            Text("\(band.clients) 台")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 有线

    private var portCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("有线")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text(info.ports.count > 0 ? "\(info.ports.count) 口" : "—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            if info.ports.isEmpty {
                placeholderRow
            } else {
                ForEach(info.ports) { port in
                    if port.id != info.ports.first?.id { hairline }
                    portRow(port)
                }
            }
        }
        .glassCard(padding: 16, cornerRadius: 20)
    }

    private func portRow(_ port: NetPortInfo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(port.up ? Color.green : Color(.systemGray3))
                .frame(width: 7, height: 7)
            Text(port.role)
                .font(.system(size: 14))
            Text(portDetail(port))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(port.speedLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(port.up ? Color.green : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    (port.up ? Color.green.opacity(0.12) : Color(.tertiarySystemFill)),
                    in: Capsule()
                )
        }
        .padding(.vertical, 10)
    }

    /// WAN 那行后面跟「连接方式 · 公网地址」，LAN 那行跟路由器地址。
    /// 端口本身的名字（`eth0`）不显示：这一行要回答的是「这条线通不通、有多快」。
    private func portDetail(_ port: NetPortInfo) -> String {
        if port.role == "WAN" {
            let address = info.wanIP.isEmpty ? info.wanProtoLabel : "\(info.wanProtoLabel) · \(info.wanIP)"
            return port.up ? address : (info.wanProtoLabel.isEmpty ? "—" : info.wanProtoLabel)
        }
        return info.lanIP.isEmpty ? "—" : info.lanIP
    }

    // MARK: - 小组件

    private var hairline: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.55))
            .frame(height: 0.5)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemFill), in: Capsule())
    }

    private var placeholderRow: some View {
        Text("—")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

/// 头图里那张拓扑：云 → 路由器 → 三台设备，背后三圈同心弧。
///
/// 用 `Canvas` 画而不是拼 `Path` 视图：这里全是装饰性线条，一次画完最省事；
/// 外层套了 `.drawingGroup()`，滚动时只做图层位移，不会每帧重跑这段 draw。
private struct HeroTopology: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let router = CGPoint(x: w * 0.50, y: h * 0.46)

            // 同心弧：越外越淡，给中心一点「信号扩散」的纵深。
            let arcScales: [CGFloat] = [0.22, 0.34, 0.46]
            for (index, factor) in arcScales.enumerated() {
                let radius = w * factor
                let rect = CGRect(x: router.x - radius,
                                  y: router.y - radius,
                                  width: radius * 2,
                                  height: radius * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(0.10 - Double(index) * 0.028)),
                    lineWidth: 1
                )
            }

            // 云（三团重叠的圆 + 一块底座，纯色低透明度，远看是朵云的剪影）
            let cloud = CGPoint(x: w * 0.13, y: h * 0.42)
            let puffs: [(dx: CGFloat, dy: CGFloat, r: CGFloat)] = [
                (-9, 2, 8), (0, -3, 10), (9, 2, 8)
            ]
            for puff in puffs {
                let rect = CGRect(x: cloud.x + puff.dx - puff.r,
                                  y: cloud.y + puff.dy - puff.r,
                                  width: puff.r * 2,
                                  height: puff.r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.16)))
            }
            context.fill(
                Path(roundedRect: CGRect(x: cloud.x - 11, y: cloud.y + 2, width: 22, height: 8),
                     cornerRadius: 4),
                with: .color(.white.opacity(0.16))
            )

            // 云 → 路由器：虚线，中途断开的画法正好表示「这一跳是无线/外网」
            var wan = Path()
            wan.move(to: CGPoint(x: cloud.x + 18, y: cloud.y))
            wan.addLine(to: CGPoint(x: router.x - w * 0.16, y: router.y))
            context.stroke(
                wan,
                with: .color(.white.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1.4, dash: [4, 4])
            )

            // 路由器机身
            let bodyWidth = w * 0.24
            let bodyHeight: CGFloat = 34
            let bodyRect = CGRect(x: router.x - bodyWidth / 2,
                                  y: router.y - bodyHeight / 2,
                                  width: bodyWidth,
                                  height: bodyHeight)
            let body = Path(roundedRect: bodyRect, cornerRadius: 11)
            context.fill(body, with: .color(.white.opacity(0.13)))
            context.stroke(body, with: .color(.white.opacity(0.50)), lineWidth: 1.2)

            // 两根天线
            for offset in [-bodyWidth * 0.28, bodyWidth * 0.28] {
                var antenna = Path()
                antenna.move(to: CGPoint(x: router.x + offset, y: bodyRect.minY))
                antenna.addLine(to: CGPoint(x: router.x + offset, y: bodyRect.minY - 8))
                context.stroke(
                    antenna,
                    with: .color(.white.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
            }

            // 机身里那一格（不是指示灯，是「面板」的意思）
            context.fill(
                Path(roundedRect: CGRect(x: bodyRect.minX + 10,
                                         y: router.y - 3,
                                         width: bodyWidth * 0.46,
                                         height: 6),
                     cornerRadius: 3),
                with: .color(.white.opacity(0.30))
            )

            // 路由器 → 三台设备
            let devices = [
                CGPoint(x: w * 0.86, y: h * 0.26),
                CGPoint(x: w * 0.89, y: h * 0.46),
                CGPoint(x: w * 0.86, y: h * 0.66)
            ]
            for point in devices {
                var link = Path()
                link.move(to: CGPoint(x: bodyRect.maxX, y: router.y))
                link.addLine(to: point)
                context.stroke(link, with: .color(.white.opacity(0.22)), lineWidth: 1.2)

                let rect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.15)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.38)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
