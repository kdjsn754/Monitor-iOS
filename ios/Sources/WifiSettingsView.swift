import SwiftUI

/// 无线设置（二级页，v3.2.5）。
///
/// **入口**：网络页「无线」卡右上角的「更多」。
/// 那张卡只回答「现在开着哪些网络、几台设备」（用户 2026-11-18：只显示已开启的），
/// 开 / 关、改名改密码、调信道频宽这些事都收到这一页来。
///
/// 结构与官方 GL 无线页对齐（字段表就是 `/www/i18n/gl-sdk4-ui-wireless.zh-cn.json`
/// 那份文案）：主网络（每频段一行、独立开关）→ 访客 → IoT → 多链路 → 无线配置（按频段）。
/// **不搬官方那些灰色说明文字**（2026-10-31 的规矩：页面上不放解释性小字）。
///
/// 能改的项：名称 / 密码 / 安全性（WPA2 · 混合 · WPA3 · 无密码）/ 隐藏 / 随机 BSSID /
/// 各频段开关 / 信道 / 频宽 / 发射功率 / 5G 的 DFS。
///
/// **没做的两项**（原因写进第 5 节）：无线模式 `hwmode` 与使用环境（室内/户外）。
/// 前者写错会让 MTK 驱动直接不认这个频段，后者在固件里没有 uci 落点
/// （官方走 RPC 直调驱动，SSH 这条路够不着）。
struct WifiSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    @State private var editingGroup: WifiNetGroup?
    @State private var editingRadio: WifiBandInfo?
    @State private var creatingKind: WifiNetGroup.Kind?
    @State private var busyGroups: Set<String> = []

    private var info: NetworkInfo { model.network }
    private var groups: [WifiNetGroup] { info.wifiGroups }

    private var mainGroup: WifiNetGroup? { groups.first { $0.kind == .main } }

    var body: some View {
        Form {
            mainSection
            sideSection(.guest)
            sideSection(.iot)
            if info.mloSupported { sideSection(.mlo) }
            radioSection
        }
        .themedFormBackground()
        .primaryButtons()
        .navigationTitle("无线")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingGroup) { group in
            WifiGroupEditorSheet(group: group)
                .presentationBackground(Color.clear)
        }
        .sheet(item: $editingRadio) { band in
            WifiRadioEditorSheet(band: band)
                .presentationBackground(Color.clear)
        }
        .sheet(isPresented: Binding(get: { creatingKind != nil },
                                    set: { if !$0 { creatingKind = nil } })) {
            if let kind = creatingKind {
                WifiGroupCreateSheet(kind: kind)
                    .presentationBackground(Color.clear)
            }
        }
    }

    // MARK: - 主网络

    /// 主网络按频段各一行：左边点进编辑，右边是这一频段自己的开关。
    /// 「5G 开、2.4G 关」是这台机器最常见的状态，整组一个开关表达不了。
    @ViewBuilder
    private var mainSection: some View {
        Section("主网络") {
            if let main = mainGroup, !main.members.isEmpty {
                ForEach(main.members) { member in
                    HStack(spacing: 10) {
                        Button {
                            editingGroup = main
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.bandName)
                                    Text(member.ssid.isEmpty ? "—" : member.ssid)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!main.editable)

                        bandToggle(member, group: main)
                    }
                    .adaptiveRowBackground()
                }

                Button("修改主网络") { editingGroup = main }
                    .adaptiveRowBackground()
                    .disabled(!main.editable)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
                    .adaptiveRowBackground()
            }
        }
    }

    // MARK: - 访客 / IoT / 多链路

    @ViewBuilder
    private func sideSection(_ kind: WifiNetGroup.Kind) -> some View {
        let group = groups.first { $0.kind == kind }
        Section {
            if let group, !group.members.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        editingGroup = group
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.ssid.isEmpty ? "—" : group.ssid)
                                .foregroundStyle(group.isOn ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(group.isOn ? group.bandSummary : "未启用")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!group.editable)

                    if busyGroups.contains(kind.rawValue) {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("", isOn: groupBinding(group))
                            .labelsHidden()
                            .blueSwitch()
                            .disabled(!group.editable)
                    }
                }
                .adaptiveRowBackground()

                Button("详细设置") { editingGroup = group }
                    .adaptiveRowBackground()
                    .disabled(!group.editable)
            } else if kind == .mlo {
                Text("—")
                    .foregroundStyle(.secondary)
                    .adaptiveRowBackground()
            } else {
                Button("添加\(kind.title)") { creatingKind = kind }
                    .adaptiveRowBackground()
            }
        } header: {
            Text(kind.title)
        }
    }

    // MARK: - 无线配置（按频段）

    /// 信道 / 频宽 / 功率都是 **radio 段**上的，同一个频段的所有网络共用一份，
    /// 所以它不挂在某个网络下面，而是单独一块。频段清单取主网络的成员——
    /// 那两个 `wifi-iface` 正好各代表一个 radio。
    @ViewBuilder
    private var radioSection: some View {
        Section("无线配置") {
            let bands = mainGroup?.members ?? []
            if bands.isEmpty {
                Text("—")
                    .foregroundStyle(.secondary)
                    .adaptiveRowBackground()
            } else {
                ForEach(bands) { band in
                    Button {
                        editingRadio = band
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(band.bandName)
                                Text("\(band.channelSettingLabel) · \(band.powerLabel)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .adaptiveRowBackground()
                }
            }
        }
    }

    // MARK: - 开关

    /// 单个频段的开关：只动这一条 `wifi-iface`。
    ///
    /// 关掉的正是手机此刻连着的那一路时会立刻失联——`saveWifiGroup` 里拦了，
    /// 这里只负责按住开关、等结果。
    private func bandToggle(_ member: WifiBandInfo, group: WifiNetGroup) -> some View {
        Group {
            if busyGroups.contains(member.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 51, height: 31)
            } else {
                Toggle("", isOn: Binding(get: { member.ssidOn }, set: { value in
                    guard !busyGroups.contains(member.id) else { return }
                    busyGroups.insert(member.id)
                    Task {
                        var map: [String: Bool] = [:]
                        for item in group.members { map[item.band] = item.ssidOn }
                        map[member.band] = value
                        let problem = await model.saveWifiGroup(group, ssid: group.ssid,
                                                                key: group.key, hidden: group.hidden,
                                                                bandOn: map)
                        busyGroups.remove(member.id)
                        if let problem {
                            model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
                        } else {
                            await model.manualRefresh()
                        }
                    }
                }))
                .labelsHidden()
                .blueSwitch()
                .disabled(!member.editable)
            }
        }
        .frame(width: 51)
    }

    /// 整组开关（访客 / IoT / 多链路）。开的时候所有频段一起开。
    private func groupBinding(_ group: WifiNetGroup) -> Binding<Bool> {
        Binding(get: { group.isOn }, set: { value in
            guard !busyGroups.contains(group.kind.rawValue) else { return }
            busyGroups.insert(group.kind.rawValue)
            Task {
                var map: [String: Bool] = [:]
                for member in group.members { map[member.band] = value }
                let problem = await model.saveWifiGroup(group, ssid: group.ssid,
                                                        key: group.key, hidden: group.hidden,
                                                        bandOn: map)
                busyGroups.remove(group.kind.rawValue)
                if let problem {
                    model.notice = Notice(kind: .fail, title: "没切换成功", detail: problem)
                } else {
                    await model.manualRefresh()
                }
            }
        })
    }
}

// MARK: - 网络编辑

/// 一组无线网络的编辑页：名称 / 安全性 / 密码 / 隐藏 / 随机 BSSID / 各频段开关。
///
/// 同组的 2.4G 与 5G 是两条独立 `wifi-iface`，名称和密码必须写成一样，
/// 否则手机在两个频段上会看到两个不同名字的网络——所以由这一页统一写。
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
            Form {
                Section {
                    HStack {
                        Text("名称")
                        TextField("", text: $ssid)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .adaptiveRowBackground()

                    Picker("安全性", selection: $security) {
                        ForEach(WifiSecurity.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .adaptiveRowBackground()

                    if security.needsKey {
                        HStack {
                            Text("密码")
                            Group {
                                if showKey {
                                    TextField("", text: $key)
                                } else {
                                    SecureField("", text: $key)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .adaptiveRowBackground()
                    }

                    Toggle("隐藏网络", isOn: $hidden)
                        .blueSwitch()
                        .adaptiveRowBackground()
                    Toggle("随机 BSSID", isOn: $randomBSSID)
                        .blueSwitch()
                        .adaptiveRowBackground()
                }

                Section("频段") {
                    ForEach(group.members) { member in
                        Toggle(isOn: Binding(
                            get: { bandOn[member.band] ?? false },
                            set: { bandOn[member.band] = $0 }
                        )) {
                            Text(member.bandName)
                        }
                        .blueSwitch()
                        .adaptiveRowBackground()
                    }
                    if let bandProblem {
                        Text(bandProblem)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.22))
                            .adaptiveRowBackground()
                    }
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
            .primaryButtons()
            .navigationTitle(group.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
                            .navBarTint()
                    }
                }
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
        let problem = await model.saveWifiGroup(group, ssid: ssid, key: key, hidden: hidden,
                                                encryption: security.rawValue,
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

// MARK: - 频段设置

/// 一个频段的无线参数：信道 / 频宽 / 发射功率 / 5G 的 DFS。
///
/// 这些键挂在 radio 段上（`wireless.MT7993_1_2`），改了之后这个频段上**所有**网络
/// 一起换信道——官方也是这么写的（「以下配置将应用到所有 X 频段的网络」）。
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
        // 否则 Picker 会显示空行。
        let options = band.widthOptions
        let initialWidth = options.contains(band.width) ? band.width : (options.first ?? "")
        _width = State(initialValue: initialWidth)
        // 读回来的百分比不在四档里（有人手动改过 60）就取最近的一档，
        // 免得 Picker 空着——这一页不提供任意百分比，官方也只有四档。
        let nearest = Self.powerLevels.min {
            abs($0 - band.txPowerPercent) < abs($1 - band.txPowerPercent)
        } ?? 100
        _power = State(initialValue: band.txPowerPercent > 0 ? nearest : 100)
        _dfs = State(initialValue: band.dfsEnabled)
    }

    /// 信道候选：自动 + 这一频段的常用非 DFS 信道。
    ///
    /// **当前值一定要在列表里**：路由器可能正停在 DFS 信道（100 / 52…）上，
    /// 那些值不在 `channelOptions` 里，不补进去 Picker 会显示空行、一保存就把它改掉。
    private var channelChoices: [String] {
        var list = ["auto"] + band.channelOptions.map(String.init)
        if !list.contains(channel) { list.insert(channel, at: 1) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("信道", selection: $channel) {
                        ForEach(channelChoices, id: \.self) { value in
                            Text(value == "auto" ? "自动" : "CH \(value)").tag(value)
                        }
                    }
                    .adaptiveRowBackground()

                    Picker("频宽", selection: $width) {
                        ForEach(band.widthOptions, id: \.self) { value in
                            Text("\(value) MHz").tag(value)
                        }
                    }
                    .adaptiveRowBackground()

                    Picker("发射功率", selection: $power) {
                        ForEach(Self.powerLevels, id: \.self) { value in
                            Text(powerLabel(value)).tag(value)
                        }
                    }
                    .adaptiveRowBackground()
                }

                if band.band == "5" {
                    Section {
                        Toggle("允许 DFS 信道", isOn: $dfs)
                            .blueSwitch()
                            .adaptiveRowBackground()
                    }
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
            .primaryButtons()
            .navigationTitle(band.bandName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await save() } }
                            .fontWeight(.semibold)
                            .navBarTint()
                    }
                }
            }
        }
    }

    private func powerLabel(_ value: Int) -> String {
        switch value {
        case 100: return "最大（100%）"
        case 75: return "高（75%）"
        case 50: return "中（50%）"
        case 25: return "低（25%）"
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
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("名称")
                        TextField(kind.title, text: $ssid)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .adaptiveRowBackground()

                    HStack {
                        Text("密码")
                        SecureField("至少 8 位", text: $key)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .adaptiveRowBackground()
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
            .primaryButtons()
            .navigationTitle("添加\(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .navBarTint()
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("创建") { Task { await create() } }
                            .fontWeight(.semibold)
                            .navBarTint()
                    }
                }
            }
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
