import SwiftUI
import UIKit
import CoreImage

/// 无线（二级页）。
///
/// **入口**：网络页「无线」卡右上角的「更多」。
///
/// ## v3.4.5 第四次重做：四类网络分屏
///
/// 用户 2026-11-27 20:41：「把 4 类 WiFi 分到单独 4 页顶部切换，每页都有对应的图表数据」，
/// 21:0x 又指定「看 `E:\Gemini\glinet-monitor` 这个项目的源码，照着做无线页」。
///
/// 结构（图形件与四个页面都在 `WifiTabPages.swift`）：
///
/// | 区域 | 画法 |
/// | --- | --- |
/// | 顶部 | 四段切换：主网络 / 访客 / IoT / 多链路；正在广播的段右侧一颗绿点 |
/// | 翻页 | 左右滑动，顶栏跟着走；固件没有 MLO 时只有三段 |
/// | ① 主网络 | 频段频谱包络（梯形块，宽窄就是频宽）+ 各频段 SSID + 无线参数 |
/// | ② 访客 | 访客终端 → 访问隔离 → 互联网 三节点 + 比例条 |
/// | ③ IoT | 三层穿墙波纹 + 本组在线设备 |
/// | ④ 多链路 | 双频胶囊 → MLO → 速度条 → 手机 |
/// | 每页 | 图下统一一排三格读数，再往下才是可改的行 |
///
/// 沿用的三条硬规矩（见 开发交接.md 第 5 节）：
/// 1. **一页只有一族主色**（主网络/访客/多链路走蓝，IoT 走青），频段靠标签和开关
///    状态区分，关掉的一律压灰；绿点只表示「这一组在广播」，不参与版面配色；
/// 2. **图形只出现在那一页的第一张卡里，且只有一处**；下面一律是安静的行，
///    不再每卡配一条小图；
/// 3. **信道 / 频宽 / 功率不进 SSID 行**——它们是 radio 级参数，同频段所有网络共用，
///    混在 SSID 行里既重复又挤。
///
/// v3.4.3 那套「一页一张场景图」连同 `WifiScene` 一起删了：一类网络一页之后，
/// 再把三类网络挤进同一张图就没有意义了。
///
/// **能不能改得动，靠的是通道不是界面**：所有写入都走 `AppModel.saveWifiGroup` /
/// `createWifiGroup` / `saveRadioSettings`，写完回读 `uci`，对得上才算成功，最后
/// `wifi reload` 生效（那一步会断线，见 `reloadWireless`）。
///
/// **没做的两项**（原因写进第 5 节）：无线模式 `hwmode` 与使用环境（室内/户外）。
/// 前者这台固件没有 `hwmode` 这个键，制式写在 `htmode` 前缀里，写错会让 MTK 驱动
/// 直接不认这个频段；后者在固件里没有 uci 落点（官方走 RPC 直调驱动）。

// MARK: - 主视图（v3.4.5：四类网络分屏）

/// 顶栏那四段（固件没有 MLO 时三段）。
///
/// rawValue 和 `WifiNetGroup.Kind` 一模一样，`liveTabs` 就是按这个对上的。
enum WifiNetTab: String, CaseIterable, Identifiable {
    case main
    case guest
    case iot
    case mlo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: return "主网络"
        case .guest: return "访客"
        case .iot: return "IoT"
        case .mlo: return "多链路"
        }
    }
}

struct WifiSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    /// 当前停在哪一页。顶栏点按和左右滑动共用这一个值。
    @State private var tab: WifiNetTab = .main

    private var info: NetworkInfo { model.network }

    /// 这台机器有没有 MLO：没有就整段不出现（不是灰掉——灰掉的段点不动，比没有更让人疑惑）。
    private var tabs: [WifiNetTab] {
        info.mloSupported ? WifiNetTab.allCases : WifiNetTab.allCases.filter { $0 != .mlo }
    }

    /// 正在广播的组，顶栏在对应那格右侧点一颗绿点。
    ///
    /// 主网络不靠 `mainGroup.isOn` 判：那一组还带着 `network.lan` 的状态，
    /// 而「有没有在广播」看的是各频段的 `ssidOn && !radioOff`（`WifiBandInfo.up`）。
    /// 访客 / IoT / 多链路才有独立的 `network.*` 段，用组的状态。
    private var liveTabs: Set<WifiNetTab> {
        var set: Set<WifiNetTab> = []
        if info.bands.contains(where: \.up) { set.insert(.main) }
        for group in info.wifiGroups where group.kind != .main && group.isOn {
            if let matched = WifiNetTab(rawValue: group.kind.rawValue) { set.insert(matched) }
        }
        return set
    }

    var body: some View {
        Group {
            if info.bands.isEmpty {
                ScrollView {
                    CardPanel("读不到无线配置", icon: "wifi.slash") {
                        Text("这一拍没取到频段信息，下拉刷新一次。")
                            .font(UI.row())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    .padding(.horizontal, UI.pagePadding)
                    .padding(.top, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: 0) {
                    WifiModeBar(tabs: tabs, live: liveTabs, selection: $tab)
                        .padding(.horizontal, UI.pagePadding)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    TabView(selection: $tab) {
                        WifiMainPage()
                            .tag(WifiNetTab.main)
                        WifiSidePage(kind: .guest)
                            .tag(WifiNetTab.guest)
                        WifiSidePage(kind: .iot)
                            .tag(WifiNetTab.iot)
                        if info.mloSupported {
                            WifiSidePage(kind: .mlo)
                                .tag(WifiNetTab.mlo)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
        }
        .themedScrollBackground()
        .primaryButtons()
        .navigationTitle("无线")
        .navigationBarTitleDisplayMode(.inline)
        // MLO 那段消失时（换机器 / 重新采集）别把页面停在空页上。
        .onChange(of: info.mloSupported) { _, supported in
            if !supported && tab == .mlo { tab = .main }
        }
    }
}

/// 顶栏四段切换。
///
/// 尺寸照安卓版 `WifiModeBar`：圆角 13 的外框、4 的内衬、每格高 34、圆角 9.5，
/// 选中格用主色 12% 底 + 深一档的主色字，正在广播的格右侧点一颗 5.5 的绿点。
private struct WifiModeBar: View {
    let tabs: [WifiNetTab]
    let live: Set<WifiNetTab>
    @Binding var selection: WifiNetTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs) { item in
                let on = item == selection
                Button {
                    if selection != item {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = item }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? WifiPalette.ink : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if live.contains(item) {
                            Circle()
                                .fill(WifiPalette.live)
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                            .fill(on ? WifiPalette.accent.opacity(0.12) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - 图形件

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
struct WifiErrorNote: View {
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
func wifiTone(_ light: (CGFloat, CGFloat, CGFloat),
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
enum WifiPalette {
    /// 主色（蓝）。和系统开关的蓝接近，所以开关、标签、图形看上去是一套。
    static let accent = wifiTone((0.15, 0.47, 0.90), (0.42, 0.66, 0.98))

    /// 同一主色的深一档，只给文字。
    static let ink = wifiTone((0.05, 0.28, 0.62), (0.72, 0.86, 1.00))
}

/// 三种附加网络的 SF Symbol。
///
/// 只管图标，**不再管颜色**——颜色统一走 `WifiPalette`，否则又会变成一页五色。
enum KindIcon {
    static func symbol(_ kind: WifiNetGroup.Kind) -> String {
        switch kind {
        case .guest: return "person.2.fill"
        case .iot: return "cpu"
        case .mlo: return "square.stack.3d.up.fill"
        case .main: return "wifi"
        }
    }
}

// MARK: - 单频段编辑

/// 只改一个频段：名称 / 安全性 / 密码 / 隐藏 / 随机 BSSID / 启用。
///
/// 主网络卡里点哪一段，改的就是那一段（官方那句「仅修改 X GHz，不影响其他频段」）。
/// v3.4.6 及以前点开的是**整组**编辑页——改 2.4G 的名字会把 5G 一起改掉，
/// 关 2.4G 的 SSID 也会把 5G 关掉，这是这一页最容易被当成「bug」的地方。
/// 写入走 `saveBand`，只碰这一条 `wifi-iface` 和它自己的 `random_bssid`。
struct WifiBandSheet: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let band: WifiBandInfo
    /// 这是不是最后一个还在广播的频段。是的话不许在这里关——关掉就断连。
    var isLastLive = false

    @State private var ssid: String
    @State private var key: String
    @State private var hidden: Bool
    @State private var randomBSSID: Bool
    @State private var enabled: Bool
    @State private var security: WifiSecurity
    @State private var showKey = false
    @State private var busy = false
    @State private var errorText: String?
    /// 用户点过安全性那几档没有。没点过就不写 `encryption`。
    @State private var securityTouched = false

    init(band: WifiBandInfo, isLastLive: Bool = false) {
        self.band = band
        self.isLastLive = isLastLive
        _ssid = State(initialValue: band.ssid)
        _key = State(initialValue: band.key)
        _hidden = State(initialValue: band.hidden)
        _randomBSSID = State(initialValue: band.randomBSSID)
        // 和列表里的开关同一个口径：radio 关着就是关着，不因为 iface 的 disabled=0 就当开。
        _enabled = State(initialValue: band.ssidOn && !band.radioOff)
        _security = State(initialValue: WifiSecurity.match(band.encryption) ?? .mixed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    identityCard
                    securityCard
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
            .navigationTitle("\(band.bandName) 设置")
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
            VStack(alignment: .leading, spacing: 6) {
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
                Text("只改 \(band.bandName)，其他频段的名称与密码不动。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
                        .disabled(busy)

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
            .foregroundStyle(selected ? WifiPalette.ink : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? WifiPalette.accent.opacity(0.12) : Color(.tertiarySystemFill))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var optionsCard: some View {
        CardPanel("其他", icon: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WifiPalette.ink)
                        .frame(width: 18, alignment: .leading)
                    Text("隐藏网络").font(UI.row())
                    Spacer(minLength: 8)
                    Toggle("", isOn: $hidden)
                        .labelsHidden()
                        .blueSwitch()
                        .disabled(busy)
                }
                .padding(.vertical, UI.rowPadding)

                CardRule()

                HStack(spacing: 9) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WifiPalette.ink)
                        .frame(width: 18, alignment: .leading)
                    Text("随机 BSSID").font(UI.row())
                    Spacer(minLength: 8)
                    Toggle("", isOn: $randomBSSID)
                        .labelsHidden()
                        .blueSwitch()
                        .disabled(busy)
                }
                .padding(.vertical, UI.rowPadding)

                CardRule()

                HStack(spacing: 9) {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WifiPalette.ink)
                        .frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用这个频段").font(UI.row())
                        Text(enabled
                             ? "保存后开始广播"
                             : (isLastLive ? "这是最后一个在广播的频段，不能在这里关" : "保存后停止广播（同组其他频段不受影响）"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .blueSwitch()
                        .disabled(busy)
                }
                .padding(.vertical, UI.rowPadding)
            }
        }
    }

    private func save() async {
        guard !busy else { return }
        // 断连的这一个动作只留在列表里做：那里有二次确认，这里没有。
        if isLastLive, band.up, !enabled {
            errorText = "这是最后一个在广播的频段，关掉会立刻断连。请回列表点开关并确认。"
            return
        }
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32 else {
            errorText = "Wi-Fi 名称要 1–32 个字符"
            return
        }
        if security.needsKey {
            let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard secret.count >= 8, secret.count <= 63 else {
                errorText = "密码要 8–63 个字符"
                return
            }
            guard !secret.contains(where: { $0.isWhitespace || !$0.isASCII }) else {
                errorText = "密码不能包含空格或中文字符"
                return
            }
        }
        busy = true
        errorText = nil
        // 认不出来的老加密（`owe` / `psk2+tkip+ccmp`）且用户没动过：不写 encryption，
        // 免得「只改了个名字」把固件原有的组合压成别的。
        let encryption: String? = (securityTouched || WifiSecurity.match(band.encryption) != nil)
            ? security.rawValue : nil
        let problem = await model.saveBand(band, ssid: name, key: key,
                                           hidden: hidden, enabled: enabled,
                                           encryption: encryption,
                                           randomBSSID: randomBSSID)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "\(band.bandName) 已保存", detail: name)
            dismiss()
            await model.manualRefresh()
            return
        }
        errorText = problem
    }
}

// MARK: - 二维码分享

/// 一条分享用的网络信息（标准 `WIFI:` 串，系统相机和微信扫一扫都认）。
struct WifiQrPayload: Identifiable {
    let id = UUID()
    let ssid: String
    let key: String
    let security: String
    let hidden: Bool
    let bandLabel: String

    var encoded: String {
        let noPass = security.isEmpty || security.contains("无")
        let specials: Set<Character> = ["\\", ";", ",", ":", "\""]
        func escape(_ raw: String) -> String {
            var out = ""
            for ch in raw {
                if specials.contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }
        // 二维码规范里只有 WPA / WEP / nopass 三种；WPA3 落在 WPA 这一档。
        let type = noPass ? "nopass" : "WPA"
        var text = "WIFI:T:" + type + ";S:" + escape(ssid) + ";"
        if !noPass { text += "P:" + escape(key) + ";" }
        if hidden { text += "H:true;" }
        return text + ";"
    }
}

struct WifiQrSheet: View {
    @Environment(\.dismiss) private var dismiss

    let payload: WifiQrPayload
    private let image: UIImage?

    init(payload: WifiQrPayload) {
        self.payload = payload
        self.image = Self.makeImage(payload.encoded)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UI.cardSpacing) {
                    CardPanel("扫一扫连接", icon: "qrcode") {
                        VStack(spacing: 12) {
                            if let image {
                                Image(uiImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 186, height: 186)
                                    .padding(12)
                                    // 二维码必须留白底：深色模式下透出页面底会扫不出来。
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } else {
                                Text("二维码没生成出来")
                                    .font(UI.row())
                                    .foregroundStyle(.secondary)
                            }
                            VStack(spacing: 4) {
                                Text(payload.ssid.isEmpty ? "未命名" : payload.ssid)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(payload.bandLabel)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Text("用手机相机或微信扫一扫，直接连上这个网络。二维码只在本机生成，密码不会上传。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }

                    if !payload.key.isEmpty {
                        CardPanel("密码", icon: "key") {
                            Text(payload.key)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .themedScrollBackground()
            .navigationTitle("分享 Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .navBarTint()
                }
            }
        }
    }

    private static func makeImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
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
        // 和列表里的开关同一个口径：radio 关着就是关着。
        // 只看 `ssidOn` 的话，radio 被关掉的频段在编辑页里会显示成开，
        // 保存时又被写回 `disabled=0`，顺手把它打开了。
        for member in group.members { map[member.band] = member.ssidOn && !member.radioOff }
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
