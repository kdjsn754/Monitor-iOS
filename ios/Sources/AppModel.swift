import Foundation
import SwiftUI
import Observation

enum AppError: LocalizedError {
    case notConnected
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH 尚未连接"
        case .cancelled: return "已取消连接"
        case .message(let value): return value
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var connected = false
    var connecting = false
    var reconnecting = false
    var activityTitle: String?
    var activitySubtitle: String?
    var busy = false
    var status = "未连接"
    var errorMessage: String?
    var stats = OverviewStats()
    var flashInfo = FlashInfo()
    var routerInfo = RouterInfo()
    var devices: [DeviceInfo] = []
    /// 自定义设备名：键是 MAC（租约重新下发时 IP 会变，MAC 不会），没 MAC 才退回 IP。
    var deviceAliases: [String: String] = [:]
    /// 删掉（隐藏）的离线设备。键同上，值是删掉那一刻。
    ///
    /// 路由器上的租约**不动**——那是 dnsmasq 管的文件，手机端去改容易把
    /// 「谁在用这个 IP」搞乱。这里只是本机记账，目标是把「人已经走了、
    /// 只剩一条租约」的僵尸条目从列表里清掉。设备真的回来时自动撤销隐藏，
    /// 所以不需要额外的「恢复」按钮去救它。
    private(set) var hiddenDeviceCount = 0
    /// 自动清理离线设备。
    var autoRemoveOffline: Bool = false {
        didSet {
            guard autoRemoveOffline != oldValue else { return }
            UserDefaults.standard.set(autoRemoveOffline, forKey: Self.autoRemoveKey)
        }
    }
    /// 离线多久算「可以清掉」，默认 1 小时。
    var offlineRemoveMinutes: Int = 60 {
        didSet {
            guard offlineRemoveMinutes != oldValue else { return }
            UserDefaults.standard.set(offlineRemoveMinutes, forKey: Self.offlineMinutesKey)
        }
    }

    private static let hiddenDevicesKey = "hiddenDeviceKeys"
    private static let offlineSinceKey = "offlineSinceKeys"
    private static let autoRemoveKey = "autoRemoveOffline"
    private static let offlineMinutesKey = "offlineRemoveMinutes"

    /// 被删掉的设备：MAC → 删除时间。
    private var hiddenDeviceKeys: [String: Date] = [:]
    /// 每台设备「第一次被发现离线」的时刻，用来算自动清理的时长。
    private var offlineSince: [String: Date] = [:]
    /// 采集到的全部设备（含被删掉的）。筛选后的才是 `devices`。
    private var allDevices: [DeviceInfo] = []

    /// 风扇控制（gl-fanctrl 插件）。只在打开控制面板时才去问，不跟着轮询跑：
    /// 一份配置要塞十来次 uci，每 2 秒问一次纯属浪费路由器的 CPU。
    var fan = FanControlState()
    /// 正在写风扇配置（面板里按钮转圈、同时避免连点）。
    var fanBusy = false

    var openClash = OpenClashInfo()
    /// OpenClash 的完整状态（装没装、代理模式、配置列表）是否已经成功问过一次。
    ///
    /// 「还没问」和「问过、确定没装」是两件事。以前两种情况都用默认值 false 表示，
    /// 于是刚进网络代理页的那几秒，界面会一口咬定「未检测到插件」，
    /// 顶部那两排按钮也跟着被整段拿掉——用户看到的就是「空白很久，按钮才蹦出来」。
    private(set) var ocStateLoaded = false
    /// 状态探针正在跑（进代理页时先单独问一次，不等那条要 curl 内核的指标命令）。
    private(set) var ocStateLoading = false
    var ocMetrics = OpenClashMetrics()
    /// 指标脚本有没有成功跑过一轮。
    ///
    /// `ocMetrics.apiReachable` 的默认值是 false，光看它分不清「面板真的不通」和
    /// 「第一拍还没回来」。控制面板徽标要靠这个区分，否则进页面会先闪一下「未运行」再变绿。
    private(set) var ocMetricsLoaded = false
    /// 路由器上的订阅列表（UCI `config_subscribe`）。只在打开配置弹窗时读一次，
    /// 不跟着轮询：订阅是低频数据，改一次才动一次。
    var subscriptions: [ProxySubscription] = []
    /// 正在更新的订阅名；nil = 空闲。
    private(set) var subsBusy: String?
    /// 用户刚在本地改过、路由器还没确认的开关状态（键 = UCI 段名）。
    ///
    /// 读列表是异步的：点开关的同时如果正好有一次 `loadSubscriptions` 在飞，
    /// 它带回来的是**改之前**的值，回来就把刚关掉的开关又打开——真机上表现为
    /// 「第一次进这页，开关关了它自己又打开」。这里把未确认的改动压住，
    /// 直到某次读列表真的读回同一个值才放手。
    private var pendingEnabled: [String: Bool] = [:]
    private(set) var subsLoaded = false
    /// 正在读当前配置那一条订阅的流量。界面用它显示「正在读取流量…」。
    ///
    /// 用量本身不放单独的表，直接回填进 `subscriptions[i].usage`：列表、编辑页
    /// 拿的是同一份值，不会出现「列表里有流量、点进编辑就没了」。
    private(set) var subUsageLoading = false
    /// 「刷新流程」正在跑——从点下按钮到 curl 回来**整段**都算（v2.4.23）。
    ///
    /// 和 `subUsageLoading` 的区别就是那个时间差：`subUsageLoading` 要等前面的
    /// 探针 / 读订阅列表跑完才置位，中间这段时间按钮毫无变化，用户以为没点到，
    /// 于是连点——而 SSH 是串行队列，点三次就是排三次，一次比一次慢。
    /// 现在按钮一按就置位，界面上立刻转圈；同一时间只允许一条刷新在飞。
    private(set) var subUsageRefreshing = false
    /// 上一次读取失败的原因（成功时清空）。v2.4.21 起界面上要显示出来：
    /// 上一版读不到就静默留白，谁也不知道是机场没给还是命令没跑起来。
    private(set) var subUsageError: String?
    /// 上一次读成功的时间点，卡片上显示「几分钟前」。
    private(set) var subUsageAt: Date?
    /// 上一次读成功的时间：来回切页面时 30 秒内不重复打机场接口。
    private var subUsageFetchedAt: Date?
    /// 上一次**真正发出请求**的时间，成败都记（v2.4.22）。
    ///
    /// 自动加载的节流靠它：失败时 `subUsageFetchedAt` 不会更新，只看那一个的话，
    /// 每切一次页就会重打一次机场接口，机场那边看着像在刷订阅。
    private var subUsageAttemptAt: Date?
    /// 用量缓存（键是订阅名）。
    ///
    /// 必须留着：`loadSubscriptions` 每次都会拿 UCI 重造一遍数组，`usage` 随之清零。
    /// 没有这份缓存，30 秒内第二次进这一页就会看到「流量没了」——数据其实还在，
    /// 只是被列表刷新冲掉了。
    private var subUsageCache: [String: SubscriptionUsage] = [:]
    /// 落盘的流量快照（v2.4.25），键是**配置文件名全名**（`Aurora.yaml`，小写去空白）。
    ///
    /// 为什么不用订阅名做键：冷启动第一帧订阅列表还没读回来（`loadSubscriptions`
    /// 要等 SSH），`currentConfigSubscription` 是 nil，按名字什么都查不到；
    /// 而配置文件全名——`oc.config` 一去扩展名就能比，`oc.config` 本身没探测到时
    /// 退回上次读成功时记下的那个——**第一帧就拿得到**。所以这份缓存只能按文件名存。
    private var usageSnapshots: [String: StoredUsage] = AppModel.loadUsageSnapshots()
    /// 上一次读成功时用的配置文件名全名（落盘）。冷启动 `oc.config` 还没回来的那几秒靠它。
    ///
    /// 界面也会拿它当标题（`configTitle`）：那几秒卡片下面已经画出缓存流量了，
    /// 标题还写「读取中…」会显得自相矛盾。
    private(set) var lastConfigFileName: String? = AppModel.loadLastConfigName()
    /// 「2 秒后再去拉」的定时任务。重复调度直接取消重排，
    /// 所以页面挂载、连接完成两声铃不会变成两次请求。
    @ObservationIgnored private var usageAutoTask: Task<Void, Never>?
    /// 弹窗里的操作结果（成功/失败/进行中的说明）。见 `Notice` 的注释：
    /// 弹窗里没有系统 alert 可用，`errorMessage` 又只在登录页/设置页渲染，
    /// 所以订阅相关的每一步都必须往这里写一条，否则界面看起来「什么都没发生」。
    var notice: Notice?
    var accessChecks = AccessCheck.Site.allCases.map { AccessCheck(site: $0) }
    var history: [HistoryPoint] = []
    var profiles: [RouterProfile] = []
    var currentProfileID: UUID?
    var moduleOrder: [OverviewModule] = OverviewModule.allCases
    var hiddenModules: Set<OverviewModule> = []
    /// 采集配置：现在只有一个全局刷新间隔，改完立即生效。
    var pollConfig: PollConfiguration = PollConfiguration() {
        didSet {
            // @Observable 下 didSet 可能被调用两次（已知问题），这里用 oldValue 挡住，
            // 否则会重复 startPolling()，白白多发一轮 SSH 采集。
            guard pollConfig != oldValue else { return }
            pollConfig.save()
            if connected { startPolling() }
        }
    }
    /// 当前在看的标签页。采集只跟着它走：切到设置页就完全停下。
    private(set) var activePage: AppPage = .overview

    private var ssh = SSHService()
    /// 正在尝试建立的新会话：成功之后才顶替掉 `ssh`，
    /// 失败或用户中途停止时旧会话还活着，界面可以直接退回上一台路由器。
    private var attemptService: SSHService?
    /// 这次尝试开始时连着谁，用来失败/取消后回滚。
    private var attemptFallback: (profileID: UUID?, password: String?, connected: Bool)?
    /// 当前 SSH 会话实际连的是哪个连接（不是「选中」的那个），
    /// 回滚时以它为准，避免把刚点到一半的新连接当成上一台。
    private var sessionProfileID: UUID?
    /// 尝试序号：取消后旧任务收尾时据此判断自己是否已经过期。
    private var attemptToken = 0
    /// 上一次连接尝试是否失败（不是取消），弹窗据此决定显示失败还是成功。
    private(set) var lastConnectFailed = false
    /// 这次尝试的目标。失败回滚后 `currentProfile` 已经变回上一台了，
    /// 弹窗的标题和「重试」得靠它，不能用 currentProfile。
    private(set) var attemptTarget: (profile: RouterProfile, password: String)?
    private var pollTask: Task<Void, Never>?
    /// 错误提示的自动消失计时器。
    private var errorExpiry: Task<Void, Never>?
    /// 网络代理页「拿到状态后跑一次访问检测」的开关，进页面置真、跑完置假。
    private var pendingAccessCheck = false
    /// 最近一次访问检测的时间，界面上用来显示「最近检测 xx:xx」。
    private(set) var lastAccessCheckAt: Date?
    private var activePassword: String?
    private var lastSuccessfulPoll: Date?
    private var lastReconnectAttempt: Date?
    /// CPU / 网速都是「两次读数做差再除以时间」算出来的，所以必须记住上一拍的时间。
    /// 缺了这个时间戳，两轮挨得太近时除的是一个几十毫秒的窗口，占用率会蹦到 100%。
    private var lastCpuTotal: Double?
    private var lastCpuIdle: Double?
    private var lastCpuDate: Date?
    private var lastRx: Double?
    private var lastTx: Double?
    private var lastNetDate: Date?
    /// 上一轮采集的开始时间：切页时用它挡掉「紧接着又来一轮」的重复采集。
    private var lastTickAt: Date?
    private var lastOcPid = ""
    private var lastOcTicks: Double?
    private var lastOcTotal: Double?
    /// /traffic 取不到时的兜底基线：用 /connections 的累计值做差算速度。
    private var lastOcUploadTotal: UInt64?
    private var lastOcDownloadTotal: UInt64?
    private var lastOcTotalDate: Date?

    init() {
        // 这两个有 didSet，必须在 init 里显式赋值（在 init 里赋值不会触发 didSet）。
        autoRemoveOffline = UserDefaults.standard.bool(forKey: Self.autoRemoveKey)
        let storedMinutes = UserDefaults.standard.integer(forKey: Self.offlineMinutesKey)
        offlineRemoveMinutes = storedMinutes > 0 ? storedMinutes : 60
        pollConfig = PollConfiguration.load()
        loadProfiles()
        loadModules()
        loadDeviceAliases()
        loadHiddenDevices()
    }

    // MARK: - 设备别名

    private func aliasKey(_ device: DeviceInfo) -> String {
        let mac = device.mac.trimmingCharacters(in: .whitespaces).uppercased()
        return mac.isEmpty ? device.ip : mac
    }

    /// 列表里显示的名字：改过就用自定义的，没改过就是租约里的主机名。
    func displayName(for device: DeviceInfo) -> String {
        let custom = deviceAliases[aliasKey(device)]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? device.name : custom
    }

    func hasAlias(_ device: DeviceInfo) -> Bool {
        !(deviceAliases[aliasKey(device)] ?? "").isEmpty
    }

    /// 传空串（或与原名相同）就是恢复 DHCP 里的名字。
    func setDeviceAlias(_ name: String, for device: DeviceInfo) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = aliasKey(device)
        if trimmed.isEmpty || trimmed == device.name {
            deviceAliases.removeValue(forKey: key)
        } else {
            deviceAliases[key] = trimmed
        }
        UserDefaults.standard.set(deviceAliases, forKey: "deviceAliases")
    }

    private func loadDeviceAliases() {
        if let stored = UserDefaults.standard.dictionary(forKey: "deviceAliases") {
            deviceAliases = stored.compactMapValues { $0 as? String }
        }
    }

    // MARK: - 删掉离线设备

    /// 当前列表里还能删的（离线的）设备有几台。
    var offlineDeviceCount: Int {
        devices.filter { !$0.online }.count
    }

    /// 删掉指定的设备。**只对离线的生效**——在线的点删除会被忽略，
    /// 免得手滑把正在用的设备从列表里抹掉（它其实也没法「删」，
    /// 租约还在、设备还在连，下一轮采集就会回来）。
    func removeDevices(_ targets: [DeviceInfo]) {
        let now = Date()
        var removed = false
        for device in targets where !device.online {
            let key = aliasKey(device)
            hiddenDeviceKeys[key] = now
            offlineSince.removeValue(forKey: key)
            removed = true
        }
        guard removed else { return }
        saveHiddenDevices()
        applyDeviceVisibility()
    }

    /// 把删掉的设备全放回来。设备下次上线其实也会自动回来，
    /// 这个入口是给「手滑删错」留的后路。
    func restoreHiddenDevices() {
        guard !hiddenDeviceKeys.isEmpty else { return }
        hiddenDeviceKeys.removeAll()
        offlineSince.removeAll()
        saveHiddenDevices()
        applyDeviceVisibility()
    }

    /// 采集结果 → 可见列表。被删掉的、还没上线的都不进来。
    private func applyDeviceVisibility() {
        devices = allDevices.filter { hiddenDeviceKeys[aliasKey($0)] == nil }
    }

    private func loadHiddenDevices() {
        hiddenDeviceKeys = Self.loadDateMap(Self.hiddenDevicesKey)
        offlineSince = Self.loadDateMap(Self.offlineSinceKey)
        hiddenDeviceCount = hiddenDeviceKeys.count
    }

    private func saveHiddenDevices() {
        UserDefaults.standard.set(hiddenDeviceKeys.mapValues { $0.timeIntervalSince1970 },
                                  forKey: Self.hiddenDevicesKey)
        UserDefaults.standard.set(offlineSince.mapValues { $0.timeIntervalSince1970 },
                                  forKey: Self.offlineSinceKey)
        hiddenDeviceCount = hiddenDeviceKeys.count
    }

    private static func loadDateMap(_ key: String) -> [String: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var result: [String: Date] = [:]
        for (name, value) in stored {
            if let seconds = value as? Double {
                result[name] = Date(timeIntervalSince1970: seconds)
            }
        }
        return result
    }

    var currentProfile: RouterProfile? {
        profiles.first { $0.id == currentProfileID }
    }

    var visibleModules: [OverviewModule] {
        moduleOrder.filter { !hiddenModules.contains($0) }
    }

    func isVisible(_ module: OverviewModule) -> Bool {
        !hiddenModules.contains(module)
    }

    func setModule(_ module: OverviewModule, visible: Bool) {
        if visible { hiddenModules.remove(module) } else { hiddenModules.insert(module) }
        saveModules()
    }

    func moveModules(from source: IndexSet, to destination: Int) {
        moduleOrder.move(fromOffsets: source, toOffset: destination)
        saveModules()
    }

    func resetModules() {
        moduleOrder = OverviewModule.allCases
        hiddenModules = []
        saveModules()
    }

    // MARK: - Connections

    func connect(host: String, port: Int, user: String, password: String,
                 label: String = "", webPort: Int = 80) async {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !password.isEmpty else {
            presentError("请填写路由器地址和密码")
            return
        }

        var profile: RouterProfile
        if let index = profiles.firstIndex(where: {
            $0.host == cleanHost && $0.port == port && $0.user == user
        }) {
            profile = profiles[index]
            if !label.isEmpty { profile.label = label }
            profile.webPort = webPort
            profiles[index] = profile
        } else {
            profile = RouterProfile(label: label, host: cleanHost, port: port,
                                    user: user, webPort: webPort)
            profiles.append(profile)
        }
        currentProfileID = profile.id
        saveProfiles()
        // 密码一律存：启动时自动连接是默认行为，不再有「记住了但不自动连」这种状态。
        KeychainStore.savePassword(
            password,
            account: KeychainStore.passwordAccount(for: profile)
        )
        // 保存就保存了：连不上的时候也留在列表里，用户改完再试，
        // 「重试」也有个确定的目标可指。
        await connect(profile: profile, password: password)
    }

    /// 发起一次连接。
    ///
    /// 旧版本一上来就 `disconnect()`，于是「新建连接」一旦失败或者卡住，
    /// 原来那台路由器也没了、只能掉回登录页。现在旧会话会一直留到新会话
    /// 握手成功的那一刻才关闭：失败、超时、用户中途停止，都能原样退回上一台。
    /// - Returns: 新会话是否真的连上了。
    @discardableResult
    func connect(profile: RouterProfile, password: String) async -> Bool {
        attemptToken += 1
        let token = attemptToken
        attemptFallback = (sessionProfileID, activePassword, connected)
        attemptTarget = (profile, password)

        connecting = true
        lastConnectFailed = false
        clearError()
        status = "正在连接…"

        let attempt = SSHService()
        attemptService = attempt
        do {
            try await attempt.connect(
                host: profile.host,
                port: profile.port,
                user: profile.user,
                password: password
            )
        } catch {
            finishAttempt(token: token, error: error)
            return false
        }
        // 期间用户点了停止（token 已作废），这个会话直接丢弃。
        guard token == attemptToken else { return false }
        attemptService = nil

        // 握手成功，这之后才真正切换过去。
        ssh.disconnect()
        ssh = attempt
        attemptFallback = nil
        attemptTarget = nil
        connecting = false
        lastConnectFailed = false
        clearError()
        currentProfileID = profile.id
        sessionProfileID = profile.id
        connected = true
        activePassword = password
        lastSuccessfulPoll = Date()
        lastReconnectAttempt = nil
        status = "已连接"
        resetSamplingBaselines()
        stats = OverviewStats()
        routerInfo = RouterInfo()
        devices = []
        flashInfo = FlashInfo()
        openClash = OpenClashInfo()
        ocStateLoaded = false
        ocStateLoading = false
        ocMetrics = OpenClashMetrics()
        ocMetricsLoaded = false
        history = []
        await bootstrapRefresh()
        startPolling()
        // 连上时如果正停在网络代理页，同样要补一次访问检测。
        pendingAccessCheck = activePage == .proxy
        return true
    }

    /// 用户点「停止连接」：立刻把状态收回去，别让界面一直等。
    func cancelConnect() {
        guard connecting else { return }
        attemptToken += 1                 // 让这次尝试的收尾逻辑失效
        attemptService?.cancelAttempt()   // 打断卡在 socket 上的连接
        attemptService = nil
        connecting = false
        lastConnectFailed = false
        clearError()
        restoreFallback(cancelled: true)
    }

    private func finishAttempt(token: Int, error: Error) {
        guard token == attemptToken else { return }
        attemptService = nil
        connecting = false
        if case AppError.cancelled = error {
            clearError()
            lastConnectFailed = false
            restoreFallback(cancelled: true)
        } else {
            presentError(describe(error), seconds: 12)
            lastConnectFailed = true
            restoreFallback(cancelled: false)
        }
    }

    /// 回到尝试前的状态。旧会话没被拆掉的话，`connected` 依然是 true，直接可用。
    private func restoreFallback(cancelled: Bool) {
        guard let fallback = attemptFallback else {
            connected = false
            status = cancelled ? "已取消连接" : "连接失败"
            return
        }
        attemptFallback = nil
        guard fallback.connected else {
            // 本来就没连上（登录页/首次连接）：保持选中项不动，让用户接着改地址。
            connected = false
            status = cancelled ? "已取消连接" : "连接失败"
            return
        }
        if let id = fallback.profileID { currentProfileID = id }
        sessionProfileID = fallback.profileID
        activePassword = fallback.password
        connected = true
        lastReconnectAttempt = nil
        lastSuccessfulPoll = Date()
        status = "已连接"
    }

    private func describe(_ error: Error) -> String {
        // 旧版这里把 NSError 的 domain / code 和 `String(describing:)` 一起拼进去，
        // 界面上就是三行「连接超时…\n[OpenWrtMonitor.AppError 0]\nAppError.message(...)」，
        // 又长又不像是给人看的。这里只给一句人话。
        if let app = error as? AppError {
            switch app {
            case .notConnected: return "SSH 会话已断开"
            case .cancelled: return "已取消连接"
            case .message(let text): return text
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "网络请求失败：\(ns.localizedDescription)"
        }
        let text = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "操作失败，请重试" : text
    }

    /// 统一出口：设置错误并且**自动过期**。
    ///
    /// 以前 `errorMessage` 只在「下一次连接成功」时被清掉，于是连接失败后那行红字
    /// 会一直挂在设置页上，除非退出 App 重进。现在 8 秒后自动淡出，
    /// 用户也可以点右边的叉立刻收掉。
    func presentError(_ message: String, seconds: Double = 8) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorMessage = text
        // 顺手镜像一份到弹窗提示：登录页之外没有视图渲染 errorMessage，
        // 在 sheet 里报错就等于静音（v2.1.0「点更新没反应」的根因）。
        notice = Notice(kind: .fail, title: "出错了", detail: text)
        errorExpiry?.cancel()
        errorExpiry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.errorMessage == text { self.errorMessage = nil }
            if self.notice?.detail == text { self.notice = nil }
        }
    }

    func clearNotice() {
        notice = nil
    }

    func clearError() {
        errorExpiry?.cancel()
        errorExpiry = nil
        errorMessage = nil
    }

    func autoConnectIfPossible() async {
        guard !connected, let profile = currentProfile,
              let password = KeychainStore.loadPassword(
                account: KeychainStore.passwordAccount(for: profile)
              ) else { return }
        await connect(profile: profile, password: password)
    }

    func switchTo(_ profile: RouterProfile) async {
        guard let password = KeychainStore.loadPassword(
            account: KeychainStore.passwordAccount(for: profile)
        ) else {
            presentError("这个连接没有保存密码，请点「编辑」重新填一次")
            return
        }
        currentProfileID = profile.id
        saveProfiles()
        await connect(profile: profile, password: password)
    }

    func saveNewProfile(host: String, port: Int, user: String,
                        password: String, label: String, webPort: Int = 80) async {
        await connect(host: host, port: port, user: user, password: password,
                      label: label, webPort: webPort)
    }

    func updateProfile(_ profile: RouterProfile, host: String, port: Int,
                       user: String, password: String, label: String,
                       webPort: Int) async {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profiles[index]
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.host = cleanHost
        updated.port = port
        updated.user = user
        updated.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.webPort = webPort
        profiles[index] = updated
        currentProfileID = updated.id
        saveProfiles()
        KeychainStore.savePassword(
            password,
            account: KeychainStore.passwordAccount(for: updated)
        )
        await connect(profile: updated, password: password)
    }

    var currentPassword: String? {
        if let activePassword { return activePassword }
        guard let currentProfile else { return nil }
        return KeychainStore.loadPassword(
            account: KeychainStore.passwordAccount(for: currentProfile)
        )
    }

    var routerWebURL: URL? {
        guard let profile = currentProfile else { return nil }
        return URL(string: "http://\(profile.host):\(profile.webPortValue)/")
    }

    func deleteProfile(_ profile: RouterProfile) {
        KeychainStore.deletePassword(account: KeychainStore.passwordAccount(for: profile))
        // 删掉的正好是当前会话时，SSH 其实还连着那台：不断开的话界面会停在
        // 「已连接」上，可它已经不在列表里了，重连、刷新、编辑全都指向空。
        let wasSession = profile.id == sessionProfileID
        profiles.removeAll { $0.id == profile.id }
        if currentProfileID == profile.id {
            currentProfileID = profiles.first?.id
        }
        saveProfiles()
        if wasSession {
            // keepPassword 为真：这个连接的密码上面已经删了，
            // 别让 disconnect 顺手把「新选中的那条」的密码也删掉。
            Task { await disconnect(keepPassword: true) }
        }
    }

    func disconnect(keepPassword: Bool = false) async {
        pollTask?.cancel()
        pollTask = nil
        pendingAccessCheck = false
        ssh.disconnect()
        attemptService?.cancelAttempt()
        attemptService = nil
        attemptToken += 1
        attemptFallback = nil
        attemptTarget = nil
        connected = false
        reconnecting = false
        busy = false
        connecting = false
        lastConnectFailed = false
        activePassword = nil
        sessionProfileID = nil
        lastSuccessfulPoll = nil
        lastReconnectAttempt = nil
        status = "未连接"
        resetSamplingBaselines()
        // 断开之后这些状态就不再可信了：留着的话下次连上别的路由器，
        // 代理页会先拿上一台的插件状态和配置列表糊一遍。
        openClash = OpenClashInfo()
        ocStateLoaded = false
        ocStateLoading = false
        ocMetricsLoaded = false
        if !keepPassword, let profile = currentProfile {
            KeychainStore.deletePassword(account: KeychainStore.passwordAccount(for: profile))
        }
    }

    /// 清掉所有「跟上一台路由器/上一秒」相关的增量基线。
    /// 换会话时必须清零，否则第一轮的速度/CPU 会拿新旧两台做差，蹦出离谱的数字。
    private func resetSamplingBaselines() {
        lastCpuTotal = nil
        lastCpuIdle = nil
        lastCpuDate = nil
        lastRx = nil
        lastTx = nil
        lastNetDate = nil
        lastTickAt = nil
        lastOcPid = ""
        lastOcTicks = nil
        lastOcTotal = nil
        lastOcUploadTotal = nil
        lastOcDownloadTotal = nil
        lastOcTotalDate = nil
    }

    /// 有系统浮层（相册选择器 / 裁切页）盖在屏幕上时为真。
    ///
    /// 这期间不做「回前台恢复连接」：换壁纸跟路由器一点关系都没有，而重连会把
    /// 根视图整套换掉——系统选择器被顺手关掉，用户翻相册翻到一半就跳回顶部
    /// （v2.4.11 用户反馈的第一条）。
    ///
    /// 只在 `resumeAfterForeground()` 和下面的 `setModalActive` 里读写，
    /// 不进任何视图的 `body`，所以不会多出一次刷新。
    private var modalActive = false

    /// 浮层的开与关都由背景卡报过来。
    func setModalActive(_ value: Bool) {
        guard value != modalActive else { return }
        modalActive = value
        // 收起时把轮询接回来：后台暂停过（pausePolling）就靠这一句续上，
        // 当前页没有周期项时 `startPolling` 自己会直接返回。
        if !value, connected, pollTask == nil { startPolling() }
    }

    func resumeAfterForeground() async {
        guard connected else { return }
        // 系统浮层盖着：别重连、也别重开轮询，交给浮层收起时那句。
        guard !modalActive else { return }
        if let lastSuccessfulPoll,
           Date().timeIntervalSince(lastSuccessfulPoll) < 10 {
            startPolling()
            return
        }
        await reconnect(force: true)
    }

    func manualRefresh() async {
        guard connected else { return }
        if status == "连接中断" || reconnecting ||
            (lastSuccessfulPoll.map { Date().timeIntervalSince($0) > 12 } ?? true) {
            await reconnect(force: true)
            return
        }
        await bootstrapRefresh()
    }

    func reconnect(force: Bool) async {
        // 正在「新建/切换连接」时别插一脚：那会儿 currentProfile 可能已经指向新连接，
        // 抢着重连会把旧会话搅乱。
        guard !reconnecting, !connecting, let profile = currentProfile else { return }
        if !force, let lastReconnectAttempt,
           Date().timeIntervalSince(lastReconnectAttempt) < 5 {
            return
        }
        guard let password = activePassword ?? KeychainStore.loadPassword(
            account: KeychainStore.passwordAccount(for: profile)
        ) else {
            return
        }

        lastReconnectAttempt = Date()
        reconnecting = true
        do {
            try await ssh.connect(
                host: profile.host,
                port: profile.port,
                user: profile.user,
                password: password
            )
            activePassword = password
            sessionProfileID = profile.id
            connected = true
            await bootstrapRefresh()
            startPolling()
            reconnecting = false
            lastReconnectAttempt = nil
            status = "已连接"
            clearError()
        } catch {
            reconnecting = false
            status = "连接中断"
            presentError(describe(error), seconds: 12)
            if connected {
                startPolling()
            }
        }
    }

    func logout() async {
        await disconnect(keepPassword: false)
        for profile in profiles {
            KeychainStore.deletePassword(account: KeychainStore.passwordAccount(for: profile))
        }
        profiles = []
        currentProfileID = nil
        saveProfiles()
        stats = OverviewStats()
        routerInfo = RouterInfo()
        devices = []
        history = []
    }

    // MARK: - SSH

    func execute(_ command: String, timeout: TimeInterval = 30) async throws -> String {
        try await ssh.execute(command, timeout: timeout)
    }

    // MARK: - Polling
    //
    // 采集跟着页面走：只有当前标签页要用的数据才会被采集，切到设置页就完全停下，
    // 路由器不用替一个看不见的界面干活。同一次刷新里的所有项拼成**一条**命令、
    // 一个 shell 跑完，全部以 nice -n 19 执行，所以进程数不会随项数增加。

    /// 当前页面要采集的数据项。
    var activeItems: [PollItem] {
        pollConfig.items(on: activePage)
    }

    /// 当前页面上会反复采集的项（OpenClash 配置只在进页面时取一次）。
    private var periodicItems: [PollItem] {
        activeItems.filter(\.isPeriodic)
    }

    var pollSeconds: Double { pollConfig.clampedSeconds }

    func setPollSeconds(_ value: Double) {
        var config = pollConfig
        config.setSeconds(value)
        pollConfig = config
    }

    /// 切换标签页：立刻为这一页取一次数据，然后按新的一组项继续轮询。
    func setActivePage(_ page: AppPage) {
        guard page != activePage else { return }
        // 离开网络代理页就把还没跑的自动检测作废，别在别的页面上偷偷跑 curl。
        pendingAccessCheck = page == .proxy
        activePage = page
        // 上一页的轮询先停下：切页的空窗里不该还在采别的数据。
        pollTask?.cancel()
        pollTask = nil
        guard connected else { return }
        guard page == .proxy else {
            startPolling(refreshNow: true)
            return
        }
        // 先单独问一次 OpenClash 状态，拿到就画按钮，然后才开周期采集。
        //
        // 这一条只有 pidof + 几次 uci，比那条要 curl 内核接口的指标命令快一个数量级；
        // 混在一起跑，就会出现「流量已经动起来了、启动/关闭/重启还不见」的样子。
        ocStateLoading = true
        Task {
            await self.runOpenClashProbe()
            // 探针跑完时用户可能已经切走了：那就别再按「代理页」的节奏重开轮询，
            // 目标页自己的 startPolling 已经在跑了。
            guard self.activePage == .proxy else { return }
            self.startPolling(refreshNow: true)
            // v2.4.22：配置已经读回来了，顺手把订阅流量也拉一次——
            // 用户不该为了看几个数字先点一次刷新。
            // v2.4.25：改成延迟 2 秒排队，先把落盘缓存画出来再更新。
            self.scheduleAutoLoadSubscriptionUsage()
        }
    }

    /// 只问「装没装、跑的哪个模式、有哪些配置」，不碰流量。
    ///
    /// 它决定网络代理页顶部那两排按钮和配置条能不能画出来。
    /// 失败不弹红字——大概率只是 SSH 通道正忙着，下一轮轮询会自己补上。
    private func runOpenClashProbe() async {
        defer { ocStateLoading = false }
        try? await runItems([.clashState])
    }

    /// 轮询循环：固定间隔，跑的永远是当前页面的那一组数据。
    ///
    /// 切页后的「立刻取一次」曾经和循环的第一拍紧挨着跑——两轮之间只隔了几十毫秒，
    /// 而 CPU / 网速都是拿两次读数做差算的，短窗口算出来的就是噪声，于是每点一次
    /// 概览，CPU 就蹦到 100%。现在先取一次、睡满一个间隔，再进循环。
    private func startPolling(refreshNow: Bool = false) {
        pollTask?.cancel()
        pollTask = nil
        guard !periodicItems.isEmpty else { return }
        // 上一轮刚跑完（比如切页切得很快）就不再插队，直接进循环。
        let justPolled = lastTickAt.map { Date().timeIntervalSince($0) < 0.8 } ?? false
        // 但「只取一次」的那项不能跟着一起挡：上一轮跑的是别的页面的周期采集，
        // 挡掉之后 OpenClash 的状态和配置列表就一直是空的，按钮要等一整轮才出来。
        let needOnce = activePage == .proxy && !ocStateLoaded
        let immediate = refreshNow && (!justPolled || needOnce)
        pollTask = Task { [weak self] in
            guard let self else { return }
            if immediate {
                await self.pollTick(includeOnce: true)
                if Task.isCancelled { return }
            }
            while !Task.isCancelled {
                let interval = self.pollSeconds
                // 刚采过（切页那一拍、或者连接后的首次填充）就把这一拍等满，
                // 绝不在一个间隔里连着采两次。
                if let last = self.lastTickAt {
                    let wait = interval - Date().timeIntervalSince(last)
                    if wait > 0.2 { try? await Task.sleep(for: .seconds(wait)) }
                }
                if Task.isCancelled { return }
                let started = Date()
                // 状态探针要是没跑成（通道当时正忙），每一拍都捎上它，
                // 直到拿到为止——否则按钮会一直缺着，直到下次切页。
                await self.pollTick(includeOnce: self.activePage == .proxy && !self.ocStateLoaded)
                if Task.isCancelled { return }
                // 这一轮本身要花时间（/traffic 是流式接口，至少一秒才吐第一行），
                // 把耗时从间隔里扣掉，实际刷新节奏才和用户设置的一致。
                let remaining = interval - Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(Int(max(0.25, remaining) * 1000)))
            }
        }
    }

    /// App 进入后台时停掉轮询，回前台由 resumeAfterForeground() 重新拉起。
    func pausePolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 连接后的首次填充：先取当前页面的数据（界面立刻有数字），再补静态信息。
    private func bootstrapRefresh() async {
        do {
            try await runItems(activeItems)
            lastTickAt = Date()
            lastSuccessfulPoll = Date()
        } catch {
            status = "连接中断"
            return
        }
        await refreshInfo()
    }

    /// 一轮：把当前页面要采集的项拼成一条命令发出去。
    /// includeOnce 为真时连「只在进页面时取」的项一起跑（切页后的第一轮）。
    private func pollTick(includeOnce: Bool = false) async {
        guard connected else { return }
        var items = includeOnce ? activeItems : periodicItems
        // 进页面时那条独立的探针已经问过（或正在问）状态了，这一拍不用再问一遍。
        if includeOnce, ocStateLoaded || ocStateLoading {
            items = items.filter { $0 != .clashState }
        }
        guard !items.isEmpty else { return }
        lastTickAt = Date()
        do {
            try await runItems(items)
            lastSuccessfulPoll = Date()
            if !connecting, status != "已连接" { status = "已连接" }
            // 网络代理页：第一次拿到状态之后，顺手跑一次访问检测，
            // 省得进页面还得自己点一下「重新检测」。
            if activePage == .proxy, pendingAccessCheck {
                pendingAccessCheck = false
                Task { await self.checkAccess(silent: true) }
            }
        } catch {
            // 正在连新连接时，旧会话的报错别去动界面状态。
            if connecting { return }
            status = "连接中断"
            if !reconnecting, activePassword != nil {
                Task { await self.reconnect(force: false) }
            }
        }
    }

    /// 跑一组数据项。OpenClash 状态和它的指标必须分成两条命令：
    /// 指标里要用的端口和密钥，来自状态查询的结果。
    private func runItems(_ items: [PollItem]) async throws {
        guard !items.isEmpty else { return }
        let stateItems = items.filter { $0 == .clashState }
        let otherItems = items.filter { $0 != .clashState }
        if !stateItems.isEmpty {
            apply(parseSections(try await execute(command(for: stateItems))), items: stateItems)
        }
        if !otherItems.isEmpty {
            apply(parseSections(try await execute(command(for: otherItems))), items: otherItems)
        }
    }

    private func apply(_ sections: [String: String], items: [PollItem]) {
        if items.contains(.core) { applyCore(sections) }
        if items.contains(.sensors) {
            updateSensors(temp: sections["TEMP"] ?? "",
                          fan: sections["FAN"] ?? "",
                          pwm: sections["FANPWM"] ?? "")
        }
        if items.contains(.flash) { updateFlash(sections["FLASH"] ?? "") }
        if items.contains(.devices) { updateDevices(sections) }
        if items.contains(.clashState) {
            openClash = parseOpenClashInfo(sections, current: openClash)
        }
        if items.contains(.clashTraffic) || items.contains(.clashConnections) {
            applyClashPresence(sections)
            applyMetrics(sections)
        }
    }

    /// 指标脚本里自带 pidof 和面板端口，所以每轮都能自己确认运行状态，
    /// 不用等状态档先跑过——旧版这里就是「流量和内核状态一直不更新」的根源。
    private func applyClashPresence(_ sections: [String: String]) {
        var info = openClash
        let state = firstLine(sections["OCSTATE"])
        if !state.isEmpty {
            info.installed = ["running", "stopped", "installed"].contains(state)
            info.running = state == "running"
            // 插件确实不存在时，就不用再等状态查询了：结果已经是确定的。
            if state == "missing" { ocStateLoaded = true }
        }
        if let port = Int(firstLine(sections["OCPORT"])), port > 0 {
            info.panelPort = port
        }
        if sections["OCSECRET"] != nil {
            info.secret = firstLine(sections["OCSECRET"])
        }
        info.panelURL = buildPanelURL(info)
        openClash = info
    }

    private func applyCore(_ sections: [String: String]) {
        updateCPU(sections["STAT"] ?? "")
        updateMemory(sections["MEMINFO"] ?? "")
        let wan = parseWanDevice(sections["ROUTE"] ?? "")
        if !wan.isEmpty, wan != stats.wanDevice {
            stats.wanDevice = wan
            lastRx = nil
            lastTx = nil
            lastNetDate = nil
        }
        updateNetwork(sections["DEV"] ?? "")
        if let value = firstLine(sections["UPTIME"]).split(separator: " ").first,
           let uptime = Double(value) {
            stats.uptime = uptime
        }
        let loadValues = firstLine(sections["LOADAVG"])
            .split(separator: " ")
            .compactMap { Double($0) }
        if loadValues.count >= 1 { stats.load = loadValues[0] }
        if loadValues.count >= 2 { stats.load5 = loadValues[1] }
        if loadValues.count >= 3 { stats.load15 = loadValues[2] }
        appendHistory()
    }

    /// OpenClash 指标：/traffic 和 /connections 可能只成功一个，哪段有就更新哪段，
    /// 缺的部分保持上一次的值，不会因为一次失败就把数字清成 0。
    private func applyMetrics(_ sections: [String: String]) {
        var value = ocMetrics
        var reachable = false
        let now = Date()

        var gotConnectionTotal = false
        if let data = json(sections["CONN"]) {
            value.uploadTotal = UInt64(number(data["uploadTotal"]) ?? 0)
            value.downloadTotal = UInt64(number(data["downloadTotal"]) ?? 0)
            if let rows = data["connections"] as? [[String: Any]] {
                value.connections = rows.count
            }
            gotConnectionTotal = true
            reachable = true
        }

        var gotTraffic = false
        if let data = json(sections["TRAFFIC"]),
           let up = number(data["up"]), let down = number(data["down"]) {
            value.upload = up
            value.download = down
            gotTraffic = true
            reachable = true
        }

        // /traffic 是每秒一行的流式接口，部分固件上 curl/wget 会被砍断、或干脆没有这个接口。
        // 这时用 /connections 的累计值做差补一个速度，界面至少还在动，
        // 而不是永远停在 0（连接关闭时累计值会回落，负数按 0 处理）。
        if !gotTraffic, gotConnectionTotal {
            if let lastUp = lastOcUploadTotal, let lastDown = lastOcDownloadTotal,
               let lastDate = lastOcTotalDate {
                let elapsed = now.timeIntervalSince(lastDate)
                if elapsed >= 0.5, elapsed <= 30 {
                    value.upload = Double(value.uploadTotal > lastUp
                                          ? value.uploadTotal - lastUp : 0) / elapsed
                    value.download = Double(value.downloadTotal > lastDown
                                            ? value.downloadTotal - lastDown : 0) / elapsed
                }
            }
        }
        if gotConnectionTotal {
            lastOcUploadTotal = value.uploadTotal
            lastOcDownloadTotal = value.downloadTotal
            lastOcTotalDate = now
        }

        if let status = sections["OCSTATUS"] {
            let memory = parseVmRSS(status)
            if memory > 0 { value.memory = memory }
        }
        if sections["OCSTAT"] != nil, sections["SYSTAT"] != nil {
            updateCoreCPU(sections, into: &value)
        }
        // 负载取 5 分钟均值除以核数，跟指标同一条命令取回来，不额外 fork。
        let load = firstLine(sections["LOADAVG"])
            .split(separator: " ")
            .compactMap { Double($0) }
        if load.count >= 2 {
            let cores = max(1, Double(routerInfo.cpuCores > 0 ? routerInfo.cpuCores : 1))
            value.load = max(0, load[1] / cores * 100)
        }
        value.apiReachable = reachable
        ocMetrics = value
        ocMetricsLoaded = true
    }

    /// JSONSerialization 出来的数字都是 NSNumber，统一走这里取，整数也能取到。
    private func number(_ any: Any?) -> Double? {
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? Double { return value }
        return nil
    }
    func refreshInfo() async {
        do {
            let sections = parseSections(try await execute(infoCommand))
            var value = RouterInfo()
            value.model = firstLine(sections["MODEL"])
            value.hostname = firstLine(sections["HOST"])
            value.kernel = firstLine(sections["KERNEL"])
            value.architecture = firstLine(sections["ARCH"])
            // 核数在路由器上数好再传上来，省得把 /proc/cpuinfo 整段搬过来再逐行扫。
            value.cpuCores = Int(firstLine(sections["CPUCORES"])) ?? 0
            value.firmware = parseRelease(sections["RELEASE"] ?? "")
            routerInfo = value
            let wan = parseWanDevice(sections["ROUTE"] ?? "")
            if !wan.isEmpty { stats.wanDevice = wan }
        } catch {
            // 静态信息拿不到就先不显示，别把连接状态改成错误
        }
    }

    func refreshOpenClash() async {
        do {
            let sections = parseSections(try await execute(command(for: [.clashState])))
            openClash = parseOpenClashInfo(sections, current: openClash)
        } catch {
            presentError(describe(error))
        }
    }

    func startOpenClash() async {
        if openClash.running {
            clearError()
            status = "OpenClash 已启动"
            return
        }
        await action("uci -q set openclash.config.enable='1'; uci -q commit openclash; /etc/init.d/openclash start >/dev/null 2>&1; echo done",
                     title: "正在启动", subtitle: "正在启动 OpenClash…")
    }

    func stopOpenClash() async {
        if !openClash.running {
            clearError()
            status = "OpenClash 已关闭"
            return
        }
        await action("uci -q set openclash.config.enable='0'; uci -q commit openclash; /etc/init.d/openclash stop >/dev/null 2>&1; echo done",
                     title: "正在关闭", subtitle: "正在停止 OpenClash…")
    }

    func restartOpenClash() async {
        await action("uci -q set openclash.config.enable='1'; uci -q commit openclash; /etc/init.d/openclash restart >/dev/null 2>&1; echo done",
                     title: "正在重启", subtitle: "正在重启 OpenClash…")
    }

    func switchMode(_ mode: String) async {
        await action("uci -q set openclash.config.proxy_mode='\(mode)'; uci -q set 'openclash.@overwrite[0].proxy_mode'='\(mode)'; uci -q commit openclash; /etc/init.d/openclash restart >/dev/null 2>&1; echo done",
                     title: "正在切换模式", subtitle: "正在应用新的代理模式…")
    }

    func switchConfig(_ name: String) async {
        guard !name.isEmpty, !name.contains("'") else { return }
        await action("uci -q set openclash.config.config_path='/etc/openclash/config/\(name)'; uci -q set openclash.config.enable='1'; uci -q commit openclash; /etc/init.d/openclash restart >/dev/null 2>&1; echo done",
                     title: "正在切换配置", subtitle: "正在应用新的配置文件…")
    }

    // MARK: - 订阅

    /// 正在跑的那份配置文件名（`吹雪云.yaml`）。判断「更新会不会重启内核」要用它。
    var currentConfigName: String {
        openClash.config.isEmpty ? "" : (openClash.config as NSString).lastPathComponent
    }

    /// 订阅名不能重复：重名会写到同一个 yaml 上，互相覆盖。
    func subscriptionNameTaken(_ name: String, excluding id: String?) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return subscriptions.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    func loadSubscriptions(silent: Bool = false) async {
        guard connected else { return }
        do {
            let sections = parseSections(try await execute(subscriptionsCommand))
            guard sections["OCSUBS"] != nil else { return }
            var parsed = parseSubscriptions(sections["OCSUBS"] ?? "")
            // 还没落盘的开关改动优先：读回来是旧值就按用户点的那个走，
            // 读回来跟他点的一致说明路由器已经替我们保存好了，这才放手。
            var confirmed: [String] = []
            for (id, on) in pendingEnabled {
                guard let index = parsed.firstIndex(where: { $0.id == id }) else { continue }
                if parsed[index].enabled == on {
                    confirmed.append(id)
                } else {
                    parsed[index].enabled = on
                }
            }
            for id in confirmed { pendingEnabled[id] = nil }
            // 重造的数组没有 usage，从缓存补回来（见 `subUsageCache` 的注释）。
            for index in parsed.indices {
                parsed[index].usage = subUsageCache[parsed[index].name]
            }
            subscriptions = parsed
            subsLoaded = true
        } catch {
            if !silent { presentError(describe(error)) }
        }
    }

    /// 读每条订阅的流量与到期。
    ///
    /// 走的路子和 OpenClash 网页后台完全一样（`fetch_sub_info`）：对所有启用的订阅
    /// **并发**跑 `curl -sLI -X GET`，只取响应头里的 `subscription-userinfo` 那一行。
    /// 串行跑四条就是三十秒，所以命令里每条都挂 `&`，最后 `wait`。
    /// 请求从路由器发出（不是手机），机场看到的是路由器的出口 IP，和更新订阅时一致。
    /// 当前配置文件对应的那条订阅。
    ///
    /// OpenClash 的约定是「订阅名 = 产物文件名」（`/etc/openclash/config/<name>.yaml`），
    /// 所以拿 `oc.config` 的 basename 去掉扩展名去比订阅名就能对上。
    /// 配置文件也可能是手动放的（不来自任何订阅），那时返回 nil，卡片上就不显示流量。
    var currentConfigSubscription: ProxySubscription? {
        let file = (openClash.config as NSString).lastPathComponent
        guard !file.isEmpty, !openClash.config.isEmpty else { return nil }
        let stem = (file as NSString).deletingPathExtension
        // 去扩展名后直接比；再给一层「忽略大小写与首尾空白」的宽匹配——
        // 有人订阅名写成 `Aurora Sub`、文件却叫 `aurora sub.yaml`，严格比会匹配不上，
        // 那卡片就永远是空的，还看不出是为什么。
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let target = normalize(stem)
        return subscriptions.first { normalize($0.name) == target }
            ?? subscriptions.first { normalize($0.name) == normalize(file) }
    }

    /// 读**当前配置文件那一条**订阅的流量与到期（v2.4.21）。
    ///
    /// 不再遍历所有订阅：五条订阅就是五次对外请求，而卡片上只展示当前在用的那条，
    /// 其余四条纯属白打机场接口（还慢）。要全部刷新就把当前配置切过去。
    ///
    /// 走的路子和 OpenClash 网页后台一样（`fetch_sub_info`）：只取响应头里的
    /// `subscription-userinfo`。请求从路由器发出，机场看到的出口 IP 与更新订阅时一致。
    func loadSubscriptionUsages(force: Bool = false) async {
        guard connected, !subUsageLoading else { return }
        // 进页面时 `oc.config` 可能还没读回来（OpenClash 探针是异步的），
        // 这时候按名字匹配会得到 nil，等于静默不拉。补一次探针再匹配。
        if openClash.config.isEmpty { await runOpenClashProbe() }
        guard let sub = currentConfigSubscription else {
            subUsageError = "当前配置不是来自订阅"
            return
        }
        if !force, let last = subUsageFetchedAt, Date().timeIntervalSince(last) < 30,
           sub.usage != nil {
            return
        }
        subUsageLoading = true
        subUsageAttemptAt = Date()
        subUsageError = nil
        defer { subUsageLoading = false }
        do {
            let output = try await execute(subscriptionUsageCommand(sub), timeout: 45)
            var header: String?
            var diag = ""
            for raw in output.split(separator: "\n") {
                if raw.hasPrefix("D|") { diag = String(raw.dropFirst(2)); continue }
                // 订阅名里可能有 `|`，所以从**最后**一个分隔符切开。
                guard raw.hasPrefix("U|"), let bar = raw.lastIndex(of: "|") else { continue }
                let body = String(raw[raw.index(after: bar)...])
                if !body.isEmpty { header = body }
            }
            guard let header, let usage = SubscriptionUsage(header: header) else {
                // 明确说清是「没拿到这一行」，而不是静默留白——上一版就是静默，
                // 结果谁也不知道是机场没给、还是命令压根没跑起来。
                subUsageError = diag.isEmpty ? "订阅没有返回流量信息" : diag
                return
            }
            subUsageCache[sub.name] = usage
            var updated = subscriptions
            for index in updated.indices where updated[index].name == sub.name {
                updated[index].usage = usage
            }
            subscriptions = updated
            subUsageFetchedAt = Date()
            subUsageAt = Date()
            // 落盘一份（键是配置文件名全名）。下次冷启动第一帧就有数字可画，
            // 不用再盯着「正在读取流量…」等 SSH 往返。
            if !openClash.config.isEmpty {
                rememberUsage(usage, configFile: (openClash.config as NSString).lastPathComponent)
            }
        } catch {
            subUsageError = "读取超时，点刷新重试"
        }
    }

    // MARK: - 流量缓存（v2.4.25）

    /// 冷启动第一屏要画的那份流量：从落盘缓存按**配置文件名**取。
    ///
    /// 超过 7 天的不画——换过套餐、月度重置过的旧数字比空白更误导人。
    var cachedConfigUsage: SubscriptionUsage? {
        guard let key = cachedConfigKey, let stored = usageSnapshots[key] else { return nil }
        guard Date().timeIntervalSince1970 - stored.savedAt < 7 * 86_400 else { return nil }
        return stored.usage
    }

    /// 缓存键：优先用刚探测到的 `oc.config`，还没探测到就退回上次成功时记下的文件名。
    private var cachedConfigKey: String? {
        let file = (openClash.config as NSString).lastPathComponent
        if !file.isEmpty { return Self.usageKey(file) }
        return lastConfigFileName.map(Self.usageKey)
    }

    /// 卡片上该画什么：真实数据优先，没有就顶一份落盘缓存。
    ///
    /// `subsLoaded` 这个分支是必要的：订阅列表已经读回来却匹配不到订阅，说明当前配置是
    /// 手动放进 `/etc/openclash/config` 的 yaml——这时候不能拿缓存冒充订阅数据
    /// （哪怕文件名恰好和某条历史订阅一样）。而列表还没读回来时必须用缓存，
    /// 因为「还没读」和「没有订阅」是两件完全不同的事。
    var configDisplayUsage: SubscriptionUsage? {
        if let sub = currentConfigSubscription {
            return sub.usage ?? cachedConfigUsage
        }
        return subsLoaded ? nil : cachedConfigUsage
    }

    /// 订阅列表某一行的流量：真实数据优先；当前正在用的那条，数据还没回来时用缓存顶上。
    ///
    /// 只可能命中当前这条——缓存的键是配置文件名，别的订阅对不上。
    func displayUsage(for sub: ProxySubscription) -> SubscriptionUsage? {
        if let usage = sub.usage { return usage }
        guard sub.name == currentConfigSubscription?.name else { return nil }
        return cachedConfigUsage
    }

    /// 写一份落盘快照。键用配置文件名全名，和 `cachedConfigKey` 严格对齐。
    private func rememberUsage(_ usage: SubscriptionUsage, configFile: String) {
        guard !configFile.isEmpty else { return }
        usageSnapshots[Self.usageKey(configFile)] = StoredUsage(usage)
        // 只留最近 12 条：换掉的旧配置留着没用，也别在 UserDefaults 里堆垃圾。
        if usageSnapshots.count > 12 {
            let keep = usageSnapshots.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(12)
            usageSnapshots = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        lastConfigFileName = configFile
        UserDefaults.standard.set(configFile, forKey: Self.lastConfigKey)
        Self.saveUsageSnapshots(usageSnapshots)
    }

    private static let usageStoreKey = "oc.usage.snapshots.v1"
    private static let lastConfigKey = "oc.usage.lastConfig.v1"

    private static func usageKey(_ file: String) -> String {
        file.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadUsageSnapshots() -> [String: StoredUsage] {
        guard let data = UserDefaults.standard.data(forKey: usageStoreKey),
              let decoded = try? JSONDecoder().decode([String: StoredUsage].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveUsageSnapshots(_ value: [String: StoredUsage]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: usageStoreKey)
    }

    private static func loadLastConfigName() -> String? {
        UserDefaults.standard.string(forKey: lastConfigKey)
    }

    /// 自动拉流量的统一入口：**先让界面把缓存画出来，2 秒后再去问机场**（v2.4.25）。
    ///
    /// 为什么不在页面一出现就拉：冷启动那一拍订阅列表、OpenClash 探针、指标采集全挤在
    /// 同一条 SSH 通道上，抢在前面拉流量只会让第一屏更晚出来。晚 2 秒既能先画出落盘缓存，
    /// 也避开连接刚建好时那阵忙。多次调用只保留最后一次（取消重排），不会叠成两次请求。
    func scheduleAutoLoadSubscriptionUsage(delay: TimeInterval = 2) {
        // 手上没有缓存可画时（第一次装、或者刚换了一条配置），没必要再等满 2 秒——
        // 那 2 秒本来就是留给第一屏把缓存画出来的。等下去只会让人对着
        // 「还没读到」多盯两秒。
        let effective = configDisplayUsage == nil ? min(delay, 0.4) : delay
        usageAutoTask?.cancel()
        usageAutoTask = Task { [effective] in
            if effective > 0 {
                try? await Task.sleep(nanoseconds: UInt64(effective * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self.autoLoadSubscriptionUsage()
        }
    }

    /// 进代理页 / 刚连上时**自动**拉一次当前订阅的流量（v2.4.22）。
    ///
    /// 以前只有卡片右上角那颗刷新钮能拉，用户每次开 App 都得先点一下才有数字。
    /// 这里把「点一下」省掉，但不敢每次都打机场接口（那是对外请求）：
    /// 一分钟内已经问过——无论成败——就直接返回，用户来回切页不会变成连打机场。
    /// 冷启动时 `subUsageAttemptAt` 是空的，所以第一次进页面一定会拉一次。
    ///
    /// 三种情况直接跳过：没连上（连接成功那一拍会再调一次）、正在连、正在拉。
    func autoLoadSubscriptionUsage() async {
        guard connected, !connecting, !subUsageLoading, !subUsageRefreshing else { return }
        if let last = subUsageAttemptAt, Date().timeIntervalSince(last) < 60 { return }
        // 配置还没读回来就匹配不到订阅，补一次探针。
        if openClash.config.isEmpty { await runOpenClashProbe() }
        if subscriptions.isEmpty { await loadSubscriptions(silent: true) }
        // 手动丢进 `/etc/openclash/config` 的 yaml 没有订阅可问，别去猜。
        // 这里只在有订阅可匹配时继续，省得把「不是来自订阅」写成一条错误挂到卡片上。
        guard currentConfigSubscription != nil else { return }
        await loadSubscriptionUsages()
    }

    /// 卡片上那个刷新钮：重读配置（必要时）与订阅列表，再拉当前这条的流量。
    ///
    /// 顺序不能反——`oc.config` 可能刚被换过，先拉流量会拉到上一条订阅头上。
    ///
    /// v2.4.23 三处提速 / 防连点：
    /// ① **一进来就置 `subUsageRefreshing`**，界面立刻转圈，不用等探针跑完；
    /// ② 已有 `oc.config` 时不再探一次状态（一次 SSH 往返，少说几百毫秒），
    ///    只有配置为空才补探针——切换配置那条路自己会把 `oc.config` 刷新好；
    /// ③ 订阅列表已经读过就不再重读（它只影响名字匹配，不影响地址）。
    ///    常见路径因此只剩一条命令：那条 curl。剩下的时间基本全是机场响应。
    func refreshCurrentSubscriptionUsage() async {
        guard connected, !subUsageRefreshing else { return }
        subUsageRefreshing = true
        defer { subUsageRefreshing = false }
        if openClash.config.isEmpty { await runOpenClashProbe() }
        if subscriptions.isEmpty { await loadSubscriptions(silent: true) }
        await loadSubscriptionUsages(force: true)
    }

    /// 切换配置文件之后：重读状态（拿到新的 `oc.config`）→ 只拉新那条的流量。
    ///
    /// 用户切完订阅看到的第一眼就是配置卡，流量还挂着上一条的数字会很怪；
    /// 这里不等节流，切一次就拉一次（切换本身是低频动作，一次请求不算多）。
    ///
    /// 必须**先** `refreshOpenClash()`：`oc.config` 不更新，匹配到的还是上一条订阅。
    func switchConfigAndRefreshUsage(_ name: String) async {
        await switchConfig(name)
        await refreshOpenClash()
        await loadSubscriptionUsages(force: true)
    }

    /// 抓这条订阅的 `subscription-userinfo`。
    ///
    /// 五道保险，都是踩出来的：
    /// ① `curl -I` 先行（只读响应头，最省流量），没拿到就用 **GET + `-D -` + `-o /dev/null`**
    ///    再要一次——不少机场/CDN 对 HEAD 不回头，`-I` 永远拿不到这个头，这是 v2.4.20
    ///    「读不到流量」最可能的一条原因。
    /// ② 两种 UA 都试：`clash-verge` 拿不到就换 `Quantumultx`（OpenClash 的 `fetch_sub_info`
    ///    同样是「非 200 换 Quantumultx 重试」）。
    /// ③ 没 curl 的固件退到 `wget -S`（busybox wget 把响应头打在 stderr，`2>&1` 混回来）。
    /// ④ 全部失败时打一行 `D|` 说明卡在哪一步，界面直接显示，不用再猜。
    /// ⑤ `printf` 而不是 `echo "U|$name|$h"`：名字里有空格 / 中文时，引号拼在双引号里
    ///    会把引号本身也打出来，`printf` 按参数分开引用才稳。
    func subscriptionUsageCommand(_ sub: ProxySubscription) -> String {
        guard let url = sub.lines.first else {
            return lowPriority("echo \"D|这条订阅没有地址\"")
        }
        let agent = sub.ua.isEmpty ? "clash-verge/v2.4.5" : sub.ua
        return lowPriority("""
        echo @@OCUSAGE
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { echo "D|路由器上没有 curl / wget"; exit 0; }
        subinfo() {
          if command -v curl >/dev/null 2>&1; then
            curl -sLI -X GET -m 6 -H "User-Agent: $2" "$1" 2>/dev/null
          else
            wget -q -S -O /dev/null --header="User-Agent: $2" --timeout=6 "$1" 2>&1
          fi
        }
        subbody() {
          if command -v curl >/dev/null 2>&1; then
            curl -sL -m 10 -D - -o /dev/null -H "User-Agent: $2" "$1" 2>/dev/null
          fi
        }
        URL=\(shQuote(url))
        UA=\(shQuote(agent))
        h=$(subinfo "$URL" "$UA" | grep -i 'subscription-userinfo' | head -1)
        [ -z "$h" ] && h=$(subbody "$URL" "$UA" | grep -i 'subscription-userinfo' | head -1)
        [ -z "$h" ] && h=$(subinfo "$URL" 'Quantumultx' | grep -i 'subscription-userinfo' | head -1)
        [ -z "$h" ] && h=$(subbody "$URL" 'Quantumultx' | grep -i 'subscription-userinfo' | head -1)
        if [ -z "$h" ]; then echo "D|订阅没有返回 subscription-userinfo"; exit 0; fi
        printf 'U|%s|%s\n' \(shQuote(sub.name)) "$h"
        """)
    }

    /// 新增（`id == nil`）或修改一条订阅。写成功就返回**重新读回来的那一条**
    /// （新段名由 `uci add` 生成，调用方拿不到），失败返回 nil。
    ///
    /// 早先这里返回 Bool，调用方只能拿旧 id 去列表里翻，翻不到就静默 `return`；
    /// 现在直接把结果递回去，不给「点了没反应」留口子。
    func saveSubscription(id: String?, name: String, address: String,
                          ua: String, enabled: Bool,
                          keywords: [String], excludeKeywords: [String]) async -> ProxySubscription? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !body.isEmpty else {
            presentError("名称和订阅地址都不能为空")
            return nil
        }
        let agent = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let output = try await execute(subscriptionSaveCommand(
                id: id, name: trimmed, address: body,
                ua: agent.isEmpty ? "clash-verge/v2.4.5" : agent,
                enabled: enabled,
                keywords: keywords, excludeKeywords: excludeKeywords
            ))
            guard output.contains("saved") else {
                presentError("写入订阅失败，请确认路由器上装了 OpenClash")
                return nil
            }
            await loadSubscriptions(silent: true)
            if let id, let hit = subscriptions.first(where: { $0.id == id }) { return hit }
            return subscriptions.first { $0.name == trimmed }
        } catch {
            presentError(describe(error))
            return nil
        }
    }

    /// 删除路由器上的一个配置文件（`/etc/openclash/config/xxx.yaml`）。
    ///
    /// 和删订阅是两条独立的路：订阅段删掉之后 yaml 还留着，想重新拉一份又怕
    /// 旧文件里的节点混进来，就得能单独把它清掉。删的正好是当前在用的那份时
    /// 会一并清掉 `config_path`，否则 OpenClash 重启会找不到文件。
    func deleteConfigFile(_ name: String) async {
        guard connected else { return }
        let wasActive = name == currentConfigName
        do {
            let output = try await execute(configDeleteCommand(name))
            guard output.contains("deleted") else {
                presentError("删除「\(name)」失败，确认路由器上这个文件有写权限")
                return
            }
            await refreshOpenClash()
            notice = Notice(
                kind: .ok,
                title: "已删除「\(name)」",
                detail: wasActive
                    ? "它正是当前在用的配置，已把 OpenClash 的配置指针清空，去「配置文件」里重新选一份。"
                    : "路由器上的配置文件已经删掉，订阅条目没动。"
            )
        } catch {
            presentError(describe(error))
        }
    }

    /// 删除订阅。只删 UCI 段，**不删**已下载的配置文件——
    /// 那份 yaml 可能正是当前在跑的配置，删掉会让 OpenClash 起不来。
    func deleteSubscription(_ sub: ProxySubscription) async {
        guard connected else { return }
        do {
            _ = try await execute(subscriptionDeleteCommand(sub))
            // 同名订阅以后可能再建一条，缓存不能留着旧的流量。
            subUsageCache.removeValue(forKey: sub.name)
            await loadSubscriptions(silent: true)
            notice = Notice(kind: .ok, title: "已删除「\(sub.name)」",
                            detail: "只删了路由器上的订阅条目，已下载的配置文件还在。")
        } catch {
            presentError(describe(error))
        }
    }

    /// 开关只影响「全部更新」是否带上它，不改当前运行状态。
    ///
    /// 顺序很讲究：先动本地数组（开关要跟手），再压一条「待确认」，
    /// 然后才发 UCI。以前只做前两步里的一半，正好撞上异步读列表，
    /// 旧值回来就把开关又拨回去——看着像「关了它自己又开」。
    func setSubscriptionEnabled(_ sub: ProxySubscription, _ enabled: Bool) async {
        guard connected else { return }
        if let index = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[index].enabled = enabled
        }
        pendingEnabled[sub.id] = enabled
        do {
            let output = try await execute(subscriptionEnableCommand(sub, on: enabled))
            guard output.contains("saved") else {
                throw AppError.message("路由器没有确认这次写入")
            }
            // 写完立刻读一次：确认落盘，也顺手把「待确认」放掉。
            await loadSubscriptions(silent: true)
        } catch {
            pendingEnabled[sub.id] = nil
            if let index = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                subscriptions[index].enabled = !enabled
            }
            presentError(describe(error))
        }
    }

    /// 更新订阅：**一条一条地在路由器前台跑** `openclash.sh`，每条都带硬超时。
    ///
    /// v2.3.7 之前是「丢到路由器后台 + 轮询 `/tmp/oc_sub_rc`」。那套有两个死穴，
    /// 正好对上真机上的两个现象：
    ///
    /// 1. 后台进程写完 `rc` 才算结束，可它一旦卡在 `openclash.sh` 内部的 curl 上
    ///    （地址连不通、机场不响应），`rc` 永远不出现 —— 界面就一直转圈；
    /// 2. 后台进程在 SSH 通道关掉后不一定活得下来（dropbear / busybox 没有 nohup 时），
    ///    连日志都留不下，只能看到「更新超时」四个字。
    ///
    /// 现在每条订阅单独一条命令、前台跑完再返回：能拿到脚本的 `exit_code`
    /// （OpenClash 就是用它告诉 LuCI 成功与否）、`/etc/openclash/config/<name>.yaml`
    /// 的新时间戳，以及这次新增的 `/tmp/openclash.log` 原文 —— 失败原因直接摊在红条里。
    /// 代价是这条命令会占着 SSH 通道几十秒（读超时按条放宽到 60 秒）。
    func updateSubscriptions(_ targets: [ProxySubscription], restart: Bool = false) async {
        guard !targets.isEmpty, subsBusy == nil, connected else { return }
        defer { subsBusy = nil }

        var finished = 0
        var replaced = 0
        var problems: [String] = []

        for (index, sub) in targets.enumerated() {
            subsBusy = sub.name
            let step = targets.count > 1 ? "（\(index + 1)/\(targets.count)）" : ""
            notice = Notice(kind: .info,
                            title: "正在更新「\(sub.name)」\(step)",
                            detail: "路由器正在下载并校验配置，通常 5~30 秒。")
            do {
                let output = try await execute(subscriptionDownloadCommand(sub.name), timeout: 60)
                let result = parseSubscriptionDownload(output)
                if result.ok {
                    finished += 1
                    if !result.noChange { replaced += 1 }
                } else {
                    problems.append("「\(sub.name)」\(result.reason)")
                }
            } catch {
                problems.append("「\(sub.name)」\(describe(error))")
            }
            // 每跑完一条就刷一次列表：成功的那条立刻从「还没下载」变成「刚刚更新」。
            await loadSubscriptions(silent: true)
        }

        if problems.isEmpty {
            // 逐条跑的时候成败可能掺着来：只要有一条真的换了文件就算「已替换」。
            var detail = replaced > 0 ? "配置文件已替换" : "配置没有变化，文件没被替换"
            if restart {
                // 替换的正是当前在跑的那份，内核不重启就不会生效。
                _ = try? await execute("/etc/init.d/openclash restart >/dev/null 2>&1; echo done", timeout: 60)
                detail += "；内核已重启"
            }
            notice = Notice(kind: .ok,
                            title: targets.count == 1 ? "「\(targets[0].name)」更新完成"
                                                      : "\(finished) 个订阅更新完成",
                            detail: detail)
        } else {
            let title = targets.count == 1
                ? "「\(targets[0].name)」更新失败"
                : "\(problems.count) 个订阅没更新成功"
            notice = Notice(kind: .fail, title: title, detail: problems.joined(separator: "\n"))
        }
        await refreshOpenClash()
    }

    private func action(_ command: String, title: String, subtitle: String) async {
        busy = true
        activityTitle = title
        activitySubtitle = subtitle
        defer {
            busy = false
            activityTitle = nil
            activitySubtitle = nil
        }
        do {
            _ = try await execute(command)
            try? await Task.sleep(for: .seconds(2))
            await refreshOpenClash()
            status = "已连接"
        } catch {
            presentError(describe(error))
        }
    }

    /// 访问检测。
    /// - Parameter silent: 「刚拿到状态顺手跑一次」用的静默模式：不弹全屏遮罩、
    ///   失败不弹红字，只在格子里显示结果，也不打扰正在进行的轮询。
    func checkAccess(silent: Bool = false) async {
        guard connected else { return }
        if silent {
            // 快速来回切标签页时不重复跑；正在跑别的操作也让路。
            if let last = lastAccessCheckAt, Date().timeIntervalSince(last) < 15 { return }
            if busy { return }
            // 先让这一轮的数据落到界面上，再去跑检测。
            try? await Task.sleep(for: .milliseconds(1200))
            guard connected, !Task.isCancelled else { return }
        }
        lastAccessCheckAt = Date()
        if !silent { busy = true }
        defer { if !silent { busy = false } }

        do {
            let sections = parseSections(try await execute(accessCommand))
            let text = sections["CHECK"] ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if !silent { presentError("访问检测没有返回结果，请确认路由器可以执行 curl") }
                return
            }
            var results: [AccessCheck.Site: (Bool, Int)] = [:]
            for line in text.split(separator: "\n") {
                let fields = splitFields(line)
                guard fields.count >= 3, fields[0] == "C",
                      let site = AccessCheck.Site(rawValue: fields[1]) else { continue }
                let code = fields[2]
                let seconds = Double(fields.count > 3 ? fields[3] : "") ?? 0
                let ok = code != "000" && !code.isEmpty && seconds > 0
                results[site] = (ok, ok ? Int((seconds * 1000).rounded()) : 0)
            }
            guard !results.isEmpty else {
                if !silent { presentError("访问检测没有返回结果，请确认路由器可以执行 curl") }
                return
            }
            accessChecks = AccessCheck.Site.allCases.map { site in
                guard let result = results[site] else {
                    return AccessCheck(site: site)
                }
                var check = AccessCheck(site: site, tested: true)
                check.success = result.0
                check.latency = result.1
                return check
            }
            if !silent { clearError() }
        } catch {
            if !silent { presentError(describe(error)) }
        }
    }

    // MARK: - 风扇控制

    /// 读一次风扇状态：插件配置（UCI）+ 温度 / 转速 / PWM + 两个服务的运行情况。
    ///
    /// 一条命令取全，失败也不弹红字：面板上有刷新按钮，重连之后自己会补上。
    func refreshFan() async {
        guard connected else { return }
        do {
            let sections = parseSections(try await execute(fanStatusCommand))
            var next = parseFan(sections)
            // 状态段完全没回来（通道被切断）时不要覆盖上一次的结果，
            // 否则面板会瞬间变成「未安装插件」。
            guard next.installed || !(sections["FANCTRL"] ?? "").isEmpty else { return }
            next.loaded = true
            fan = next
        } catch {
            return
        }
    }

    /// 只读运行态的一次刷新：温度 / 转速 / PWM / 守护进程，**不读 UCI 配置**。
    ///
    /// 面板开着的时候每 2 秒跑这条。之前面板只在打开那一刻读一次，之后温度、转速、
    /// PWM 全是开机那张快照——风扇明明已经从 32% 爬到 60%，界面还显示 32%。
    /// 也不能直接复用 `refreshFan()`：`uci show` 要 fork 好几次、回来十几行配置，
    /// 而这些配置在用户按「应用」之前不会变；更要紧的是整份 `fan` 被覆盖会触发
    /// 面板的 `onChange` 把正在拖的曲线草稿顶回旧值。
    func refreshFanRuntime() async {
        guard connected, !fanBusy else { return }
        do {
            let sections = parseSections(try await execute(fanRuntimeCommand))
            // 三个段一个都没回来（通道忙、脚本被截断）就别动，
            // 否则界面会瞬间从「65°」跳成「—」。
            guard sections["FANTEMP"] != nil || sections["FANRPM"] != nil
                    || sections["FANPWM"] != nil else { return }
            if let value = firstNumber(sections["FANTEMP"]) {
                fan.temperature = value > 200 ? value / 1000 : value
            }
            if let value = firstNumber(sections["FANRPM"]) {
                fan.rpm = value
            }
            if let pwm = parseFanPWM(sections["FANPWM"] ?? "") {
                fan.pwmPercent = pwm
            }
            for line in (sections["FANSVC"] ?? "").split(separator: "\n") {
                if line.hasPrefix("plugin=") { fan.pluginRunning = line.hasSuffix("1") }
            }
        } catch {
            return
        }
    }

    /// 接管开关：0 = 交回官方 gl_fan，1 = 由 gl-fanctrl 守护进程控制。
    func setFanEnabled(_ on: Bool) async {
        await fanAction([("enabled", on ? "1" : "0")])
    }

    /// 只切模式、不动参数。
    ///
    /// v1.28.28 起界面不再直接调它：`applyFanAuto` 自带 `mode=auto`、`setFanManual`
    /// 自带 `mode=manual`，一次提交就能把模式和参数一起写掉，先切模式再写参数是
    /// 两次 commit、两次重启守护进程。留着是给「只想改模式」的场合用。
    func setFanMode(_ mode: FanControlState.Mode) async {
        await fanAction([("mode", mode.rawValue)])
    }

    /// 应用整条自动温控曲线。
    ///
    /// 值在这里再夹一次：插件的 `/usr/share/gl-validator.d` 会按
    /// `wall_temp ≥ start_temp + 5`、`critical_temp ≥ wall_temp + 3` 校验，
    /// 不合法时 uci commit 被拒、风扇会在原地不动，用户只会看到「点了没反应」。
    func applyFanAuto(startTemp: Int, wallTemp: Int, criticalTemp: Int,
                      hysteresis: Int, startPercent: Int, maxPercent: Int,
                      pollInterval: Int) async {
        let start = min(max(startTemp, 35), 85)
        let wall = min(max(wallTemp, start + 5), 95)
        let critical = min(max(criticalTemp, wall + 3), 105)
        let hyst = min(max(hysteresis, 1), 10)
        let floor = min(max(startPercent, 0), 100)
        let ceiling = min(max(maxPercent, floor), 100)
        let poll = min(max(pollInterval, 1), 30)
        await fanAction([
            ("mode", "auto"),
            ("start_temp", "\(start)"),
            ("wall_temp", "\(wall)"),
            ("critical_temp", "\(critical)"),
            ("hysteresis", "\(hyst)"),
            ("start_percent", "\(floor)"),
            ("max_percent", "\(ceiling)"),
            ("poll_interval", "\(poll)")
        ])
    }

    /// 手动调速。`0` 表示停转；`1..100` 会被插件夹在「起转 PWM .. 最大 PWM」之间，
    /// 所以这里不自己兜底，交给守护进程按它自己的上下限处理。
    func setFanManual(_ percent: Int) async {
        await fanAction([
            ("mode", "manual"),
            ("manual_percent", "\(min(max(percent, 0), 100))")
        ])
    }

    /// 恢复插件默认配置（含 `enabled=0`，也就是把风扇交回官方服务）。
    func restoreFanDefaults() async {
        await fanAction([
            ("enabled", "0"),
            ("mode", "auto"),
            ("start_temp", "70"),
            ("wall_temp", "76"),
            ("critical_temp", "88"),
            ("hysteresis", "3"),
            ("start_percent", "35"),
            ("max_percent", "100"),
            ("manual_percent", "0"),
            ("poll_interval", "2")
        ])
    }

    /// 写配置 → commit → 重启插件服务 → 回读一遍。
    ///
    /// 重启是必须的：手动模式的 PWM、新的起转温度都要靠守护进程重新读配置才生效，
    /// 光 commit 的话要等它下一轮轮询（最长 30 秒），用户会以为没生效。
    private func fanAction(_ assignments: [(String, String)]) async {
        guard connected else { return }
        if fanBusy { return }
        fanBusy = true
        defer { fanBusy = false }
        do {
            let output = try await execute(fanWriteCommand(assignments))
            guard output.contains("committed") else {
                presentError("写入风扇配置失败，请确认路由器上已安装 gl-fanctrl 插件")
                return
            }
            // 给守护进程一点时间重新起风、把转速读出来，再回读状态。
            try? await Task.sleep(for: .milliseconds(900))
            await refreshFan()
        } catch {
            presentError(describe(error))
        }
    }

    /// 解析风扇状态命令的输出。
    private func parseFan(_ sections: [String: String]) -> FanControlState {
        var state = FanControlState()
        let dump = sections["FANCTRL"] ?? ""
        state.installed = dump.split(separator: "\n")
            .contains { String($0).trimmingCharacters(in: .whitespaces) == "installed" }

        // uci show 每行形如 `gl_fanctrl.<section>.<key>='<value>'`。
        // 段名可能是 `settings` 也可能是匿名的 `@fanctrl[0]`，所以只认最后一段的键名。
        for line in dump.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].split(separator: ".").last.map(String.init) ?? ""
            let raw = String(line[line.index(after: eq)...])
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            switch key {
            case "enabled": state.enabled = value == "1" || value == "true"
            case "mode": state.mode = FanControlState.Mode(rawValue: value) ?? .auto
            case "start_temp": state.startTemp = Int(Double(value) ?? 70)
            case "wall_temp": state.wallTemp = Int(Double(value) ?? 76)
            case "critical_temp": state.criticalTemp = Int(Double(value) ?? 88)
            case "hysteresis": state.hysteresis = Int(Double(value) ?? 3)
            case "start_percent": state.startPercent = Int(Double(value) ?? 35)
            case "max_percent": state.maxPercent = Int(Double(value) ?? 100)
            case "manual_percent": state.manualPercent = Int(Double(value) ?? 0)
            case "poll_interval": state.pollInterval = Int(Double(value) ?? 2)
            default: break
            }
        }

        // 温度：/proc/gl-hw-info/temperature 是摄氏度，thermal_zone 是毫摄氏度，
        // 两者混在同一个段里按行输出，靠「大于 200 就除以 1000」区分。
        if let value = firstNumber(sections["FANTEMP"]) {
            state.temperature = value > 200 ? value / 1000 : value
        }
        if let value = firstNumber(sections["FANRPM"]) {
            state.rpm = value
        }

        // PWM：cooling_device 里可能不止一个（CPU 降频也是 cooling_device），
        // 优先取 type 里带 fan / pwm 的那个，都没有才退回第一个。
        if let pwm = parseFanPWM(sections["FANPWM"] ?? "") {
            state.pwmPercent = pwm
        }

        for line in (sections["FANSVC"] ?? "").split(separator: "\n") {
            if line.hasPrefix("plugin=") { state.pluginRunning = line.hasSuffix("1") }
        }
        return state
    }

    /// `type cur_state max_state` 一行一台 cooling_device，换算成百分比。
    /// 全量读和只读运行态两条路径共用，免得两处口径慢慢走偏。
    private func parseFanPWM(_ text: String) -> Int? {
        var pwm: (current: Int, max: Int)?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  let current = Int(fields[1]),
                  let maxState = Int(fields[2]), maxState > 0 else { continue }
            let type = String(fields[0]).lowercased()
            if type.contains("fan") || type.contains("pwm") {
                pwm = (current, maxState)
                break
            }
            if pwm == nil { pwm = (current, maxState) }
        }
        guard let pwm else { return nil }
        return Int((Double(pwm.current) / Double(pwm.max) * 100).rounded())
    }

    /// 取第一行里的第一个数字（`1234`、`53.4`、`1234 RPM` 都认）。
    private func firstNumber(_ text: String?) -> Double? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            let head = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            if let value = Double(head) { return value }
        }
        return nil
    }

    // MARK: - Parsing

    private func parseOpenClashInfo(_ sections: [String: String],
                                    current: OpenClashInfo) -> OpenClashInfo {
        var info = current
        let state = firstLine(sections["OCSTATE"])
        // 没拿到状态段（通道忙、脚本被切断）就原样返回：默认值是 installed = false，
        // 一次读失败就会被当成「路由器上没装 OpenClash」，那是句假话。
        guard !state.isEmpty else { return info }
        ocStateLoaded = true
        info.installed = ["running", "stopped", "installed"].contains(state)
        info.running = state == "running"
        if !info.running {
            ocMetrics = OpenClashMetrics()
            lastOcUploadTotal = nil
            lastOcDownloadTotal = nil
            lastOcTotalDate = nil
        }
        info.mode = firstLine(sections["OCMODE"])
        if info.mode.isEmpty { info.mode = "rule" }
        info.config = (firstLine(sections["OCCONFIG"]) as NSString).lastPathComponent
        info.configs = (sections["OCCONFIGS"] ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        let port = Int(firstLine(sections["OCPORT"])) ?? 9090
        info.panelPort = port
        info.secret = firstLine(sections["OCSECRET"])
        info.dashboards = (sections["OCDIRS"] ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        var dash = firstLine(sections["OCDASH"]).lowercased()
        if dash.isEmpty || (!info.dashboards.isEmpty && !info.dashboards.contains(dash)) {
            dash = info.dashboards.first ?? "zashboard"
        }
        info.dashboard = dash
        info.panelURL = buildPanelURL(info)
        return info
    }

    /// 解析 `键|值` 形式的订阅列表。`.` 是一段的结束标记。
    private func parseSubscriptions(_ text: String) -> [ProxySubscription] {
        var result: [ProxySubscription] = []
        var current: ProxySubscription?
        var address: [String] = []
        var keywords: [String] = []
        var excludes: [String] = []

        func commit() {
            guard var sub = current else { return }
            sub.address = address.joined(separator: "\n")
            sub.keywords = keywords
            sub.excludeKeywords = excludes
            if sub.ua.isEmpty { sub.ua = "clash-verge/v2.4.5" }
            if !sub.name.isEmpty { result.append(sub) }
            current = nil
            address = []
            keywords = []
            excludes = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line == "." { commit(); continue }
            guard let bar = line.firstIndex(of: "|") else { continue }
            let key = String(line[line.startIndex..<bar])
            let value = String(line[line.index(after: bar)...])
            switch key {
            case "S":
                commit()
                current = ProxySubscription(id: value, name: "", address: "",
                                            ua: "", enabled: true, updatedAt: nil)
            case "N":
                current?.name = value
            case "E":
                // 没写过这个键的段按「启用」算，和 LuCI 的默认值一致。
                current?.enabled = (value != "0")
            case "U":
                current?.ua = value
            case "A":
                if !value.isEmpty { address.append(value) }
            case "K":
                if !value.isEmpty { keywords.append(value) }
            case "X":
                if !value.isEmpty { excludes.append(value) }
            case "T":
                current?.updatedAt = Double(value).map { Date(timeIntervalSince1970: $0) }
            default:
                break
            }
        }
        commit()
        return result
    }

    /// 一次订阅下载的结果。`ok` 认的是 `openclash.sh` 的 exit_code——
    /// 它最后那行 `exit $exit_code` 就是给 LuCI 判断成败用的，我们照抄同一套标准。
    private struct SubscriptionDownload {
        var ok = false
        var noChange = false
        var reason = ""
    }

    private func parseSubscriptionDownload(_ output: String) -> SubscriptionDownload {
        let sections = parseSections(output)
        func section(_ key: String) -> String {
            (sections[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let code = section("RC")
        let ocLog = section("OCLOG")
        let subLog = section("SUBLOG")
        if code == "0" {
            return SubscriptionDownload(ok: true, noChange: ocLog.contains("No Change"))
        }
        return SubscriptionDownload(ok: false, noChange: false,
                                    reason: subscriptionFailureReason(ocLog, subLog, code: code))
    }

    /// 把 OpenClash 的日志翻译成一句人话。
    ///
    /// 这些话都是 `openclash.sh` 里写死的：
    /// - `Unable To Parse Config File` / `Format Validation Failed` → 下载回来的不是 Clash 配置；
    /// - `Has No Proxy Field` → YAML 能读但没有 `proxies`，说明是普通订阅链接没转换；
    /// - `Subscribed Failed` / `Update Error` → 连不上地址或被机场拒；
    /// - `Tested Failed` → 校验配置时内核报错。
    /// 认不出来就把日志最后两行原样贴出来，别再让用户猜。
    private func subscriptionFailureReason(_ ocLog: String, _ subLog: String, code: String) -> String {
        let text = (ocLog + "\n" + subLog).lowercased()
        if code == "127" {
            return "没在这台路由器上找到 OpenClash 的更新脚本"
        }
        if text.contains("unable to parse config file") || text.contains("format validation failed") {
            return "地址返回的不是 Clash 配置（YAML 解析失败），这条多半要在网页后台打开「订阅转换」"
        }
        if text.contains("has no proxy field") {
            return "配置里没有 proxies 字段，订阅链接需要先转换"
        }
        if text.contains("ruby works abnormally") {
            return "路由器缺 ruby 库，配置校验没跑起来"
        }
        if text.contains("tested failed") {
            return "内核校验配置没通过：" + tailLines(ocLog, 2)
        }
        if text.contains("subscribed failed") || text.contains("update error") {
            return "下载失败：路由器连不上这个地址，或被机场拒绝（UA / 证书）"
        }
        let tail = tailLines(ocLog + "\n" + subLog, 3)
        return tail.isEmpty ? "脚本返回 \(code)，日志里没有更多信息"
                            : "脚本返回 \(code)：\(tail)"
    }

    /// 取最后几行非空内容，用「 / 」连起来，塞进提示条时不会撑成一长条。
    private func tailLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " / ")
    }

    private func buildPanelURL(_ info: OpenClashInfo) -> URL? {
        guard let profile = currentProfile else { return nil }
        let base = "http://\(profile.host):\(info.panelPort)/ui/\(info.dashboard)"
        let host = profile.host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.host
        let secret = info.secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let secretPart = secret.isEmpty ? "" : "&secret=\(secret)"
        switch info.dashboard {
        case "yacd":
            return URL(string: "\(base)/?hostname=\(host)&port=\(info.panelPort)\(secretPart)")
        case "dashboard":
            return URL(string: "\(base)/#/?host=\(host)&port=\(info.panelPort)\(secretPart)")
        case "zashboard", "metacubexd":
            return URL(string: "\(base)/#/setup?hostname=\(host)&port=\(info.panelPort)\(secretPart)")
        default:
            return URL(string: base + "/")
        }
    }

    /// CPU 占用率 = 两次 /proc/stat 的增量比。
    ///
    /// 关键在于**窗口长度**：切页、手动刷新、重连都会插进来一轮采集，两次读数
    /// 可能只隔几十毫秒。那个窗口里随便一点中断就能算出 80%~100%，于是「点一下
    /// 概览，CPU 就飙到 100%」——数字是量出来的噪声，不是路由器真的忙。
    /// 这里要求窗口至少 0.8 秒，太短的这一拍直接丢掉且不动基线，
    /// 下一拍仍然按一个完整间隔来算，读数就稳定了。
    private func updateCPU(_ text: String) {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return }
        let values = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard values.count >= 4 else { return }
        let total = values.prefix(8).reduce(0, +)
        let idle = values[3] + (values.count > 4 ? values[4] : 0)
        let now = Date()
        if let lastTotal = lastCpuTotal, let lastIdle = lastCpuIdle, let lastDate = lastCpuDate {
            let elapsed = now.timeIntervalSince(lastDate)
            guard elapsed >= 0.8 else { return }
            let deltaTotal = total - lastTotal
            let deltaIdle = idle - lastIdle
            if deltaTotal > 0 {
                stats.cpu = max(0, min(100, (deltaTotal - deltaIdle) / deltaTotal * 100))
            }
        }
        lastCpuTotal = total
        lastCpuIdle = idle
        lastCpuDate = now
    }

    private func updateMemory(_ text: String) {
        var total: UInt64 = 0
        var available: UInt64 = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            if parts[0] == "MemTotal:" { total = (UInt64(parts[1]) ?? 0) * 1024 }
            if parts[0] == "MemAvailable:" { available = (UInt64(parts[1]) ?? 0) * 1024 }
        }
        stats.memoryTotal = total
        stats.memoryUsed = total > available ? total - available : 0
    }

    private func updateFlash(_ text: String) {
        var romTotal: UInt64 = 0
        var romUsed: UInt64 = 0
        var fsTotal: UInt64 = 0
        var fsUsed: UInt64 = 0
        var fsAvail: UInt64 = 0

        for line in text.split(separator: "\n") {
            let fields = splitFields(line)
            switch fields.first ?? "" {
            case "ROM" where fields.count >= 3:
                romTotal = (UInt64(fields[1]) ?? 0) * 1024
                romUsed = (UInt64(fields[2]) ?? 0) * 1024
            case "ROOT" where fields.count >= 4:
                fsTotal = (UInt64(fields[1]) ?? 0) * 1024
                fsUsed = (UInt64(fields[2]) ?? 0) * 1024
                fsAvail = (UInt64(fields[3]) ?? 0) * 1024
            default:
                break
            }
        }

        // 没有 overlay 的纯只读固件（少见）：df / 和 df /rom 报的是同一个 squashfs，
        // 直接相加会把固件算两遍，认出来就只留一份。
        if fsTotal > 0, fsTotal == romTotal, fsUsed == romUsed {
            fsUsed = 0
            fsAvail = 0
        }

        let used = romUsed &+ fsUsed
        // 总容量只按系统真实看得见的两块算：只读固件 + 可写分区（已用 + 剩余）。
        // 不再用「squashfs 镜像 + overlay 分区总量」相加，也不再读 /proc/mtd ——
        // 那条路上同一段闪存会被算两遍，读出来比物理容量还大。
        var capacity = used &+ fsAvail
        if capacity == 0 {
            // 两个 df 都没读到内容：退回只读固件自身的容量，总比显示 0 强。
            capacity = romTotal &+ fsTotal
        }
        guard capacity > 0 else { return }
        if capacity < used { capacity = used }

        flashInfo = FlashInfo(
            total: capacity,
            systemUsed: romUsed,
            appUsed: fsUsed,
            available: capacity > used ? capacity - used : 0
        )
    }

    private func updateNetwork(_ text: String) {
        guard !stats.wanDevice.isEmpty else { return }
        for line in text.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(stats.wanDevice + ":") else { continue }
            let numbers = trimmed.split(separator: ":").dropFirst().joined()
                .split(separator: " ").compactMap { Double($0) }
            guard numbers.count >= 9 else { return }
            let rx = numbers[0]
            let tx = numbers[8]
            let now = Date()
            if let lastRx, let lastTx, let lastNetDate {
                let elapsed = now.timeIntervalSince(lastNetDate)
                // 和 CPU 同理：窗口太短算出来的速度是抖动，直接跳过这一拍。
                guard elapsed >= 0.5 else { return }
                stats.download = max(0, (rx - lastRx) / elapsed)
                stats.upload = max(0, (tx - lastTx) / elapsed)
                stats.sessionDownload += max(0, rx - lastRx)
                stats.sessionUpload += max(0, tx - lastTx)
            }
            lastRx = rx
            lastTx = tx
            lastNetDate = now
            return
        }
    }

    private func updateSensors(temp: String, fan: String, pwm: String) {
        let temps = temp.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "T" else { return nil }
            let value = Double(parts[1]) ?? 0
            return value > 1000 ? value / 1000 : value
        }
        if let value = temps.max(), value > 0 { stats.temperature = value }
        let fans = fan.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "F" else { return nil }
            return Double(parts[1])
        }
        if let value = fans.max(), value > 0 { stats.fanRPM = value }
        // 0 是有效值（风扇停着），所以只在解析出东西时才覆盖；一次读空留着上一拍，
        // 免得轮询抖一下徽标就消失。
        if let value = parseFanPWM(pwm) { stats.fanPWM = value }
    }

    /// 设备列表 = DHCP 租约（名字）+ 三张表（在线）。
    ///
    /// 以前只看租约，于是「租出去过」被当成「还连着」：设备关机、平板带走、
    /// 手机换网，租约还在 12 小时，列表就一直显示在线，标题还写着「N 台在线」。
    /// 现在每台设备都要在 ARP / 邻居表 / WiFi 关联表里找到活口才算在线，
    /// 在线的排前面，离线的沉到下面。
    private func updateDevices(_ sections: [String: String]) {
        let reachable = parseReachability(neigh: sections["NEIGH"] ?? "",
                                         arp: sections["ARP"] ?? "",
                                         sta: sections["STA"] ?? "")

        var result: [DeviceInfo] = []
        for line in (sections["LEASES"] ?? "").split(separator: "\n") {
            let fields = splitFields(line)
            guard fields.count >= 4 else { continue }
            let ip = fields[2]
            let mac = fields[1].lowercased()
            // 有些固件把「永久租约」的 MAC 写成全零，这种行没有意义。
            guard !mac.isEmpty, mac != "00:00:00:00:00:00" else { continue }
            result.append(DeviceInfo(
                ip: ip,
                mac: fields[1],
                name: fields[3] == "*" ? ip : fields[3],
                online: reachable.ips.contains(ip) || reachable.macs.contains(mac)
            ))
        }

        // 在线优先，同组内按 IP 末段数字排，192.168.8.9 排在 .100 前面。
        // 「全部设备」都从同一个位置开始滚，比按租约文件顺序（谁先连谁在前）好找。
        trackOffline(result)
        result.sort { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online }
            return ipTail(lhs.ip) < ipTail(rhs.ip)
        }
        allDevices = result
        applyDeviceVisibility()
    }

    /// 维护「离线多久了」，够久就自动删掉；设备重新上线则撤销隐藏。
    ///
    /// 计时存本机（不是内存），这样 App 关掉再打开不会把已经离线三小时的设备
    /// 重新算成「刚离线」，自动清理的规则才说得通。
    private func trackOffline(_ current: [DeviceInfo]) {
        let now = Date()
        var present = Set<String>()
        var dirty = false

        for device in current {
            let key = aliasKey(device)
            present.insert(key)
            if device.online {
                if offlineSince.removeValue(forKey: key) != nil { dirty = true }
                // 设备真回来了就撤销隐藏——不需要用户再去某个设置里「恢复」。
                if hiddenDeviceKeys.removeValue(forKey: key) != nil { dirty = true }
            } else if offlineSince[key] == nil {
                offlineSince[key] = now
                dirty = true
            }
        }

        // 租约已经消失的（换了 IP、路由器重启过），计时也别留着占地方。
        let before = offlineSince.count
        offlineSince = offlineSince.filter { present.contains($0.key) }
        if offlineSince.count != before { dirty = true }

        if autoRemoveOffline {
            let limit = TimeInterval(max(1, offlineRemoveMinutes) * 60)
            for (key, since) in offlineSince where now.timeIntervalSince(since) >= limit {
                if hiddenDeviceKeys[key] == nil {
                    hiddenDeviceKeys[key] = now
                    dirty = true
                }
            }
        }

        if dirty { saveHiddenDevices() }
    }

    /// 从 IP 里取末段数字用于排序；解析不出来就排在最后。
    private func ipTail(_ ip: String) -> Int {
        guard let last = ip.split(separator: ".").last else { return .max }
        return Int(last) ?? .max
    }

    /// 哪些 IP / MAC 此刻真的在线。
    private struct Reachability {
        var ips: Set<String> = []
        var macs: Set<String> = []
    }

    private func parseReachability(neigh: String, arp: String, sta: String) -> Reachability {
        var result = Reachability()

        // WiFi 关联表：station dump 只列出真正握手的客户端，最硬的证据。
        for line in sta.split(separator: "\n") {
            let mac = String(line).trimmingCharacters(in: .whitespaces).lowercased()
            if mac.count == 17 { result.macs.insert(mac) }
        }

        // 邻居表状态：REACHABLE 是内核刚刚确认过的，DELAY / PROBE 是正在确认；
        // STALE 只表示「以前通过、最近没流量」，离线设备最常见的残留就是它，
        // 所以一律不算在线。FAILED / INCOMPLETE 更不算。
        var sawNeigh = false
        for line in neigh.split(separator: "\n") {
            let fields = splitFields(line)
            guard let ip = fields.first, let state = fields.last else { continue }
            sawNeigh = true
            guard ["REACHABLE", "DELAY", "PROBE"].contains(state) else { continue }
            result.ips.insert(ip)
            if let idx = fields.firstIndex(of: "lladdr"), idx + 1 < fields.count {
                result.macs.insert(fields[idx + 1].lowercased())
            }
        }

        // 没有 iproute2 的固件：退回 /proc/net/arp，Flags 为 0x2 表示条目完整。
        // 这条路拿不到状态，STALE 残留会误判为在线，但总比「全员在线」准。
        if !sawNeigh {
            for line in arp.split(separator: "\n").dropFirst() {
                let fields = splitFields(line)
                guard fields.count >= 4, fields[2] != "0x0" else { continue }
                result.ips.insert(fields[0])
                result.macs.insert(fields[3].lowercased())
            }
        }
        return result
    }

    private func updateCoreCPU(_ sections: [String: String], into value: inout OpenClashMetrics) {
        let pid = firstLine(sections["OCPID"])
        let stat = sections["OCSTAT"] ?? ""
        let sys = sections["SYSTAT"] ?? ""
        guard let procTicks = parseProcTicks(stat), let total = parseTotalTicks(sys) else { return }
        if pid != lastOcPid {
            lastOcPid = pid
            lastOcTicks = nil
            lastOcTotal = nil
        }
        if let lastTicks = lastOcTicks, let lastTotal = lastOcTotal,
           total > lastTotal, procTicks >= lastTicks {
            value.cpu = max(0, (procTicks - lastTicks) / (total - lastTotal) * 100)
        }
        lastOcTicks = procTicks
        lastOcTotal = total
    }

    private func parseVmRSS(_ status: String) -> UInt64 {
        for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ")
            if parts.count >= 2 { return (UInt64(parts[1]) ?? 0) * 1024 }
        }
        return 0
    }

    private func parseProcTicks(_ stat: String) -> Double? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let rest = stat[stat.index(after: close)...].split(separator: " ")
        guard rest.count >= 13 else { return nil }
        return (Double(rest[11]) ?? 0) + (Double(rest[12]) ?? 0)
    }

    private func parseTotalTicks(_ stat: String) -> Double? {
        guard let line = stat.split(separator: "\n").first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 5 else { return nil }
        return fields.dropFirst().prefix(8).compactMap { Double($0) }.reduce(0, +)
    }

    /// WAN 口取自 /proc/net/route：Destination 为 00000000 的那行就是默认路由，
    /// 比每次 `ip route show default` 便宜得多。也兼容 `ip route` 的 "dev X" 形式。
    private func parseWanDevice(_ route: String) -> String {
        if let range = route.range(of: "dev ") {
            let value = route[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if !value.isEmpty { return value }
        }
        for line in route.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields[0] != "Iface" else { continue }
            if fields[1] == "00000000" { return fields[0] }
        }
        return ""
    }

    private func parseRelease(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            if line.contains("DISTRIB_DESCRIPTION") || line.contains("PRETTY_NAME") {
                let value = (line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    private func appendHistory() {
        history.append(HistoryPoint(
            date: Date(),
            download: stats.download,
            upload: stats.upload
        ))
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    var memoryFraction: Double {
        stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : 0
    }

    private func parseSections(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var key: String?
        for line in raw.replacingOccurrences(of: "\r", with: "").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            if line.hasPrefix("@@") {
                key = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                result[key!] = ""
            } else if let key {
                result[key, default: ""] += String(line) + "\n"
            }
        }
        return result
    }

    private func firstLine(_ text: String?) -> String {
        guard let text else { return "" }
        return text.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    /// 取一段文本里的 JSON 对象。
    ///
    /// 内核的 /traffic 是**流式**接口：每秒吐一行 `{"up":…,"down":…}` 并且不断开连接，
    /// 所以一次读回来常常是多个对象首尾相接。旧版直接「第一个 `{` 到最后一个 `}`」取下标，
    /// 拼出来的字符串必然是非法 JSON，解析永远失败——实时流量于是一直停在 0。
    /// 这里改成按大括号配对（跳过字符串里的括号）切出每个对象，取最后一个能解析的，
    /// 也就是最新的那个；单对象、带前后杂字符的情况一样能处理。
    private func json(_ text: String?) -> [String: Any]? {
        guard let text, text.contains("{") else { return nil }
        if let object = decodeJSON(text) { return object }
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var latest: [String: Any]?
        for index in text.indices {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start,
                       let object = decodeJSON(String(text[start...index])) {
                        latest = object
                    }
                }
            default:
                break
            }
        }
        return latest
    }

    private func decodeJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    // MARK: - Persistence

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "profiles"),
              let decoded = try? JSONDecoder().decode([RouterProfile].self, from: data) else {
            return
        }
        profiles = decoded
        if let raw = UserDefaults.standard.string(forKey: "currentProfileID"),
           let id = UUID(uuidString: raw) {
            currentProfileID = id
        }
        if currentProfileID == nil { currentProfileID = profiles.first?.id }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
        UserDefaults.standard.set(currentProfileID?.uuidString, forKey: "currentProfileID")
    }

    private func loadModules() {
        if let raw = UserDefaults.standard.stringArray(forKey: "moduleOrder") {
            let values = raw.compactMap(OverviewModule.init(rawValue:))
            if !values.isEmpty { moduleOrder = values }
        }
        let hidden = UserDefaults.standard.stringArray(forKey: "hiddenModules") ?? []
        hiddenModules = Set(hidden.compactMap(OverviewModule.init(rawValue:)))
        // 旧配置里可能有已被删掉的模块（v1.27 把「资源占用」并进了「硬件状态」），
        // compactMap 时已经丢掉；新版新增的模块直接补在末尾。
        for module in OverviewModule.allCases where !moduleOrder.contains(module) {
            moduleOrder.append(module)
        }
    }

    private func saveModules() {
        UserDefaults.standard.set(moduleOrder.map(\.rawValue), forKey: "moduleOrder")
        UserDefaults.standard.set(hiddenModules.map(\.rawValue), forKey: "hiddenModules")
    }
}

// MARK: - Commands

private extension AppModel {
    /// 让路由器以最低调度优先级执行这段脚本。监控不该跟转发、防火墙、
    /// OpenClash 抢 CPU；万一固件里没有 nice，就退回普通执行，不影响功能。
    func lowPriority(_ script: String) -> String {
        let body = script
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "'\\''")
        return "if command -v nice >/dev/null 2>&1; then nice -n 19 sh -c '\(body)'; else sh -c '\(body)'; fi"
    }

    /// 连接后取一次静态信息。
    /// OpenClash 的运行状态改由 pidof 判断：`/etc/init.d/openclash status`
    /// 在部分固件里会 source 一整套 shell 函数、甚至去列防火墙规则，
    /// 弱 CPU 上这是最容易被忽略的一次高开销调用。
    var infoCommand: String {
        lowPriority("""
        echo @@MODEL; cat /tmp/sysinfo/model 2>/dev/null
        echo @@HOST; cat /proc/sys/kernel/hostname 2>/dev/null
        echo @@RELEASE; cat /etc/openwrt_release 2>/dev/null
        echo @@KERNEL; uname -r 2>/dev/null
        echo @@ARCH; uname -m 2>/dev/null
        echo @@CPUCORES; awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null
        echo @@UPTIME; cat /proc/uptime 2>/dev/null
        echo @@LOAD; cat /proc/loadavg 2>/dev/null
        echo @@ROUTE; cat /proc/net/route 2>/dev/null
        echo @@OCSTATE
        set -- $(pidof clash clash_meta clash_tun clash_lite mihomo 2>/dev/null); OCPID=$1
        if [ -n "$OCPID" ]; then echo running
        elif [ -d /usr/share/openclash ] || [ -x /etc/init.d/openclash ]; then echo stopped
        else echo missing; fi
        echo @@OCPID; echo "$OCPID"
        echo @@OCMODE; uci -q get openclash.config.proxy_mode 2>/dev/null
        echo @@OCCONFIG; uci -q get openclash.config.config_path 2>/dev/null
        echo @@OCCONFIGS; ls /etc/openclash/config/*.yaml /etc/openclash/config/*.yml 2>/dev/null | xargs -n1 basename 2>/dev/null
        echo @@OCPORT; p=$(uci -q get openclash.config.cn_port 2>/dev/null); [ -n "$p" ] || p=9090; echo "$p"
        echo @@OCSECRET; uci -q get openclash.config.dashboard_password 2>/dev/null
        echo @@OCDASH; uci -q get openclash.config.default_dashboard 2>/dev/null
        echo @@OCDIRS; for d in zashboard metacubexd yacd dashboard; do [ -d "/usr/share/openclash/ui/$d" ] && echo "$d"; done
        true
        """)
    }

    /// 风扇状态：一次取回插件配置、温度、转速、PWM 和两个服务的运行情况。
    ///
    /// 路径顺序照 gl-fanctrl README 的探测顺序来：先 `/proc/gl-hw-info/*`（GL 固件
    /// 自己维护的，最准），再退到标准 sysfs。整段没有单引号，能安全塞进
    /// `lowPriority` 的 `sh -c '...'` 里。
    var fanStatusCommand: String {
        lowPriority("""
        echo @@FANCTRL
        if [ -f /etc/config/gl_fanctrl ]; then echo installed; else echo missing; fi
        uci -q show gl_fanctrl 2>/dev/null
        echo @@FANTEMP
        cat /proc/gl-hw-info/temperature 2>/dev/null
        for f in /sys/class/thermal/thermal_zone*/temp; do
          if [ -r "$f" ]; then read -r v < "$f"; echo "$v"; break; fi
        done
        echo @@FANRPM
        cat /proc/gl-hw-info/fan 2>/dev/null
        for f in /sys/class/hwmon/hwmon*/fan1_input; do
          if [ -r "$f" ]; then read -r v < "$f"; echo "$v"; break; fi
        done
        echo @@FANPWM
        for d in /sys/class/thermal/cooling_device*; do
          if [ -r "$d/cur_state" ]; then
            t=$(cat "$d/type" 2>/dev/null)
            c=$(cat "$d/cur_state" 2>/dev/null)
            m=$(cat "$d/max_state" 2>/dev/null)
            echo "$t $c $m"
          fi
        done
        echo @@FANSVC
        if ps 2>/dev/null | grep -q "[g]l-fanctrl-daemon"; then echo plugin=1; else echo plugin=0; fi
        true
        """)
    }

    /// 面板轮询用的轻量版：只有温度、转速、PWM、守护进程，没有 `uci show`。
    ///
    /// 配置那一段一天也变不了一次，没必要每 2 秒搬十几行回来；
    /// 探测路径和 `fanStatusCommand` 保持一致，两个口子读数才不会打架。
    var fanRuntimeCommand: String {
        lowPriority("""
        echo @@FANTEMP
        cat /proc/gl-hw-info/temperature 2>/dev/null
        for f in /sys/class/thermal/thermal_zone*/temp; do
          if [ -r "$f" ]; then read -r v < "$f"; echo "$v"; break; fi
        done
        echo @@FANRPM
        cat /proc/gl-hw-info/fan 2>/dev/null
        for f in /sys/class/hwmon/hwmon*/fan1_input; do
          if [ -r "$f" ]; then read -r v < "$f"; echo "$v"; break; fi
        done
        echo @@FANPWM
        for d in /sys/class/thermal/cooling_device*; do
          if [ -r "$d/cur_state" ]; then
            t=$(cat "$d/type" 2>/dev/null)
            c=$(cat "$d/cur_state" 2>/dev/null)
            m=$(cat "$d/max_state" 2>/dev/null)
            echo "$t $c $m"
          fi
        done
        echo @@FANSVC
        if ps 2>/dev/null | grep -q "[g]l-fanctrl-daemon"; then echo plugin=1; else echo plugin=0; fi
        true
        """)
    }

    /// 写风扇配置：定位段名 → 逐项 uci set → commit → 重启插件服务。
    ///
    /// 段名不能写死：插件的 `/etc/config/gl_fanctrl` 里可能是具名的 `config fanctrl 'settings'`，
    /// 也可能是匿名的（`uci show` 显示成 `@fanctrl[0]`）。这里从输出里反查，
    /// 查不到才退回 `@fanctrl[0]`。
    ///
    /// 这段**不能**套 `lowPriority`：里面用了 `$S` 变量和 awk 的单引号，
    /// 被再包一层 `sh -c '…'` 会全部失效。
    func fanWriteCommand(_ assignments: [(String, String)]) -> String {
        var lines: [String] = [
            "S=$(uci -q show gl_fanctrl 2>/dev/null | awk -F. '/[.]enabled=/ {print $2; exit}')",
            "[ -n \"$S\" ] || S=$(uci -q show gl_fanctrl 2>/dev/null | awk -F. 'NR==1{print $2}')",
            "[ -n \"$S\" ] || S='@fanctrl[0]'"
        ]
        for (key, value) in assignments {
            lines.append("uci -q set \"gl_fanctrl.$S.\(key)=\(value)\"")
        }
        lines.append("uci -q commit gl_fanctrl 2>/dev/null && echo committed")
        lines.append("/etc/init.d/gl_fanctrl restart >/dev/null 2>&1 || { /etc/init.d/gl_fanctrl stop >/dev/null 2>&1; /etc/init.d/gl_fanctrl start >/dev/null 2>&1; }")
        lines.append("sleep 1")
        lines.append("true")
        return lines.joined(separator: "; ")
    }

    /// 把任意字符串塞进 shell 的单引号里。值里可能有中文、空格、`$`、甚至换行。
    func shQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 读订阅列表。
    ///
    /// 不用 `uci show` 整段解析：多行地址在那种格式里是**跨行**的单引号值，
    /// 一个地址换了行，后面的键值全跟着错位。这里逐段 `uci get`，
    /// 输出成 `键|值` 的行，Swift 侧只按第一个 `|` 切，天然不怕换行。
    var subscriptionsCommand: String {
        lowPriority("""
        echo @@OCSUBS
        for s in $(uci -q show openclash 2>/dev/null | grep '=config_subscribe$' | cut -d= -f1 | cut -d. -f2-); do
          echo "S|$s"
          echo "N|$(uci -q get "openclash.$s.name" 2>/dev/null)"
          echo "E|$(uci -q get "openclash.$s.enabled" 2>/dev/null)"
          echo "U|$(uci -q get "openclash.$s.sub_ua" 2>/dev/null)"
          uci -q get "openclash.$s.address" 2>/dev/null | while IFS= read -r line; do [ -n "$line" ] && echo "A|$line"; done
          # 节点筛选：keyword / ex_keyword 都是 UCI 列表，uci get 一次吐一行。
          uci -q get "openclash.$s.keyword" 2>/dev/null | while IFS= read -r line; do [ -n "$line" ] && echo "K|$line"; done
          uci -q get "openclash.$s.ex_keyword" 2>/dev/null | while IFS= read -r line; do [ -n "$line" ] && echo "X|$line"; done
          n=$(uci -q get "openclash.$s.name" 2>/dev/null)
          if [ -n "$n" ]; then
            for ext in yaml yml; do
              f="/etc/openclash/config/$n.$ext"
              if [ -f "$f" ]; then
                # stat -c 在个别固件上没有，退回 date -r；两个都拿不到就不输出，
                # 列表里显示「还没下载」，好歹不会显示一个假时间。
                t=$(stat -c %Y "$f" 2>/dev/null)
                [ -n "$t" ] || t=$(date -r "$f" +%s 2>/dev/null)
                [ -n "$t" ] && echo "T|$t"
                break
              fi
            done
          fi
          echo "."
        done
        true

        """)
    }

    /// 新增（`id == nil`）或覆盖一条订阅。`uci add` 会把新段名打在标准输出上。
    ///
    /// 节点筛选的两个字段是 **UCI 列表**（`list keyword '香港'`），不是普通字符串：
    /// 每次保存先 `delete` 再逐条 `add_list`，否则旧关键词会一直挂在后面，
    /// 改一次多一条，越改越脏。
    func subscriptionSaveCommand(id: String?, name: String, address: String,
                                 ua: String, enabled: Bool,
                                 keywords: [String], excludeKeywords: [String]) -> String {
        var lines: [String] = []
        if let id, !id.isEmpty {
            lines.append("S=\(shQuote(id))")
        } else {
            lines.append("S=$(uci -q add openclash config_subscribe)")
        }
        lines.append("uci -q set \"openclash.$S.name\"=\(shQuote(name))")
        lines.append("uci -q set \"openclash.$S.address\"=\(shQuote(address))")
        lines.append("uci -q set \"openclash.$S.sub_ua\"=\(shQuote(ua))")
        lines.append("uci -q set \"openclash.$S.enabled\"=\(shQuote(enabled ? "1" : "0"))")
        // 新建时把 `sub_convert` 固定成 0（地址本身就是 Clash 配置，不做订阅转换）。
        // 空值会让 openclash.sh 里的 `[ "$sub_convert" -eq 0 ]` 报
        // 「integer expression expected」，那行错误会混进 /tmp/oc_sub.log，
        // 让真正的原因更难认。编辑时不覆盖，交给网页后台。
        if id == nil || id?.isEmpty == true {
            lines.append("uci -q set \"openclash.$S.sub_convert\"='0'")
        }

        lines.append("uci -q delete \"openclash.$S.keyword\" 2>/dev/null; true")
        for k in keywords {
            lines.append("uci -q add_list \"openclash.$S.keyword\"=\(shQuote(k))")
        }
        lines.append("uci -q delete \"openclash.$S.ex_keyword\" 2>/dev/null; true")
        for k in excludeKeywords {
            lines.append("uci -q add_list \"openclash.$S.ex_keyword\"=\(shQuote(k))")
        }
        // 两个列表都空的时候**不碰** keyword_option：网页后台可能特意关掉了筛选，
        // 这里硬写 1 会让它在用户没察觉的情况下开始过滤节点。
        if !keywords.isEmpty || !excludeKeywords.isEmpty {
            lines.append("uci -q set \"openclash.$S.keyword_option\"='1'")
        }

        lines.append("uci -q commit openclash && echo saved")
        lines.append("true")
        return lowPriority(lines.joined(separator: "; "))
    }

    func subscriptionDeleteCommand(_ sub: ProxySubscription) -> String {
        lowPriority("""
        uci -q delete \(shQuote("openclash.\(sub.id)"))
        uci -q commit openclash && echo deleted
        true

        """)
    }

    func subscriptionEnableCommand(_ sub: ProxySubscription, on: Bool) -> String {
        lowPriority("""
        uci -q set \(shQuote("openclash.\(sub.id).enabled"))=\(shQuote(on ? "1" : "0"))
        uci -q commit openclash && echo saved
        true

        """)
    }

    /// 前台跑一次订阅下载（`openclash.sh <名称> norestart`），把结果原样带回手机。
    ///
    /// 返回四段，各管一件事：
    ///   `@@RC`     —— 脚本的 `exit_code`（OpenClash 就是用它告诉 LuCI 成没成）；
    ///   `@@FILE`   —— `/etc/openclash/config/<名称>.yaml` 的 mtime，文件不在就是空；
    ///   `@@OCLOG`  —— 这一次**新增**的 `/tmp/openclash.log`（脚本正文日志全在这里，
    ///                  `LOG_OUT` 写的是文件不是 stdout，所以光看 stdout 永远是空的）；
    ///   `@@SUBLOG` —— 脚本自己的 stdout/stderr（正常为空，脚本崩了才有）。
    ///
    /// 只取新增的行：先记下当前行数，跑完从 `n+1` 行开始 tail，既有来龙去脉，
    /// 又不会把几百行历史日志整段搬回手机。
    func subscriptionDownloadCommand(_ name: String) -> String {
        let cfg = shQuote("/etc/openclash/config/\(name).yaml")
        return lowPriority("""
        base=$(wc -l < /tmp/openclash.log 2>/dev/null)
        [ -n "$base" ] || base=0
        B=/bin/bash
        [ -x "$B" ] || B=$(command -v bash 2>/dev/null)
        [ -n "$B" ] || B=/bin/sh
        if [ ! -f /usr/share/openclash/openclash.sh ]; then
          echo @@RC
          echo 127
          echo @@FILE
          echo @@OCLOG
          echo "路由器上没有 /usr/share/openclash/openclash.sh（插件没装全？）"
          echo @@SUBLOG
        else
          "$B" /usr/share/openclash/openclash.sh \(shQuote(name)) norestart >/tmp/oc_sub.log 2>&1
          sub_rc=$?
          echo @@RC
          echo "$sub_rc"
          echo @@FILE
          if [ -f \(cfg) ]; then
            t=$(stat -c %Y \(cfg) 2>/dev/null)
            [ -n "$t" ] || t=$(date -r \(cfg) +%s 2>/dev/null)
            echo "$t"
          fi
          echo @@OCLOG
          tail -n +$((base+1)) /tmp/openclash.log 2>/dev/null | tail -n 12
          echo @@SUBLOG
          tail -n 8 /tmp/oc_sub.log 2>/dev/null
        fi
        true

        """)
    }

    /// 删掉路由器上的一个配置文件。
    ///
    /// 和订阅是两回事：订阅段存在 UCI 里，配置文件是 `/etc/openclash/config/` 下的
    /// yaml。删订阅不会删文件（那可能正是内核在跑的那份），所以清理残留得单独来一次。
    ///
    /// 如果删的正好是 `config_path` 指向的那份，就把这个键一起删掉：留着一个指向
    /// 不存在文件的指针，OpenClash 下次启动会直接起不来。
    func configDeleteCommand(_ name: String) -> String {
        let path = "/etc/openclash/config/\(name)"
        return lowPriority("""
        p=\(shQuote(path))
        rm -f "$p" 2>/dev/null
        if [ "$(uci -q get openclash.config.config_path 2>/dev/null)" = "$p" ]; then
          uci -q delete openclash.config.config_path
          uci -q commit openclash
          echo cleared
        fi
        if [ -f "$p" ]; then echo failed; else echo deleted; fi
        true

        """)
    }

    /// 每个数据项对应一段脚本。同一档里的项用换行拼成一条命令，交给同一个 shell 跑完，
    /// 所以“项多了”只是脚本变长，不会多 fork 进程。
    func script(for item: PollItem) -> String {
        switch item {
        case .core:
            return """
            LC_ALL=C awk 'FNR==1{n=split(FILENAME,p,"/"); print "@@" toupper(p[n])} {print}' /proc/stat /proc/meminfo /proc/net/dev /proc/uptime /proc/loadavg /proc/net/route 2>/dev/null

            """
        case .sensors:
            return """
            echo @@TEMP
            for f in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
              if [ -r "$f" ]; then read -r v < "$f"; echo "T $v"; fi
            done
            echo @@FAN
            for f in /sys/class/hwmon/hwmon*/fan*_input; do
              if [ -r "$f" ]; then read -r v < "$f"; echo "F $v"; fi
            done
            echo @@FANPWM
            for d in /sys/class/thermal/cooling_device*; do
              if [ -r "$d/cur_state" ]; then
                t=$(cat "$d/type" 2>/dev/null)
                [ -n "$t" ] || t=unknown
                c=$(cat "$d/cur_state" 2>/dev/null)
                m=$(cat "$d/max_state" 2>/dev/null)
                echo "$t $c $m"
              fi
            done
            true

            """
        case .flash:
            // /rom 是只读 squashfs（df 的 Used 就是整块固件），/ 是 overlayfs
            // （等于可写分区）。只取这两行，不再读 /proc/mtd：那里既有整块固件分区、
            // 又有从它切出来的子分区（kernel / rootfs / rootfs_data），求和在不少机型上
            // 会把同一段空间算两遍，512 MB 的机器能读出 1 GB 来。
            return """
            echo @@FLASH
            df -k /rom / 2>/dev/null | awk 'NR>1{if($NF=="/rom")print "ROM",$2,$3; else if($NF=="/")print "ROOT",$2,$3,$4}'
            true

            """
        case .devices:
            // 租约只说明「发过 IP」，不能说明「还连着」。三处交叉判断：
            //   NEIGH —— ip neigh 里 REACHABLE/DELAY/PROBE 是内核刚确认过的；
            //   ARP   —— 没装 iproute2 的精简固件退回 /proc/net/arp；
            //   STA   —— WiFi 关联表（station dump），真正连着的客户端才有。
            // 三条命令都很轻，全部失败也只是判不出在线，不会影响列表本身。
            return """
            echo @@LEASES
            cat /tmp/dhcp.leases 2>/dev/null
            echo @@NEIGH
            ip -4 neigh show 2>/dev/null
            echo @@ARP
            cat /proc/net/arp 2>/dev/null
            echo @@STA
            for d in /sys/class/net/*; do
              n=${d##*/}
              [ -e "$d/phy80211" ] || continue
              iw dev "$n" station dump 2>/dev/null | awk '/^Station/{print $2}'
            done
            true

            """
        case .clashState:
            return """
            echo @@OCSTATE
            set -- $(pidof clash clash_meta clash_tun clash_lite mihomo 2>/dev/null); OCPID=$1
            if [ -n "$OCPID" ]; then echo running
            elif [ -d /usr/share/openclash ] || [ -x /etc/init.d/openclash ]; then echo stopped
            else echo missing; fi
            echo @@OCPID; echo "$OCPID"
            echo @@OCMODE; uci -q get openclash.config.proxy_mode 2>/dev/null
            echo @@OCCONFIG; uci -q get openclash.config.config_path 2>/dev/null
            echo @@OCCONFIGS; ls /etc/openclash/config/*.yaml /etc/openclash/config/*.yml 2>/dev/null | xargs -n1 basename 2>/dev/null
            echo @@OCPORT; p=$(uci -q get openclash.config.cn_port 2>/dev/null); [ -n "$p" ] || p=9090; echo "$p"
            echo @@OCSECRET; uci -q get openclash.config.dashboard_password 2>/dev/null
            echo @@OCDASH; uci -q get openclash.config.default_dashboard 2>/dev/null
            echo @@OCDIRS; for d in zashboard metacubexd yacd dashboard; do [ -d "/usr/share/openclash/ui/$d" ] && echo "$d"; done
            true

            """
        case .clashTraffic, .clashConnections:
            return metricsScript
        }
    }

    /// OpenClash 指标：一条命令里把状态、流量、连接表、内核内存/CPU、负载全取回来。
    ///
    /// 端口和密钥在这里自己查，不再依赖“状态档先跑过”。旧版靠状态查询把端口写进
    /// openClash.panelPort，一旦那条命令失败、或者切页时顺序不对，/traffic 就打在
    /// 默认 9090 上、或者带着错的密钥返回 4xx，界面就永远停在 0。
    /// 取数做了三层兜底：带密钥 curl → 不带密钥 curl → wget（部分固件只有 wget）。
    ///
    /// /traffic 必须只留**一行**：它是流式的，每秒吐一个 JSON 对象且不断开连接，
    /// 不截断的话一次会抓到好几行拼在一起（`{"up":1}{"up":2}`），解析必然失败。
    /// 用 `head -n 1` 拿到第一行就关管道，顺带把耗时从 3 秒压到 1 秒左右。
    var metricsScript: String {
        lowPriority("""
        CURL=$(command -v curl 2>/dev/null)
        WGET=$(command -v wget 2>/dev/null)
        PORT=$(uci -q get openclash.config.cn_port 2>/dev/null)
        [ -n "$PORT" ] || PORT=9090
        SECRET=$(uci -q get openclash.config.dashboard_password 2>/dev/null)
        set -- $(pidof clash clash_meta clash_tun clash_lite mihomo 2>/dev/null); OCPID=$1
        echo @@OCSTATE
        if [ -n "$OCPID" ]; then echo running
        elif [ -d /usr/share/openclash ] || [ -x /etc/init.d/openclash ]; then echo stopped
        else echo missing; fi
        echo @@OCPID; echo "$OCPID"
        echo @@OCPORT; echo "$PORT"
        echo @@OCSECRET; echo "$SECRET"
        echo @@TRAFFIC
        T=""
        if [ -n "$OCPID" ] && [ -n "$CURL" ]; then
          if [ -n "$SECRET" ]; then T=$($CURL -s -N -f -m 2 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$PORT/traffic" 2>/dev/null | head -n 1); fi
          [ -n "$T" ] || T=$($CURL -s -N -f -m 2 "http://127.0.0.1:$PORT/traffic" 2>/dev/null | head -n 1)
        fi
        if [ -z "$T" ] && [ -n "$OCPID" ] && [ -n "$WGET" ]; then
          T=$($WGET -q -O - -T 2 "http://127.0.0.1:$PORT/traffic" 2>/dev/null | head -n 1)
        fi
        echo "$T"
        echo @@CONN
        C=""
        if [ -n "$OCPID" ] && [ -n "$CURL" ]; then
          if [ -n "$SECRET" ]; then C=$($CURL -s -f -m 3 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$PORT/connections" 2>/dev/null); fi
          [ -n "$C" ] || C=$($CURL -s -f -m 3 "http://127.0.0.1:$PORT/connections" 2>/dev/null)
        fi
        if [ -z "$C" ] && [ -n "$OCPID" ] && [ -n "$WGET" ]; then
          C=$($WGET -q -O - -T 3 "http://127.0.0.1:$PORT/connections" 2>/dev/null)
        fi
        echo "$C"
        echo @@OCSTATUS
        if [ -n "$OCPID" ]; then awk '/^VmRSS|^Threads/' /proc/$OCPID/status 2>/dev/null; fi
        echo @@OCSTAT
        if [ -n "$OCPID" ]; then cat /proc/$OCPID/stat 2>/dev/null; fi
        echo @@SYSTAT
        read -r SY < /proc/stat 2>/dev/null; echo "$SY"
        echo @@LOADAVG
        read -r LD < /proc/loadavg 2>/dev/null; echo "$LD"
        true

        """)
    }
    /// 把同一页的项拼成一条命令：同一个 shell 里按顺序跑完，只有一次进程创建。
    /// 有几项共用一个脚本（比如流量和连接数合成的一条），这里按内容去重，避免重复执行。
    func command(for items: [PollItem]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for item in items {
            let body = script(for: item)
            if seen.insert(body).inserted { parts.append(body) }
        }
        return lowPriority(parts.joined(separator: "\n"))
    }

    /// 访问检测脚本。
    ///
    /// 四个站点**并行**探（各 `&` 后台跑，最后 `wait`），所以整条命令最多花一个
    /// `-m 4` 的时间，而不是四个串起来 20 秒——SSH 通道是串行的，串行检测会把
    /// 正在跑的轮询一起堵住。毫秒换算也挪回 Swift 侧，不再为每条结果 fork 一次 awk。
    var accessCommand: String {
        lowPriority("""
        echo @@CHECK
        p(){ r=$(curl -s -o /dev/null -L -m 4 -w '%{http_code} %{time_total}' "https://$2" 2>/dev/null); printf 'C %s %s\\n' "$1" "$r"; }
        p baidu www.baidu.com &
        p netease music.163.com &
        p github github.com &
        p youtube www.youtube.com &
        wait
        """)
    }
}

func formatBytes(_ value: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var number = max(0, value)
    var index = 0
    while number >= 1024 && index < units.count - 1 {
        number /= 1024
        index += 1
    }
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", number, units[index])
}

/// 闪存容量：单位规则和 `formatBytes` 完全一致，只有一处不同——
/// 不到 1 MB 时取整显示（`512 KB`，不带小数），因为闪存剩余很少掉到这个量级，
/// 真掉到了也没人关心 0.1 KB。之前这里把 GB / MB 两档又抄了一遍，纯属重复。
func formatFlashBytes(_ value: UInt64) -> String {
    let bytes = Double(value)
    guard bytes >= 1024 * 1024 else {
        return String(format: "%.0f KB", bytes / 1024)
    }
    return formatBytes(bytes)
}

func formatSpeed(_ value: Double) -> String {
    formatBytes(value) + "/s"
}

func formatUptime(_ seconds: Double) -> String {
    let total = Int(seconds)
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 { return "\(days)天 \(hours)小时" }
    if hours > 0 { return "\(hours)小时 \(minutes)分钟" }
    return "\(minutes)分钟"
}

/// 把采集脚本输出的一行按空格切开。
///
/// 这条 `line.split(separator: " ").map(String.init)` 原本在五个解析函数里各写一遍
/// （访问检查、闪存、DHCP 租约、邻居表、ARP 表），除了重复之外没有任何差别。
///
/// 参数写成具体的 `Substring` 而不是 `S: StringProtocol`：泛型版本在 CI 上编译不过。
/// 原因是 `" "` 这个字面量同时能推断成 `Character`（`Collection.split(separator:)`）
/// 和 `String`（Swift 5.7 起 `String` 也算 `RegexComponent`，走
/// `StringProtocol.split(separator: some RegexComponent)`），接收方是泛型时
/// 两个重载的优先级分不出高低，报 `ambiguous use of 'split'`。
/// 五个调用点传的都是 `text.split(separator: "\n")` 出来的 `Substring`，
/// 所以收窄成具体类型就回到原来那五行代码的写法，顺带把 `" "` 标成 `Character`
/// 让重载只剩一个候选。
private func splitFields(_ line: Substring) -> [String] {
    line.split(separator: " " as Character).map(String.init)
}


/// 落盘用的流量快照：`SubscriptionUsage` 负责算，这里只负责存。
///
/// 多一个 `savedAt`：判断这份缓存是不是太旧了——太久以前的数字画出来只会误导。
/// 存成独立类型而不是给 `SubscriptionUsage` 加 `Codable`：后者将来改字段
/// （比如机场新增一个 `reset_day`）会顺带改掉磁盘格式，旧数据就解不出来了。
private struct StoredUsage: Codable {
    var upload: Int64
    var download: Int64
    var total: Int64
    var expire: TimeInterval?
    var savedAt: TimeInterval

    init(_ usage: SubscriptionUsage) {
        upload = usage.upload
        download = usage.download
        total = usage.total
        expire = usage.expire
        savedAt = Date().timeIntervalSince1970
    }

    var usage: SubscriptionUsage {
        SubscriptionUsage(upload: upload, download: download, total: total, expire: expire)
    }
}
