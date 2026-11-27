import SwiftUI
import UIKit

/// 无线页的四类网络分屏（v3.4.6）。
///
/// **这一版是照着 `E:\Gemini\glinet-monitor` 的 `WifiSettingsScreen.kt` 一比一对齐的**，
/// 不再只是「结构类似」（用户在 v3.4.5 之后回「界面完全不一样，做一样的」）。
/// 对齐的几处硬指标，改之前先读一遍：
///
/// | 位置 | 参考实现（dp / sp） | 这里 |
/// | --- | --- | --- |
/// | 卡片内图盒 | 圆角 13、`adaptiveSubSurfaceColor()`、内衬 11×9（主网络）/ 10×10（其余） | 同 |
/// | 图与读数之间 | `Spacer(10)` + `CardRule()` + `Spacer(8)` | 同，**不许把读数直接贴在图下面** |
/// | 三格读数 | 纯文本三列：标签 10.5 三级灰 / 值 13 半粗 / 副行 10 三级灰，列距 8 | 同，**不许给读数加底色块** |
/// | 频段行 | 行距 11、上下 6.5、标签 44×30、SSID 14.5 半粗、胶囊距 5 | 同 |
/// | 密码行 | 缩进 55、字 11.5、眼睛 15、复制 11.5 半粗、行距 7 | 同 |
/// | 卡头右侧 | `WifiStatusPill`：10.5 半粗、色 12% 底、内衬 8×2.5；纯文字项是 11.5 三级灰 | 同 |
/// | 软按钮 / 主按钮 | 38×圆角 11 / 42×圆角 12，13.5 与 14 半粗 | 同 |
///
/// 与安卓版**有意**不同的三处（别照着「补全」）：
/// 1. **没有「删除」按钮**：`AppModel` 里没有删 `wifi-iface` 段的写入口，摆一颗按不动的
///    按钮比不摆更糟；现在只留一颗「修改」（参考里是「修改 + 删除」并排）。
/// 2. **没有二维码分享**：iOS 侧还没做 `QrShareTarget` 那条链路，密码行只有「眼睛 + 复制」。
/// 3. **颜色守「一页一族主色」**：主网络与访客走蓝、IoT 走青；绿点只表示「正在广播」。

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
/// 右上角有两种尾巴，二选一（同参考的 `trailingContent` / `trailingText`）：
/// - `pill`：状态胶囊（`2 / 2 广播中`、`已开启`）；
/// - `trailing`：一句灰字（`分频段独立设置`、`同频段共用`）。
struct WifiCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = WifiPalette.accent
    var pill: WifiPill? = nil
    var trailing: String? = nil
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

                if let pill {
                    pill
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.bottom, 10)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// 卡片右上角那颗状态胶囊（参考 `WifiStatusPill`）。
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
            .padding(.horizontal, 8)
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
        case .accent: return WifiPalette.accent.opacity(0.14)
        case .iot: return WifiPalette.iot.opacity(0.15)
        case .live: return WifiPalette.live.opacity(0.15)
        }
    }
}

// MARK: - 读数与标签

/// 一格读数：标签 10.5、值 13 半粗、副行 10。
struct WifiMetric: Identifiable {
    let label: String
    let value: String
    var sub: String? = nil

    var id: String { label }
}

/// 图下面那排三格读数。
///
/// **没有底色、没有边框、没有内衬**——参考里就是三列文本贴着卡片的边。
/// v3.4.5 给每格套了一块 4.5% 灰底，一屏看过去像三个小方块，和「图表读数」的气质完全不对。
struct WifiMetrics: View {
    let items: [WifiMetric]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Text(item.value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    if let sub = item.sub, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 名下一行小胶囊：加密方式、信道、显示/隐藏…… 传了 `tint` 就是「亮」的那一颗。
struct WifiChip: View {
    let text: String
    var tint: Color? = nil
    var ink: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 5.5)
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
        return tint.opacity(0.12)
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

// MARK: - 通用小件

/// 提示条（参考 `WifiTipBanner`）：11% 主色底 + 圆角 11 + 图标 15。
struct WifiTipBanner: View {
    let text: String
    var tint: Color = WifiPalette.accent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(0.11))
        }
    }
}

/// 一行「名 — 值」（参考 `GeekKvRow`）。
struct WifiKvRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 9)
    }
}

/// 实底主按钮（参考 `WifiPrimaryActionButton`）：高 42、圆角 12、14 半粗白字。
struct WifiPrimaryButton: View {
    let text: String
    var tint: Color = WifiPalette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint)
                }
        }
        .buttonStyle(.plain)
    }
}

/// 淡底软按钮（参考 `WifiSoftButton`）：高 38、圆角 11、tint 12% 底。
struct WifiSoftButton: View {
    let text: String
    var tint: Color = WifiPalette.accent
    var ink: Color = WifiPalette.ink
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(enabled ? ink : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(enabled ? tint.opacity(0.12) : Color.primary.opacity(0.05))
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 密码行（参考 `WifiPasswordActionRow`）：密码、眼睛、复制、二维码。
struct WifiKeyRow: View {
    let key: String
    let revealed: Bool
    var indent: CGFloat = 0
    var tint: Color = WifiPalette.ink
    let onReveal: () -> Void
    let onCopy: () -> Void
    /// 二维码分享。不传就不摆那颗按钮——没实现分享的页面别留一个按不动的图标。
    var onShare: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        HStack(spacing: 7) {
            Text("密码 \(revealed ? key : wifiMaskedKey(key))")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button(action: onReveal) {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onCopy()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    copied = false
                }
            } label: {
                Text(copied ? "已复制" : "复制")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onShare {
                Button(action: onShare) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, indent)
        .padding(.top, 2)
        .padding(.bottom, 5)
    }
}

// MARK: - 主网络页

/// 主网络：频段频谱 → 各频段 SSID → 无线配置（信道 / 频宽 / 功率）。
struct WifiMainPage: View {
    @Environment(AppModel.self) private var model: AppModel

    @State private var editingBand: WifiBandInfo?
    @State private var editingRadio: WifiBandInfo?
    /// 正在等用户确认「关掉最后一个频段」。
    @State private var pendingClose: WifiBandInfo?
    @State private var qrTarget: WifiQrPayload?
    @State private var busyBands: Set<String> = []
    @State private var revealed: Set<String> = []
    @State private var errorText: String?

    private var info: NetworkInfo { model.network }

    /// 中继锁定的提示色（琥珀）。跟主色分开，一眼看出这是「不能改」而不是「出错了」。
    private var amber: Color { wifiTone((0.62, 0.42, 0.02), (1.00, 0.78, 0.30)) }

    /// 按实机的顺序摆：6 GHz → 5 GHz → 2.4 GHz。
    ///
    /// `info.bands` 本身是 2.4 → 5 → 6（网络页的拓扑也用这个顺序），但官方无线页
    /// 把最快的频段放最上面，照它来。只影响这一页的显示，不动 `info.bands`。
    private var bands: [WifiBandInfo] {
        info.bands.sorted { bandRank($0.band) < bandRank($1.band) }
    }

    private func bandRank(_ band: String) -> Int {
        switch band {
        case "6": return 0
        case "5": return 1
        case "2.4": return 2
        default: return 3
        }
    }

    private var mainGroup: WifiNetGroup? { info.wifiGroups.first { $0.kind == .main } }
    private var liveBands: [WifiBandInfo] { bands.filter(\.up) }
    private var clientCount: Int { bands.reduce(0) { $0 + $1.clients } }

    /// 主网里第一台在线设备，读数第一格的副行要报它的名字。
    ///
    /// **按网口认，不按「第一台不是有线的」认**：`gl-clients` 的 `dev` 就是设备挂的
    /// 那一个 VAP（`rai0` / `ra1`…），访客手机与 IoT 设备挂的是同一台机器的别的 VAP。
    /// 以前取第一台无线设备，主网络下面报出来的名字经常是访客的手机。
    private var firstClient: NetClient? {
        let online = info.onlineClients.filter { !$0.wired }
        let live = bands.filter { $0.ssidOn && !$0.radioOff }
        let ifnames = Set(live.map(\.ifname).filter { !$0.isEmpty })
        if !ifnames.isEmpty, let hit = online.first(where: { ifnames.contains($0.dev) }) {
            return hit
        }
        // 旧固件的客户端列表没有 `dev`，退回按频段标签对（`2.4G` / `5G`）。
        let tags = Set(live.map { wifiShortBand($0.band) })
        return online.first { tags.contains($0.iface) }
    }

    /// 中继正在用的那个频段。改它的信道 / 频宽等于把上级连接掐掉，官方在界面上锁住。
    private var repeaterLockedBand: String {
        guard info.uplink == .repeater else { return "" }
        let raw = info.repeater.lockBand.lowercased()
        if raw.hasPrefix("2") { return "2.4" }
        if raw.hasPrefix("5") { return "5" }
        if raw.hasPrefix("6") { return "6" }
        // 没锁频段时按上级信道推断：14 以上只可能是 5G。
        if let channel = Int(info.upstreamChannel), channel > 0 {
            return channel > 14 ? "5" : "2.4"
        }
        return ""
    }

    private func isRepeaterLocked(_ band: WifiBandInfo) -> Bool {
        !repeaterLockedBand.isEmpty && band.band == repeaterLockedBand
    }

    private var offBandNames: [String] {
        bands.filter { !($0.ssidOn && !$0.radioOff) }.map { wifiShortBand($0.band) }
    }

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
        .sheet(item: $editingBand) { band in
            WifiBandSheet(band: band, isLastLive: liveBands.count <= 1)
        }
        .sheet(item: $editingRadio) { band in
            WifiRadioEditorSheet(band: band)
        }
        .sheet(item: $qrTarget) { payload in
            WifiQrSheet(payload: payload)
        }
        .overlay {
            if let pendingClose {
                SheetOverlay(onDismiss: { self.pendingClose = nil }) {
                    SheetOverlayCard {
                        Text("关闭 \(wifiShortBand(pendingClose.band)) 的主 Wi-Fi")
                            .font(.headline)
                        Text("请确保至少还有一个频段的 Wi-Fi 开着。全部关掉后，手机和电脑会立刻断开这台路由器，只能插网线或按机身上的开关才能恢复。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { self.pendingClose = nil }
                            SheetOverlayButton(title: "确认关闭", tint: .red) {
                                let band = pendingClose
                                self.pendingClose = nil
                                commitBand(band, on: false)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 频谱

    private var spectrumCard: some View {
        WifiCard(title: "频段频谱与广播状态",
                icon: "chart.line.uptrend.xyaxis",
                pill: WifiPill(text: "\(liveBands.count) / \(bands.count) 广播中",
                               tone: liveBands.isEmpty ? .neutral : .live)) {
            VStack(spacing: 8) {
                ForEach(bands) { band in
                    envelopeRow(band)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }

            CardRule()
                .padding(.top, 10)

            WifiMetrics(items: [
                WifiMetric(label: "在线终端",
                           value: "\(clientCount) 台",
                           sub: firstClient.map { clientCount > 1 ? "\($0.displayName) 等" : $0.displayName }
                               ?? (clientCount > 0 ? "主网已连入" : "暂无设备")),
                WifiMetric(label: "活跃频段",
                           value: liveBands.isEmpty
                               ? "已关闭"
                               : liveBands.map { wifiShortBand($0.band) }.joined(separator: " + "),
                           sub: offBandNames.isEmpty ? "全部广播中" : "\(offBandNames.joined(separator: "/")) 已关"),
                // iOS 的采集里没有 `country`（官方那格是「功率 · 地区」），
                // 这里报「功率 · 制式」——不编一个读不到的地区出来。
                WifiMetric(label: "功率 · 制式",
                           value: bands.first?.powerLabel ?? "最大",
                           sub: bands.first.map { wifiStandard($0) } ?? "—")
            ])
            .padding(.top, 8)
        }
    }

    private func envelopeRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(envelopeLabel(band))
                    .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? WifiPalette.ink : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 4)

                Text(envelopeStatus(band, on: on))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isRepeaterLocked(band) && on
                                     ? amber : Color.secondary.opacity(on ? 1 : 0.62))
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

    /// 频谱行右侧那句：中继锁住时要说明「为什么这台数不会变」。
    private func envelopeStatus(_ band: WifiBandInfo, on: Bool) -> String {
        if on, isRepeaterLocked(band) { return "中继锁定 · \(band.clients) 台" }
        return on ? "\(band.clients) 台" : "已关闭 · 0 台"
    }

    /// `2.4G · 自动 · CH 6 · 40MHz`。
    ///
    /// 「自动」和落点是两件事：官方行里钉住信道写 `CH 6`，自动时写 `自动`，
    /// 但自动也必须把实测落点带出来，否则用户以为信道没定。
    private func envelopeLabel(_ band: WifiBandInfo) -> String {
        var parts: [String] = [wifiShortBand(band.band)]
        let pinned = band.channelMode.isEmpty || band.channelMode == "auto"
        if pinned {
            parts.append(band.channel > 0 ? "自动 · CH \(band.channel)" : "自动")
        } else {
            parts.append("CH \(band.channelMode)")
        }
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
                trailing: "分频段独立设置") {
            VStack(spacing: 0) {
                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    if index > 0 { CardRule() }
                    mainRow(band)
                    // 密码行跟着频段走（参考也是每段一行，缩进 55 对齐 SSID），
                    // 不再整组挤在卡片末尾——那样根本分不清是哪一段的密码。
                    if let key = keyFor(band), !key.isEmpty {
                        WifiKeyRow(key: key,
                                   revealed: revealed.contains(band.id),
                                   indent: 55,
                                   tint: WifiPalette.ink,
                                   onReveal: { toggleReveal(band.id) },
                                   onCopy: { copy(key, label: band.ssid) },
                                   onShare: {
                                       qrTarget = WifiQrPayload(ssid: band.ssid,
                                                                key: key,
                                                                security: band.securityLabel,
                                                                hidden: band.hidden,
                                                                bandLabel: band.bandName)
                                   })
                    }
                }
            }
        }
    }

    /// 这一频段要显示的密码：成员自己的 `key`，没取到就退回整组的。
    private func keyFor(_ band: WifiBandInfo) -> String? {
        guard band.ssidOn, !band.radioOff else { return nil }
        guard WifiSecurity.match(band.encryption)?.needsKey ?? true else { return nil }
        if !band.key.isEmpty { return band.key }
        if let group = mainGroup, group.needsKey, !group.key.isEmpty { return group.key }
        return nil
    }

    private func mainRow(_ band: WifiBandInfo) -> some View {
        let on = band.ssidOn && !band.radioOff
        return HStack(spacing: 11) {
            WifiBandTag(text: wifiShortBand(band.band), on: on)

            Button {
                // 只改这一段（官方也是「仅修改 X GHz，不影响其他频段」）。
                // 以前点这里打开的是整组编辑页，改 2.4G 的名字会把 5G 一起改掉。
                if band.editable { editingBand = band }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.ssid.isEmpty ? "未命名" : band.ssid)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        if on {
                            WifiChip(text: band.hidden ? "隐藏" : "显示",
                                     tint: WifiPalette.accent,
                                     ink: WifiPalette.ink)
                        } else {
                            WifiChip(text: band.radioOff ? "射频已关" : "已关闭")
                        }
                        WifiChip(text: band.securityLabel)
                        let channelTag = band.channel > 0
                            ? "\(band.channel)"
                            : band.channelMode
                        if !channelTag.isEmpty, channelTag != "auto" {
                            WifiChip(text: "信道 \(channelTag)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!band.editable)

            bandSwitch(band)
        }
        .padding(.vertical, 6.5)
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

    // MARK: 无线配置

    /// 信道 / 频宽 / 发射功率挂在 radio 段上，这一频段的**所有**网络共用一份，
    /// 所以单独一张卡，不跟某个 SSID 走。
    private var radioCard: some View {
        WifiCard(title: "无线配置",
                icon: "slider.horizontal.3",
                trailing: "同频段共用") {
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

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(band.channelSettingLabel) · \(band.width.isEmpty ? "—" : band.width + "MHz")")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(isRepeaterLocked(band)
                         ? "中继已锁定信道与频宽 · 功率 \(band.powerLabel)"
                         : "\(wifiStandard(band)) · 功率 \(band.powerLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(isRepeaterLocked(band) ? amber : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!band.editable)
    }

    // MARK: 写

    private func toggleReveal(_ id: String) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    private func copy(_ key: String, label: String) {
        UIPasteboard.general.string = key
        model.notice = Notice(kind: .ok, title: "密码已复制", detail: label)
    }

    private func setBand(_ band: WifiBandInfo, on: Bool) {
        guard !busyBands.contains(band.id) else { return }
        // 关掉最后一个还在广播的频段 = 手机立刻掉线、也没法再连回来打开它。
        // 官方在这一步先弹一句「请确保至少有一个频段开着」，这里照做。
        if !on, liveBands.count <= 1 {
            pendingClose = band
            return
        }
        commitBand(band, on: on)
    }

    private func commitBand(_ band: WifiBandInfo, on: Bool) {
        guard !busyBands.contains(band.id) else { return }
        busyBands.insert(band.id)
        errorText = nil
        Task {
            // 只改这一条 `wifi-iface`。以前是把整组的 `disabled` 全部重写一遍，
            // 其中「radio 关着、SSID 还开着」的频段会被算成开，顺手又给写回 0，
            // 于是用户切 A 频段，B 频段的射频也跟着被拉起来。
            let problem = await model.setBandEnabled(band, on)
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
                    shape.fill(tint.opacity(0.22))
                    shape.stroke(tint,
                                 style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
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
    @State private var confirmingDelete = false
    @State private var qrTarget: WifiQrPayload?
    @State private var busy = false
    @State private var revealed = false
    @State private var errorText: String?

    private var info: NetworkInfo { model.network }
    private var group: WifiNetGroup? { info.wifiGroups.first { $0.kind == kind } }
    /// 已经创建过（不是「固件预置了模板段」）。删除后要回到「＋ 添加」，
    /// 所以不能只看 `members` 在不在。
    private var hasNet: Bool { group?.isCreated == true }
    private var isOn: Bool { group?.isOn ?? false }

    private var tint: Color { kind == .iot ? WifiPalette.iot : WifiPalette.accent }
    private var ink: Color { kind == .iot ? WifiPalette.iotInk : WifiPalette.ink }
    private var danger: Color { wifiTone((0.72, 0.16, 0.13), (1.00, 0.45, 0.40)) }

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
            WifiGroupCreateSheet(kind: kind, available: createBands)
        }
        .sheet(item: $qrTarget) { payload in
            WifiQrSheet(payload: payload)
        }
        .overlay {
            if confirmingDelete, let group {
                SheetOverlay(onDismiss: { confirmingDelete = false }) {
                    SheetOverlayCard {
                        Text("移除\(kind.title)")
                            .font(.headline)
                        Text("将停用并重置这组网络的配置，已连入的设备会断开连接。配置段会留着（不删除），下次「添加」还是用同一批模板段。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(group.ssid.isEmpty ? "未命名" : group.ssid)
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { confirmingDelete = false }
                            SheetOverlayButton(title: "确认移除", tint: .red) {
                                confirmingDelete = false
                                remove(group)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 图卡

    private var vizCard: some View {
        WifiCard(title: vizTitle, icon: vizIcon, tint: tint,
                pill: WifiPill(text: vizPillText, tone: pillTone)) {
            // 图盒（圆角 13、次级底、内衬 10×10）——参考里四个页面的图都装在这个盒子里。
            viz
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }

            CardRule()
                .padding(.top, 10)

            WifiMetrics(items: metrics)
                .padding(.top, 8)
        }
    }

    private var vizTitle: String {
        switch kind {
        case .guest: return "访客网络隔离架构"
        case .iot: return "IoT 覆盖与在线设备"
        default: return "Wi-Fi 7 多链路操作 (MLO)"
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
            return liveBandShort.isEmpty ? "广播中" : liveBandShort + " 广播中"
        }
        return "已开启"
    }

    @ViewBuilder
    private var viz: some View {
        switch kind {
        case .guest:
            GuestViz(isOn: isOn,
                     created: hasNet,
                     clients: group?.clients ?? 0,
                     bands: group?.onBandShort ?? "",
                     supported: supportedBands)
        case .iot:
            IotViz(isOn: isOn,
                   clients: iotOnlineCount,
                   bandTag: iotBandTag,
                   sample: iotClients.first)
        default:
            MloViz(isOn: isOn,
                   model: model.routerInfo.model)
        }
    }

    /// 创建页要勾的频段（原始代号 `2.4` / `5` / `6`）。有模板成员就按成员的，
    /// 没建过就退回路由器报告的频段。
    private var createBands: [String] {
        let list = (group?.members.isEmpty == false ? group!.members : info.bands)
        var unique: [String] = []
        for band in list where !band.band.isEmpty && !unique.contains(band.band) {
            unique.append(band.band)
        }
        return unique
    }

    /// 这一组支持的频段（`2.4G / 5G`），没成员就退回全部频段的短名。
    private var supportedBands: String {
        let list = (group?.members.isEmpty == false ? group!.members : info.bands)
        var unique: [String] = []
        for band in list {
            let name = wifiShortBand(band.band)
            if !name.isEmpty && !unique.contains(name) { unique.append(name) }
        }
        return unique.isEmpty ? "2.4G / 5G" : unique.joined(separator: " / ")
    }

    /// IoT 组里在线的那几台。
    ///
    /// **按网口认**（`NetClient.dev` 就是 `ra1` / `rai1` 这种 VAP 名）。这台固件的
    /// `gl-clients` 在 `iface` 里只给「2.4G / 5G / 有线」，不写 SSID；按频段筛会把
    /// 主网同频段的手机算进来，按 `iface.contains("iot")` 又永远筛不到。
    /// 旧固件没有 `dev` 时退回本组台数，但**不再随便抓一台别组的设备**当样本。
    private var iotClients: [NetClient] {
        guard let group else { return [] }
        let ifnames = Set(group.members.map(\.ifname).filter { !$0.isEmpty })
        guard !ifnames.isEmpty else { return [] }
        return info.onlineClients.filter { !$0.wired && ifnames.contains($0.dev) }
    }

    /// IoT 在线台数：能按网口数就按网口数，旧固件退回本组台数。
    private var iotOnlineCount: Int {
        guard let group else { return 0 }
        let ifnames = Set(group.members.map(\.ifname).filter { !$0.isEmpty })
        return ifnames.isEmpty ? group.clients : iotClients.count
    }

    /// IoT 共用信道：优先这一组的 2.4G，其次主网 2.4G，再其次组内任一段。
    /// 以前写的是「第一个不是 5G 的成员」——有 6G 时会报成 6G 的信道。
    private var iotSharedChannel: String {
        let members = group?.members ?? []
        if let two = members.first(where: { $0.band == "2.4" }), two.channel > 0 {
            return "CH \(two.channel)"
        }
        if let hit = members.first(where: { $0.channel > 0 }) {
            return "CH \(hit.channel)"
        }
        if let main = info.bands.first(where: { $0.band == "2.4" }), main.channel > 0 {
            return "CH \(main.channel)"
        }
        return "自动"
    }

    /// 真正在广播的频段串（`ssidOn` 且 radio 没关）。
    ///
    /// `WifiNetGroup.onBandShort` 只看 `ssidOn`：radio 被关掉的频段它也算进来。
    /// 读数与状态胶囊用这个，否则界面说「2.4G · 5G 开着」，实际只有 2.4G 有信号。
    private var liveBandShort: String {
        guard let group else { return "" }
        var names: [String] = []
        for member in group.members where member.ssidOn && !member.radioOff {
            let name = wifiShortBand(member.band)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: " · ")
    }

    /// IoT 正在广播的那个频段短名，没在广播就写 IoT。
    private var iotBandTag: String {
        if let short = group?.onBandShort, !short.isEmpty { return short }
        return info.bands.first { $0.band == "2.4" }.map { wifiShortBand($0.band) } ?? "2.4G"
    }

    /// 未创建时那三格读数（参考里每个页的首卡都有这样一组「还没建」的说明）。
    private var emptyMetrics: [WifiMetric] {
        switch kind {
        case .guest:
            return [WifiMetric(label: "当前状态", value: "未创建"),
                    WifiMetric(label: "支持频段", value: supportedBands),
                    WifiMetric(label: "主网隔离", value: "默认开启")]
        case .iot:
            return [WifiMetric(label: "当前状态", value: "未创建"),
                    WifiMetric(label: "建议频段", value: "2.4 GHz"),
                    WifiMetric(label: "加密兼容", value: "WPA2 优先")]
        default:
            return [WifiMetric(label: "当前状态", value: "未创建"),
                    WifiMetric(label: "可聚合频段", value: "2.4G + 5G"),
                    WifiMetric(label: "推荐安全性", value: "WPA3")]
        }
    }

    private var metrics: [WifiMetric] {
        guard let group, hasNet else { return emptyMetrics }

        switch kind {
        case .guest:
            return [WifiMetric(label: "访客终端", value: "\(group.clients) 台"),
                    WifiMetric(label: "开启频段", value: liveBandShort.isEmpty ? "未开启" : liveBandShort),
                    WifiMetric(label: "主网隔离", value: "已开启")]
        case .iot:
            return [WifiMetric(label: "在线设备", value: "\(iotOnlineCount) 台"),
                    WifiMetric(label: "共用信道", value: iotSharedChannel),
                    WifiMetric(label: "随机 BSSID", value: group.randomBSSID ? "已开启" : "未开启")]
        default:
            return [WifiMetric(label: "在线终端", value: "\(group.clients) 台"),
                    WifiMetric(label: "聚合链路", value: liveBandShort.isEmpty ? "2.4G · 5G" : liveBandShort),
                    WifiMetric(label: "安全标准", value: group.securityLabel.isEmpty ? "—" : group.securityLabel)]
        }
    }

    // MARK: 网络卡

    private var networkCard: some View {
        WifiCard(title: cardTitle, icon: KindIcon.symbol(kind), tint: tint) {
            if !hasNet {
                emptyContent
            } else if let group {
                createdContent(group)
            }
        }
    }

    /// IoT 已建时标题带频段（`IoT 网络 · 2.4GHz`），其余就是组名。
    private var cardTitle: String {
        guard kind == .iot, let group, !group.members.isEmpty else {
            return kind == .mlo ? "多链路操作 (MLO)" : kind.title
        }
        let live = group.members.filter { $0.ssidOn && !$0.radioOff }
        let paused = group.members.filter { $0.ssidOn }
        let list = !live.isEmpty ? live : (!paused.isEmpty ? paused : group.members)
        let bands = list
            .map { $0.bandName.replacingOccurrences(of: " ", with: "") }
            .joined(separator: " · ")
        return "IoT 网络 · " + (bands.isEmpty ? "2.4GHz" : bands)
    }

    /// 未创建：提示条 + 三行说明 + 实底主按钮（参考就是这么三件，不是一行「新建」）。
    @ViewBuilder
    private var emptyContent: some View {
        VStack(spacing: 0) {
            WifiTipBanner(text: tipText, tint: tint)

            switch kind {
            case .guest:
                WifiKvRow(label: "可选 Wi-Fi 频段", value: supportedBands)
                CardRule()
                WifiKvRow(label: "默认随机 BSSID", value: "开启")
                CardRule()
                WifiKvRow(label: "独立名称与密码", value: "与主网隔离")
            case .iot:
                WifiKvRow(label: "默认频段", value: "2.4 GHz")
                CardRule()
                WifiKvRow(label: "默认随机 BSSID", value: "开启")
                CardRule()
                WifiKvRow(label: "推荐加密方式", value: "WPA2")
            default:
                WifiKvRow(label: "Wi-Fi 频段", value: "2.4G + 5G")
                CardRule()
                WifiKvRow(label: "启用随机化的 BSSID", value: "支持开启")
                CardRule()
                WifiKvRow(label: "推荐加密方式", value: "WPA3")
            }

            // 多链路 v3.4.8 起也能建：写 `wireless.mld0` + 每个成员 + `/etc/config/mlo`
            //（写法见 `AppModel.createWifiGroup` 的取证表）。
            WifiPrimaryButton(text: addTitle, tint: WifiPalette.accent) { creating = true }
                .padding(.top, 12)
                .padding(.bottom, 2)

            if kind == .mlo, createBands.count < 2 {
                Text("这台路由器只有一个频段，聚不起多链路。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var tipText: String {
        switch kind {
        case .guest: return "为访客提供专属网络，确保便捷安全的互联网接入。"
        case .iot: return "为 IoT 设备提供专属网络，建议将 IoT 设备连接到 2.4 GHz 频段以确保最佳兼容性。"
        default: return "Wi-Fi 7 客户端推荐连接 MLO Wi-Fi，通过多频段连接可以大大提高网络传输速率和可靠性。"
        }
    }

    private var addTitle: String {
        switch kind {
        case .guest: return "＋ 添加访客网络"
        case .iot: return "＋ 添加 IoT 网络"
        default: return "＋ 添加多链路操作 (MLO)"
        }
    }

    /// 已创建：SSID 行 + 密码行 + 说明行 + 软按钮。
    @ViewBuilder
    private func createdContent(_ group: WifiNetGroup) -> some View {
        VStack(spacing: 0) {
            ssidRow(group)

            if group.needsKey, !group.key.isEmpty {
                WifiKeyRow(key: group.key,
                           revealed: revealed,
                           indent: 0,
                           tint: ink,
                           onReveal: { revealed.toggle() },
                           onCopy: { copyKey(group.key, label: group.ssid) },
                           onShare: {
                               qrTarget = WifiQrPayload(ssid: group.ssid,
                                                        key: group.key,
                                                        security: group.securityLabel,
                                                        hidden: group.hidden,
                                                        bandLabel: kind == .mlo ? "多链路 (MLO)" : cardTitle)
                           })
            }

            CardRule()

            if kind == .iot {
                WifiKeyValueRowCompressed(label: "随机 BSSID",
                                          value: randomBSSIDText(group))
            } else {
                WifiKvRow(label: kind == .mlo ? "聚合频段" : "开启频段",
                          value: liveBandShort.isEmpty ? "—" : liveBandShort)
                CardRule()
                WifiKvRow(label: "随机 BSSID", value: randomBSSIDText(group))
            }

            HStack(spacing: 9) {
                WifiSoftButton(text: "修改",
                               tint: tint,
                               ink: ink,
                               enabled: group.editable) { editing = true }
                WifiSoftButton(text: "删除",
                               tint: danger,
                               ink: danger,
                               enabled: group.editable) { confirmingDelete = true }
            }
            .padding(.top, 12)

            if kind == .iot {
                Text(tipText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func randomBSSIDText(_ group: WifiNetGroup) -> String {
        group.randomBSSID ? "已开启" : "未开启"
    }

    private func ssidRow(_ group: WifiNetGroup) -> some View {
        HStack(spacing: 11) {
            Button {
                if group.editable { editing = true }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.ssid.isEmpty ? "未命名" : group.ssid)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(group.isOn ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        WifiChip(text: group.hidden ? "隐藏" : "显示",
                                 tint: group.isOn ? tint : nil,
                                 ink: group.isOn ? ink : nil)
                        WifiChip(text: group.securityLabel)
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
        .padding(.vertical, 4.5)
    }

    // MARK: 写

    private func copyKey(_ key: String, label: String) {
        UIPasteboard.general.string = key
        model.notice = Notice(kind: .ok, title: "密码已复制", detail: label)
    }

    private func setGroup(_ on: Bool) {
        guard let group, !busy else { return }
        busy = true
        errorText = nil
        Task {
            // 整组开 / 关交给 `setWifiGroup`：成员、`mld0`、`network.guest|iot`
            // 与桥接接口它一起处理，还会把 `init` 摆对。以前是「重写一遍
            // ssid / key / hidden 再带 bandOn」，多走了一条本来不需要的写入路径。
            let problem = await model.setWifiGroup(group, on: on)
            busy = false
            if let problem {
                errorText = problem
                model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
            } else {
                await model.manualRefresh()
            }
        }
    }

    private func remove(_ group: WifiNetGroup) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            let problem = await model.deleteWifiGroup(group)
            busy = false
            if let problem {
                errorText = problem
                model.notice = Notice(kind: .fail, title: "没移除成功", detail: problem)
            } else {
                model.notice = Notice(kind: .ok, title: "\(kind.title)已移除", detail: group.ssid)
                await model.manualRefresh()
            }
        }
    }
}

/// IoT 那一行的「随机 BSSID」值可能很长（真实 MAC），压成 13pt 也好放。
private struct WifiKeyValueRowCompressed: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 访客：三节点隔离

/// 访客终端 → 访问隔离 → 互联网，下面一条比例条说明「访客只占这么点」。
///
/// 尺寸照参考 `GuestWifiTabPage`：节点上下 8（隔离块 9）、标题 11.5 半粗、
/// 副行 10.5 / 9.5、连线 22×4、比例条 6。
private struct GuestViz: View {
    let isOn: Bool
    let created: Bool
    let clients: Int
    let bands: String
    let supported: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                node(title: "访客终端",
                     value: "\(clients) 台",
                     strong: false,
                     tint: WifiPalette.accent,
                     ink: WifiPalette.ink,
                     vertical: 8,
                     radius: 10)

                connector(active: isOn, tint: WifiPalette.accent)

                node(title: "访问隔离",
                     value: "禁止访问主网",
                     strong: true,
                     tint: WifiPalette.accent,
                     ink: WifiPalette.ink,
                     vertical: 9,
                     radius: 11)

                connector(active: isOn, tint: WifiPalette.live)

                node(title: "互联网",
                     value: "仅通外网",
                     strong: false,
                     tint: WifiPalette.live,
                     ink: WifiPalette.liveInk,
                     vertical: 8,
                     radius: 10)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    if barFraction > 0 {
                        Capsule()
                            .fill(WifiPalette.accent)
                            .frame(width: max(geo.size.width * barFraction, 8))
                    }
                }
            }
            .frame(height: 6)

            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 参考的算法：有人就按「几台 / 6」给比例（0.25…1），空了给 0.18，没建就是 0。
    private var barFraction: CGFloat {
        guard created else { return 0 }
        guard isOn else { return 0 }
        if clients > 0 {
            return min(max(CGFloat(clients) / 6, 0.25), 1)
        }
        return 0.18
    }

    private var caption: String {
        if !created {
            return "尚未启用访客网络 · 支持 " + supported
        }
        if isOn {
            return "访客已与内网隔离 · 开启频段 " + (bands.isEmpty ? "已开" : bands)
        }
        return "访客网络已创建（当前暂停广播）"
    }

    private func node(title: String,
                      value: String,
                      strong: Bool,
                      tint: Color,
                      ink: Color,
                      vertical: CGFloat,
                      radius: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(strong ? ink : (isOn ? Color.primary : Color.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: strong ? 9.5 : 10.5))
                .foregroundStyle(strong ? ink.opacity(0.85) : (isOn ? tint : Color.secondary.opacity(0.7)))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, vertical)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(nodeFill(strong: strong, tint: tint))
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isOn ? tint.opacity(strong ? 0.40 : 0.35) : Color.primary.opacity(0.10),
                              lineWidth: 0.8)
        }
    }

    private func nodeFill(strong: Bool, tint: Color) -> Color {
        if strong {
            return isOn ? tint.opacity(0.12) : Color.primary.opacity(0.06)
        }
        return Color(.secondarySystemGroupedBackground)
    }

    private func connector(active: Bool, tint: Color) -> some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(active ? tint : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                       dash: active ? [] : [2.5, 2.5]))
        }
        .frame(width: 22, height: 4)
    }
}

// MARK: - IoT：穿墙波纹 + 在线设备

/// 左侧三层波纹 + 连线，右侧真实在线设备卡（参考 `IotWifiTabPage`）。
private struct IotViz: View {
    let isOn: Bool
    let clients: Int
    let bandTag: String
    let sample: NetClient?

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                IotRipples(tint: isOn ? WifiPalette.iot : Color.secondary,
                           active: isOn)
                Text(isOn ? bandTag : "IoT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isOn ? WifiPalette.iotInk : Color.secondary)
                    .frame(width: 36)
                    .padding(.leading, 26)
            }
            .frame(width: 114, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                if let sample {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(WifiPalette.live)
                            .frame(width: 7, height: 7)
                        Text(sample.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if clients > 1 {
                            Text("+\(clients - 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(WifiPalette.iotInk)
                        }
                    }
                    Text(sample.ip.isEmpty ? sample.mac : sample.ip)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    WifiChip(text: sample.iface.isEmpty ? bandTag : sample.iface,
                             tint: WifiPalette.iot,
                             ink: WifiPalette.iotInk)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(isOn ? "等待 IoT 设备接入" : "IoT 网络未广播")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Text("兼容老款智能家居与传感器")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(sample != nil && isOn
                                  ? WifiPalette.iot.opacity(0.42)
                                  : Color.primary.opacity(0.10),
                                  lineWidth: 0.8)
            }
        }
    }
}

/// 三层波纹 + 一条连到右侧设备卡的线（参考的 Canvas 逐项重画）。
private struct IotRipples: View {
    let tint: Color
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let cx: CGFloat = 44
            let cy = size.height / 2
            let outer: CGFloat = 38
            let mid: CGFloat = 26
            let inner: CGFloat = 14.5

            ctx.stroke(Path(ellipseIn: CGRect(x: cx - outer, y: cy - outer, width: outer * 2, height: outer * 2)),
                       with: .color(tint.opacity(active ? 0.25 : 0.14)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))

            ctx.stroke(Path(ellipseIn: CGRect(x: cx - mid, y: cy - mid, width: mid * 2, height: mid * 2)),
                       with: .color(tint.opacity(active ? 0.38 : 0.20)),
                       style: StrokeStyle(lineWidth: 1.4))

            let innerRect = CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2)
            ctx.fill(Path(ellipseIn: innerRect), with: .color(tint.opacity(active ? 0.18 : 0.08)))
            ctx.stroke(Path(ellipseIn: innerRect), with: .color(tint), style: StrokeStyle(lineWidth: 1.5))

            // 连到右边设备卡：线接到画布右缘，终点补一颗 3pt 的圆点。
            var line = Path()
            line.move(to: CGPoint(x: cx + outer, y: cy))
            line.addLine(to: CGPoint(x: size.width - 2, y: cy))
            ctx.stroke(line, with: .color(tint.opacity(active ? 0.85 : 0.35)),
                       style: StrokeStyle(lineWidth: 1.5))
            ctx.fill(Path(ellipseIn: CGRect(x: size.width - 5, y: cy - 3, width: 6, height: 6)),
                     with: .color(tint))
        }
    }
}

// MARK: - 多链路：双频汇聚

/// 五段式（参考 `MloWifiTabPage`）：路由器线稿 → 双频胶囊 → MLO 圆筒 → 速度条 → Wi-Fi 7 手机框。
private struct MloViz: View {
    let isOn: Bool
    let model: String

    private var shortModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Wi-Fi 7" }
        return trimmed.hasPrefix("GL-") ? String(trimmed.dropFirst(3)) : trimmed
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                RouterSideGlyph(tint: isOn ? WifiPalette.accent : Color.secondary)
                    .frame(width: 48, height: 34)
                Text(shortModel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 62)

            VStack(spacing: 6) {
                Text("5 GHz")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 21)
                    .background {
                        Capsule().fill(WifiPalette.accent.opacity(isOn ? 0.92 : 0.78))
                    }

                Text("2.4 GHz")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WifiPalette.iotInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 21)
                    .background {
                        Capsule().fill(WifiPalette.iot.opacity(0.34))
                    }
                    .overlay {
                        Capsule().strokeBorder(WifiPalette.iot, lineWidth: 0.8)
                    }
            }
            .frame(maxWidth: .infinity)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(WifiPalette.accent.opacity(isOn ? 0.72 : 0.42), lineWidth: 1.2)
                Text("MLO")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(WifiPalette.ink)
            }
            .frame(width: 56, height: 54)

            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(WifiPalette.accent.opacity(0.70)).frame(width: 22, height: 5.5)
                Capsule().fill(WifiPalette.accent.opacity(0.48)).frame(width: 26, height: 5.5)
                Capsule().fill(WifiPalette.iot.opacity(0.58)).frame(width: 18, height: 5.5)
            }
            .frame(width: 26, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isOn ? WifiPalette.accent : Color.secondary, lineWidth: 1.2)
                Image(systemName: "wifi")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(WifiPalette.ink)
            }
            .frame(width: 42, height: 58)
        }
    }
}

/// 路由器侧视线稿（参考的 `RouterModelGlyph` 是官方实机轮廓的贝塞尔曲线，
/// 这里按同一种「斜视方盒 + 前面板 + 两只脚」的画法给一笔，48×34）。
private struct RouterSideGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }

            // 顶面
            var top = Path()
            top.move(to: p(0.04, 0.58))
            top.addLine(to: p(0.66, 0.26))
            top.addLine(to: p(0.98, 0.42))
            top.addLine(to: p(0.36, 0.74))
            top.closeSubpath()
            ctx.fill(top, with: .color(tint.opacity(0.14)))
            ctx.stroke(top, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))

            // 前面板
            var front = Path()
            front.move(to: p(0.36, 0.74))
            front.addLine(to: p(0.98, 0.42))
            front.addLine(to: p(0.98, 0.58))
            front.addLine(to: p(0.36, 0.90))
            front.closeSubpath()
            ctx.fill(front, with: .color(tint.opacity(0.06)))
            ctx.stroke(front, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))

            // 两只脚
            var feet = Path()
            feet.move(to: p(0.42, 0.90))
            feet.addLine(to: p(0.42, 0.98))
            feet.move(to: p(0.88, 0.62))
            feet.addLine(to: p(0.88, 0.70))
            ctx.stroke(feet, with: .color(tint.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round))

            // 前面板两颗状态灯
            for x in [CGFloat(0.60), CGFloat(0.68)] {
                let dot = CGRect(x: w * x - 1.2, y: h * 0.60 - 1.2, width: 2.4, height: 2.4)
                ctx.fill(Path(ellipseIn: dot), with: .color(tint.opacity(0.8)))
            }
        }
    }
}
