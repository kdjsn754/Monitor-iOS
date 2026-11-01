import SwiftUI

/// 风扇控制页（对接路由器的 `gl-fanctrl` 插件）。
///
/// 为什么不自己接管风扇：这个 App 只能走 SSH，没有常驻进程。真要自己按温度调 PWM，
/// 就得不停地 `cat 温度` → `echo pwm`，手机一锁屏、一断开，风扇就停在最后一个值上，
/// 那是最危险的失败模式。插件的守护进程本来就跑在路由器上，掉线也不影响它，
/// 所以这里只当它的「遥控器」：读写同一份 UCI 配置，然后让它自己重启生效。
///
/// **v1.28.28 起是独立页面**（从概览的「风扇」那块 push 进来），不再是半屏面板：
/// 面板只有半屏、内容又长，滚到下面的曲线时上面的状态永远看不到。
/// 改页面之后顶部走系统导航栏（透明底）——不自己画返回钮，是为了保住 iOS 的
/// 右滑返回手势：`.toolbar(.hidden)` 一开，interactivePopGesture 就跟着失效了。
struct FanControlView: View {
    @EnvironmentObject private var model: AppModel

    /// 自动曲线的编辑副本。没按「应用」之前不碰路由器——七个 Stepper 每动一格
    /// 就 commit + 重启一次服务，路由器上的 flash 和风扇都受不了。
    @State private var draft = FanDraft()
    /// 模式也走草稿（v1.28.28，用户：「增加应用按钮，不是现在点击后直接就切换了」）。
    /// 以前分段控件一碰就 `uci set mode` + 重启守护进程，手指划过去就算改了。
    @State private var draftMode: FanControlState.Mode = .auto
    @State private var manualValue: Double = 0
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !model.fan.loaded {
                    loadingCard
                } else if !model.fan.installed {
                    installCard
                } else {
                    statusCard
                    controlCard
                    // 卡片跟着**草稿**走，不跟路由器上的实际模式走：
                    // 选了「手动」就该立刻看到滑块，不能等应用完才切过去。
                    if draftMode == .auto {
                        curveCard
                    } else {
                        manualCard
                    }
                    applySection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 26)
        }
        .background(Color.clear)
        .navigationTitle("风扇控制")
        .navigationBarTitleDisplayMode(.inline)
        // 透明底：这页背后是 App 的渐变背景，导航栏一旦有了实心底就会切出一条横杠。
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshFan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(model.fanBusy)
                .accessibilityLabel("刷新风扇状态")
            }
        }
        .task {
            await model.refreshFan()
            seed()
            // 页面开着就每 2 秒刷一次**运行态**（温度 / 转速 / PWM / 守护进程）。
            // 只刷运行态、不重读配置：`uci show` 又慢又没必要，而且整份 `fan`
            // 被覆盖会把正在拖的曲线草稿顶回旧值。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await model.refreshFanRuntime()
            }
        }
        // 草稿只在**配置**变化时对齐：运行态每 2 秒都在变，拿它当触发条件的话，
        // 用户正拖着 Stepper 的时候草稿会被反复重置。
        .onChange(of: FanDraft(model.fan)) { _, _ in seed() }
        // 模式不在这份草稿里（它不是一个数字），单独跟。
        .onChange(of: model.fan.mode) { _, new in
            draftMode = new
            manualValue = Double(model.fan.manualPercent)
        }
        // 确认框仍然自绘：系统的 `confirmationDialog` 在这套页面里会被锚到
        // 屏幕半空（看着像贴歪的气泡），和「连接设备」面板统一走这套浮层。
        .overlay {
            if confirmReset {
                SheetOverlay(onDismiss: { confirmReset = false }) {
                    SheetOverlayCard {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("恢复插件的默认配置？")
                                .font(.headline)
                            Text("会把接管关掉、曲线恢复成 70/76/88 °C，风扇交回官方温控。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            SheetOverlayButton(title: "取消") { confirmReset = false }
                            SheetOverlayButton(title: "恢复默认", tint: .red) {
                                confirmReset = false
                                Task { await model.restoreFanDefaults() }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        SectionCard("运行状态", icon: "fanblades", accessory: { controlPill }) {
            // 三格从「5% 主色淡底」换成白底 + separator 细边（v1.28.27 定下的语言）。
            // 「按曲线此刻应为 x%」那行提示按用户要求在 v1.28.28 删掉了：
            // 它只给一个数、不给判断依据，却占着整整一行。
            HStack(spacing: 8) {
                statTile("温度",
                         value: model.fan.temperature.map { String(format: "%.0f", $0) } ?? "—",
                         unit: "°")
                statTile("转速",
                         value: model.fan.rpm.map { String(format: "%.0f", $0) } ?? "—",
                         unit: "RPM")
                statTile("PWM",
                         value: model.fan.pwmPercent.map { "\($0)" } ?? "—",
                         unit: "%")
            }
        }
    }

    private func statTile(_ title: String, value: String, unit: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .plainTile(radius: 12)
    }

    /// 标题行右上角那枚小胶囊：一眼看出风扇此刻归谁管。
    private var controlPill: some View {
        let taken = model.fan.enabled
        return HStack(spacing: 4) {
            Circle()
                .fill(taken ? Color.blue : Color(.systemGray3))
                .frame(width: 5, height: 5)
            Text(taken ? "插件接管" : "官方温控")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(taken ? Color.blue : Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemFill), in: Capsule())
    }

    /// 状态小胶囊（控制方式卡里那两个）。
    /// 只写中文、只留「在不在跑」这一层信息：副词、解释、警告一律不进胶囊。
    private func stateChip(_ title: String, tone: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? tone : Color(.systemGray3))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? tone : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .softTile(active ? tone : Color(.systemGray), in: Capsule())
    }

    // MARK: - 控制方式（接管 + 模式）

    /// 以前「由插件接管风扇」和「风扇模式」是两张卡，各自只有一行内容却各占一张卡壳
    /// （标题 + 32pt 内边距）。合成一张之后省下一套壳，逻辑也顺：谁在管、怎么管。
    private var controlCard: some View {
        SectionCard("控制方式", icon: "hand.raised") {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("由插件接管风扇")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Toggle("由插件接管风扇", isOn: Binding(
                        get: { model.fan.enabled },
                        set: { value in Task { await model.setFanEnabled(value) } }
                    ))
                    .labelsHidden()
                    .tint(.blue)
                    .disabled(model.fanBusy)
                }

                HStack(spacing: 6) {
                    stateChip(model.fan.pluginRunning ? "守护进程运行" : "守护进程未运行",
                              tone: .blue,
                              active: model.fan.pluginRunning)
                    stateChip(model.fan.enabled ? "官方温控已停" : "官方温控在管",
                              tone: .green,
                              active: !model.fan.enabled)
                    Spacer(minLength: 0)
                    if model.fanBusy {
                        ProgressView().controlSize(.mini)
                    }
                }

                Divider()

                // 分段只改**草稿**，按「应用到路由器」才真正下发（v1.28.28）。
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("风扇模式")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                        Picker("风扇模式", selection: $draftMode) {
                            ForEach(FanControlState.Mode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    // 开关是即时的、模式是草稿的，两者不一样。这里把「选好了还没应用」
                    // 说清楚，否则用户切到手动会以为风扇已经换模式了。
                    if draftMode != model.fan.mode {
                        Text("待应用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(model.fanBusy || !model.fan.enabled)
                .opacity(model.fan.enabled ? 1 : 0.45)
            }
        }
    }

    // MARK: - 自动曲线

    private var curveCard: some View {
        SectionCard("自动温控曲线", icon: "thermometer.medium") {
            VStack(alignment: .leading, spacing: 10) {
                groupLabel("温度")
                paramRow("起转温度", value: $draft.startTemp, range: 35...85, unit: "°C")
                paramRow("温度墙", value: $draft.wallTemp, range: 35...95, unit: "°C",
                         note: "达到即满速")
                paramRow("保护温度", value: $draft.criticalTemp, range: 35...105, unit: "°C",
                         note: "两种模式下都强制满速")
                paramRow("回差", value: $draft.hysteresis, range: 1...10, unit: "°C",
                         note: "避免临界点反复启停")

                Divider().padding(.vertical, 2)

                groupLabel("转速")
                paramRow("起转 PWM", value: $draft.startPercent, range: 0...100, unit: "%",
                         note: "低了可能起转失败")
                paramRow("最大 PWM", value: $draft.maxPercent, range: 0...100, unit: "%")
                paramRow("轮询间隔", value: $draft.pollInterval, range: 1...30, unit: "s")
            }
            // 依赖关系就地夹紧：插件的校验规则是「温度墙 ≥ 起转+5、保护 ≥ 温度墙+3」，
            // 不满足时 commit 会被静默拒绝，界面却还显示着自己那套数字。
            .onChange(of: draft.startTemp) { _, new in
                if draft.wallTemp < new + 5 { draft.wallTemp = min(new + 5, 95) }
                if draft.criticalTemp < draft.wallTemp + 3 { draft.criticalTemp = min(draft.wallTemp + 3, 105) }
            }
            .onChange(of: draft.wallTemp) { _, new in
                if draft.criticalTemp < new + 3 { draft.criticalTemp = min(new + 3, 105) }
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func paramRow(_ title: String, value: Binding<Int>,
                          range: ClosedRange<Int>, unit: String,
                          note: String? = nil) -> some View {
        Stepper(value: value, in: range) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                    if let note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                // 值右对齐并给一个最小宽度：以前中间空出一大段，眼睛要从左扫到最右再扫回来。
                Text("\(value.wrappedValue)\(unit)")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
        .tint(.blue)
        .disabled(model.fanBusy || !model.fan.enabled)
        .opacity(model.fan.enabled ? 1 : 0.45)
    }

    // MARK: - 手动

    private var manualCard: some View {
        SectionCard("手动转速", icon: "dial.medium") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(manualValue.rounded()))")
                        .font(.system(size: 32, weight: .bold))
                        .monospacedDigit()
                    Text("%")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let pwm = model.fan.pwmPercent {
                        Text("实际 PWM \(pwm)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // v1.28.28 起拖动不再即时下发：松手只是改草稿，和模式、曲线一起
                // 由页面底部那个「应用到路由器」统一提交。
                // （以前每松一次手就写一遍 uci + 重启服务，一次拖动能写几十遍 flash。）
                Slider(value: $manualValue, in: 0...100, step: 1)
                    .tint(.blue)
                    .disabled(model.fanBusy || !model.fan.enabled)
                    .opacity(model.fan.enabled ? 1 : 0.45)

                Text(model.fan.enabled
                     ? "0% 停转；1–100% 会被夹在「起转 PWM」和「最大 PWM」之间，避免低到起转失败。"
                     : "先打开上面的「由插件接管风扇」，才能手动调速。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 应用 / 恢复默认

    /// 页面级的两个动作，不再是「塞在曲线卡底部的按钮」：
    /// 手动模式下没有曲线卡，按钮跟着卡走就没地方放了。
    private var applySection: some View {
        VStack(spacing: 10) {
            Button(action: applyChanges) {
                Text(model.fanBusy ? "正在应用…" : "应用到路由器")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            // 没有改动时按钮是灰的：它本身就是「有没有东西等着写进去」的信号。
            .buttonStyle(GlassProminentButtonStyle(dimmed: !canApply))
            .disabled(!canApply)

            Button {
                confirmReset = true
            } label: {
                Text("恢复插件默认配置")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .rowTile(radius: 12)
            .disabled(model.fanBusy)
        }
        .padding(.top, 2)
    }

    /// 按钮能不能按：有改动、不忙、接管开着。
    private var canApply: Bool {
        model.fan.enabled && !model.fanBusy && hasChanges
    }

    /// 有没有「选了但还没写进路由器」的东西。按钮亮不亮就看它。
    private var hasChanges: Bool {
        guard model.fan.loaded, model.fan.installed else { return false }
        if draftMode != model.fan.mode { return true }
        if draftMode == .auto { return curveDirty }
        return Int(manualValue.rounded()) != model.fan.manualPercent
    }

    private var curveDirty: Bool {
        let f = model.fan
        return draft.startTemp != f.startTemp
            || draft.wallTemp != f.wallTemp
            || draft.criticalTemp != f.criticalTemp
            || draft.hysteresis != f.hysteresis
            || draft.startPercent != f.startPercent
            || draft.maxPercent != f.maxPercent
            || draft.pollInterval != f.pollInterval
    }

    /// 一次提交把模式和参数一起写掉。
    ///
    /// 两个 API 本来就自带 `mode`：`applyFanAuto` 写的是 `mode=auto` + 七个参数，
    /// `setFanManual` 写的是 `mode=manual` + 一个百分比。所以不需要先 `setFanMode`
    /// 再写参数——那是两次 commit、两次重启守护进程，风扇会平白抖一下。
    private func applyChanges() {
        guard model.fan.enabled else { return }
        Task {
            if draftMode == .auto {
                await model.applyFanAuto(
                    startTemp: draft.startTemp,
                    wallTemp: draft.wallTemp,
                    criticalTemp: draft.criticalTemp,
                    hysteresis: draft.hysteresis,
                    startPercent: draft.startPercent,
                    maxPercent: draft.maxPercent,
                    pollInterval: draft.pollInterval
                )
            } else {
                await model.setFanManual(Int(manualValue.rounded()))
            }
        }
    }

    // MARK: - 加载 / 未安装

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读取风扇状态…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .rowTile(radius: 14)
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("路由器上没有 gl-fanctrl")
                    .font(.subheadline.weight(.semibold))
            }
            Text("风扇控制读写的是一份 UCI 配置（/etc/config/gl_fanctrl），需要先在路由器上装好这个插件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                codeLine("opkg install /tmp/gl-fanctrl_0.1.0_all.ipk")
                codeLine("apk add --allow-untrusted /tmp/gl-fanctrl-0.1.0-r1.apk")
            }
            Text("opkg 用于 OpenWrt 21/22 固件，apk 用于 24.10+ 固件。装完回到这里点右上角刷新。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowTile(radius: 14)
    }

    private func codeLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.55), lineWidth: 0.5)
            }
    }

    /// 页面里的数字跟着路由器回读的值走。用户没按「应用」之前，改动只存在草稿里。
    private func seed() {
        draft = FanDraft(model.fan)
        draftMode = model.fan.mode
        manualValue = Double(model.fan.manualPercent)
    }
}

/// 自动曲线在界面上的编辑副本。
private struct FanDraft: Equatable {
    var startTemp = 70
    var wallTemp = 76
    var criticalTemp = 88
    var hysteresis = 3
    var startPercent = 35
    var maxPercent = 100
    var pollInterval = 2

    init() {}

    init(_ state: FanControlState) {
        startTemp = state.startTemp
        wallTemp = state.wallTemp
        criticalTemp = state.criticalTemp
        hysteresis = state.hysteresis
        startPercent = state.startPercent
        maxPercent = state.maxPercent
        pollInterval = state.pollInterval
    }
}
