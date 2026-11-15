import SwiftUI

/// 上网（二级页，v2.9.4 整页重做）。
///
/// **入口**：网络页拓扑图最上面那个出口节点。
///
/// ## 为什么不用 `Form` 了（v2.9.4）
///
/// 老版本是 `Form` + 五个 Section：第一张卡十行「标签—值」堆成一面墙，读到第五行
/// 就不知道自己在看什么；最后一行「MAC 地址」被底部那条浮着的玻璃底栏压掉一半
/// （`Form` 不会替那颗悬浮底栏留白）；「保存」在以太网 / 蜂窝页签里也是灰着摆在那儿。
/// 用户 2026-11-15 的截图 + 原话「这个上网页里面 bug 太多了整个页面全部重新设计重做」。
///
/// 现在的结构（自上而下，每一块只回答一个问题）：
///
/// | 区块 | 回答的问题 |
/// | --- | --- |
/// | 状态卡 | **现在**怎么上网、通没通、信号多好 |
/// | 网络信息卡 | 出口的 IP / 网关 / DNS / MAC（跟**当前**链路走，不跟页签走） |
/// | 连接方式三块 | 有哪几种方式、哪种在用、点谁看谁的配置 |
/// | 面板 | 这种方式的细节和它自己的操作 |
///
/// 关键的一条：**「在看哪种方式」和「现在用哪种方式」是两件事**。
/// 以前页签切换时会顺手把当前连接方式也改掉（`seed()` 里），所以「点开以太网看看」
/// 就会变成「切到以太网」；现在页签只切面板，真切换要点面板里那颗带确认的按钮，
/// 在用哪一种用状态卡 + 三块里的绿点说明。
///
/// 数据只走官方通道（见 `开发交接.md` 3.0）：配置 `uci show repeater`、
/// 状态 `ubus call repeater status`、周边 `ubus call repeater surveys`（按需）、
/// 蜂窝 `ubus call cellular.modem status`。**不碰 LuCI 那一套。**
struct UplinkSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    /// 当前在看哪种上网方式的配置。**只是切换看的面板，不动路由器。**
    @State private var mode: UplinkMode = .repeater
    /// 表单已经按采集结果填过一次，之后不再自动回填（刷新会把用户刚敲的字冲掉）。
    @State private var seeded = false

    // ---- 上级网络（可写）----
    @State private var ssid = ""
    @State private var key = ""
    @State private var bssid = ""
    @State private var disguise = false
    @State private var autoPortal = false
    @State private var enabled = true
    /// 0 不切换 / 1 自动切换 / 2 仅没网自动切换
    @State private var switchMode = 1
    /// 频段选择，空 = 自动
    @State private var lockBand = ""
    /// 密码要不要显示明文。
    @State private var showKey = false

    // ---- 周边 Wi-Fi ----
    @State private var surveys: [RepeaterSurvey] = []
    @State private var scanning = false

    @State private var busy = false
    @State private var errorText: String?
    /// 切上网方式的确认弹窗
    @State private var pendingMode: UplinkMode?

    private var info: NetworkInfo { model.network }
    private var rep: RepeaterInfo { info.repeater }

    /// 当前**实际在用**的上网方式（默认路由落在哪条线上）。未联网为 nil。
    private var activeMode: UplinkMode? {
        switch info.uplink {
        case .repeater: return .repeater
        case .wired: return .wired
        case .none: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                networkCard
                modeCard
                switch mode {
                case .repeater: repeaterPanel
                case .wired: wiredPanel
                case .cellular: cellularPanel
                }
                if let errorText { errorCard(errorText) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // 底栏是浮在内容上的玻璃条，不是不透明容器：不自己留这一截，
            // 最后一行就会被它盖住（v2.9.3 之前的截图就是这样）。
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScrollBackground()
        // 按钮文字一律主色，只有开关是蓝的（`ButtonStyles.swift` 的四类）。
        .primaryButtons()
        .navigationTitle("上网")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 只在「中继」面板 + 真有改动时才是可点的保存。
                // 以前不分页签、不看改动，永远是颗灰按钮摆在右上角。
                if busy {
                    ProgressView().controlSize(.small)
                } else if mode == .repeater, dirty {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                        .navBarTint()
                }
            }
        }
        .onAppear(perform: seed)
        .confirmationDialog(
            "切换上网方式",
            isPresented: Binding(get: { pendingMode != nil },
                                 set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pendingMode {
                Button(target == .repeater ? "切到中继" : "切到以太网") {
                    Task { await applyMode(target) }
                }
            }
            Button("取消", role: .cancel) { pendingMode = nil }
        } message: {
            Text(pendingMode == .repeater
                 ? "中继会重新连接上游网络，断开十几秒。"
                 : "有线口没插网线时切过去，路由器就没有网络了。")
        }
    }

    // MARK: - 状态卡

    /// 「现在是怎么上网的」，一句话读完。
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(stateColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: uplinkIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(stateColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(statusTitle)
                            .font(.system(size: 17, weight: .semibold))
                        pill(info.uplinkOK ? stateShort : "未联网",
                             info.uplinkOK ? stateColor : .secondary)
                    }
                    Text(statusSubline)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if info.uplinkOK {
                divider.padding(.top, 12)
                metricRow(("IP 地址", emptyDash(info.uplinkIP), nil),
                          ("网关", emptyDash(info.uplinkGateway), nil))
                divider
                metricRow(("信号", signalText, info.upstreamSignal != 0 ? signalColor(info.upstreamSignal) : nil),
                          ("在线时长", info.uplinkUptime > 0 ? durationLabel(info.uplinkUptime) : "—", nil))
                divider
                metricRow(("DNS", emptyDash(info.uplinkDNS.prefix(2).joined(separator: "  ")), nil))
            } else {
                divider.padding(.top, 12)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("路由器现在没有默认路由，下面的配置保存后才会生效。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 11)
            }
        }
        .cardSurface()
    }

    private var statusTitle: String {
        switch info.uplink {
        case .repeater: return "中继上网"
        case .wired: return "有线上网"
        case .none: return "未联网"
        }
    }

    private var statusSubline: String {
        switch info.uplink {
        case .repeater:
            var parts: [String] = []
            if !info.upstreamSSID.isEmpty { parts.append(info.upstreamSSID) }
            if !rep.band.isEmpty { parts.append(bandLabel(rep.band)) }
            if rep.channel > 0 { parts.append("CH \(rep.channel)") }
            parts.append(info.protoLabel)
            return parts.joined(separator: " · ")
        case .wired:
            var parts = [info.protoLabel, info.bestPortLabel]
            if !info.wanCable { parts[0] = "未插网线" }
            return parts.joined(separator: " · ")
        case .none:
            return "中继 / 以太网都没连上，检查下面的连接方式"
        }
    }

    private var uplinkIcon: String {
        switch info.uplink {
        case .repeater: return "wifi"
        case .wired: return "cable.connector"
        case .none: return "wifi.slash"
        }
    }

    private var stateColor: Color {
        info.uplinkOK ? NetPalette.wan : Color.secondary
    }

    /// 状态卡右侧那颗小胶囊里的话。
    private var stateShort: String {
        switch info.uplink {
        case .repeater: return rep.connected ? "已连接" : "已启用"
        case .wired: return "已连接"
        case .none: return "未联网"
        }
    }

    /// MAC 模式的几档 + 实际地址。老版是「随机 · FA:59:…」一行，被尾巴截断。
    private var macLabel: String {
        let modeText: String
        switch rep.macMode {
        case "random": modeText = "随机"
        case "clone": modeText = "克隆"
        default: modeText = "出厂"
        }
        return rep.macAddress.isEmpty ? modeText : "\(modeText) · \(rep.macAddress)"
    }

    private var signalText: String {
        guard info.upstreamSignal != 0 else { return "—" }
        return "\(info.upstreamSignal) dBm"
    }

    // MARK: - 网络信息卡

    /// 出口的网络信息。**跟当前链路走，不跟页签走**——以前这些只有在「中继」页签里看得见，
    /// 切到以太网/蜂窝就全变成「—」，明明网是通的。
    private var networkCard: some View {
        card("网络信息", trailing: info.uplink == .none ? "" : info.protoLabel) {
            metricRow(("方式", info.uplinkLabel, nil),
                      ("出口接口", info.uplink == .none ? "—" : info.uplinkInterface, nil))
            divider
            metricRow(("会话", info.connections > 0 ? "\(info.connections)" : "—", nil),
                      ("↓ 下载", info.wanRxTotal > 0 ? formatBytes(info.wanRxTotal) : "—", nil))
            divider
            metricRow(("↑ 上传", info.wanTxTotal > 0 ? formatBytes(info.wanTxTotal) : "—", nil))
        }
    }

    // MARK: - 连接方式

    /// 三块选一。选中的只是「看谁的配置」，**在用的那一块右下角有绿点**。
    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("连接方式")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("点开是看配置，不是切换")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                ForEach(UplinkMode.allCases) { item in
                    modeTile(item)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
        }
    }

    private func modeTile(_ item: UplinkMode) -> some View {
        let selected = mode == item
        let active = activeMode == item
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { mode = item }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? NetPalette.wan : Color.secondary)
                    .frame(height: 20)
                Text(item.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(modeCaption(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(active ? Color.green : Color(.tertiaryLabel))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? NetPalette.wan.opacity(0.10) : Color(.tertiarySystemFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? NetPalette.wan.opacity(0.5) : Color.clear,
                                  lineWidth: 1.2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeCaption(_ item: UplinkMode) -> String {
        if activeMode == item { return "使用中" }
        switch item {
        case .repeater: return rep.connected ? "已连接" : "未连接"
        case .wired: return info.wanCable ? "已插网线" : "未插网线"
        case .cellular: return rep.modemPresent ? "已插入" : "无 Modem"
        }
    }

    // MARK: - 中继面板

    @ViewBuilder
    private var repeaterPanel: some View {
        card("上级网络", trailing: dirty ? "未保存" : "") {
            fieldBlock("名称", text: $ssid, placeholder: "上级 Wi-Fi 名称")
            fieldBlock("密码", text: $key, placeholder: "留空表示不改", secure: true)
            menuRow("锁定 BSSID", selection: $bssid) {
                Text("自动").tag("")
                ForEach(bssidChoices) { item in
                    Text("\(item.bssid) · \(item.signal) dBm").tag(item.bssid)
                }
            }
            if dirty {
                divider
                Button {
                    reseed()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                        Text("撤销修改")
                            .font(.system(size: 14))
                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        card("中继设置") {
            switchRow("启用中继", isOn: $enabled)
            divider
            switchRow("启用伪装", isOn: $disguise)
            divider
            switchRow("公共热点认证模式", isOn: $autoPortal)
            divider
            menuRow("切换模式", selection: $switchMode) {
                Text("不切换").tag(0)
                Text("自动切换").tag(1)
                Text("仅没网自动切换").tag(2)
            }
            divider
            menuRow("频段选择", selection: $lockBand) {
                ForEach(rep.bandChoices) { item in
                    Text(item.label).tag(item.value)
                }
            }
            divider
            // MAC 占满一整行：老版这条挤在「标签—值」里被截成「随机 · FA:59:BE:E0:01:B1…」
            metricRow(("MAC 地址", macLabel, nil))
        }

        savedNetworksCard
        availableNetworksCard
        saveHint
    }

    /// 已保存的上级网络：点就是切过去（这一行本来就是动作，不是配置）。
    @ViewBuilder
    private var savedNetworksCard: some View {
        if !rep.saved.isEmpty {
            card("已保存网络", trailing: "\(rep.saved.count) 个") {
                ForEach(Array(rep.saved.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { divider }
                    Button {
                        Task { await switchTo(item) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.selected ? "checkmark.circle.fill" : "wifi")
                                .font(.system(size: 14))
                                .foregroundStyle(item.selected ? NetPalette.wan : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.ssid.isEmpty ? "—" : item.ssid)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.bssid.isEmpty ? "—" : item.bssid)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            if item.selected {
                                Text("使用中")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 3) {
                                    Text("切换")
                                        .font(.system(size: 13))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
        }
    }

    /// 周边 Wi-Fi：按需扫描，点一条把名称 + BSSID 填进上面的表单。
    private var availableNetworksCard: some View {
        card("可用网络", trailing: surveys.isEmpty ? "" : "\(surveys.count) 个") {
            Button {
                Task { await scan() }
            } label: {
                HStack(spacing: 9) {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(scanning ? "扫描中…" : (surveys.isEmpty ? "扫描周边 Wi-Fi" : "重新扫描"))
                        .font(.system(size: 15))
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(scanning)

            ForEach(surveys) { item in
                divider
                Button {
                    ssid = item.ssid
                    bssid = item.bssid
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.secured ? "lock.fill" : "wifi")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.ssid)
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(item.bandLabel) · CH \(item.channel)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(item.signal) dBm")
                            .font(.system(size: 12.5))
                            .foregroundStyle(signalColor(item.signal))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 中继面板最下面那一句提醒：改完要按右上角保存。
    private var saveHint: some View {
        Text("改完右上角「保存」才会写进路由器；中继会断开十几秒再连上。")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 以太网面板

    @ViewBuilder
    private var wiredPanel: some View {
        card("以太网", trailing: wiredStateLabel) {
            metricRow(("协商速率", info.bestPortLabel, nil),
                      ("协议", info.uplink == .wired ? info.protoLabel : "—", nil))
            divider
            metricRow(("端口", wanPortText, nil),
                      ("地址", info.uplink == .wired ? emptyDash(info.uplinkIP) : "—", nil))
            divider
            Text(info.wanCable
                 ? "网线接在 WAN 口上。切过来之前先确认上级是能直接给地址的光猫/路由器。"
                 : "WAN 口没有链路。现在切过去会断网，先把网线插上再切。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 11)

            if info.uplink != .wired {
                divider
                Button {
                    pendingMode = .wired
                } label: {
                    HStack {
                        Text("切换到以太网上网")
                            .font(.system(size: 15, weight: .medium))
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(info.wanCable ? NetPalette.wan : Color(.systemGray3))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!info.wanCable || busy)
                .padding(.vertical, 11)
            } else {
                divider
                actionLine(icon: "checkmark.circle.fill", text: "现在走的就是这条线", tint: .green)
            }
        }
    }

    /// 以太网出口的三档状态（用户 2026-11-15 的截图：WAN 口空着却写「已连接」）。
    /// - 默认路由真走有线、且拿到了地址 → 已连接；
    /// - WAN 口有链路、但没在用（走的还是中继）→ 已插网线，未联网；
    /// - WAN 口连链路都没有 → 未插网线。
    private var wiredStateLabel: String {
        if info.uplink == .wired, !info.uplinkIP.isEmpty { return "已连接" }
        return info.wanCable ? "已插网线，未联网" : "未插网线"
    }

    private var wanPortText: String {
        guard let port = info.wanPort else { return "—" }
        return "\(port.name) · \(port.up ? "已连接" : "未插线")"
    }

    // MARK: - 蜂窝面板

    @ViewBuilder
    private var cellularPanel: some View {
        card("蜂窝网络", trailing: rep.modemPresent ? "已插入" : "未检测到") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text(rep.modemPresent ? "检测到 USB Modem，但本版还没接上蜂窝拨号。" : "没有检测到 USB Modem。")
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("插上 Modem 后，这一页会显示运营商、信号和流量；现在不支持切换，免得把路由器网络切没。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - 表单是否改过

    /// 和路由器上的值比：有任何一项不同就算「未保存」。
    /// 以前不看这个，右上角永远是颗可点的「保存」，点一次白跑一趟 SSH。
    private var dirty: Bool {
        ssid != rep.ssid || key != rep.key || bssid != rep.bssid
            || disguise != rep.disguise || autoPortal != rep.autoPortal
            || enabled != rep.enabled || switchMode != rep.switchMode
            || lockBand != rep.lockBand
    }

    // MARK: - 小工具：卡片 / 行

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
            .padding(.bottom, 6)
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

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.45))
            .frame(height: 0.5)
    }

    private func metricRow(_ left: (String, String, Color?),
                           _ right: (String, String, Color?)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            metricCell(left.0, left.1, left.2)
            if let right {
                metricCell(right.0, right.1, right.2)
            }
        }
        .padding(.vertical, 9)
    }

    private func metricCell(_ label: String, _ value: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(color ?? Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background { Capsule().fill(color.opacity(0.12)) }
    }

    private func actionLine(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
            Text(text)
                .font(.system(size: 13.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 11)
    }

    /// 输入框：标签在上、框在下。右对齐的 `TextField` 在 iOS 上编辑长 SSID 时很难用。
    private func fieldBlock(_ label: String, text: Binding<String>,
                            placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Group {
                    if secure && !showKey {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                    }
                }
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if secure {
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            }
        }
        .padding(.vertical, 8)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 15))
            .blueSwitch()
            .padding(.vertical, 10)
    }

    private func menuRow<Value: Hashable, Content: View>(_ title: String,
                                                         selection: Binding<Value>,
                                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15))
            Spacer(minLength: 8)
            Picker(title, selection: selection) { content() }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.primary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 文案小工具

    private func emptyDash(_ text: String) -> String { text.isEmpty ? "—" : text }

    private func bandLabel(_ raw: String) -> String {
        switch raw {
        case "2g": return "2.4G"
        case "5g": return "5G"
        case "6g": return "6G"
        default: return raw
        }
    }

    private func signalColor(_ dbm: Int) -> Color {
        if dbm >= -55 { return Color(red: 0.13, green: 0.66, blue: 0.38) }
        if dbm >= -70 { return Color(red: 0.90, green: 0.55, blue: 0.10) }
        return Color(red: 0.85, green: 0.25, blue: 0.22)
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

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.85, green: 0.25, blue: 0.22).opacity(0.08))
        }
    }

    /// 可选的 BSSID：周边同名网络 + 当前已锁的那一个
    /// （已锁的那个不一定在这次扫描结果里，漏了就选不回来）。
    private var bssidChoices: [RepeaterSurvey] {
        var list = sameNameSurveys
        if !bssid.isEmpty, !list.contains(where: { $0.bssid == bssid }) {
            list.insert(RepeaterSurvey(ssid: ssid, bssid: bssid), at: 0)
        }
        return list
    }

    /// 周边网络里和当前上级网络同名的那些（锁 BSSID 只能在同名的 AP 里挑）。
    private var sameNameSurveys: [RepeaterSurvey] {
        surveys.filter { $0.ssid == ssid }
    }

    // MARK: - 读 / 写

    /// 按采集结果填一次表单。之后刷新不再回填。
    ///
    /// **不再顺手改 `mode`**：v2.9.1 里 `if rep.connected { mode = .repeater }`，
    /// 于是「点开以太网看看」在一轮采集回来后就自己跳回中继。页签只跟着用户的手走。
    private func seed() {
        guard !seeded else { return }
        reseed()
        seeded = true
        // 第一次进来，默认落在「现在真在用的那种方式」上。
        if let active = activeMode { mode = active }
    }

    /// 把表单恢复成路由器上的值。
    private func reseed() {
        ssid = rep.ssid
        key = rep.key
        bssid = rep.bssid
        disguise = rep.disguise
        autoPortal = rep.autoPortal
        enabled = rep.enabled
        switchMode = rep.switchMode
        lockBand = rep.lockBand
        errorText = nil
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        surveys = await model.loadRepeaterSurveys()
        scanning = false
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.saveRepeater(ssid: ssid, key: key, bssid: bssid,
                                              disguise: disguise, autoPortal: autoPortal,
                                              switchMode: switchMode, lockBand: lockBand,
                                              enabled: enabled)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已保存", detail: ssid)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    private func switchTo(_ item: RepeaterSavedNetwork) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.switchRepeaterNetwork(ssid: item.ssid, bssid: item.bssid)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已切换", detail: item.ssid)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    private func applyMode(_ target: UplinkMode) async {
        pendingMode = nil
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.applyUplinkMode(target)
        busy = false
        if let problem {
            errorText = problem
            return
        }
        mode = target
        model.notice = Notice(kind: .ok, title: "已切换", detail: target.title)
        // 换链路要十几秒才重新拿到地址，这里等一下再刷新。
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await model.manualRefresh()
    }
}

// MARK: - 卡面

/// 页面里所有卡片共用的底：18 圆角 + 分组底色 + 一根细描边。
///
/// 和网络页的 `card(...)` 完全同一套值（18 / separator 0.45 / 0.6pt），
/// 两页并排看不出来是两个人写的。
private struct UplinkCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.6)
            }
    }
}

private extension View {
    func cardSurface() -> some View { modifier(UplinkCardSurface()) }
}
