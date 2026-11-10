import Foundation

enum OverviewModule: String, CaseIterable, Codable, Identifiable {
    case speed
    case hardware
    case flash
    case devices
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "实时速度"
        case .hardware: return "硬件状态"
        case .flash: return "闪存"
        case .devices: return "连接设备"
        case .system: return "系统信息"
        }
    }

    var subtitle: String {
        switch self {
        case .speed: return "上下行速率与速度曲线"
        case .hardware: return "CPU、内存、温度与风扇"
        case .flash: return "已用与剩余空间"
        case .devices: return "DHCP 租约设备"
        case .system: return "主机、固件、内核与负载"
        }
    }

    var icon: String {
        switch self {
        case .speed: return "speedometer"
        case .hardware: return "thermometer.medium"
        case .flash: return "internaldrive"
        case .devices: return "laptopcomputer.and.iphone"
        case .system: return "info.circle"
        }
    }
}

struct RouterProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var host: String
    var port: Int
    var user: String
    var webPort: Int? = nil

    var title: String { label.isEmpty ? host : label }
    var subtitle: String { "\(user)@\(host):\(port)" }
    var webPortValue: Int {
        guard let webPort, (1...65535).contains(webPort) else { return 80 }
        return webPort
    }
}

struct DeviceInfo: Identifiable {
    let id = UUID()
    var ip: String
    var mac: String
    var name: String
    /// 是否真的还在线。
    ///
    /// `/tmp/dhcp.leases` 只是「租出去过」的记录，租期默认 12 小时，
    /// 设备关机后租约照样在文件里躺着——以前拿它当在线名单，
    /// 于是关掉的手机、搬走的笔记本永远显示「在线」。
    /// 现在这条由 ARP / 邻居表 / WiFi 关联表三处交叉得出，租约只负责名字。
    var online: Bool = true
}

struct OverviewStats {
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var download: Double = 0
    var upload: Double = 0
    var sessionDownload: Double = 0
    var sessionUpload: Double = 0
    var uptime: Double = 0
    var load: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var temperature: Double?
    var fanRPM: Double?
    /// 风扇转速占比（0–100），由 `cooling_device` 的 `cur_state / max_state` 换算。
    ///
    /// 概览页的「低速 / 中速 / 高速」只看这个值，不再看 rpm：各机型风扇满转
    /// 从 2000 到 5000 转都有，写死 1200 / 2400 两档对谁都对不上——3000 转的
    /// 机器永远进不了「高速」，5000 转的机器刚过半就已经满格了。
    var fanPWM: Int?
    var wanDevice = ""
}

struct RouterInfo {
    var hostname = ""
    var model = ""
    var architecture = ""
    var firmware = ""
    var kernel = ""
    var cpuCores = 0
}

struct OpenClashInfo {
    var installed = false
    var running = false
    var mode = "rule"
    var config = ""
    var configs: [String] = []
    var panelPort = 9090
    var secret = ""
    var dashboard = ""
    var dashboards: [String] = []
    var panelURL: URL?
}

struct OpenClashMetrics {
    var upload: Double = 0
    var download: Double = 0
    var uploadTotal: UInt64 = 0
    var downloadTotal: UInt64 = 0
    var connections: Int = 0
    var memory: UInt64 = 0
    var cpu: Double = 0
    var load: Double = 0
    /// 最近一次是否真的读到了内核接口（curl/wget 失败或密钥不对时为 false）。
    var apiReachable = false
}

/// 一条 OpenClash 订阅（路由器 UCI 里的 `config_subscribe` 段）。
///
/// 订阅不存手机里：路由器上的 UCI 才是唯一来源，网页后台和 App 改的是同一份数据，
/// 所以这里只做「读出来 → 改 → commit」，不在本地另存一份。
/// `name` 同时是产物文件名（`/etc/openclash/config/<name>.yaml`），重名会互相覆盖。
struct ProxySubscription: Identifiable, Hashable {
    /// UCI 段名（`cfg0a1b2c` 或 `@config_subscribe[0]`），增删改都靠它定位。
    var id: String
    var name: String
    /// 原始地址字段，可能有多行：一行一条订阅地址。
    var address: String
    /// 请求时的 User-Agent，OpenClash 默认 `clash-verge/v2.4.5`。
    var ua: String
    var enabled: Bool
    /// 已下载配置文件的修改时间；还没下载过就是 nil。
    var updatedAt: Date?
    /// 节点筛选：命中这些关键词的节点才保留（UCI `keyword`，是个列表）。
    /// 一行一个；一行里用 `&` 连接表示「必须同时包含」，多行之间是「或」，都不区分大小写。
    var keywords: [String] = []
    /// 排除关键词（UCI `ex_keyword`），命中就丢掉，写法同上。
    var excludeKeywords: [String] = []
    /// 机场报回来的流量和到期（v2.4.19）。列表先渲染基础信息，这一项是后补的，
    /// 所以是可选的：读不到就整块不出现，不留一个「0 B / 0 B」的假条。
    var usage: SubscriptionUsage?

    /// 有没有配过筛选。空 = 不筛，全部节点都留下。
    var hasFilters: Bool { !keywords.isEmpty || !excludeKeywords.isEmpty }

    var lines: [String] {
        address.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 列表第二行：第一行地址的域名。拿不到 host 就退回原串。
    var host: String {
        guard let first = lines.first else { return "" }
        if let host = URL(string: first)?.host, !host.isEmpty { return host }
        return first
    }

    var detail: String {
        guard !host.isEmpty else { return "没有地址" }
        guard let date = updatedAt else { return host + " · 还没下载" }
        return host + " · " + Self.relative(date)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前更新" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400)) 天前更新" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日更新"
        return formatter.string(from: date)
    }
}

/// 订阅的用量信息，来自机场响应头 `subscription-userinfo`。
///
/// **为什么在 App 里自己请求**：OpenClash 不缓存这个头。它的网页后台每次渲染
/// 配置文件列表都现场 `curl -sLI -X GET` 打一遍订阅地址，从响应头里抠出这一行
/// （`luci-app-openclash/luasrc/controller/openclash.lua` 的 `fetch_sub_info`）。
/// 配置文件和 UCI 里都没有这份数据，想显示就只能照同样的路子重新请求一次。
///
/// 字段语义与 OpenClash 一致：三个数都是**字节**，`expire` 是 Unix 秒，
/// `total = 0` 表示不限量（网页后台显示 ∞），`expire = 0` 表示长期有效。
struct SubscriptionUsage: Hashable {
    var upload: Int64
    var download: Int64
    /// 0 = 不限量。
    var total: Int64
    /// nil = 机场没给这一项；0 = 长期有效。
    var expire: TimeInterval?

    var used: Int64 { upload + download }

    /// 已用比例。总量为 0（不限量）时没有比例可言。
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    /// 剩余天数，向上取整；已过期为 0。长期有效或没给到期时间返回 nil。
    func daysLeft(now: Date = Date()) -> Int? {
        guard let expire, expire > 0 else { return nil }
        return max(0, Int(ceil((expire - now.timeIntervalSince1970) / 86_400)))
    }

    var isLifetime: Bool { expire == 0 }

    /// 「已用 / 总量」，总量为 0 时按 OpenClash 的写法显示 ∞。
    var amountText: String {
        let usedText = Self.bytes(used)
        guard total > 0 else { return usedText + " / ∞" }
        return usedText + " / " + Self.bytes(total)
    }

    var percentText: String? {
        guard let fraction else { return nil }
        return String(format: "%.1f%%", fraction * 100)
    }

    /// 到期那一行的文案：`12-01 到期 · 剩 21 天` / `长期有效` / 过期后 `已过期`。
    var expireText: String? {
        guard let expire else { return nil }
        if expire == 0 { return "长期有效" }
        let date = Date(timeIntervalSince1970: expire)
        let formatter = DateFormatter()
        formatter.dateFormat = "yy-MM-dd"
        let day = formatter.string(from: date)
        guard let left = daysLeft() else { return day + " 到期" }
        if left == 0 { return day + " · 已过期" }
        return day + " · 剩 \(left) 天"
    }

    /// 和 OpenClash 的 `fs.filesize` 对齐：超过 1 GB 用 GB，其余 MB / KB，只留一位小数。
    static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        if v >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1024 * 1024 { return String(format: "%.1f MB", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.1f KB", v / 1024) }
        return "\(Int(v)) B"
    }

    /// 从 `subscription-userinfo: upload=1; download=2; total=3; expire=4` 里抠数字。
    /// 键名大小写不敏感（各机场写法不统一），缺 `total` 就当不限量。
    init?(header: String) {
        let lower = header.lowercased()
        guard lower.contains("subscription-userinfo") else { return nil }

        func number(_ key: String) -> Int64? {
            guard let range = lower.range(of: key + "=") else { return nil }
            let digits = lower[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int64(digits)
        }

        guard let up = number("upload"), let down = number("download") else { return nil }
        upload = up
        download = down
        total = number("total") ?? 0
        expire = number("expire").map(TimeInterval.init)
    }
}

/// 一次操作的结果，摊在弹窗里给人看。
///
/// 为什么不用系统 `alert`：sheet 里系统弹窗的锚点会算错、有时干脆不显示（v1.28.21 踩过）。
/// 为什么必须有它：`errorMessage` 只在登录页和设置页渲染，弹窗里调 `presentError`
/// 等于把错误丢进黑洞——v2.1.0 用户点「立即更新」毫无反应就是这么来的。
struct Notice: Equatable {
    enum Kind { case ok, fail, info }

    var kind: Kind
    var title: String
    var detail: String = ""

    var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .fail: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}


struct AccessCheck: Identifiable {
    enum Site: String, CaseIterable, Identifiable {
        case baidu
        case netease
        case github
        case youtube

        var id: String { rawValue }

        var title: String {
            switch self {
            case .baidu: return "百度搜索"
            case .netease: return "网易云音乐"
            case .github: return "GitHub"
            case .youtube: return "YouTube"
            }
        }
    }

    /// 用站点做标识，不用新建 UUID：每次检测都会重建数组，
    /// 用 UUID 会让 SwiftUI 认为所有格子都换了新的，整块重新插入、动画乱闪。
    var id: String { site.id }
    var site: Site
    var success = false
    var latency: Int = 0
    var tested = false
}

struct FlashInfo {
    var total: UInt64 = 0
    var systemUsed: UInt64 = 0
    var appUsed: UInt64 = 0
    var available: UInt64 = 0

    var hasData: Bool { total > 0 }

    /// total 只由系统看得见的两块算出来：只读固件（squashfs）+ 可写分区，
    /// 所以永远不会超过物理闪存，「已用 + 剩余 = 共」也恒成立，
    /// 圆环填到哪儿和中间的百分比是同一个数。
    var usedBytes: UInt64 {
        guard total > 0 else { return 0 }
        return min(total, systemUsed &+ appUsed)
    }

    var usedFraction: Double {
        total > 0 ? min(1, Double(usedBytes) / Double(total)) : 0
    }
}

/// 速度曲线上的一个点。只保留画图要用的两个值，
/// 以前还顺带存了 cpu / memory，但没有任何视图读它——每 2 秒多存两份 Double，
/// 只为了让整个数组多一次拷贝。
/// 速度曲线的一个采样点。
/// 以前是 `Identifiable` + `id = UUID()`，但全仓没有任何 `ForEach` 用它——
/// 每 2 秒白生成一个 UUID，数组还因为 id 不同没法直接比较（v2.1.13 去掉）。
struct HistoryPoint {
    let date: Date
    let download: Double
    let upload: Double
}

// MARK: - 风扇控制

/// 路由器上的风扇控制状态，字段与 `gl-fanctrl` 插件的 UCI 配置一一对应。
///
/// 参考 https://github.com/XIAOZHAOXSXH/gl-fanctrl —— 它把风扇接管逻辑放在一个 procd
/// 守护进程里，配置写在 `/etc/config/gl_fanctrl`，界面只是这个配置的另一个入口。
/// 所以本 App **不自己算曲线、也不直接写 sysfs**：只读写同一份 UCI 配置再重启服务，
/// 免得和守护进程抢同一个 cooling_device（两边各写一次，风扇会来回跳）。
struct FanControlState: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case auto
        case manual

        var id: String { rawValue }
        var title: String { self == .auto ? "自动" : "手动" }
    }

    /// 装了这个插件没有（`/etc/config/gl_fanctrl` 是否存在）。
    var installed = false
    /// 有没有成功读过一次。没读过之前不能一口咬定「未安装」——
    /// 刚打开面板那半秒，`installed` 还是默认的 false。
    var loaded = false

    // 配置（UCI）
    var enabled = false
    var mode: Mode = .auto
    var startTemp = 70
    var wallTemp = 76
    var criticalTemp = 88
    var hysteresis = 3
    var startPercent = 35
    var maxPercent = 100
    var manualPercent = 0
    var pollInterval = 2

    // 运行态（sysfs / proc）
    var temperature: Double?
    var rpm: Double?
    /// cooling_device 的 cur_state 按 max_state 换算出来的百分比。
    var pwmPercent: Int?
    /// gl-fanctrl 守护进程是否在跑。官方 gl_fan 的进程名在各型号固件里不统一，
    /// 探不准就不显示——宁可少一格信息，也不要给一个会骗人的绿点。
    var pluginRunning = false

    // v1.28.28 删掉了 `expectedPercent`：它唯一的用途是风扇页那行
    //「按曲线此刻应为 x%」的提示，而用户要求把那行去掉。
    // 那个数只把温度代进曲线算一遍，界面上既不解释依据、也不带操作，
    // 读的人还得自己判断「29% 和实测 26% 算不算异常」。留着就是死代码。
    // 想恢复的话：`startPercent + (t - startTemp)/(wallTemp - startTemp) * (maxPercent - startPercent)`，
    // 还要处理回差带和温度墙以上两段。
}

// MARK: - 页面与采集

/// 轮询跟着页面走：只有当前标签页要用的数据才会被采集。
enum AppPage: String, CaseIterable, Identifiable {
    case overview
    case proxy
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .proxy: return "代理"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxy: return "globe"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// TabView 的下标 ↔ 页面。
    init(tab: Int) {
        switch tab {
        case 1: self = .proxy
        case 2: self = .settings
        default: self = .overview
        }
    }
}

/// 一项可以单独采集的数据。每一项只属于一个页面，只有那一页在前台时才会去取。
enum PollItem: String, CaseIterable, Identifiable, Codable {
    case core
    case sensors
    case flash
    case devices
    case clashState
    case clashTraffic
    case clashConnections

    var id: String { rawValue }

    var page: AppPage {
        switch self {
        case .core, .sensors, .flash, .devices: return .overview
        case .clashState, .clashTraffic, .clashConnections: return .proxy
        }
    }

    /// 是否跟着刷新间隔反复采集。
    /// OpenClash 的模式和配置文件列表要问 7 次 uci，只在进入代理页时取一次，
    /// 之后每轮只确认运行状态和面板端口，省下的都是路由器的 CPU。
    var isPeriodic: Bool { self != .clashState }
}

/// 存进 UserDefaults 的采集配置：现在只有一个全局刷新间隔。
struct PollConfiguration: Codable, Equatable {
    var seconds: Double = 2

    static let range: ClosedRange<Double> = 1...15

    var clampedSeconds: Double {
        min(max(seconds.rounded(), Self.range.lowerBound), Self.range.upperBound)
    }

    func items(on page: AppPage) -> [PollItem] {
        PollItem.allCases.filter { $0.page == page }
    }

    mutating func setSeconds(_ value: Double) {
        seconds = min(max(value.rounded(), Self.range.lowerBound), Self.range.upperBound)
    }

    init() {}

    /// 老版本的配置里存的是三档秒数，没有 seconds，这里回落默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 2
        seconds = min(max(value.rounded(), Self.range.lowerBound), Self.range.upperBound)
    }

    static func load() -> PollConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "pollConfiguration"),
              let decoded = try? JSONDecoder().decode(PollConfiguration.self, from: data) else {
            return PollConfiguration()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "pollConfiguration")
        }
    }
}
