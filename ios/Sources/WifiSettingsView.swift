import SwiftUI
import UIKit

/// 无线（二级页）。
///
/// **入口**：网络页「无线」卡右上角的「更多」。
///
/// ## v3.4.1 重做（用户 2026-11-25：「无线页也参考官方重做，布局也重做不要参考
/// 官方布局，你自己设计要图形化」）
///
/// 之前这一页是 `Form` + 五张系统分区表：主网络两行、访客一行、IoT 一行、多链路
/// 一行、无线配置两行，全是「标题 + 灰字 + 开关」的文字行。用户要的是图形化，
/// 所以版式整个换掉，**信息结构仍然按官方那套**（`/www/i18n/gl-sdk4-ui-wireless`
/// 的分组：主网络 / 访客 / IoT / 多链路 / 无线配置），只是把它画出来：
///
/// | 区域 | 画法 |
/// | --- | --- |
/// | 顶部 | 无线波纹 + 「几个频段在广播 / 几台设备」+ 每个频段的色点胶囊 |
/// | 每个频段一张卡 | 频段徽章（2.4 / 5）+ SSID + 开关 + **频谱条** + 三项参数胶囊 |
/// | 频谱条 | 按这一频段可用信道画刻度，高亮当前信道、宽度按频宽占位 |
/// | 其他网络 | 彩色图标块 + 频段圆点 + 开关（访客 / IoT / 多链路） |
/// | 编辑页 | 安全性四个胶囊、频段开关、密码框；无线参数页是「信道标尺 + 频宽块 + 功率格」 |
///
/// **能不能改得动，靠的是通道不是界面**：所有写入都走 `AppModel.saveWifiGroup` /
/// `createWifiGroup` / `saveRadioSettings`，写完回读 `uci`，对得上才算成功，最后
/// `wifi reload` 生效（那一步会断线，见 `reloadWireless`）。
///
/// 这一版顺手修掉一个会「改坏」的老毛病：编辑页以前不管用户动没动安全性，
/// 保存时都把 `encryption` 写一遍。原值是认不出的老组合（`owe` / `wpa3` 之类）时，
/// 只改个名字也会被压成 WPA2/WPA3 混合——现在没动过就不写。
///
/// **没做的两项**（原因写进第 5 节）：无线模式 `hwmode` 与使用环境（室内/户外）。
/// 前者这台固件没有 `hwmode` 这个键，制式写在 `htmode` 前缀里，写错会让 MTK 驱动
/// 直接不认这个频段；后者在固件里没有 uci 落点（官方走 RPC 直调驱动）。
///
/// ## v3.4.2 配色重定（用户 2026-11-25：「这页面的配色太丑了」）
///
/// 版式没动，只换颜色。旧版一屏里有五种高饱和色，而且互相撞：
/// 2.4G 墨绿和 IoT 草绿是同一个色族，6G 的紫和「多链路」的紫**完全相同**
/// （都是 `0.44,0.36,0.88`），再叠一个很亮的橙，整页像拼图。
///
/// 现在：
/// - **频段只用冷色一族**——青绿（2.4）→ 青蓝（5，接着网络页拓扑的青色）→ 靛蓝（6），
///   色相只差二十来度，明度对齐，扫过去是一组；
/// - **次要网络全部降饱和**——访客暖赭（唯一暖色，用来分主次）、物联网中性灰蓝、
///   多链路暗洋红，都不与频段撞；
/// - **亮色系 + 两档**（用户同日 23:53：「要用亮色系」）：色块取亮的一档（400 级，
///   薄荷绿 / 天青 / 亮靛），文字取同色相深一档（`ink`），浅色 / 深色各有一套值；
/// - 顺手把「关闭态」的灰从 `systemGray4` 换到 `Color.primary.opacity(…)`，浅色下
///   那些 13% 灰底原先几乎看不见。 
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

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                heroCard

                if bands.isEmpty {
                    emptyCard
                } else {
                    ForEach(bands) { band in
                        bandCard(band)
                    }
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

    // MARK: - 顶部：现在开着几个频段

    /// 顶上那一块：左边是无线波纹（弧数跟着开着的频段数走），右边一句结论。
    private var heroCard: some View {
        let live = bands.filter { $0.up }
        let clients = bands.reduce(0) { $0 + $1.clients }
        return HStack(alignment: .center, spacing: 14) {
            WifiWaveGlyph(lit: live.isEmpty ? 0 : min(live.count, 3),
                          color: live.isEmpty ? Color.secondary : NetPalette.wifi)
                .frame(width: 86, height: 64)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(live.isEmpty ? "无线已关闭" : "\(live.count) 个频段在广播")
                    .font(UI.title(.semibold))
                    .foregroundStyle(.primary)
                Text(clients > 0 ? "\(clients) 台设备连着" : "暂时没有设备连着")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                if !bands.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(bands) { band in
                            bandPill(band)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    private func bandPill(_ band: WifiBandInfo) -> some View {
        let on = band.up
        let tint = BandTint.color(band.band)
        return HStack(spacing: 4) {
            Circle()
                .fill(on ? tint : Color(.systemGray3))
                .frame(width: 5, height: 5)
            Text(shortBand(band.band))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? BandTint.ink(band.band) : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill((on ? tint : Color(.systemGray4)).opacity(0.18))
        }
    }

    private var emptyCard: some View {
        CardPanel("读不到无线配置", icon: "wifi.slash") {
            Text("这一拍没取到频段信息，下拉刷新一次。")
                .font(UI.row())
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    // MARK: - 每个频段一张卡

    /// 一个频段 = 一张卡：频段徽章、主 SSID、开关、频谱条、三项参数。
    ///
    /// 参数（信道 / 频宽 / 功率）挂在 radio 上，这一频段的**所有**网络共用一份，
    /// 所以它不跟着某个 SSID 走，而是单独一行，点开就是无线参数页（与官方
    /// 「以下配置将应用到所有 X 频段的网络」同一件事）。
    private func bandCard(_ band: WifiBandInfo) -> some View {
        let tint = BandTint.color(band.band)
        let on = band.ssidOn && !band.radioOff

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                bandBadge(band, on: on)

                Button {
                    if let mainGroup { editingGroup = mainGroup }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(band.ssid.isEmpty ? "—" : band.ssid)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(bandSubline(band))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(mainGroup?.editable != true)

                bandSwitch(band)
            }

            WifiSpectrum(channels: spectrumChannels(band),
                         highlight: band.channel,
                         slots: spectrumSlots(band.width),
                         tint: on ? tint : Color(.systemGray3))
                .frame(height: 28)
                .padding(.top, 12)
                .opacity(on ? 1 : 0.55)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                paramChip("信道", band.channelSettingLabel, band: band)
                paramChip("频宽", band.width.isEmpty ? "—" : "\(band.width) MHz", band: band)
                paramChip("功率", band.powerLabel, band: band)
            }
            .padding(.top, 10)
        }
        .cardSurface()
    }

    private func bandBadge(_ band: WifiBandInfo, on: Bool) -> some View {
        let tint = BandTint.color(band.band)
        return VStack(spacing: -1) {
            Text(band.band.isEmpty ? "?" : band.band)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(on ? BandTint.ink(band.band) : Color.secondary)
            Text("GHz")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle((on ? BandTint.ink(band.band) : Color.secondary).opacity(0.8))
        }
        .frame(width: 48, height: 42)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((on ? tint : Color(.systemGray4)).opacity(0.16))
        }
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

    /// 信道 / 频宽 / 功率：三颗等宽的小胶囊，点哪一颗都进同一页（无线参数）。
    private func paramChip(_ title: String, _ value: String, band: WifiBandInfo) -> some View {
        Button {
            editingRadio = band
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(band.editable ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!band.editable)
    }

    /// 频率刻度上的候选信道。当前信道一定要在里面（可能停在 DFS 信道上），
    /// 否则频谱条上会找不到高亮，看着像「没信号」。
    private func spectrumChannels(_ band: WifiBandInfo) -> [Int] {
        var list = band.channelOptions
        if band.channel > 0, !list.contains(band.channel) {
            list.append(band.channel)
            list.sort()
        }
        return list
    }

    /// 频宽在频谱条上占几格（20M 一格、40M 两格、80M 四格、160M 八格）。
    private func spectrumSlots(_ width: String) -> Int {
        switch width {
        case "160": return 8
        case "80": return 4
        case "40": return 2
        default: return 1
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

    /// 一行一个组：彩色图标块 + 标题 + SSID + 频段圆点 + 开关。
    /// 没有成员段的组画成「添加」，点进去就是创建页；多链路没有模板段，只画一条占位。
    private func networkRow(_ group: WifiNetGroup) -> some View {
        let exists = !group.members.isEmpty
        let on = group.isOn
        let tint = KindTint.color(group.kind)
        let canCreate = group.kind == .guest || group.kind == .iot

        return HStack(alignment: .center, spacing: 12) {
            Button {
                if exists {
                    editingGroup = group
                } else if canCreate {
                    creatingKind = group.kind
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(exists && on ? tint.opacity(0.16) : Color.primary.opacity(0.06))
                            .frame(width: 42, height: 42)
                        Image(systemName: exists ? KindTint.icon(group.kind) : "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(exists && on ? KindTint.ink(group.kind) : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(exists ? group.kind.title : "添加\(group.kind.title)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(exists ? Color.primary : Color.secondary)
                            .lineLimit(1)

                        if exists {
                            Text(group.ssid.isEmpty ? "—" : group.ssid)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            bandDots(group)
                        } else {
                            Text(canCreate ? "还没有这个网络" : "这台路由器没有这一组")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 51)
            }
        }
        .padding(.vertical, 10)
    }

    /// 组里哪几个频段在广播：亮色 = 开，灰 = 关。
    private func bandDots(_ group: WifiNetGroup) -> some View {
        HStack(spacing: 4) {
            ForEach(group.members) { member in
                let lit = member.ssidOn && !member.radioOff
                Text(shortBand(member.band))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(lit ? BandTint.ink(member.band) : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background {
                        Capsule()
                            .fill(lit ? BandTint.color(member.band).opacity(0.19) : Color.primary.opacity(0.07))
                    }
            }
            if group.clients > 0 {
                Text("\(group.clients) 台")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 1)
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

/// 无线波纹：底部一个圆点，向上三圈弧。亮起的弧数跟着「开着几个频段」走。
///
/// 用 `Canvas` 一次画完（同网络页的 `TopoFork`），滚动时只做位移合成，
/// 不会因为几个 `Path` 叠在一起掉帧。
private struct WifiWaveGlyph: View {
    let lit: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let base = CGPoint(x: size.width / 2, y: size.height - 5)
            let radii: [CGFloat] = [size.height * 0.30,
                                    size.height * 0.52,
                                    size.height * 0.74]
            for (index, radius) in radii.enumerated() {
                var path = Path()
                path.addArc(center: base, radius: radius,
                            startAngle: .degrees(215), endAngle: .degrees(325),
                            clockwise: false)
                let on = index < lit
                context.stroke(path,
                               with: .color(color.opacity(on ? 0.9 - Double(index) * 0.18 : 0.16)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            var dot = Path()
            dot.addEllipse(in: CGRect(x: base.x - 4, y: base.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(color.opacity(lit > 0 ? 1 : 0.32)))
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

/// 频段配色（v3.4.2 重定）：**青绿 → 青蓝 → 靛蓝，同一个冷色族**。
///
/// 旧值（v3.4.1 及以前）是 2.4G 墨绿 `(0.10,0.62,0.45)` + 5G 青 + 6G 紫：三个色相
/// 各在一百二十度开外，一屏摆三张卡像三套皮肤的拼图；墨绿在白卡上尤其脏，绿又和
/// 「IoT」那个草绿撞、紫又和「多链路」的紫**完全同色**（`0.44,0.36,0.88` 一字不差）。
///
/// 现在三档只动色相 20° 左右、明度对齐，扫过去是一组，读单个又能分开：
/// 2.4G 偏绿（穿墙、远）、5G 居中（沿用网络页拓扑的青色系，两页对得上）、6G 偏靛（最新）。
private enum BandTint {
    /// **亮色块**：频谱高亮、圆点、开关、徽章底、图标块。
    static func color(_ band: String) -> Color {
        switch band {
        case "2.4":
            return wifiTone((0.25, 0.78, 0.71), (0.36, 0.80, 0.75))
        case "6":
            return wifiTone((0.49, 0.53, 0.94), (0.60, 0.62, 0.96))
        default:
            return wifiTone((0.27, 0.71, 0.88), (0.31, 0.71, 0.84))
        }
    }

    /// **同族深一档**，只给文字用。
    ///
    /// 亮色块在白卡上好看，但当 10~17pt 的彩色**字**就糊了（#45B6E0 在白底上的对比
    /// 只有 2.6:1）。所以凡是有字的地方取这一档，块面还是亮的。
    static func ink(_ band: String) -> Color {
        switch band {
        case "2.4":
            return wifiTone((0.04, 0.50, 0.44), (0.62, 0.94, 0.89))
        case "6":
            return wifiTone((0.27, 0.30, 0.72), (0.80, 0.82, 1.00))
        default:
            return wifiTone((0.03, 0.45, 0.60), (0.66, 0.90, 1.00))
        }
    }
}

/// 三种附加网络的配色与图标。
///
/// 频段已经把冷色族占满了（青绿 / 青蓝 / 靛），次要网络再上一个饱和橙、饱和绿，
/// 整页就成了调色盘。这里全部降到低饱和：访客是暖赭（唯一暖色，一眼区分主次），
/// 物联网是中性灰蓝（和 2.4G 的青绿拉开，不再撞绿），多链路是暗洋红（和 6G 的靛
/// 分开，不再同色）。
private enum KindTint {
    /// 亮色块（图标底、圆点）。
    static func color(_ kind: WifiNetGroup.Kind) -> Color {
        switch kind {
        case .guest: return wifiTone((0.94, 0.66, 0.24), (0.90, 0.71, 0.40))
        case .iot: return wifiTone((0.56, 0.65, 0.72), (0.66, 0.71, 0.75))
        case .mlo: return wifiTone((0.88, 0.48, 0.78), (0.90, 0.64, 0.84))
        case .main: return BandTint.color("5")
        }
    }

    /// 文字 / 图标用的深一档（同 `BandTint.ink` 的理由）。
    static func ink(_ kind: WifiNetGroup.Kind) -> Color {
        switch kind {
        case .guest: return wifiTone((0.62, 0.38, 0.05), (0.98, 0.82, 0.58))
        case .iot: return wifiTone((0.28, 0.36, 0.44), (0.82, 0.87, 0.91))
        case .mlo: return wifiTone((0.66, 0.22, 0.54), (1.00, 0.78, 0.94))
        case .main: return BandTint.ink("5")
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

    private var tint: Color { BandTint.color(band.band) }

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
                    .foregroundStyle(channel == "auto" ? BandTint.ink(band.band) : Color.secondary)
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
                             ink: BandTint.ink(band.band)) { picked in
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
                    .fill(KindTint.color(kind).opacity(0.13))
                    .frame(width: 52, height: 52)
                Image(systemName: KindTint.icon(kind))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(KindTint.ink(kind))
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
