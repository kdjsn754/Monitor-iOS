import SwiftUI

/// 上网（二级页，v2.9.1）。
///
/// **入口**：网络页拓扑图最上面那个出口节点（点它进来，不再是滚到「上网」卡）。
///
/// **页面结构照官方 App 的 Internet 页**：顶部三个页签 —— 中继 / 以太网 / 蜂窝网络
/// （官方 App 的 `internet_repeater` / `internet_ethernet` / `internet_cellular`，
/// 官方网页端的 `repeater` / `cable` / `modem` 三块卡片也是这个顺序）。
///
/// **数据只走官方通道**（见 `开发交接.md` 3.0）：
/// - 配置读 `uci show repeater`，状态读 `ubus call repeater status`；
/// - 周边 Wi-Fi 读 `ubus call repeater surveys`（按需拉，不进轮询）；
/// - 蜂窝读 `ubus call cellular.modem status`。
/// **不碰 LuCI 那一套。**
///
/// 能改的（都在 `repeater` 这份配置里，写完 `reload` + 回读核对）：
/// 上级网络名称与密码、锁定 BSSID、启用中继、启用伪装、自动启用公共热点认证模式、
/// 切换模式（不切换 / 自动切换 / 仅没网自动切换）、频段选择（自动 / 2.4G / 5G / 6G）。
/// 另外两条：**切到已保存的其它网络**、**扫描周边 Wi-Fi 并加入**。
struct UplinkSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    /// 当前在看哪种上网方式的配置。**只是切换看的面板，不动路由器**——
    /// 真正切换走面板里那颗按钮，会先弹确认。
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

    // ---- 周边 Wi-Fi ----
    @State private var surveys: [RepeaterSurvey] = []
    @State private var scanning = false

    @State private var busy = false
    @State private var errorText: String?
    /// 切上网方式的确认弹窗
    @State private var pendingMode: UplinkMode?

    private var info: NetworkInfo { model.network }
    private var rep: RepeaterInfo { info.repeater }

    var body: some View {
        Form {
            modeSection
            switch mode {
            case .repeater: repeaterSections
            case .wired: wiredSection
            case .cellular: cellularSection
            }
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                        .adaptiveRowBackground()
                }
            }
        }
        .themedFormBackground()
        .tint(.blue)
        .navigationTitle("上网")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(mode != .repeater)
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

    // MARK: - 连接模式

    private var modeSection: some View {
        Section("连接模式") {
            Picker("连接模式", selection: $mode) {
                ForEach(UplinkMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .adaptiveRowBackground()
        }
    }

    // MARK: - 中继

    @ViewBuilder
    private var repeaterSections: some View {
        Section("中继") {
            valueRow("状态", rep.connected ? "已连接" : (rep.state.isEmpty ? "未连接" : rep.state),
                     color: rep.connected ? .green : .secondary)
            valueRow("上级网络", rep.ssid.isEmpty ? "—" : rep.ssid)
            valueRow("信号", rep.signal != 0 ? "\(rep.signal) dBm" : "—",
                     color: rep.signal != 0 ? signalColor(rep.signal) : .secondary)
            valueRow("频段", rep.band.isEmpty ? "—" : bandLabel(rep.band))
            valueRow("信道", rep.channel > 0 ? "\(rep.channel)" : "—")
            valueRow("BSSID", rep.currentBSSID.isEmpty ? "—" : rep.currentBSSID)
            valueRow("IP 地址", info.uplinkIP.isEmpty ? "—" : info.uplinkIP)
            valueRow("网关", info.uplinkGateway.isEmpty ? "—" : info.uplinkGateway)
            valueRow("DNS", rep.dns.isEmpty ? "—" : rep.dns.joined(separator: "  "))
            valueRow("MAC 地址", macLabel)
        }

        Section("上级网络") {
            TextField("名称", text: $ssid)
                .adaptiveRowBackground()
            SecureField("密码", text: $key)
                .adaptiveRowBackground()
            bssidRow
            Toggle("启用中继", isOn: $enabled)
                .adaptiveRowBackground()
            Toggle("启用伪装", isOn: $disguise)
                .adaptiveRowBackground()
            Toggle("公共热点认证模式", isOn: $autoPortal)
                .adaptiveRowBackground()
            Picker("切换模式", selection: $switchMode) {
                Text("不切换").tag(0)
                Text("自动切换").tag(1)
                Text("仅没网自动切换").tag(2)
            }
            .pickerStyle(.menu)
            .adaptiveRowBackground()
            Picker("频段选择", selection: $lockBand) {
                ForEach(rep.bandChoices) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.menu)
            .adaptiveRowBackground()
        }

        if !rep.saved.isEmpty {
            Section("已保存网络") {
                ForEach(rep.saved) { item in
                    Button {
                        Task { await switchTo(item) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.ssid.isEmpty ? "—" : item.ssid)
                                    .foregroundStyle(.primary)
                                Text(item.bssid.isEmpty ? "—" : item.bssid)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            if item.selected {
                                Text("使用中")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(.systemBlue))
                            } else {
                                Text("切换")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(.systemBlue))
                            }
                        }
                    }
                    .adaptiveRowBackground()
                }
            }
        }

        Section("可用网络") {
            Button {
                Task { await scan() }
            } label: {
                HStack {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(scanning ? "扫描中…" : "扫描周边 Wi-Fi")
                    Spacer(minLength: 8)
                }
            }
            .adaptiveRowBackground()
            .disabled(scanning)

            ForEach(surveys) { item in
                Button {
                    ssid = item.ssid
                    bssid = item.bssid
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.secured ? "lock.fill" : "wifi")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.ssid)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(item.bandLabel) · CH \(item.channel)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(item.signal) dBm")
                            .font(.system(size: 13))
                            .foregroundStyle(signalColor(item.signal))
                            .monospacedDigit()
                    }
                }
                .adaptiveRowBackground()
            }
        }
    }

    /// 「锁定 BSSID」：默认自动（不锁，路由器自己挑 AP），
    /// 也可以锁到周边某个同名 AP 上（官方 App 的 `internet_lockBssid`）。
    private var bssidRow: some View {
        Picker("锁定 BSSID", selection: $bssid) {
            Text("自动").tag("")
            ForEach(bssidChoices) { item in
                Text("\(item.bssid) · \(item.signal) dBm").tag(item.bssid)
            }
        }
        .pickerStyle(.menu)
        .adaptiveRowBackground()
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

    private var macLabel: String {
        let modeText: String
        switch rep.macMode {
        case "random": modeText = "随机"
        case "clone": modeText = "克隆"
        default: modeText = "出厂"
        }
        return rep.macAddress.isEmpty ? modeText : "\(modeText) · \(rep.macAddress)"
    }

    // MARK: - 以太网

    @ViewBuilder
    private var wiredSection: some View {
        Section("以太网") {
            valueRow("状态", info.wiredOK ? "已连接" : (info.wanCable ? "已插网线，未联网" : "未插网线"))
            valueRow("协议", info.uplink == .wired ? info.protoLabel : "—")
            valueRow("IP 地址", info.uplink == .wired && !info.uplinkIP.isEmpty ? info.uplinkIP : "—")
            valueRow("网关", info.uplink == .wired && !info.uplinkGateway.isEmpty ? info.uplinkGateway : "—")
            valueRow("协商速率", info.bestPortLabel)
            Button {
                pendingMode = .wired
            } label: {
                HStack {
                    Text("切到以太网")
                    Spacer(minLength: 8)
                    if info.uplink == .wired {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(.systemBlue))
                    }
                }
            }
            .adaptiveRowBackground()
        }
    }

    // MARK: - 蜂窝

    @ViewBuilder
    private var cellularSection: some View {
        Section("蜂窝网络") {
            valueRow("Modem", rep.modemPresent ? "已插入" : "未检测到 Modem")
        }
    }

    // MARK: - 小工具

    private func valueRow(_ label: String, _ value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .adaptiveRowBackground()
    }

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

    // MARK: - 读 / 写

    /// 按采集结果填一次表单。之后刷新不再回填。
    private func seed() {
        if mode == .repeater, !seeded {
            ssid = rep.ssid
            key = rep.key
            bssid = rep.bssid
            disguise = rep.disguise
            autoPortal = rep.autoPortal
            enabled = rep.enabled
            switchMode = rep.switchMode
            lockBand = rep.lockBand
            seeded = true
        }
        if rep.connected { mode = .repeater }
        else if info.uplink == .wired { mode = .wired }
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
        model.notice = Notice(kind: .ok, title: "已切换", detail: target.title)
        // 换链路要十几秒才重新拿到地址，这里等一下再刷新。
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await model.manualRefresh()
    }
}
