import SwiftUI

/// 上网（二级页）。
///
/// **入口**：网络页拓扑图最上面那个出口节点。
///
/// ## 这一版（v3.3.12）为什么又重做
///
/// 用户 2026-11-25 的反馈是两件事：
/// 1. 「很多时候修改不起作用」——这不是界面问题。固件里 `repeater reload`
///    只处理 `@main` 那一组（`lock_band` / `smart_reconnect` / `disabled`），
///    `@network` 里的 `disguise` / `auto_portal` / `key` / `bssid` 必须走
///    `ubus call repeater connect`。老版把所有项一起 `uci set` 再 `reload`，
///    于是「启用伪装」「公共热点认证模式」写进去了、运行态没变（见
///    `AppModel.applyRepeaterOptions` / `applyRepeaterNetwork`）。
/// 2. 「操作步骤也重新设计」——老版一屏里既有状态、又有 SSID/密码输入框、
///    又有六个开关，右上角一个「保存」把这些全提交；点扫描结果只是把值填回
///    上面的表单，用户还得往上滚、再点保存。
///
/// 现在按「看 → 换 → 调」三步拆开：
///
/// | 位置 | 干什么 |
/// | --- | --- |
/// | 状态卡 | 现在走哪条线、通没通、IP / 信号 / 时长 |
/// | 方式条 | 中继 / 以太网 / 蜂窝，只切换看谁 |
/// | 当前网络 | 连的是哪个 AP；「重新连接」「忽略此网络」 |
/// | 其他网络 | 已保存的（点一下就切）+ 扫描到的（点一下输密码就加入） |
/// | 中继设置 › | 所有参数在这一页（`RepeaterOptionsView`），一次保存分两条通道 |
///
/// 数据只走官方通道：配置 `uci show repeater`、状态 `ubus call repeater status`、
/// 周边 `ubus call repeater surveys`、写入 `ubus call repeater connect` /
/// `uci + reload`（各自管各自那半边，见 `AppModel` 里那两个方法）。
struct UplinkSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    /// 当前在看哪种上网方式的配置。**只是切换看的面板，不动路由器。**
    @State private var mode: UplinkMode = .repeater
    /// 第一次进来落在「现在真在用的那种方式」上，之后不再跟着采集跳。
    @State private var seeded = false

    // ---- 周边 Wi-Fi ----
    @State private var surveys: [RepeaterSurvey] = []
    @State private var scanning = false

    @State private var busy = false
    @State private var errorText: String?
    /// 切上网方式的确认弹窗
    @State private var pendingMode: UplinkMode?
    /// 断开热点共享的确认弹窗（v3.2.2）
    @State private var pendingTetherOff = false
    /// 要忽略（删除）的已保存网络
    @State private var pendingForget: RepeaterSavedNetwork?
    /// 点了一条没存过的网络：弹这一层输密码
    @State private var pendingJoin: RepeaterSurvey?
    @State private var joinKey = ""
    @State private var joinReveal = false
    /// 「现在连着、网络也通」时又去点重连／点当前网络：不执行，只把原因摆出来。
    /// 用户 2026-11-25 明确要求：这种状态下不要触发重连，点重连也不行，弹个提示。
    @State private var noReconnectReason: String?

    private var info: NetworkInfo { model.network }
    private var rep: RepeaterInfo { info.repeater }

    /// 当前**实际在用**的上网方式（默认路由落在哪条线上）。未联网为 nil。
    private var activeMode: UplinkMode? {
        switch info.uplink {
        case .repeater: return .repeater
        case .wired: return .wired
        // 热点共享归在「蜂窝」那一格里（官方也是手机热点与 Modem 并列在同一页）。
        case .tethering: return .cellular
        case .none: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                statusCard
                modeBar
                switch mode {
                case .repeater: repeaterPanel
                case .wired: wiredPanel
                case .cellular: cellularPanel
                }
                if let errorText { errorCard(errorText) }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 12)
            // 底栏是浮在内容上的玻璃条：不自己留这一截，最后一行会被它盖住。
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScrollBackground()
        .primaryButtons()
        .navigationTitle("上网")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .onAppear(perform: seed)
        // 所有确认框都自绘（v3.2.4）。系统的 `confirmationDialog` 在 iOS 26 会被锚到
        // 页面上方，看着像贴歪的气泡、底下那行按钮还露在外面——`Glass.swift` 里
        // 那条「任何页面都不用系统 alert / confirmationDialog」没有例外。
        .overlay {
            if let target = pendingMode {
                SheetOverlay(onDismiss: { pendingMode = nil }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("切换上网方式").font(.headline)
                            Text(modeHint(target))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { pendingMode = nil }
                            SheetOverlayButton(title: modeActionTitle(target), tint: .blue) {
                                Task { await applyMode(target) }
                            }
                        }
                    }
                }
            }

            if pendingTetherOff {
                SheetOverlay(onDismiss: { pendingTetherOff = false }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("断开热点共享").font(.headline)
                            Text("断开后手机的网络不再分给路由器；数据线不用拔，随时能再连。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { pendingTetherOff = false }
                            SheetOverlayButton(title: "断开", tint: .red) {
                                Task { await disconnectTether() }
                            }
                        }
                    }
                }
            }

            if let victim = pendingForget {
                SheetOverlay(onDismiss: { pendingForget = nil }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("忽略此网络").font(.headline)
                            Text("路由器会忘掉「\(victim.ssid)」的密码，之后要重新输入。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { pendingForget = nil }
                            SheetOverlayButton(title: "忽略", tint: .red) {
                                Task { await forget(victim) }
                            }
                        }
                    }
                }
            }

            if let target = pendingJoin {
                SheetOverlay(onDismiss: { pendingJoin = nil }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("加入「\(target.ssid)」").font(.headline)
                            HStack(spacing: 8) {
                                Group {
                                    if joinReveal {
                                        TextField("密码", text: $joinKey)
                                    } else {
                                        SecureField("密码", text: $joinKey)
                                    }
                                }
                                .font(.system(size: 15))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background {
                                    AdaptiveFill(shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                                 color: Color(.tertiarySystemFill))
                                }
                                Button { joinReveal.toggle() } label: {
                                    Image(systemName: joinReveal ? "eye.slash" : "eye")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { pendingJoin = nil }
                            SheetOverlayButton(title: "连接", tint: .blue) {
                                Task { await join(target) }
                            }
                        }
                    }
                }
            }

            // 已经连着、而且真的通：重连一律不执行，把原因说清楚。
            if let reason = noReconnectReason {
                SheetOverlay(onDismiss: { noReconnectReason = nil }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("无需重新连接").font(.headline)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "知道了", tint: .blue) {
                                noReconnectReason = nil
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 状态卡

    /// 「现在是怎么上网的」，一卡读完：走哪条线、通没通、地址、信号、时长。
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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(statusTitle)
                            .font(.system(size: UI.titleSize, weight: .semibold))
                        if info.uplinkOK { StatusTag(text: stateShort, color: stateColor) }
                    }
                    Text(statusSubline)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }

            if info.uplinkOK {
                Text(trafficLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 6)

                CardRule().padding(.top, 10)
                metricRow(("IP 地址", emptyDash(info.uplinkIP), nil),
                          ("网关", emptyDash(info.uplinkGateway), nil))
                CardRule()
                metricRow(("信号", signalText, nil),
                          ("在线时长", info.uplinkUptime > 0 ? durationLabel(info.uplinkUptime) : "—", nil))
                CardRule()
                metricRow(("DNS", emptyDash(info.uplinkDNS.prefix(2).joined(separator: "  ")), nil))
            }
        }
        .cardSurface()
    }

    private var trafficLine: String {
        var parts: [String] = []
        if !info.uplinkInterface.isEmpty { parts.append(info.uplinkInterface) }
        if info.connections > 0 { parts.append("\(info.connections) 会话") }
        if info.wanRxTotal > 0 { parts.append("↓ \(formatBytes(info.wanRxTotal))") }
        if info.wanTxTotal > 0 { parts.append("↑ \(formatBytes(info.wanTxTotal))") }
        return parts.joined(separator: " · ")
    }

    private var statusTitle: String {
        switch info.uplink {
        case .repeater: return "中继上网"
        case .wired: return "有线上网"
        case .tethering: return "热点共享上网"
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
        case .tethering:
            var parts: [String] = []
            if let usb = rep.usbUplink, !usb.label.isEmpty { parts.append(usb.label) }
            if let usb = rep.usbUplink, !usb.name.isEmpty { parts.append(usb.name) }
            parts.append(info.protoLabel)
            return parts.joined(separator: " · ")
        case .none:
            return ""
        }
    }

    private var uplinkIcon: String {
        switch info.uplink {
        case .repeater: return "wifi"
        case .wired: return "cable.connector"
        case .tethering: return "personalhotspot"
        case .none: return "wifi.slash"
        }
    }

    private var stateColor: Color { info.uplinkOK ? NetPalette.wan : Color.secondary }

    private var stateShort: String {
        switch info.uplink {
        case .repeater: return rep.connected ? "已连接" : "已启用"
        case .wired, .tethering: return "已连接"
        case .none: return "未联网"
        }
    }

    /// 「其他网络」里要列的那些：已保存、但**现在没在用**的。
    ///
    /// 2026-11-25：把当前这个 AP 也滤掉。以前只滤 `selected='1'`，而扫描列表里
    /// 还会出现同一个 SSID，点一下就走了一遍 `connect`——用户的感受就是
    /// 「点一下已连接的网络，他就重连去了」。
    ///
    /// 判「同一个 AP」用的是 BSSID：同一台路由器的 2.4G / 5G 常是同名两条，
    /// 那种要留着——换频段是合法操作。
    private var otherSaved: [RepeaterSavedNetwork] {
        rep.saved.filter { item in
            guard !item.ssid.isEmpty, !item.selected else { return false }
            return !isSameAccessPoint(ssid: item.ssid, bssid: item.bssid)
        }
    }

    /// 这条路现在是不是「已连上、而且互联网是通的」。
    ///
    /// 只有两只都成立才算数：`rep.connected` 是无线链路，`info.uplinkOK`
    /// 是默认路由真在这条线上。`connected` 但没网的时候仍然允许重连——
    /// 那正是用户需要点一下的时候。
    private var linkIsHealthy: Bool { rep.connected && info.uplinkOK }

    /// 这一条是不是当前正在用的网络。
    private func isCurrentNetwork(_ ssid: String) -> Bool {
        !ssid.isEmpty && ssid == rep.ssid && rep.connected
    }

    /// 这一条是不是**当前正连着的那个 AP**（不是「同一台路由器的另一个频段」）。
    ///
    /// BSSID 读不到的时候退回 SSID 比较——宁可多挡一次（弹提示），
    /// 也别把「点一下已连接的网络就断开重连」放出去。
    private func isSameAccessPoint(ssid: String, bssid: String) -> Bool {
        guard isCurrentNetwork(ssid) else { return false }
        let tuned = rep.currentBSSID.isEmpty ? rep.bssid : rep.currentBSSID
        guard !tuned.isEmpty, !bssid.isEmpty else { return true }
        return bssid == tuned
    }

    private var signalText: String {
        guard info.upstreamSignal != 0 else { return "—" }
        return "\(info.upstreamSignal) dBm · \(signalGrade(info.upstreamSignal))"
    }

    private func signalGrade(_ dbm: Int) -> String {
        if dbm >= -55 { return "强" }
        if dbm >= -70 { return "中" }
        return "弱"
    }

    // MARK: - 方式条

    /// 切换确认弹层里那句解释（三种方式各说各的后果）。
    private func modeHint(_ target: UplinkMode) -> String {
        switch target {
        case .repeater:
            return "中继会重新连接上游网络，断开十几秒。"
        case .wired:
            return "有线口没插网线时切过去，路由器就没有网络了。"
        case .cellular:
            return "会通过数据线用手机的网络，中继会断开。"
        }
    }

    private func modeActionTitle(_ target: UplinkMode) -> String {
        switch target {
        case .repeater: return "切到中继"
        case .wired: return "切到以太网"
        case .cellular: return "切到热点共享"
        }
    }

    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach(UplinkMode.allCases) { item in
                modeSegment(item)
            }
        }
        .padding(3)
        .background {
            AdaptiveFill(shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                         color: Color(.secondarySystemGroupedBackground))
        }
        .overlay {
            AdaptiveBorder(shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                           width: 0.6, strength: 0.45)
        }
    }

    private func modeSegment(_ item: UplinkMode) -> some View {
        let selected = mode == item
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { mode = item }
            errorText = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if activeMode == item {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected ? NetPalette.wan : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? NetPalette.wan.opacity(0.12) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 中继

    @ViewBuilder
    private var repeaterPanel: some View {
        if !rep.enabled {
            disabledCard
        } else {
            currentNetworkCard
        }
        otherNetworksCard
        optionsEntry
    }

    /// 中继没启用时：不摆一堆灰着的参数，只给一颗「开启」。
    private var disabledCard: some View {
        CardPanel("中继未启用", icon: "wifi.slash") {
            Text("开启后会去连已保存的上级网络。")
                .font(UI.row())
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            primaryButton("开启中继", icon: "power") {
                Task { await enableRepeater() }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    /// 当前连的这个 AP：结论在上，动作在下。
    private var currentNetworkCard: some View {
        CardPanel("当前网络", icon: "wifi",
                  trailing: rep.connected ? "已连接" : "未连接") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rep.ssid.isEmpty ? "—" : rep.ssid)
                    .font(UI.title())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if rep.connected, info.upstreamSignal != 0 {
                    Text("\(info.upstreamSignal) dBm")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.top, 2)

            CardRule().padding(.top, 10)
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "频段", value: rep.band.isEmpty ? "—" : bandLabel(rep.band))
                MetricCell(label: "信道", value: rep.channel > 0 ? "CH \(rep.channel)" : "—")
                MetricCell(label: "BSSID",
                           value: rep.currentBSSID.isEmpty ? (rep.bssid.isEmpty ? "—" : rep.bssid)
                                                           : rep.currentBSSID)
            }
            .padding(.vertical, UI.rowPadding)

            CardRule()
            Button {
                Task { await reconnect() }
            } label: {
                actionRow("重新连接", icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(busy)

            CardRule()
            Button {
                pendingForget = RepeaterSavedNetwork(ssid: rep.ssid, bssid: rep.bssid,
                                                     key: rep.key, selected: true)
            } label: {
                actionRow("忽略此网络", icon: "trash", tint: Color(red: 0.85, green: 0.25, blue: 0.22))
            }
            .buttonStyle(.plain)
            .disabled(busy || rep.ssid.isEmpty)
        }
    }

    /// 已保存的 + 扫到的，合成一张。
    private var otherNetworksCard: some View {
        CardPanel("其他网络", icon: "dot.radiowaves.left.and.right",
                  trailing: otherSaved.isEmpty ? "" : "\(otherSaved.count) 个已保存") {
            ForEach(Array(otherSaved.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardRule() }
                Button {
                    Task { await switchTo(item) }
                } label: {
                    savedRow(item)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if !otherSaved.isEmpty { CardRule() }
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
                        .font(UI.row())
                    Spacer(minLength: 8)
                }
                .padding(.vertical, UI.rowPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(scanning || busy)

            ForEach(surveys) { item in
                CardRule()
                Button {
                    Task { await pick(item) }
                } label: {
                    surveyRow(item)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    /// 入口：所有参数在这一页。
    private var optionsEntry: some View {
        NavigationLink {
            RepeaterOptionsView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 18, alignment: .leading)
                Text("中继设置")
                    .font(UI.cardTitle())
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(optionsSummary)
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 入口右侧那一句：把这一页里最关键的三个结论摊在外面，不用点进去也知道现状。
    private var optionsSummary: String {
        var parts: [String] = []
        parts.append(rep.switchMode == 0 ? "不切换" : (rep.switchMode == 2 ? "仅没网切换" : "自动切换"))
        parts.append(rep.lockBand.isEmpty ? "频段自动" : bandLabel(rep.lockBand))
        if rep.disguise { parts.append("伪装") }
        return parts.joined(separator: " · ")
    }

    private func savedRow(_ item: RepeaterSavedNetwork) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ssid.isEmpty ? "—" : item.ssid)
                    .font(UI.row())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.bssid.isEmpty {
                    Text(item.bssid)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            Text("切换")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, UI.rowPadding)
        .contentShape(Rectangle())
    }

    private func surveyRow(_ item: RepeaterSurvey) -> some View {
        let current = isSameAccessPoint(ssid: item.ssid, bssid: item.bssid)
        return HStack(spacing: 10) {
            Image(systemName: current ? "wifi" : (item.secured ? "lock.fill" : "wifi"))
                .font(.system(size: 11))
                .foregroundStyle(current ? NetPalette.wan : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.ssid)
                    .font(UI.row())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(item.bandLabel) · CH \(item.channel)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if current {
                // 当前就连着这一个：右边写「已连接」，不再显示信号——
                // 点它也不会重连（`pick` 里挡），写清楚比让用户猜好。
                Text("已连接")
                    .font(.system(size: 12.5))
                    .foregroundStyle(NetPalette.wan)
            } else {
                Text(item.signal != 0 ? "\(item.signal) dBm · \(signalGrade(item.signal))" : "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UI.rowPadding)
        .contentShape(Rectangle())
    }

    // MARK: - 以太网面板

    /// 以太网（官方 `internet_ethernet` 那一套）。
    ///
    /// 2026-11-25 之前这一卡只有「协商速率 / 协议」两行加一颗切换按钮，
    /// 用户说「其他几个模式没参考官方改」。官方是**先看状态、再配地址**，
    /// 配置在单独一页（`ethernet_settings_page.dart`）。现在对齐：
    ///
    /// | 本卡 | 官方 |
    /// | --- | --- |
    /// | 端口 / 协商速率 | `internet_networkPortManagement` |
    /// | 地址获取（DHCP / 静态 IP） | `internet_DHCPTip` / `internet_manuallySetStaticIP` |
    /// | IP / 网关 | 同上 |
    /// | 「以太网设置 ›」 | `ethernet_protocol_set_page` |
    @ViewBuilder
    private var wiredPanel: some View {
        CardPanel("以太网", icon: "cable.connector", trailing: wiredStateLabel) {
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "端口", value: info.wanPort?.name ?? "—")
                MetricCell(label: "协商速率", value: info.bestPortLabel)
            }
            .padding(.vertical, UI.rowPadding)

            CardRule()
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "地址获取", value: info.wanProtoLabel, valueWeight: .semibold)
                MetricCell(label: "协议", value: info.uplink == .wired ? info.protoLabel : "—")
            }
            .padding(.vertical, UI.rowPadding)

            if info.uplink == .wired {
                CardRule()
                HStack(alignment: .top, spacing: 12) {
                    MetricCell(label: "IP 地址", value: emptyDash(info.uplinkIP))
                    MetricCell(label: "网关", value: emptyDash(info.uplinkGateway))
                }
                .padding(.vertical, UI.rowPadding)
            }

            CardRule()
            NavigationLink {
                EthernetSettingsView()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, alignment: .leading)
                        .foregroundStyle(.blue)
                    Text("以太网设置").font(UI.row())
                    Spacer(minLength: 8)
                    Text(info.wanProtoLabel)
                        .font(UI.label())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, UI.rowPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if info.uplink != .wired {
                primaryButton("切换到以太网上网", icon: "arrow.right", enabled: info.wanCable) {
                    pendingMode = .wired
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
    }

    /// 以太网出口的三档状态（用户 2026-11-15 的截图：WAN 口空着却写「已连接」）。
    private var wiredStateLabel: String {
        if info.uplink == .wired, !info.uplinkIP.isEmpty { return "已连接" }
        return info.wanCable ? "已插网线，未联网" : "未插网线"
    }

    // MARK: - 蜂窝面板

    /// 蜂窝 / 热点共享（官方 `internet_cellular` + `internet_tethering` 两组）。
    ///
    /// 这台机器没有 Modem 口，所以页面的主体是「手机 USB 热点共享」这条路。
    /// 2026-11-25 之前这里有三个问题：
    /// 1. 没插设备时只写一行「没有检测到 USB Modem 或手机热点」，**不告诉用户怎么弄**；
    ///    官方写的是「插入智能手机或 USB Modem 即可启动」（`internet_noTethering`）。
    /// 2. 不显示连的是哪台手机、走哪个网卡、拿了什么地址——官方有
    ///    `internet_currentClient`（当前客户端）。
    /// 3. 连接按钮叫「连接热点共享」，看不出是数据线共享还是插卡 Modem。
    ///
    /// 现在按「有设备 / 没设备」两种形态分别画，一屏说清。
    @ViewBuilder
    private var cellularPanel: some View {
        // 这台机器的「蜂窝」这一格实际只有两条路：手机 USB 热点共享（常用）、
        // 插 SIM 卡的 USB Modem（没这个硬件）。标题按实际在用的那条写，
        // 不要把两件事塞进一个叫「蜂窝网络」的框里。
        CardPanel(rep.modemPresent ? "蜂窝网络" : "热点共享",
                  icon: rep.modemPresent ? "antenna.radiowaves.left.and.right" : "personalhotspot",
                  trailing: cellularTrailing) {
            if let usb = rep.usbUplink {
                tetheredBody(usb)
            } else {
                cellularEmpty
            }

            if rep.modemPresent { modemBody }

            // 没有 USB 设备时，这里给一条能点的出路：去官方那套流程的等价动作。
            if rep.usbUplink == nil, !rep.modemPresent {
                Text("数据线连上手机后，手机上打开「USB 网络共享」，这一页会自动出现这台手机。")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
        }
    }

    /// 插着手机（USB 网卡在）：显示是谁、哪个网卡、什么地址，再给连/断。
    @ViewBuilder
    private func tetheredBody(_ usb: UsbUplink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 15))
                .foregroundStyle(tetherOn ? NetPalette.wan : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(usb.label)
                    .font(UI.row())
                    .lineLimit(1)
                Text(usb.connected ? "已经分到地址" : "已插上，还没分到地址")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if tetherOn {
                Text("使用中")
                    .font(UI.label())
                    .foregroundStyle(NetPalette.wan)
            }
        }
        .padding(.vertical, 12)

        CardRule()
        HStack(alignment: .top, spacing: 12) {
            MetricCell(label: "接口", value: usb.name)
            MetricCell(label: "地址", value: usb.ip.isEmpty ? "—" : usb.ip)
        }
        .padding(.vertical, UI.rowPadding)

        if !usb.manufacturer.isEmpty || !usb.product.isEmpty {
            CardRule()
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "厂商", value: usb.manufacturer.isEmpty ? "—" : usb.manufacturer)
                MetricCell(label: "型号", value: usb.product.isEmpty ? "—" : usb.product)
            }
            .padding(.vertical, UI.rowPadding)
        }

        CardRule()
        if tetherOn {
            Button {
                pendingTetherOff = true
            } label: {
                actionRow("断开热点共享", icon: "xmark.circle",
                          tint: Color(red: 0.85, green: 0.25, blue: 0.22))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        } else {
            primaryButton("连接这条热点共享", icon: "arrow.right") {
                Task { await connectTether(usb) }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    /// 什么都没插：照官方那句写清楚「插上就能用」，别只报一句「没检测到」。
    private var cellularEmpty: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("没有检测到热点共享设备")
                    .font(UI.row())
                Text("插入智能手机或 USB Modem 即可启动。")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    /// 插了 SIM 卡 Modem：这台机器没这个硬件，读不到的一律不编。
    private var modemBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardRule()
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "Modem", value: "已插入")
                MetricCell(label: "SIM 卡", value: "未读取")
            }
            .padding(.vertical, UI.rowPadding)
            Text("SIM 卡、APN、频段这些要固件支持 Modem 才读得到，这台按官方接口取不到就不编。")
                .font(UI.label())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
    }

    private var tetherOn: Bool {
        info.uplink == .tethering || (rep.usbUplink?.connected ?? false)
    }

    private var cellularTrailing: String {
        if rep.modemPresent { return "已插入" }
        guard let usb = rep.usbUplink else { return "未检测到" }
        return usb.connected ? "已连接" : "未连接"
    }

    // MARK: - 小工具

    private func metricRow(_ left: (String, String, Color?),
                           _ right: (String, String, Color?)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MetricCell(label: left.0, value: left.1, valueColor: left.2 ?? .primary)
            if let right {
                MetricCell(label: right.0, value: right.1, valueColor: right.2 ?? .primary)
            }
        }
        .padding(.vertical, UI.rowPadding)
    }

    /// 一行普通动作（蓝字图标 + 文字 + 右侧箭头）。
    private func actionRow(_ title: String, icon: String, tint: Color = .primary) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, alignment: .leading)
            Text(title).font(UI.row())
            Spacer(minLength: 8)
        }
        .foregroundStyle(tint)
        .padding(.vertical, UI.rowPadding)
        .contentShape(Rectangle())
    }

    /// 主操作按钮：蓝底白字（`ButtonStyles.swift` 的第④类）。
    private func primaryButton(_ title: String, icon: String,
                               enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer(minLength: 8)
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(enabled ? NetPalette.wan : Color(.systemGray3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }

    private func emptyDash(_ text: String) -> String { text.isEmpty ? "—" : text }

    private func bandLabel(_ raw: String) -> String {
        switch raw {
        case "2g": return "2.4G"
        case "5g": return "5G"
        case "6g": return "6G"
        default: return raw
        }
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
            Button { errorText = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22).opacity(0.7))
                    .padding(2)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.85, green: 0.25, blue: 0.22).opacity(0.08))
        }
    }

    // MARK: - 读写

    private func seed() {
        guard !seeded else { return }
        seeded = true
        // 第一次进来，默认落在「现在真在用的那种方式」上；之后页签只跟着手走。
        if let active = activeMode { mode = active }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        surveys = await model.loadRepeaterSurveys()
        scanning = false
    }

    /// 点扫描到的一条：存过密码就直接连，没存过就弹输入框。
    ///
    /// 老版是「把值填进上面的表单，再自己滚上去点保存」——用户 2026-11-17
    /// 说「点了不起作用」就是这个。现在点一下只有两种结果：连上了，或者弹出密码框。
    ///
    /// 2026-11-25：点的是**当前已经连着的那一个**时什么都不做，只弹提示。
    private func pick(_ item: RepeaterSurvey) async {
        // 点的是当前这个 AP（不是同名另一个频段）才挡；换频段照常执行。
        if isSameAccessPoint(ssid: item.ssid, bssid: item.bssid) {
            noReconnectReason = linkIsHealthy
                ? "「\(item.ssid)」就是当前连着的网络，网络也正常。重复连接会先断开再连，中间会断网十几秒，所以这次没有执行。"
                : "「\(item.ssid)」正在连接中。想重建连接的话，先点「重新连接」。"
            return
        }
        if let saved = rep.saved.first(where: { $0.ssid == item.ssid && !$0.key.isEmpty }) {
            await switchTo(saved, band: item.band)
            return
        }
        joinKey = ""
        joinReveal = false
        pendingJoin = item
    }

    private func join(_ item: RepeaterSurvey) async {
        pendingJoin = nil
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.applyRepeaterNetwork(ssid: item.ssid,
                                                       key: joinKey,
                                                       bssid: item.bssid,
                                                       disguise: rep.disguise,
                                                       autoPortal: rep.autoPortal,
                                                       band: item.band.isEmpty ? nil : item.band)
        busy = false
        surveys = []
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已连接",
                                  detail: item.bandLabel.isEmpty ? item.ssid : "\(item.ssid) · \(item.bandLabel)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    private func switchTo(_ item: RepeaterSavedNetwork, band: String? = nil) async {
        // 切到「当前正连着、网络也通」的那一个 AP = 无意义的重连：不执行。
        if item.ssid == rep.ssid, linkIsHealthy,
           isSameAccessPoint(ssid: item.ssid, bssid: item.bssid) {
            noReconnectReason = "「\(item.ssid)」就是当前连着的网络，网络也正常。重复连接会先断开再连，中间会断网十几秒，所以这次没有执行。"
            return
        }
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.applyRepeaterNetwork(ssid: item.ssid,
                                                       key: item.key,
                                                       bssid: item.bssid,
                                                       disguise: rep.disguise,
                                                       autoPortal: rep.autoPortal,
                                                       band: band)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已切换", detail: item.ssid)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    /// 用当前参数重连一次（不动任何设置）。
    ///
    /// 2026-11-25：链路健康时**不执行**。用户原话「已经连接上且互联网是通的
    /// 就不要触发重新连接了，点重连也不行，直接弹个提示」——重连会先断开，
    /// 白白断十几秒，对已通的链路纯属伤害。
    private func reconnect() async {
        if linkIsHealthy {
            noReconnectReason = "中继已经连着「\(rep.ssid.isEmpty ? "上级网络" : rep.ssid)」，互联网也是通的。重新连接会先断开再连，中间会断网十几秒。真要重建连接，可以先切到别的网络再切回来。"
            return
        }
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.applyRepeaterNetwork(ssid: rep.ssid,
                                                       key: rep.key,
                                                       bssid: rep.bssid,
                                                       disguise: rep.disguise,
                                                       autoPortal: rep.autoPortal)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已重新连接", detail: rep.ssid)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    private func enableRepeater() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        if let problem = await model.applyRepeaterOptions(switchMode: rep.switchMode,
                                                          lockBand: rep.lockBand,
                                                          smartReconnect: rep.smartReconnect,
                                                          enabled: true) {
            busy = false
            errorText = problem
            return
        }
        // 一条已保存的都不认识就先只开开关：让他去下面「其他网络」里挑一个。
        guard !rep.ssid.isEmpty else {
            busy = false
            model.notice = Notice(kind: .info, title: "中继已开启", detail: "选一个上级网络")
            await model.manualRefresh()
            return
        }
        let problem = await model.applyRepeaterNetwork(ssid: rep.ssid,
                                                       key: rep.key,
                                                       bssid: rep.bssid,
                                                       disguise: rep.disguise,
                                                       autoPortal: rep.autoPortal)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "中继已开启", detail: rep.ssid)
            await model.manualRefresh()
            return
        }
        errorText = problem
    }

    private func forget(_ item: RepeaterSavedNetwork) async {
        pendingForget = nil
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.forgetRepeaterNetwork(ssid: item.ssid)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已忽略", detail: item.ssid)
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
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await model.manualRefresh()
    }

    // MARK: - 热点共享（v3.2.2）

    private func connectTether(_ usb: UsbUplink) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let outcome = await model.connectTethering(usb.name)
        busy = false
        if let problem = outcome.error {
            errorText = problem
            return
        }
        model.notice = Notice(kind: .ok, title: "已连接热点共享",
                              detail: outcome.note ?? usb.label)
        await model.manualRefresh()
        // 接口连通 ≠ 成为出口：多 WAN 按 metric 排队（中继 20 / 热点共享 30），
        // 中继还在连的时候出口仍然是中继。不说清楚，用户会以为「切过去了但没网」。
        if model.network.uplink != .tethering, model.network.uplink != .none {
            model.notice = Notice(kind: .info, title: "已连通，出口还在\(model.network.uplink.title)",
                                  detail: "中继还连着，默认路由排在前面。要改走手机，去「中继设置」把「启用中继」关掉。")
        }
    }

    private func disconnectTether() async {
        pendingTetherOff = false
        guard !busy else { return }
        busy = true
        errorText = nil
        let problem = await model.disconnectTethering()
        busy = false
        if let problem {
            errorText = problem
            return
        }
        model.notice = Notice(kind: .ok, title: "已断开", detail: "热点共享")
        await model.manualRefresh()
    }
}
