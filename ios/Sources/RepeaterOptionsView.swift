import SwiftUI

/// 中继设置（二级页，v3.3.12 新增）。
///
/// ## 为什么单独开一页
///
/// 老版把「上级网络」的输入框和「中继设置」的六个开关一起摆在主页面，
/// 用户 2026-11-25 的截图里，一屏能看到名称、密码、锁定 BSSID、启用中继、
/// 公共热点认证模式……但**右上角只有一个「保存」**，一次提交要把
/// 「全局选项」和「网络参数」两套完全不同的东西一起写下去。
/// 固件里这两套根本是两条通道（见 `AppModel.applyRepeaterOptions` /
/// `applyRepeaterNetwork`），混着写的结果就是「改了不生效」。
///
/// 现在拆开：
/// - **主页面（上网）** 只回答「现在走哪条线、连的是谁、要不要换」；
/// - **本页** 管所有参数，一次保存分两条通道各写各的：全局走 uci+reload，
///   伪装 / 公共热点走 `repeater connect`（写 UCI 也改运行态）。
///
/// 分组也照官方来的（`internet_repeaterOption` 那一页的键名）：
/// 连接策略 → 身份与兼容。MAC 模式这版只读展示（见页面底部说明）。
struct RepeaterOptionsView: View {
    @Environment(AppModel.self) private var model: AppModel

    private var rep: RepeaterInfo { model.network.repeater }

    /// 表单已经按采集结果填过一次，之后不再自动回填（刷新会冲掉用户刚改的）。
    @State private var seeded = false

    @State private var enabled = true
    @State private var switchMode = 1
    @State private var lockBand = ""
    @State private var smartReconnect = false
    @State private var disguise = false
    @State private var autoPortal = false

    @State private var busy = false
    @State private var errorText: String?

    /// 和路由器上的值比：有任何一项不同就算「未保存」。
    private var dirty: Bool {
        guard seeded else { return false }
        return enabled != rep.enabled || switchMode != rep.switchMode
            || lockBand != rep.lockBand || smartReconnect != rep.smartReconnect
            || disguise != rep.disguise || autoPortal != rep.autoPortal
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                policyCard
                identityCard
                macCard
                if let errorText { errorCard(errorText) }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScrollBackground()
        .primaryButtons()
        .navigationTitle("中继设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if dirty {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                        .navBarTint()
                }
            }
        }
        .onAppear(perform: seed)
    }

    // MARK: - 连接策略

    private var policyCard: some View {
        CardPanel("连接策略", icon: "antenna.radiowaves.left.and.right") {
            toggleRow("启用中继", isOn: $enabled)
            CardRule()
            menuRow("切换模式", selection: $switchMode) {
                Text("不切换").tag(0)
                Text("自动切换").tag(1)
                Text("仅没网自动切换").tag(2)
            }
            CardRule()
            menuRow("频段选择", selection: $lockBand) {
                ForEach(rep.bandChoices) { item in
                    Text(item.label).tag(item.value)
                }
            }
            CardRule()
            toggleRow("智能重连", isOn: $smartReconnect)
        }
    }

    // MARK: - 身份

    private var identityCard: some View {
        CardPanel("身份与热点", icon: "theatermasks") {
            toggleRow("启用伪装", isOn: $disguise)
            CardRule()
            toggleRow("公共热点认证模式", isOn: $autoPortal)
        }
    }

    // MARK: - MAC

    /// MAC 只读展示。官方那套「随机 / 克隆 / 手动 / 出厂 + 自动更新策略」要先弄清
    /// 固件对 `macaddr` 三种写法的实际格式（`r,` 随机、`c,` 克隆、无前缀出厂），
    /// 这版先不做可写，免得写错把中继连不上——页面把当前值摆清楚。
    private var macCard: some View {
        CardPanel("MAC 地址", icon: "network") {
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "当前模式", value: macModeLabel, valueWeight: .semibold)
                MetricCell(label: "地址", value: rep.macAddress.isEmpty ? "—" : rep.macAddress)
            }
            .padding(.vertical, UI.rowPadding)
        }
    }

    private var macModeLabel: String {
        switch rep.macMode {
        case "random": return "随机"
        case "clone": return "克隆"
        case "manual": return "手动"
        default: return "出厂"
        }
    }

    // MARK: - 行

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(UI.row())
            .blueSwitch()
            .padding(.vertical, UI.rowPadding)
            .disabled(busy)
    }

    private func menuRow<Value: Hashable, Content: View>(_ title: String,
                                                         selection: Binding<Value>,
                                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(UI.row())
            Spacer(minLength: 8)
            Picker(title, selection: selection) { content() }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.primary)
                .disabled(busy)
        }
        .padding(.vertical, UI.rowPadding)
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
        refill()
        seeded = true
    }

    /// 把表单恢复成路由器上的值。
    private func refill() {
        enabled = rep.enabled
        switchMode = rep.switchMode
        lockBand = rep.lockBand
        smartReconnect = rep.smartReconnect
        disguise = rep.disguise
        autoPortal = rep.autoPortal
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil

        let wasEnabled = rep.enabled
        let optionsChanged = enabled != rep.enabled || switchMode != rep.switchMode
            || lockBand != rep.lockBand || smartReconnect != rep.smartReconnect
        let netChanged = disguise != rep.disguise || autoPortal != rep.autoPortal

        // 1) 全局选项：uci + reload（固件里 `reload` 只认这一组）。
        if optionsChanged {
            if let problem = await model.applyRepeaterOptions(switchMode: switchMode,
                                                              lockBand: lockBand,
                                                              smartReconnect: smartReconnect,
                                                              enabled: enabled) {
                busy = false
                errorText = problem
                return
            }
        }

        // 2) 网络参数：`repeater connect`。刚从中继关闭切到开启时也要走一次，
        //    否则 `disabled=0` 写进去了、STA 却没起来（固件自己的开关脚本
        //    `/etc/gl-switch.d/repeater.sh` 就是这么做的）。
        let needConnect = netChanged || (enabled && !wasEnabled)
        if needConnect, enabled {
            if let problem = await model.applyRepeaterNetwork(ssid: rep.ssid,
                                                              key: rep.key,
                                                              bssid: rep.bssid,
                                                              disguise: disguise,
                                                              autoPortal: autoPortal) {
                busy = false
                errorText = problem
                return
            }
        }

        busy = false
        model.notice = Notice(kind: .ok, title: "已保存", detail: rep.ssid)
        await model.manualRefresh()
        // 不自动返回：用户要能看到「启用伪装」这类开关真的被写进去了
        // （这一版之前它们写进去却不生效，正是本页要解决的问题）。
        refill()
    }
}
