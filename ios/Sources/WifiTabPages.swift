import SwiftUI
import UIKit

/// 无线页的四类网络分屏（v3.4.5）。
///
/// 结构与图形照 `E:\Gemini\glinet-monitor` 的 `WifiSettingsScreen.kt`：顶部四段切换、
/// 一页一类网络、每页第一张卡都是这一类网络的专属示意图，图下统一一排三格读数，
/// 再往下才是可改的行。
///
/// 与安卓版有意不同的三处：
/// 1. 图全部用 `Canvas` / 形状拼，不引图片资源，深浅色都跟卡片底走；
/// 2. 颜色仍守「一页一族主色」：主网络与访客走蓝，IoT 走青，多链路走蓝；
///    绿点只表示「这一组正在广播」，不参与版面配色；
/// 3. **没做删除按钮**：`AppModel` 里没有删 `wifi-iface` 段的写入口，
///    摆一颗按不动的按钮比不摆更糟。

// MARK: - 配色补充

extension WifiPalette {
    /// IoT 那一族的亮色（青）。只有 IoT 页用，别的页别借。
    static var iot: Color { wifiTone((0.18, 0.71, 0.77), (0.36, 0.84, 0.88)) }
    /// 青色深一档，凡是有字的用它（亮青当 10pt 小字只有 2.4:1）。
    static var iotInk: Color { wifiTone((0.09, 0.52, 0.58), (0.62, 0.93, 0.96)) }
    /// 「正在广播」那颗点。
    static var live: Color { wifiTone((0.16, 0.72, 0.34), (0.34, 0.88, 0.48)) }
    /// 绿点旁边偶尔要写字时的深绿。
    static var liveInk: Color { wifiTone((0.09, 0.52, 0.24), (0.48, 0.92, 0.60)) }
}

// MARK: - 小工具

/// `2.4` → `2.4G`，`S1G` → `Sub-1G`。三个页面共用。
func wifiShortBand(_ raw: String) -> String {
    switch raw {
    case "": return "无线"
    case "2.4": return "2.4G"
    case "S1G": return "Sub-1G"
    default: return raw + "G"
    }
}

/// 制式那一行（`802.11be`）：`htmode` 的前缀就是制式，后面的数字是频宽。
func wifiStandard(_ band: WifiBandInfo) -> String {
    let mode = band.htmode.uppercased()
    if mode.hasPrefix("EHT") { return "802.11be" }
    if mode.hasPrefix("HE") { return "802.11ax" }
    if mode.hasPrefix("VHT") { return "802.11ac" }
    if mode.hasPrefix("HT") { return "802.11n" }
    return "—"
}

/// 「自动 · CH 6 · 40 MHz」/「CH 149 · 160 MHz」。
func wifiChannelLine(_ band: WifiBandInfo) -> String {
    var parts: [String] = []
    if band.channelMode == "auto" || band.channelMode.isEmpty {
        parts.append(band.channel > 0 ? "自动 · CH \(band.channel)" : "自动信道")
    } else {
        parts.append("CH \(band.channelMode)")
    }
    if !band.width.isEmpty { parts.append(band.width + " MHz") }
    return parts.joined(separator: " · ")
}

/// 密码只显示圆点，长度也统一 8 个——太长的圆点会挤掉右边的「复制」。
func wifiMaskedKey(_ key: String) -> String {
    key.isEmpty ? "未设置" : "••••••••"
}

// MARK: - 卡片容器

/// 卡片：`CardPanel` 的兄弟版。
///
/// 唯一多出来的东西是右上角的**状态胶囊**（`2 / 2 广播中`、`已开启`）和可换色的图标。
/// 别直接改 `CardPanel`——四个根页都用它，这里多出来的两项它们并不需要。
struct WifiCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = WifiPalette.accent
    var pill: WifiPill? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18, alignment: .leading)

                Text(title)
                    .font(UI.cardTitle())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                if let pill { pill }
            }
            .padding(.bottom, 10)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// 卡片右上角那颗小胶囊。
struct WifiPill: View {
    enum Tone {
        case neutral
        case accent
        case iot
        case live
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background { Capsule().fill(background) }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return .secondary
        case .accent: return WifiPalette.ink
        case .iot: return WifiPalette.iotInk
        case .live: return WifiPalette.liveInk
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Color.primary.opacity(0.07)
        case .accent: return WifiPalette.accent.opacity(0.15)
        case .iot: return WifiPalette.iot.opacity(0.16)
        case .live: return WifiPalette.live.opacity(0.16)
        }
    }
}

// MARK: - 读数与标签

/// 一格读数：标签 10、值 13.5 半粗、副行 9.5。
struct WifiMetric: Identifiable {
    let label: String
    let value: String
    let sub: String

    var id: String { label }
}

/// 图下面那排三格读数。三格等宽，值必须一行放得下（放不下就缩字号）。
struct WifiMetrics: View {
    let items: [WifiMetric]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(item.value)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.sub)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
        }
    }
}

/// 名下一行小胶囊：加密方式、信道、隐藏…… 传了 `tint` 就是「亮」的那一颗。
struct WifiChip: View {
    let text: String
    var tint: Color? = nil
    var ink: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
            }
    }

    private var foreground: Color {
        guard let tint else { return .secondary }
        return ink ?? tint
    }

    private var fill: Color {
        guard let tint else { return Color.primary.opacity(0.06) }
        return tint.opacity(0.14)
    }
}

/// 频段标签：固定 44×30。开着是主色淡底，关掉只留中性灰。
///
/// **不许再按频段给不同颜色**（v3.4.1～v3.4.2 的教训）：一屏三个色块就会互相抢。
struct WifiBandTag: View {
    let text: String
    let on: Bool
    var tint: Color = WifiPalette.accent
    var ink: Color = WifiPalette.ink

    var body: some View {
        Text(text.isEmpty ? "?" : text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(on ? ink : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 44, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? tint.opacity(0.12) : Color.primary.opacity(0.05))
            }
    }
}

// MARK: - 主网络页

/// 主网络：频段频谱 → 各频段 SSID → 无线参数（信道 / 频宽 / 功率）。
struct WifiMainPage: View {
    @Environment(AppModel.self) private var model: AppModel

    @State private var editingGroup: WifiNetGroup?
    @State private var editingRadio: WifiBandInfo?
    @State private var busyBands: Set<String> = []
    @State private var errorText: String?

    private var info: NetworkInfo { model.network }
    private var bands: [WifiBandInfo] { info.bands }
    private var mainGroup: WifiNetGroup? { info.wifiGroups.first { $0.kind == .main } }
    private var liveBands: [WifiBandInfo] { bands.filter(\.up) }
    private var clientCount: Int { bands.reduce(0) { $0 + $1.clients } }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                spectrumCard
                mainCard
                radioCard
                if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 2)
            // 底栏是浮在内容上的玻璃条：不留这一截，最后一张卡会被它盖住。
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $editingGroup) { group in
            WifiGroupEditorSheet(group: group)
        }
        .sheet(item: $editingRadio) { band in
            WifiRadioEditorSheet(band: band)
        }
    }

    // MARK: 频谱

    private var spectrumCard: some View {
        WifiCard(title: "频段频谱与广播状态",
                icon: "chart.line.uptrend.xyaxis",
                pill: WifiPill(text: "\(liveBands.count) / \(bands.count) 广播中",
                               tone: liveBands.isEmpty ? .neutral : .live)) {
            VStack(spacing: 12) {
                ForEach(bands) { band in
                    envelopeRow(band)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }

            CardRule()
                .padding(.top, 10)

            WifiMetrics(items: [
                WifiMetric(label: "在线终端",
                           value: "\(clientCount) 台",
                           sub: clientCount > 0 ? "两频合计" : "暂无设备"),
                WifiMetric(label: "活跃频段",
                           value: liveBands.isEmpty
                               ? "全部关闭"
                               : liveBands.map { wifiShortBand($0.band) }.joined(separator: " + "),
                           sub: liveBands.isEmpty ? "下拉刷新" : "\(liveBands.count) / \(bands.count) 广播"),
                WifiMetric(label: "发射功率",
                           value: bands.first?.powerLabel ?? "—",
                           sub: bands.first.map { wifiStandard($0) } ?? "—")
            ])
            .padding(.top, 10)
        }
    }

    private func envelopeRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(envelopeLabel(band))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(on ? WifiPalette.ink : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                Text(band.clients > 0 ? "\(band.clients) 台" : (on ? "无设备" : "已关闭"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            BandEnvelope(center: envelopeCenter(band),
                         half: envelopeHalf(band),
                         tint: WifiPalette.accent,
                         live: on)
                .frame(height: 22)
        }
    }

    /// `2.4G · CH 6 · 40MHz`。频宽为 0 时省掉尾段，不留一个空的「MHz」。
    private func envelopeLabel(_ band: WifiBandInfo) -> String {
        var parts: [String] = [wifiShortBand(band.band)]
        parts.append(band.channel > 0 ? "CH \(band.channel)" : "自动")
        if !band.width.isEmpty { parts.append(band.width + "MHz") }
        return parts.joined(separator: " · ")
    }

    /// 频宽越宽，梯形越宽（半宽占整幅的比例）。
    private func envelopeHalf(_ band: WifiBandInfo) -> CGFloat {
        switch band.width {
        case "160": return 0.20
        case "80": return 0.145
        case "40": return 0.105
        case "20": return 0.075
        default: return 0.09
        }
    }

    /// 梯形摆在哪：按信道在这一频段可选信道里的位置算，`auto` 时用实测落点。
    private func envelopeCenter(_ band: WifiBandInfo) -> CGFloat {
        let options = band.channelOptions
        guard !options.isEmpty, band.channel > 0,
              let index = options.firstIndex(of: band.channel) else { return 0.5 }
        return (CGFloat(index) + 0.5) / CGFloat(options.count)
    }

    // MARK: 主网络

    private var mainCard: some View {
        WifiCard(title: "主网络",
                icon: "wifi",
                pill: WifiPill(text: "分频段独立设置")) {
            VStack(spacing: 0) {
                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    if index > 0 { CardRule() }
                    mainRow(band)
                }

                if let group = mainGroup, group.needsKey, !group.key.isEmpty {
                    CardRule()
                    passwordRow(group)
                }
            }
        }
    }

    private func mainRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return HStack(spacing: 11) {
            WifiBandTag(text: wifiShortBand(band.band), on: on)

            Button {
                if let mainGroup { editingGroup = mainGroup }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.ssid.isEmpty ? "—" : band.ssid)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        WifiChip(text: band.hidden ? "隐藏" : "显示",
                                 tint: on ? WifiPalette.accent : nil,
                                 ink: on ? WifiPalette.ink : nil)
                        if !band.encryption.isEmpty { WifiChip(text: band.securityLabel) }
                        if band.channel > 0 { WifiChip(text: "信道 \(band.channel)") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mainGroup?.editable != true)

            bandSwitch(band)
        }
        .padding(.vertical, 10)
    }

    private func passwordRow(_ group: WifiNetGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("密码 \(wifiMaskedKey(group.key))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                UIPasteboard.general.string = group.key
                model.notice = Notice(kind: .ok, title: "密码已复制", detail: group.ssid)
            } label: {
                Text("复制")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WifiPalette.ink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }

    private func bandSwitch(_ band: WifiBandInfo) -> some View {
        Group {
            if busyBands.contains(band.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: Binding(get: { band.ssidOn && !band.radioOff },
                                         set: { value in setBand(band, on: value) }))
                .labelsHidden()
                .blueSwitch()
                .disabled(!band.editable)
            }
        }
        .frame(width: 51)
    }

    // MARK: 无线参数

    /// 信道 / 频宽 / 发射功率挂在 radio 段上，这一频段的**所有**网络共用一份，
    /// 所以单独一张卡，不跟某个 SSID 走。
    private var radioCard: some View {
        WifiCard(title: "无线参数",
                icon: "slider.horizontal.3",
                pill: WifiPill(text: "同频段共用")) {
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
            HStack(spacing: 11) {
                WifiBandTag(text: wifiShortBand(band.band), on: on)

                VStack(alignment: .leading, spacing: 3) {
                    Text(wifiChannelLine(band))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(band.radioOff ? "频段已关闭"
                                       : "\(wifiStandard(band)) · 功率 \(band.powerLabel)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!band.editable)
    }

    // MARK: 写

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
}

// MARK: - 频段包络

/// 一段频谱包络：梯形块，宽度就是这一频段的频宽。
///
/// 不用一根根细柱子的频宽图（用户 2026-11-26 明确否过那种画法）——这里只有一块，
/// 宽窄一眼就能比。关掉的频段画成灰虚线。
struct BandEnvelope: View {
    /// 中心位置（0…1，占整幅宽的比例）。
    let center: CGFloat
    /// 半宽（0…1）。
    let half: CGFloat
    let tint: Color
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let safeHalf = min(max(half, 0.02), 0.48)
            let cx = min(max(center, safeHalf), 1 - safeHalf) * width
            let bottom = height - 1
            let topInset = safeHalf * width * 0.34
            let halfWidth = safeHalf * width

            let shape = Path { path in
                path.move(to: CGPoint(x: cx - halfWidth, y: bottom))
                path.addLine(to: CGPoint(x: cx - topInset, y: 2))
                path.addLine(to: CGPoint(x: cx + topInset, y: 2))
                path.addLine(to: CGPoint(x: cx + halfWidth, y: bottom))
                path.closeSubpath()
            }

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)

                if live {
                    shape.fill(tint.opacity(0.26))
                    shape.stroke(tint,
                                 style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                } else {
                    shape.stroke(Color.secondary.opacity(0.35),
                                 style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
        }
    }
}

// MARK: - 访客 / IoT / 多链路

/// 一页一类附加网络：上方专属示意图 + 三格读数，下方网络本身那一张卡。
struct WifiSidePage: View {
    @Environment(AppModel.self) private var model: AppModel

    let kind: WifiNetGroup.Kind

    @State private var editing = false
    @State private var creating = false
    @State private var busy = false
    @State private var errorText: String?

    private var info: NetworkInfo { model.network }
    private var group: WifiNetGroup? { info.wifiGroups.first { $0.kind == kind } }
    private var hasNet: Bool { !(group?.members.isEmpty ?? true) }
    private var isOn: Bool { group?.isOn ?? false }

    private var tint: Color { kind == .iot ? WifiPalette.iot : WifiPalette.accent }
    private var ink: Color { kind == .iot ? WifiPalette.iotInk : WifiPalette.ink }
    private var pillTone: WifiPill.Tone {
        if !hasNet { return .neutral }
        if kind == .iot { return isOn ? .iot : .neutral }
        return isOn ? .live : .neutral
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                vizCard
                networkCard
                if let errorText { WifiErrorNote(text: errorText) { self.errorText = nil } }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 2)
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $editing) {
            if let group { WifiGroupEditorSheet(group: group) }
        }
        .sheet(isPresented: $creating) {
            WifiGroupCreateSheet(kind: kind)
        }
    }

    // MARK: 图卡

    private var vizCard: some View {
        WifiCard(title: vizTitle, icon: vizIcon, tint: tint,
                pill: WifiPill(text: vizPillText, tone: pillTone)) {
            VStack(spacing: 10) {
                viz
                WifiMetrics(items: metrics)
            }
        }
    }

    private var vizTitle: String {
        switch kind {
        case .guest: return "访客网络隔离架构"
        case .iot: return "IoT 覆盖与在线设备"
        default: return "Wi-Fi 7 多链路操作"
        }
    }

    private var vizIcon: String {
        switch kind {
        case .guest: return "person.2"
        case .iot: return "dot.radiowaves.left.and.right"
        default: return "square.stack.3d.up"
        }
    }

    private var vizPillText: String {
        guard let group, hasNet else { return "未创建" }
        guard isOn else { return "已关闭" }
        if kind == .iot {
            let bands = group.onBandShort
            return bands.isEmpty ? "广播中" : bands + " 广播中"
        }
        return "已开启"
    }

    @ViewBuilder
    private var viz: some View {
        switch kind {
        case .guest:
            GuestViz(clients: group?.clients ?? 0,
                     bands: group?.onBandShort ?? "")
        case .iot:
            IotViz(clients: group?.clients ?? 0,
                   bands: group?.onBandShort ?? "",
                   sample: sampleClient,
                   channel: group?.members.first?.channelLabel ?? "—",
                   width: group?.members.first.map { $0.width } ?? "")
        default:
            MloViz(bands: group?.onBandShort ?? "2.4G · 5G",
                   security: group?.securityLabel ?? "WPA3")
        }
    }

    /// IoT 图上那台设备只是「本组在线设备里的一个样本」——这台固件不给每台设备标它挂在
    /// 哪个 SSID 上（`gl-clients` 只说频段），所以这张卡按「组内台数 + 一台代表」来讲，
    /// 不硬说「这台就是 IoT 的」。
    private var sampleClient: NetClient? {
        guard let group, group.clients > 0 else { return nil }
        let bands = Set(group.members.filter(\.ssidOn).map { wifiShortBand($0.band) })
        return info.onlineClients.first { bands.contains($0.iface) } ?? info.onlineClients.first
    }

    private var metrics: [WifiMetric] {
        guard let group, hasNet else {
            return [WifiMetric(label: "状态", value: "未创建", sub: "点下面新建"),
                    WifiMetric(label: "在线设备", value: "—", sub: "—"),
                    WifiMetric(label: "频段", value: "—", sub: "—")]
        }

        switch kind {
        case .guest:
            return [WifiMetric(label: "访客终端", value: "\(group.clients) 台", sub: group.clients > 0 ? "当前在线" : "暂无设备"),
                    WifiMetric(label: "开启频段", value: group.onBandShort.isEmpty ? "—" : group.onBandShort, sub: "\(group.members.count) 个 BSS"),
                    WifiMetric(label: "与主网隔离", value: group.networkOn ? "独立网段" : "网段停用", sub: "不与主网同桥")]
        case .iot:
            return [WifiMetric(label: "在线设备", value: "\(group.clients) 台", sub: "本组关联"),
                    WifiMetric(label: "共用信道", value: group.members.first.map { $0.channel > 0 ? "CH \($0.channel)" : "自动" } ?? "—",
                               sub: group.members.first.map { $0.width.isEmpty ? "—" : $0.width + " MHz" } ?? "—"),
                    WifiMetric(label: "随机 BSSID", value: group.randomBSSID ? "已开启" : "已关闭", sub: "每设备不同")]
        default:
            return [WifiMetric(label: "在线终端", value: "\(group.clients) 台", sub: "聚合客户端"),
                    WifiMetric(label: "聚合链路", value: group.onBandShort.isEmpty ? "—" : group.onBandShort, sub: "两频同时发"),
                    WifiMetric(label: "安全标准", value: group.securityLabel.isEmpty ? "—" : group.securityLabel, sub: "抗降级")]
        }
    }

    // MARK: 网络卡

    private var networkCard: some View {
        WifiCard(title: kind.title, icon: KindIcon.symbol(kind), tint: tint) {
            VStack(spacing: 0) {
                if !hasNet {
                    createRow
                } else if let group {
                    ssidRow(group)
                    if group.needsKey, !group.key.isEmpty {
                        CardRule()
                        keyRow(group)
                    }
                    CardRule()
                    valueRow("开启频段", group.onBandShort.isEmpty ? "—" : group.onBandShort)
                    CardRule()
                    valueRow("随机 BSSID", group.randomBSSID ? "已开启" : "已关闭")
                    editButton(group)
                }
            }
        }
    }

    private var createRow: some View {
        Button {
            creating = true
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("新建\(kind.title)")
                        .font(.system(size: 14.5, weight: .medium))
                    Text("这台路由器上还没有这个网络")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(kind == .mlo)
    }

    private func ssidRow(_ group: WifiNetGroup) -> some View {
        HStack(spacing: 11) {
            Button {
                if group.editable { editing = true }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.ssid.isEmpty ? "—" : group.ssid)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(group.isOn ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        WifiChip(text: group.hidden ? "隐藏" : "显示",
                                 tint: group.isOn ? tint : nil,
                                 ink: group.isOn ? ink : nil)
                        if !group.securityLabel.isEmpty { WifiChip(text: group.securityLabel) }
                        if !group.onBandShort.isEmpty { WifiChip(text: group.onBandShort) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!group.editable)

            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: Binding(get: { group.isOn }, set: { setGroup($0) }))
                    .labelsHidden()
                    .blueSwitch()
                    .disabled(!group.editable)
                    .frame(width: 51)
            }
        }
        .padding(.vertical, 10)
    }

    private func keyRow(_ group: WifiNetGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("密码 \(wifiMaskedKey(group.key))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                UIPasteboard.general.string = group.key
                model.notice = Notice(kind: .ok, title: "密码已复制", detail: group.ssid)
            } label: {
                Text("复制")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 14))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 9)
    }

    private func editButton(_ group: WifiNetGroup) -> some View {
        Button {
            if group.editable { editing = true }
        } label: {
            Text("修改")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        .disabled(!group.editable)
        .padding(.top, 10)
    }

    // MARK: 写

    private func setGroup(_ on: Bool) {
        guard let group, !busy else { return }
        busy = true
        errorText = nil
        Task {
            var map: [String: Bool] = [:]
            for member in group.members { map[member.band] = on }

            let problem = await model.saveWifiGroup(group,
                                                    ssid: group.ssid,
                                                    key: group.key,
                                                    hidden: group.hidden,
                                                    bandOn: map)
            busy = false
            if let problem {
                errorText = problem
                model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
            } else {
                await model.manualRefresh()
            }
        }
    }
}

// MARK: - 访客：三节点隔离

/// 访客终端 → 访问隔离 → 互联网，下面一条比例条说明「访客只占这么点」。
private struct GuestViz: View {
    let clients: Int
    let bands: String

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 4) {
                node(title: "访客终端",
                     value: clients > 0 ? "\(clients) 台" : "0 台",
                     strong: false,
                     tint: WifiPalette.accent,
                     ink: WifiPalette.ink)

                connector(WifiPalette.accent)

                node(title: "访问隔离",
                     value: "禁止访问主网",
                     strong: true,
                     tint: WifiPalette.accent,
                     ink: WifiPalette.ink)

                connector(WifiPalette.live)

                node(title: "互联网",
                     value: "仅通外网",
                     strong: false,
                     tint: WifiPalette.live,
                     ink: WifiPalette.liveInk)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(WifiPalette.accent)
                        .frame(width: max(geo.size.width * 0.34, 20))
                }
            }
            .frame(height: 6)

            Text(bands.isEmpty
                 ? "访客与内网不在同一个网桥 · 频段未开启"
                 : "访客与内网不在同一个网桥 · 开启频段 \(bands)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func node(title: String, value: String, strong: Bool, tint: Color, ink: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(strong ? ink : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(strong ? ink.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(strong ? tint.opacity(0.12) : Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint.opacity(strong ? 0.40 : 0.30), lineWidth: 0.8)
        }
    }

    private func connector(_ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 16, height: 1.5)
    }
}

// MARK: - IoT：穿墙波纹 + 在线设备

private struct IotViz: View {
    let clients: Int
    let bands: String
    let sample: NetClient?
    let channel: String
    let width: String

    var body: some View {
        HStack(spacing: 9) {
            IotRipples(tint: WifiPalette.iot)
                .frame(width: 104, height: 86)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(clients > 0 ? WifiPalette.live : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text(clients > 0 ? "\(clients) 台在线" : "暂无设备")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(sample?.displayName ?? "这一组还没有设备连上")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Text(bands.isEmpty ? "IoT" : bands)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(WifiPalette.iotInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(WifiPalette.iot.opacity(0.16))
                        }
                    if width.isEmpty == false {
                        Text(width + " MHz")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(height: 86)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(WifiPalette.iot.opacity(0.40), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    /// 第三行：有样本设备就报它的 IP，没有就退回「这一组开在哪个频段」。
    private var detailLine: String {
        if let sample, !sample.ip.isEmpty { return sample.ip }
        return bands.isEmpty ? "频段未开启" : channel
    }
}

/// 三层波纹：外圈虚线（覆盖边界）、中圈实线、内圈淡底（路由器本身）
private struct IotRipples: View {
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                    .frame(width: side * 0.94, height: side * 0.94)
                Circle()
                    .stroke(tint.opacity(0.38), lineWidth: 1.4)
                    .frame(width: side * 0.62, height: side * 0.62)
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: side * 0.35, height: side * 0.35)
                Circle()
                    .stroke(tint, lineWidth: 1.5)
                    .frame(width: side * 0.35, height: side * 0.35)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - 多链路：双频汇聚

private struct MloViz: View {
    let bands: String
    let security: String

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    pill("5 GHz", filled: true, tint: WifiPalette.accent, ink: WifiPalette.ink)
                    pill("2.4 GHz", filled: false, tint: WifiPalette.iot, ink: WifiPalette.iotInk)
                }
                .frame(width: 74)

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(WifiPalette.accent.opacity(0.70), lineWidth: 1.2)
                    Text("MLO")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(WifiPalette.ink)
                }
                .frame(width: 54, height: 54)

                VStack(spacing: 5) {
                    bar(20, WifiPalette.accent.opacity(0.70))
                    bar(16, WifiPalette.accent.opacity(0.48))
                    bar(12, WifiPalette.iot.opacity(0.58))
                }
                .frame(width: 20)

                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(WifiPalette.accent, lineWidth: 1.2)
                    Image(systemName: "iphone")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(WifiPalette.ink)
                }
                .frame(width: 36, height: 56)
            }
            .frame(maxWidth: .infinity)

            Text("\(bands) 同一张网卡同时收发 · \(security)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func pill(_ text: String, filled: Bool, tint: Color, ink: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(filled ? Color.white : ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 21)
            .background {
                Capsule()
                    .fill(filled ? tint : tint.opacity(0.30))
            }
            .overlay {
                Capsule()
                    .strokeBorder(filled ? Color.clear : tint, lineWidth: 0.8)
            }
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: 5.5)
    }
}
