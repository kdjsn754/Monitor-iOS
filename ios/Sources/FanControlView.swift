import SwiftUI

/// 风扇控制页（对接路由器的 `gl-fanctrl` 插件）。
///
/// 为什么不自己接管风扇：这个 App 只能走 SSH，没有常驻进程。真要自己按温度调 PWM，
/// 就得不停地 `cat 温度` → `echo pwm`，手机一锁屏、一断开，风扇就停在最后一个值上，
/// 那是最危险的失败模式。插件的守护进程本来就跑在路由器上，掉线也不影响它，
/// 所以这里只当它的「遥控器」：读写同一份 UCI 配置，然后让它自己重启生效。
///
/// **v1.28.28 起是独立页面**（从概览的「风扇」那块 push 进来），不再是半屏面板。
/// 改页面之后顶部走系统导航栏（透明底）——不自己画返回钮，是为了保住 iOS 的
/// 右滑返回手势：`.toolbar(.hidden)` 一开，interactivePopGesture 就跟着失效了。
///
/// **v2.3.0 重排整页布局**（用户：「风扇控制页布局重新设计，现在太丑了」）。改了什么：
/// - 七个参数行原来每行都挂一句 12pt 灰注释（「达到即满速」「避免临界点反复启停」……），
///   一屏铺开全是小字，参数本身反而看不见了。注释全部删掉，只留「参数名 → 当前值」。
/// - 新增 `FanCurveChart`：把九个数字画成一条温度→转速的折线，扫一眼就知道这条曲线陡不陡，
///   不用再靠读七个数字脑补。当前温度会在曲线上标一个点。
/// - 「守护进程运行 / 官方温控在管」两个胶囊从控制卡里撤掉，合并进状态卡右上角那一枚状态胶囊。
///   原来同一件事说了两遍，还白占一整行。
/// - 「待应用」那行 10pt 橙字删掉：底部「应用」按钮本来就是「有没有东西等着写进去」的信号，
///   没改动时它是灰的、有改动时是亮的，不需要再写一行字解释。
/// - 手动模式的大数字放大到 40pt，「实际 PWM」收进胶囊，底下那句说明删掉。
struct FanControlView: View {
    @Environment(AppModel.self) private var model: AppModel

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
            VStack(spacing: 14) {
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
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .themedScrollBackground()
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
                .navBarTint()
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

    // MARK: - 运行状态

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

    /// 标题行右上角那枚胶囊：一眼看出风扇此刻归谁管。
    ///
    /// v2.3.0 起它同时表达「守护进程在不在跑」——接管打开但守护进程没起来，
    /// 转成橙色。原来这件事是控制卡里单独一枚胶囊，同一件事说了两遍。
    private var controlPill: some View {
        let enabled = model.fan.enabled
        let running = model.fan.pluginRunning
        let tone: Color = enabled ? (running ? .blue : .orange) : Color(.systemGray)
        let title: String = enabled ? (running ? "插件接管" : "守护进程未运行") : "官方温控"

        return HStack(spacing: 4) {
            Circle()
                .fill(tone)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(enabled ? tone : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemFill), in: Capsule())
    }

    // MARK: - 控制方式（接管 + 模式）

    /// 以前「由插件接管风扇」和「风扇模式」是两张卡，各自只有一行内容却各占一张卡壳
    /// （标题 + 32pt 内边距）。合成一张之后省下一套壳，逻辑也顺：谁在管、怎么管。
    private var controlCard: some View {
        SectionCard("控制方式", icon: "hand.raised") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("由插件接管风扇")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    if model.fanBusy {
                        ProgressView().controlSize(.mini)
                    }
                    Toggle("由插件接管风扇", isOn: Binding(
                        get: { model.fan.enabled },
                        set: { value in Task { await model.setFanEnabled(value) } }
                    ))
                    .labelsHidden()
                    .tint(.blue)
                    .disabled(model.fanBusy)
                }
                .padding(.vertical, 2)

                Divider().padding(.vertical, 10)

                // 分段只改**草稿**，按「应用到路由器」才真正下发（v1.28.28）。
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
                    .frame(width: 156)
                }
                .padding(.vertical, 2)
                .disabled(model.fanBusy || !model.fan.enabled)
                .opacity(model.fan.enabled ? 1 : 0.45)
            }
        }
    }

    // MARK: - 自动曲线

    private var curveCard: some View {
        SectionCard("温控曲线", icon: "thermometer.medium") {
            VStack(alignment: .leading, spacing: 12) {
                // 曲线画的是**草稿**：改一个数字，图上那条折线立刻跟着动，
                // 不用先写到路由器再回读才知道自己调成什么样。
                FanCurveChart(startTemp: Double(draft.startTemp),
                              wallTemp: Double(draft.wallTemp),
                              criticalTemp: Double(draft.criticalTemp),
                              startPercent: Double(draft.startPercent),
                              maxPercent: Double(draft.maxPercent),
                              currentTemp: model.fan.temperature)

                Divider()

                VStack(spacing: 0) {
                    paramRow("起转温度", value: $draft.startTemp, range: 35...85, unit: "°C")
                    paramRow("温度墙", value: $draft.wallTemp, range: 35...95, unit: "°C")
                    paramRow("保护温度", value: $draft.criticalTemp, range: 35...105, unit: "°C")
                    paramRow("回差", value: $draft.hysteresis, range: 1...10, unit: "°C")
                    Divider().padding(.vertical, 8)
                    paramRow("起转 PWM", value: $draft.startPercent, range: 0...100, unit: "%")
                    paramRow("最大 PWM", value: $draft.maxPercent, range: 0...100, unit: "%")
                    paramRow("轮询间隔", value: $draft.pollInterval, range: 1...30, unit: "s")
                }
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

    /// 一行参数：左边名字、右边当前值，值右边是系统的加减控件。
    ///
    /// 原来每行还在名字下面挂一句 12pt 注释（「达到即满速」「低了可能起转失败」……），
    /// v2.3.0 全删——七个注释叠起来比七个数字还抢眼，用户要的是「名字 + 现在多少」。
    private func paramRow(_ title: String, value: Binding<Int>,
                          range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 4)
                Text("\(value.wrappedValue)\(unit)")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 58, alignment: .trailing)
            }
        }
        .tint(.blue)
        .disabled(model.fanBusy || !model.fan.enabled)
        .opacity(model.fan.enabled ? 1 : 0.45)
        .padding(.vertical, 2)
    }

    // MARK: - 手动

    private var manualCard: some View {
        SectionCard("手动转速", icon: "dial.medium") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(manualValue.rounded()))")
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                    Text("%")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let pwm = model.fan.pwmPercent {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                            Text("实际 \(pwm)%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                }

                // v1.28.28 起拖动不再即时下发：松手只是改草稿，和模式、曲线一起
                // 由页面底部那个「应用到路由器」统一提交。
                // （以前每松一次手就写一遍 uci + 重启服务，一次拖动能写几十遍 flash。）
                Slider(value: $manualValue, in: 0...100, step: 1)
                    .tint(.blue)
                    .disabled(model.fanBusy || !model.fan.enabled)
                    .opacity(model.fan.enabled ? 1 : 0.45)
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
            codeLine("opkg install /tmp/gl-fanctrl_0.1.0_all.ipk")
            codeLine("apk add --allow-untrusted /tmp/gl-fanctrl-0.1.0-r1.apk")
            Text("装好后回这页点右上角刷新。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
            .adaptiveFill(Color(.systemBackground),
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

// MARK: - 曲线图

/// 温度 → 转速的折线预览（横轴 30–105 °C，纵轴 0–100 %）。
///
/// 插件的行为是三段：低于「起转温度」**完全不转**（不是低速转）；到了起转温度直接以
/// 「起转 PWM」起转，然后到「温度墙」之间线性爬升；温度墙以上满速
/// （「保护温度」再强制一次满速，所以顶上是一段平的）。
/// 所以折线在起转温度那里会有一小段竖直的台阶——那是真实的，别把它画成斜坡：
/// 斜坡会让人以为 40 °C 时风扇在低速转，实际它是停的。
/// 把这条线画出来，比七个数字容易判断得多：起转 PWM 一抬高，左边那段就直接翘起来。
///
/// 当前温度在线上标一个点——「现在 63 °C，曲线此刻给 35 %」，一眼对得上。
/// 用 Canvas 而不是 Charts：这块只有一条折线 + 一块渐变，Charts 每次重建整套场景图
/// 太贵（概览页的速度曲线当初就是因此换掉的）。
private struct FanCurveChart: View {
    let startTemp: Double
    let wallTemp: Double
    let criticalTemp: Double
    let startPercent: Double
    let maxPercent: Double
    let currentTemp: Double?

    private static let minTemp: Double = 30
    private static let maxTemp: Double = 105

    /// 当前温度落在曲线上对应的转速（三段线性插值）。
    private var currentPercent: Double? {
        guard let temp = currentTemp else { return nil }
        if temp <= startTemp { return 0 }
        if temp >= wallTemp { return maxPercent }
        let span = max(wallTemp - startTemp, 0.1)
        return startPercent + (maxPercent - startPercent) * (temp - startTemp) / span
    }

    var body: some View {
        let current = currentPercent
        return Canvas { context, size in
            guard size.width > 4, size.height > 4 else { return }
            let top: CGFloat = 4
            let height = size.height - top - 2
            let width = size.width

            func point(_ temp: Double, _ percent: Double) -> CGPoint {
                let tx = (temp - Self.minTemp) / (Self.maxTemp - Self.minTemp)
                let ty = percent / 100
                return CGPoint(x: CGFloat(min(max(tx, 0), 1)) * width,
                               y: top + CGFloat(1 - min(max(ty, 0), 1)) * height)
            }

            // 0% 基线：曲线贴底时才看得出「这里是关着的」。
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: top + height))
            baseline.addLine(to: CGPoint(x: width, y: top + height))
            context.stroke(baseline,
                           with: .color(Color(.separator).opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // 三段折线。criticalTemp 只画标记，不再折一次——墙以上本来就已经是满速。
            let start = point(startTemp, startPercent)
            let wall = point(wallTemp, maxPercent)

            var curve = Path()
            curve.move(to: point(Self.minTemp, 0))
            // 起转温度之前是停的：这一段贴着 0 基线走到起转温度，
            // 然后竖直抬到「起转 PWM」——这一步就是插件真实的行为。
            curve.addLine(to: point(startTemp, 0))
            curve.addLine(to: start)
            curve.addLine(to: wall)
            curve.addLine(to: point(Self.maxTemp, maxPercent))

            var area = curve
            area.addLine(to: CGPoint(x: width, y: top + height))
            area.addLine(to: CGPoint(x: 0, y: top + height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Color.blue.opacity(0.18), Color.blue.opacity(0)]),
                startPoint: CGPoint(x: 0, y: top),
                endPoint: CGPoint(x: 0, y: top + height)
            ))

            context.stroke(curve, with: .color(.blue),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // 两个拐点
            for dot in [start, wall] {
                let rect = CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: rect), with: .color(.blue))
            }

            // 保护温度：红色小标记，落在满速那段平线上
            let guardPoint = point(min(criticalTemp, Self.maxTemp), maxPercent)
            let guardRect = CGRect(x: guardPoint.x - 2, y: guardPoint.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: guardRect), with: .color(.red))

            // 当前温度：竖虚线 + 线上的圆点
            if let current, let temp = currentTemp,
               temp >= Self.minTemp, temp <= Self.maxTemp {
                let dot = point(temp, current)
                var marker = Path()
                marker.move(to: CGPoint(x: dot.x, y: dot.y))
                marker.addLine(to: CGPoint(x: dot.x, y: top + height))
                context.stroke(marker, with: .color(Color.orange.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                let outer = CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: outer), with: .color(.orange))
                let inner = CGRect(x: dot.x - 2.2, y: dot.y - 2.2, width: 4.4, height: 4.4)
                context.fill(Path(ellipseIn: inner), with: .color(Color(.systemBackground)))
            }
        }
        .frame(height: 86)
        // 和概览页的速度曲线一样：Canvas 是立即模式，滚动时每一帧都会重跑这段 draw，
        // 压成离屏图层之后滚动只做合成。这里没有文字，不会糊字。
        .drawingGroup()
        .accessibilityLabel("温控曲线")
    }
}

// MARK: - 草稿

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
