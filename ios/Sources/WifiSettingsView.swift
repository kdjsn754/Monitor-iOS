import SwiftUI
import UIKit

/// 无线（二级页）。
///
/// **入口**：网络页「无线」卡右上角的「更多」。
///
/// ## v3.4.3 第三次重做（用户 2026-11-26 00:36：「配色太丑和这布局结合太丑了重新设计」
/// → 00:42「现在又没图形化了」）
///
/// 两版都被否过一次，弄清问题在哪：v3.4.1 的问题是**同一种视觉形态被复制三遍**——
/// 三个频段各一张卡，卡里都是「彩色徽章 + 频谱条 + 三颗参数胶囊」，一屏三套同样的
/// 东西，再叠五种颜色，所以又花又笨。v3.4.2 只换颜色不改形态，用户仍然说丑。
/// 而把图全删掉只留列表（第二版稿）又被回「没图形化了」——**他要图形，只是不要
/// 那种一根根细柱子的频宽图**。
///
/// 所以这一版的做法：
///
/// | 区域 | 画法 |
/// | --- | --- |
/// | 顶部 | **场景图**：一台路由器 + 三层弧 + 四周散着手机 / 笔记本 / 电视，一句话在下面 |
/// | 主网络 | 一个频段一行：频段标签、SSID、加密与台数、开关 |
/// | 无线参数 | 一个频段一行：信道与频宽、发射功率，点进去是那一频段的参数页 |
/// | 其他网络 | 图标块 + 名称 + 「SSID · 频段」+ 开关 |
///
/// 三条硬规矩（写进 开发交接.md 第 5 节）：
/// 1. **整页只有一种彩色**（`WifiPalette`），频段靠标签和开关状态区分，关掉的压灰；
/// 2. **图形只出现在顶部，且只有一处**；下面一律是安静的行，不再每卡配一条小图；
/// 3. **信道 / 频宽 / 功率不进主网络行**——它们是 radio 级参数，同频段所有网络共用，
///    混在 SSID 行里既重复又挤。
///
/// **能不能改得动，靠的是通道不是界面**：所有写入都走 `AppModel.saveWifiGroup` /
/// `createWifiGroup` / `saveRadioSettings`，写完回读 `uci`，对得上才算成功，最后
/// `wifi reload` 生效（那一步会断线，见 `reloadWireless`）。
///
/// **没做的两项**（原因写进第 5 节）：无线模式 `hwmode` 与使用环境（室内/户外）。
/// 前者这台固件没有 `hwmode` 这个键，制式写在 `htmode` 前缀里，写错会让 MTK 驱动
/// 直接不认这个频段；后者在固件里没有 uci 落点（官方走 RPC 直调驱动）。

struct WifiSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    @State private var editingGroup: WifiNetGroup?
    @State private var editingRadio: WifiBandInfo?
    @State private var creatingKind: WifiNetGroup.Kind?
    /// 单个频段开关正在写的时候，把那一颗开关换成转圈。
    @State private var busyBands: Set<String> = []
    /// 访客 / IoT / 多链路整组开关。
    @State private var busyGroups: Set<String> = []
    @State private var errorText: String?

    private var info: NetworkInfo { model.network }
    private var groups: [WifiNetGroup] { info.wifiGroups }
    private var mainGroup: WifiNetGroup? { groups.first { $0.kind == .main } }
    private var bands: [WifiBandInfo] { info.bands }

    /// 主网络之外的组，按「访客 → IoT → 多链路」排。多链路这台机器不支持就整条不出现。
    private var sideGroups: [WifiNetGroup] {
        groups
            .filter { $0.kind != .main }
            .filter { $0.kind != .mlo || info.mloSupported }
            .sorted { sideOrder($0.kind) < sideOrder($1.kind) }
    }

    private func sideOrder(_ kind: WifiNetGroup.Kind) -> Int {
        switch kind {
        case .guest: return 0
        case .iot: return 1
        case .mlo: return 2
        case .main: return -1
        }
    }

    /// 正在广播的频段。
    private var liveBands: [WifiBandInfo] { bands.filter(\.up) }

    /// 三个频段上的设备加起来（同一台设备可能同时在两个频段上，这里只是近似）。
    private var clientCount: Int { bands.reduce(0) { $0 + $1.clients } }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                if bands.isEmpty {
                    emptyCard
                } else {
                    sceneCard
                    mainCard
                    radioCard
                }

                networksCard

                if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 12)
            // 底栏是浮在内容上的玻璃条：不留这一截，最后一张卡会被它盖住。
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScrollBackground()
        .primaryButtons()
        .navigationTitle("无线")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingGroup) { group in
            WifiGroupEditorSheet(group: group)
        }
        .sheet(item: $editingRadio) { band in
            WifiRadioEditorSheet(band: band)
        }
        .sheet(isPresented: Binding(get: { creatingKind != nil },
                                    set: { if !$0 { creatingKind = nil } })) {
            if let kind = creatingKind {
                WifiGroupCreateSheet(kind: kind)
            }
        }
    }

    // MARK: - 顶部：一张场景图

    /// 顶上一整块：路由器 + 波纹 + 四周的设备，底下一句结论。
    ///
    /// 全页**唯一**的图。位置、尺寸、画法都在 `WifiScene` 里，这里只管占位和文字。
    private var sceneCard: some View {
        VStack(spacing: 0) {
            WifiScene(live: liveBands.count, tint: WifiPalette.accent)
                .frame(height: 168)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                Circle()
                    .fill(liveBands.isEmpty ? Color.secondary.opacity(0.35) : WifiPalette.accent)
                    .frame(width: 6, height: 6)
                Text(sceneLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .cardSurface()
    }

    private var sceneLine: String {
        if liveBands.isEmpty { return "无线已全部关闭" }
        var text = "\(liveBands.count) 个频段在广播"
        if clientCount > 0 { text += " · \(clientCount) 台设备连着" }
        return text
    }

    private var emptyCard: some View {
        CardPanel("读不到无线配置", icon: "wifi.slash") {
            Text("这一拍没取到频段信息，下拉刷新一次。")
                .font(UI.row())
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    // MARK: - 主网络

    /// 一个频段一行。名字、加密方式、设备数都在这一行，右端是开关。
    private var mainCard: some View {
        CardPanel("主网络", icon: "wifi", trailing: "三个频段同名") {
            VStack(spacing: 0) {
                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    if index > 0 { CardRule() }
                    mainRow(band)
                }
            }
        }
    }

    private func mainRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return HStack(spacing: 12) {
            bandTag(band.band, on: on)

            Button {
                if let mainGroup { editingGroup = mainGroup }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(band.ssid.isEmpty ? "—" : band.ssid)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(bandSubline(band))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mainGroup?.editable != true)

            bandSwitch(band)
        }
        .padding(.vertical, 11)
    }

    private func bandSubline(_ band: WifiBandInfo) -> String {
        var parts: [String] = []
        if band.radioOff {
            parts.append("频段已关闭")
        } else if !band.ssidOn {
            parts.append("网络已关闭")
        }
        if !band.encryption.isEmpty { parts.append(band.securityLabel) }
        if band.hidden { parts.append("隐藏") }
        if band.clients > 0 { parts.append("\(band.clients) 台") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// 频段标签：固定 44×30 的小块。开着是主色淡底，关掉只留中性灰。
    ///
    /// **不许再按频段给不同颜色**（v3.4.1～v3.4.2 的教训）：一屏三个色块就会互相抢，
    /// 用户原话是「配色太丑」。要区分频段，靠这几个字和开关状态就够了。
    private func bandTag(_ raw: String, on: Bool) -> some View {
        Text(raw.isEmpty ? "?" : shortBand(raw))
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(on ? WifiPalette.ink : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 44, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? WifiPalette.accent.opacity(0.12) : Color.primary.opacity(0.05))
            }
    }

    private func bandSwitch(_ band: WifiBandInfo) -> some View {
        Group {
            if busyBands.contains(band.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: Binding(get: { band.ssidOn && !band.radioOff }, set: { value in
                    setBand(band, on: value)
                }))
                .labelsHidden()
                .blueSwitch()
                .disabled(!band.editable)
            }
        }
        .frame(width: 51)
    }

    // MARK: - 无线参数

    /// 信道 / 频宽 / 发射功率挂在 radio 段上，这一频段的**所有**网络共用一份，
    /// 所以单独一张卡，不跟着某个 SSID 走。点一行就是那一频段的参数页。
    private var radioCard: some View {
        CardPanel("无线参数", icon: "slider.horizontal.3", trailing: "同频段共用") {
            VStack(spacing: 0) {
                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    if index > 0 { CardRule() }
                    radioRow(band)
                }
            }
        }
    }

    private func radioRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return Button {
            editingRadio = band
        } label: {
            HStack(spacing: 12) {
                bandTag(band.band, on: on)

                VStack(alignment: .leading, spacing: 3) {
                    Text(radioTitle(band))
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(band.radioOff ? "频段已关闭" : "发射功率 " + band.powerLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!band.editable)
    }

    /// 「自动 · CH 6 · 160 MHz」或「CH 36 · 80 MHz」。
    private func radioTitle(_ band: WifiBandInfo) -> String {
        var parts: [String] = []
        if band.channelMode == "auto" || band.channelMode.isEmpty {
            parts.append(band.channel > 0 ? "自动 · CH \(band.channel)" : "自动信道")
        } else {
            parts.append("CH \(band.channelMode)")
        }
        if !band.width.isEmpty { parts.append(band.width + " MHz") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 其他网络

    private var networksCard: some View {
        let live = sideGroups.filter { $0.isOn }.count
        return CardPanel("其他网络", icon: "square.grid.2x2",
                         trailing: live > 0 ? "\(live) 个已开启" : "都没开") {
            VStack(spacing: 0) {
                ForEach(Array(sideGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { CardRule() }
                    networkRow(group)
                }
            }
        }
    }

    /// 一行一个组：图标块 + 标题 + 「SSID · 频段」+ 开关。
    /// 没有成员段的组画成「添加」，点进去就是创建页。
    private func networkRow(_ group: WifiNetGroup) -> some View {
        let exists = !group.members.isEmpty
        let on = group.isOn
        let canCreate = group.kind == .guest || group.kind == .iot

        return HStack(spacing: 12) {
            Button {
                if exists {
                    editingGroup = group
                } else if canCreate {
                    creatingKind = group.kind
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(exists && on ? WifiPalette.accent.opacity(0.12) : Color.primary.opacity(0.05))
                            .frame(width: 38, height: 38)
                        Image(systemName: exists ? KindIcon.symbol(group.kind) : "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(exists && on ? WifiPalette.ink : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(exists ? group.kind.title : "添加\(group.kind.title)")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(exists ? Color.primary : Color.secondary)
                            .lineLimit(1)

                        Text(groupLine(group, canCreate: canCreate))
                            .font(.system(size: 12))
                            .foregroundStyle(exists ? Color.secondary : Color.secondary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(exists && !group.editable)

            if exists {
                if busyGroups.contains(group.kind.rawValue) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 51)
                } else {
                    Toggle("", isOn: groupBinding(group))
                        .labelsHidden()
                        .blueSwitch()
                        .disabled(!group.editable)
                }
            } else {
                Image(systemName: canCreate ? "chevron.right" : "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 51)
            }
        }
        .padding(.vertical, 10)
    }

    private func groupLine(_ group: WifiNetGroup, canCreate: Bool) -> String {
        guard !group.members.isEmpty else {
            return canCreate ? "还没有这个网络" : "这台路由器没有这一组"
        }
        var text = group.ssid.isEmpty ? "—" : group.ssid
        let names = group.members.map { shortBand($0.band) }
        if !names.isEmpty { text += " · " + names.joined(separator: " + ") }
        return text
    }

    // MARK: - 写：开关

    /// 单个频段的开关：只动这一条 `wifi-iface`（整组的两条名字密码一样，只切一条）。
    ///
    /// 关掉的正是手机此刻连着的那一路时会立刻失联——`saveWifiGroup` 里拦了，
    /// 这里只负责按住开关、等结果。
    private func setBand(_ band: WifiBandInfo, on: Bool) {
        guard !busyBands.contains(band.id), let group = mainGroup else { return }
        busyBands.insert(band.id)
        errorText = nil
        Task {
            var map: [String: Bool] = [:]
            for member in group.members { map[member.band] = member.ssidOn }
            map[band.band] = on
            let problem = await model.saveWifiGroup(group,
                                                    ssid: group.ssid,
                                                    key: group.key,
                                                    hidden: group.hidden,
                                                    bandOn: map)
            busyBands.remove(band.id)
            if let problem {
                errorText = problem
                model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
            } else {
                await model.manualRefresh()
            }
        }
    }

    /// 整组开关（访客 / IoT / 多链路）：开的时候所有频段一起开。
    private func groupBinding(_ group: WifiNetGroup) -> Binding<Bool> {
        Binding(get: { group.isOn }, set: { value in
            guard !busyGroups.contains(group.kind.rawValue) else { return }
            busyGroups.insert(group.kind.rawValue)
            errorText = nil
            Task {
                var map: [String: Bool] = [:]
                for member in group.members { map[member.band] = value }
                let problem = await model.saveWifiGroup(group,
                                                        ssid: group.ssid,
                                                        key: group.key,
                                                        hidden: group.hidden,
                                                        bandOn: map)
                busyGroups.remove(group.kind.rawValue)
                if let problem {
                    errorText = problem
                    model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
                } else {
                    await model.manualRefresh()
                }
            }
        })
    }

    // MARK: - 小工具

    private func shortBand(_ raw: String) -> String {
        switch raw {
        case "": return "无线"
        case "2.4": return "2.4G"
        case "S1G": return "Sub-1G"
        default: return raw + "G"
        }
    }
}

// MARK: - 图形件

/// 无线场景图：一台路由器，三层弧往外扩，四周散着几台设备。
///
/// 全页唯一的图（v3.4.3）。用 `Canvas` 一次画完，滚动时只做合成，
/// 不会因为几十个 `Path` 叠着掉帧（同网络页 `TopoFork` 的做法）。
///
/// 两处都是「示意」不是「仪表」：
/// - 弧的层数跟着**开着几个频段**走，全关只剩最里面一层很淡的；
/// - 四周的设备**不按真实台数增减**——数量一变整个画面会跳，十台也摆不下。
///   真实台数写在图下面那行字里。
private struct WifiScene: View {
    /// 开着的频段数（0…3）。
    let live: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let baseY = h * 0.76
            let on = live > 0

            // 四周的设备（先画，压在弧下面）
            let devices: [(CGRect, Double)] = [
                (CGRect(x: w * 0.085, y: h * 0.150, width: w * 0.042, height: h * 0.096), 0.30),
                (CGRect(x: w * 0.800, y: h * 0.115, width: w * 0.070, height: h * 0.046), 0.24),
                (CGRect(x: w * 0.815, y: h * 0.470, width: w * 0.082, height: h * 0.056), 0.20),
                (CGRect(x: w * 0.070, y: h * 0.500, width: w * 0.056, height: h * 0.050), 0.24)
            ]
            for (rect, alpha) in devices {
                context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.28),
                             with: .color(tint.opacity(on ? alpha : alpha * 0.6)))
            }

            // 同心弧：半径按宽度算，换屏幕不会挤在一起
            let radii: [CGFloat] = [w * 0.125, w * 0.215, w * 0.305]
            for (index, radius) in radii.enumerated() {
                var path = Path()
                path.addArc(center: CGPoint(x: cx, y: baseY),
                            radius: radius,
                            startAngle: .degrees(202),
                            endAngle: .degrees(338),
                            clockwise: false)
                let lit = index < max(live, 1)
                let alpha: Double = on ? (lit ? 0.40 - Double(index) * 0.10 : 0.09) : 0.07
                context.stroke(path,
                               with: .color(tint.opacity(alpha)),
                               style: StrokeStyle(lineWidth: index == 0 ? 2.2 : 1.5, lineCap: .round))
            }

            // 地面投影
            var shadow = Path()
            shadow.addRoundedRect(in: CGRect(x: cx - w * 0.115, y: baseY + 4,
                                             width: w * 0.23, height: 3),
                                  cornerSize: CGSize(width: 1.5, height: 1.5))
            context.fill(shadow, with: .color(tint.opacity(on ? 0.12 : 0.05)))

            // 机身
            let bodyW = w * 0.150
            let bodyH = h * 0.105
            let body = CGRect(x: cx - bodyW / 2, y: baseY - bodyH, width: bodyW, height: bodyH)
            context.fill(Path(roundedRect: body, cornerRadius: bodyH * 0.30),
                         with: .color(on ? tint : Color.secondary.opacity(0.35)))

            // 两根天线
            var antenna = Path()
            antenna.move(to: CGPoint(x: body.minX + bodyW * 0.16, y: body.minY + 1))
            antenna.addLine(to: CGPoint(x: body.minX - bodyW * 0.08, y: body.minY - bodyH * 0.78))
            antenna.move(to: CGPoint(x: body.maxX - bodyW * 0.16, y: body.minY + 1))
            antenna.addLine(to: CGPoint(x: body.maxX + bodyW * 0.08, y: body.minY - bodyH * 0.78))
            context.stroke(antenna,
                           with: .color(on ? tint : Color.secondary.opacity(0.30)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // 三颗指示灯
            for index in 0..<3 {
                let r: CGFloat = 1.5
                let x = body.minX + bodyW * (0.26 + CGFloat(index) * 0.17)
                let y = body.midY + 1
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(Color.white.opacity(on ? (index == 0 ? 0.95 : 0.5) : 0.45)))
            }
        }
    }
}

/// 频谱条：按这一频段可用信道画等距刻度，把当前信道（和频宽）高亮出来。
///
/// `ghost` 是「自动」——自动选信道时运行态会落在一个具体信道上，那条高亮用浅色，
/// 表示「现在在这儿，但不是你钉的」。
private struct WifiSpectrum: View {
    let channels: [Int]
    let highlight: Int
    /// 高亮占几格（20M = 1、40M = 2、80M = 4、160M = 8）。
    let slots: Int
    let tint: Color
    var ghost = false

    var body: some View {
        GeometryReader { geo in
            let count = max(channels.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let index = channels.firstIndex(of: highlight)
            let window = min(slot * CGFloat(max(slots, 1)), geo.size.width)
            let rawX = index.map { slot * (CGFloat($0) + 0.5) - window / 2 } ?? 0
            let x = min(max(rawX, 0), max(geo.size.width - window, 0))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))

                HStack(spacing: 0) {
                    ForEach(channels, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 9)
                            .frame(maxWidth: .infinity)
                    }
                }

                if index != nil {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(ghost ? 0.22 : 0.85))
                        .frame(width: window, height: 20)
                        .offset(x: x)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 信道标尺：一条一根，点哪根选哪个信道。比系统 `Picker` 直观——
/// 一眼能看出「我钉在 149，旁边还有 153 / 157 / 161」。
private struct ChannelRuler: View {
    let channels: [Int]
    /// 当前选中的值（`auto` 或信道号）。
    let selected: String
    /// 运行态实测落点，自动模式下用浅色标出来。
    let measured: Int
    /// 柱子 / 选中的块用亮色。
    let tint: Color
    /// 柱底下的信道号用深一档（8pt 亮色字在白卡上读不出来）。
    var ink: Color?
    let onPick: (Int) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(channels, id: \.self) { channel in
                let isOn = selected == String(channel)
                let isMeasured = channel == measured
                Button {
                    onPick(channel)
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isOn ? tint
                                  : (isMeasured ? tint.opacity(0.26) : Color.primary.opacity(0.12)))
                            .frame(height: isOn ? 32 : 22)
                        Text("\(channel)")
                            .font(.system(size: 8, weight: isOn ? .bold : .regular))
                            .foregroundStyle(isOn ? (ink ?? tint) : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 50)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

/// 页面 / 弹层共用的错误条。
private struct WifiErrorNote: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        let red = wifiTone((0.72, 0.16, 0.13), (1.0, 0.45, 0.40))
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(red)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(red.opacity(0.7))
                    .padding(2)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(red.opacity(0.08))
        }
    }
}

/// 编辑页底部那颗整宽保存按钮（蓝底白字，第④类）。
private struct WifiSaveButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(busy ? "保存中…" : title)
                    .font(.system(size: 15.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(busy ? Color(.systemGray3) : NetPalette.wan)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// 浅色 / 深色两套色值。
///
/// **为什么不用同一个 hex**：卡片底一边是白、一边是近黑，同一个颜色在一侧必然发灰、
/// 另一侧发跳。
///
/// **为什么一个色要两档**（v3.4.2）：用户要「亮色系」，亮色块铺在白卡上很清爽，但同样
/// 的亮色当 10~17pt 的**字**就糊了——`#45B5E0` 在白底上对比只有 2.6:1。所以块面用
/// `color()`，凡是有字的用 `ink()`（同色相深一档）。
private func wifiTone(_ light: (CGFloat, CGFloat, CGFloat),
                      _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(UIColor { trait in
        let v = trait.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: v.0, green: v.1, blue: v.2, alpha: 1)
    })
}

/// 整页唯一的一组颜色（v3.4.3）。
///
/// 从前每个频段一种色，一路加到五种，用户连着说「丑」。现在只有主色 + 中性灰：
/// - `accent`：场景图的弧与机身、频段标签底、其他网络图标底；
/// - `ink`：凡是**字**要用主色时取这一档（亮色当 11pt 小字对比只有 2.6:1）；
/// - 关闭态一律 `Color.primary.opacity(0.05)`，不用 `systemGray4`——
///   13% 的灰在白卡上等于没画。
///
/// 浅色 / 深色各一套：白卡上要压深、近黑卡上要提亮，一个 hex 打不了两种底。
private enum WifiPalette {
    /// 主色（蓝）。和系统开关的蓝接近，所以开关、标签、图形看上去是一套。
    static let accent = wifiTone((0.15, 0.47, 0.90), (0.42, 0.66, 0.98))

    /// 同一主色的深一档，只给文字。
    static let ink = wifiTone((0.05, 0.28, 0.62), (0.72, 0.86, 1.00))
}

/// 三种附加网络的 SF Symbol。
///
/// 只管图标，**不再管颜色**——颜色统一走 `WifiPalette`，否则又会变成一页五色。
private enum KindIcon {
    static func symbol(_ kind: WifiNetGroup.Kind) -> String {
        switch kind {
        case .guest: return "person.2.fill"
        case .iot: return "cpu"
        case .mlo: return "square.stack.3d.up.fill"
        case .main: return "wifi"
        }
    }
}

// MARK: - 网络编辑

/// 一组无线网络的编辑页：名称 / 安全性 / 密码 / 各频段开关 / 隐藏 / 随机 BSSID。
///
/// 同组的 2.4G 与 5G 是两条独立 `wifi-iface`，名称和密码必须写成一样，
/// 否则手机在两个频段上会看到两个不同名字的网络——所以由这一页统一写。
///
/// **安全性只在真动过时才写**（v3.4.1）：老值认不出来（`owe` / `wpa3` 这类）
/// 时不碰 `encryption`，免得「只改了个名字」把加密方式一起压成混合。
struct WifiGroupEditorSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let group: WifiNetGroup

    @State private var ssid: String
    @State private var key: String
    @State private var hidden: Bool
    @State private var security: WifiSecurity
    @State private var randomBSSID: Bool
    @State private var bandOn: [String: Bool]
    @State private var showKey = false
    @State private var busy = false
    @State private var errorText: String?
    /// 用户点过安全性那几个胶囊没有。没点过就不写 `encryption`。
    @State private var securityTouched = false

    init(group: WifiNetGroup) {
        self.group = group
        _ssid = State(initialValue: group.ssid)
        _key = State(initialValue: group.key)
        _hidden = State(initialValue: group.hidden)
        _security = State(initialValue: group.security ?? .mixed)
        _randomBSSID = State(initialValue: group.randomBSSID)
        var map: [String: Bool] = [:]
        for member in group.members { map[member.band] = member.ssidOn }
        _bandOn = State(initialValue: map)
    }

    /// 多链路至少要两个频段（官方那句「请选择至少两个无线电频段」）。
    private var bandCount: Int { bandOn.values.filter { $0 }.count }

    private var bandProblem: String? {
        group.kind == .mlo && bandCount > 0 && bandCount < 2 ? "多链路至少要开两个频段" : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    identityCard
                    securityCard
                    bandsCard
                    optionsCard
                    if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
                    WifiSaveButton(title: "保存", busy: busy) {
                        Task { await save() }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .themedScrollBackground()
            .primaryButtons()
            .navigationTitle(group.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
            }
        }
    }

    private var identityCard: some View {
        CardPanel("名称", icon: "wifi") {
            HStack(spacing: 8) {
                TextField("", text: $ssid)
                    .font(.system(size: 15.5, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    }
                    .disabled(busy)
                Text("\(ssid.count)/32")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private var securityCard: some View {
        CardPanel("安全性", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(WifiSecurity.allCases) { item in
                        securityPill(item)
                    }
                }
                if security.needsKey {
                    passwordField
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func securityPill(_ item: WifiSecurity) -> some View {
        let selected = security == item
        return Button {
            security = item
            securityTouched = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? NetPalette.wan : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? NetPalette.wan.opacity(0.12) : Color(.tertiarySystemFill))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var passwordField: some View {
        HStack(spacing: 8) {
            Group {
                if showKey {
                    TextField("密码", text: $key)
                } else {
                    SecureField("密码", text: $key)
                }
            }
            .font(.system(size: 15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        }
    }

    private var bandsCard: some View {
        CardPanel("频段", icon: "antenna.radiowaves.left.and.right") {
            VStack(spacing: 0) {
                ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 { CardRule() }
                    HStack(spacing: 8) {
                        Text(member.bandName)
                            .font(UI.row())
                        Text(member.channelLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { bandOn[member.band] ?? false },
                            set: { bandOn[member.band] = $0 }
                        ))
                        .labelsHidden()
                        .blueSwitch()
                    }
                    .padding(.vertical, UI.rowPadding)
                }
                if let bandProblem {
                    Text(bandProblem)
                        .font(.system(size: 12))
                        .foregroundStyle(wifiTone((0.72, 0.16, 0.13), (1.0, 0.45, 0.40)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private var optionsCard: some View {
        CardPanel("其他", icon: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 18, alignment: .leading)
                    Text("隐藏网络").font(UI.row())
                    Spacer(minLength: 8)
                    Toggle("", isOn: $hidden)
                        .labelsHidden()
                        .blueSwitch()
                }
                .padding(.vertical, UI.rowPadding)

                CardRule()

                HStack(spacing: 9) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 18, alignment: .leading)
                    Text("随机 BSSID").font(UI.row())
                    Spacer(minLength: 8)
                    Toggle("", isOn: $randomBSSID)
                        .labelsHidden()
                        .blueSwitch()
                }
                .padding(.vertical, UI.rowPadding)
            }
        }
    }

    private func save() async {
        guard !busy else { return }
        if let bandProblem {
            errorText = bandProblem
            return
        }
        busy = true
        errorText = nil
        let encryption: String? = (securityTouched || group.security != nil) ? security.rawValue : nil
        let problem = await model.saveWifiGroup(group, ssid: ssid, key: key, hidden: hidden,
                                                encryption: encryption,
                                                randomBSSID: randomBSSID,
                                                bandOn: bandOn)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "\(group.kind.title)已保存", detail: ssid)
            dismiss()
            await model.manualRefresh()
            return
        }
        errorText = problem
    }
}

// MARK: - 无线参数（按频段）

/// 一个频段的无线参数：信道 / 频宽 / 发射功率 / 5G 的 DFS。
///
/// 这些键挂在 radio 段上（`wireless.MT7993_1_2`），改了之后这个频段上**所有**网络
/// 一起换信道——官方也是这么写的（「以下配置将应用到所有 X 频段的网络」）。
///
/// 界面这一版全换成图形件：顶部一条大频谱预览，信道用「标尺」（一根一个信道，
/// 点哪根选哪个），频宽四块（横条越长越宽），功率四格（信号格越高越强）。
struct WifiRadioEditorSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let band: WifiBandInfo

    /// `auto` 或信道号。原值读回来就是这两种。
    @State private var channel: String
    @State private var width: String
    @State private var power: Int
    @State private var dfs: Bool
    @State private var busy = false
    @State private var errorText: String?

    /// 官方的四档功率（最大 / 高 / 中 / 低 = 100 / 75 / 50 / 25）。
    private static let powerLevels = [100, 75, 50, 25]

    init(band: WifiBandInfo) {
        self.band = band
        _channel = State(initialValue: band.channelMode.isEmpty ? "auto" : band.channelMode)
        // 读不到 / 不在上限表里（有人手动改成 20）就退回这一频段最低的一档，
        // 否则界面会空着。
        let options = band.widthOptions
        let initialWidth = options.contains(band.width) ? band.width : (options.first ?? "")
        _width = State(initialValue: initialWidth)
        // 读回来的百分比不在四档里（有人手动改过 60）就取最近的一档。
        let nearest = Self.powerLevels.min {
            abs($0 - band.txPowerPercent) < abs($1 - band.txPowerPercent)
        } ?? 100
        _power = State(initialValue: band.txPowerPercent > 0 ? nearest : 100)
        _dfs = State(initialValue: band.dfsEnabled)
    }

    /// 这一频段的候选信道；当前信道（可能落在 DFS 段）一定补进来。
    private var channelChoices: [Int] {
        var list = band.channelOptions
        if let current = Int(channel), current > 0, !list.contains(current) { list.append(current) }
        if band.channel > 0, !list.contains(band.channel) { list.append(band.channel) }
        return list.sorted()
    }

    /// 频谱预览上要亮的那一格：自动时用运行态实测值。
    private var previewChannel: Int {
        Int(channel) ?? band.channel
    }

    private var tint: Color { WifiPalette.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    previewCard
                    channelCard
                    widthCard
                    powerCard
                    if band.band == "5" { dfsCard }
                    if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
                    WifiSaveButton(title: "保存", busy: busy) {
                        Task { await save() }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .themedScrollBackground()
            .primaryButtons()
            .navigationTitle(band.bandName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
            }
        }
    }

    private var previewCard: some View {
        CardPanel("当前设置", icon: "waveform.path.ecg") {
            WifiSpectrum(channels: channelChoices,
                         highlight: previewChannel,
                         slots: widthSlots(width),
                         tint: tint,
                         ghost: channel == "auto")
                .frame(height: 46)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "信道",
                           value: channel == "auto"
                               ? (band.channel > 0 ? "自动 · CH \(band.channel)" : "自动")
                               : "CH \(channel)",
                           valueWeight: .semibold)
                MetricCell(label: "频宽",
                           value: width.isEmpty ? "—" : "\(width) MHz",
                           valueWeight: .semibold)
                MetricCell(label: "功率", value: powerLabel(power), valueWeight: .semibold)
            }
            .padding(.bottom, 2)
        }
    }

    private var channelCard: some View {
        CardPanel("信道", icon: "antenna.radiowaves.left.and.right") {
            HStack(spacing: 8) {
                Button {
                    channel = "auto"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: channel == "auto" ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("自动").font(.system(size: 12.5, weight: channel == "auto" ? .semibold : .regular))
                    }
                    .foregroundStyle(channel == "auto" ? WifiPalette.ink : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        Capsule().fill(channel == "auto" ? tint.opacity(0.18) : Color(.tertiarySystemFill))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if channelChoices.isEmpty {
                Text("这一频段没有可选信道")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ChannelRuler(channels: channelChoices,
                             selected: channel,
                             measured: band.channel,
                             tint: tint,
                             ink: WifiPalette.ink) { picked in
                    channel = String(picked)
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
    }

    private var widthCard: some View {
        CardPanel("频宽", icon: "arrow.left.and.right") {
            if band.widthOptions.isEmpty {
                Text("这一频段不支持改频宽")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    ForEach(band.widthOptions, id: \.self) { item in
                        widthTile(item)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
        }
    }

    private func widthTile(_ item: String) -> some View {
        let selected = width == item
        // 一条长度随频宽变化的横条：20 / 40 / 80 / 160 一眼看得出宽窄。
        let barWidth = CGFloat(widthSlots(item)) * 3.4

        return Button {
            width = item
        } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(selected ? NetPalette.wan : Color(.systemGray3))
                    .frame(width: barWidth, height: 4)
                    .frame(height: 6)
                Text(item)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                Text("MHz")
                    .font(.system(size: 8.5))
            }
            .foregroundStyle(selected ? NetPalette.wan : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? NetPalette.wan.opacity(0.12) : Color(.tertiarySystemFill))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var powerCard: some View {
        CardPanel("发射功率", icon: "bolt") {
            HStack(spacing: 8) {
                ForEach(Array(Self.powerLevels.enumerated()), id: \.element) { index, item in
                    powerTile(item, level: Self.powerLevels.count - index)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
    }

    private func powerTile(_ value: Int, level: Int) -> some View {
        let selected = power == value
        return Button {
            power = value
        } label: {
            VStack(spacing: 5) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<4, id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(bar < level
                                  ? (selected ? NetPalette.wan : Color(.systemGray2))
                                  : Color(.systemGray5))
                            .frame(width: 4, height: CGFloat(6 + bar * 4))
                    }
                }
                .frame(height: 22, alignment: .bottom)
                Text(shortPower(value))
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? NetPalette.wan : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? NetPalette.wan.opacity(0.12) : Color(.tertiarySystemFill))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var dfsCard: some View {
        CardPanel("DFS 信道", icon: "dot.radiowaves.left.and.right") {
            HStack(spacing: 9) {
                Text("允许使用 DFS 信道").font(UI.row())
                Spacer(minLength: 8)
                Toggle("", isOn: $dfs)
                    .labelsHidden()
                    .blueSwitch()
            }
            .padding(.vertical, UI.rowPadding)
        }
    }

    private func widthSlots(_ value: String) -> Int {
        switch value {
        case "160": return 8
        case "80": return 4
        case "40": return 2
        default: return 1
        }
    }

    private func shortPower(_ value: Int) -> String {
        switch value {
        case 100: return "最大"
        case 75: return "高"
        case 50: return "中"
        case 25: return "低"
        default: return "\(value)%"
        }
    }

    private func powerLabel(_ value: Int) -> String {
        switch value {
        case 100: return "100%"
        case 75: return "75%"
        case 50: return "50%"
        case 25: return "25%"
        default: return "\(value)%"
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.saveRadioSettings(band, channel: channel, width: width,
                                                    powerPercent: power, dfs: dfs)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已保存", detail: band.bandName)
            dismiss()
            await model.manualRefresh()
            return
        }
        errorText = problem
    }
}

// MARK: - 添加网络

/// 「添加网络」：把 GL 固件预置的访客 / IoT 模板段启用并命名。
///
/// 只用现成模板，不凭空造 `wifi-iface`：MTK 驱动的 `vifidx` 与 `ifname`
/// 是固件分配好的，乱写会把主网络挤掉。
struct WifiGroupCreateSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let kind: WifiNetGroup.Kind

    @State private var ssid = ""
    @State private var key = ""
    @State private var showKey = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    introCard
                    formCard
                    if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
                    WifiSaveButton(title: "创建", busy: busy) {
                        Task { await create() }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .themedScrollBackground()
            .primaryButtons()
            .navigationTitle("添加\(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
            }
        }
    }

    private var introCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WifiPalette.accent.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: KindIcon.symbol(kind))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(WifiPalette.ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(UI.title(.semibold))
                Text("为它单独起一个名字和密码，主网络的密码不用告诉客人。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    private var formCard: some View {
        CardPanel("名称与密码", icon: "wifi") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: $ssid)
                    .font(.system(size: 15.5, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    }
                    .disabled(busy)

                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField("密码（至少 8 位）", text: $key)
                        } else {
                            SecureField("密码（至少 8 位）", text: $key)
                        }
                    }
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func create() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.createWifiGroup(kind, ssid: ssid, key: key)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已创建", detail: ssid)
            dismiss()
            await model.manualRefresh()
            return
        }
        errorText = problem
    }
}
