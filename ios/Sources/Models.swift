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

/// 当前在用的上网方式。
///
/// 官方 App（`intl_zh.arb` 的 `internet_*` 一组）就是这四类：
/// 中继 / 以太网 / 蜂窝 / 热点共享。这台 MT3600BE 没有 Modem 口，
/// 所以只保留前两类 + 「未联网」——多列两个永远不可能出现的方式只会误导。
enum UplinkKind: String {
    case none
    case wired
    case repeater
    /// 手机 USB 热点共享（v3.2.2）。
    ///
    /// 和「中继 / 以太网」并列的第三条出口：路由器上是一个 `network.tethering` 接口，
    /// 出口网卡是挂在 USB 总线上的那张（这台是 `usb0`）。**和插 SIM 卡的 USB Modem
    /// 不是一回事**——那条是 `cellular.modem` 管的 `wwan`，这条是手机把它的网络
    /// 用数据线分给路由器。官方 App 的 Internet 页也是四类并列
    /// （`internet_*` 那组：repeater / cable / modem / tethering）。
    case tethering

    var title: String {
        switch self {
        case .none: return "未联网"
        case .wired: return "以太网"
        case .repeater: return "中继"
        case .tethering: return "热点共享"
        }
    }
}

/// 网络页的一整块数据（v2.6.5 起，v2.6.8 按官方 App 的字段补齐，
/// v2.8.0 补实时速率 / 累计流量 / 连接数 / 保留 IP）。
///
/// 只读采集；写操作在 `AppModel` 里另起一组（v2.7.0 起）。
struct NetworkInfo {
    /// 第一次采集回来之前为 false，界面据此把数值位置先占住（避免卡片长高再缩回）。
    var loaded = false

    // ---- 出口：哪一个接口真在联网 ----
    //
    // 这台机器（2026-11-15 实机）WAN 口根本没插线，上网走的是 5G 中继 `apclii0`。
    // v2.6.7 只认 `network.interface.wan`，于是整页显示「未连接」——这就是
    // 用户说的「数据有问题」。现在按默认路由的 dev 认领出口，中继也能正确显示。
    var uplink: UplinkKind = .none
    var uplinkProto = ""
    var uplinkIP = ""
    var uplinkGateway = ""
    var uplinkDNS: [String] = []
    var uplinkUptime: Double = 0
    var uplinkIfname = ""

    // ---- 中继上游（只有 uplink == .repeater 时有值）----
    var upstreamSSID = ""
    var upstreamSignal = 0
    var upstreamNoise = 0
    var upstreamRate = ""
    var upstreamChannel = ""
    var upstreamWidth = ""

    /// 实时速率（字节/秒），来自 `gl-clients get_wan_speed`。
    var rxSpeed: Double = 0
    var txSpeed: Double = 0

    /// 出口网口自开机以来的累计流量（字节），读 `/sys/class/net/<dev>/statistics`。
    /// 重启路由器会归零——这是网口计数器的性质，不是我把数算丢了。
    var wanRxTotal: Double = 0
    var wanTxTotal: Double = 0

    /// 当前 NAT 会话数（`/proc/net/nf_conntrack` 行数）。官方 App 的网络页也报这个。
    var connections = 0

    /// 物理 WAN 口插没插线（和「是否在用」无关：中继时它可能空着）。
    var wanCable = false

    // ---- 局域网 ----
    var lanIP = ""
    var lanMask = ""
    var dhcpStart = ""
    var dhcpLimit = ""
    var dhcpLease = ""
    var leaseCount = 0

    var bands: [WifiBandInfo] = []
    /// 无线四组（v3.0.0）：主 / 访客 / IoT / 多链路。网络页「无线」那几张卡读它。
    var wifiGroups: [WifiNetGroup] = []
    /// 驱动里有没有 MLO 段（`wireless.mld0`）。没有就不画多链路那张卡。
    var mloSupported = false
    var ports: [NetPortInfo] = []
    var clients: [NetClient] = []

    /// 中继的配置与状态（v2.9.1 起）。二级页「上网」用的就是它。
    var repeater = RepeaterInfo()

    /// 黑名单里的 MAC（大写）。用来把「阻止入网」的状态画到设备行上；
    /// 数据来自 `uci show gl-black_white_list`，与内核那层走的是同一份配置。
    var blockedMACs: [String] = []

    /// DHCP 保留地址：MAC（大写）→ IP。来自 `uci show dhcp` 的每个 `host` 段。
    /// 设备的「保留 IP」开关读这里，写完也能立刻核对，不看缓存。
    var reservedIPs: [String: String] = [:]

    /// 出口对应的 netifd 接口名：中继是 `wwan`，有线是 `wan`。断线重连要按名字调 `ifup`。
    var uplinkInterface: String {
        switch uplink {
        case .repeater: return "wwan"
        case .wired: return "wan"
        case .tethering: return "tethering"
        case .none: return "wan"
        }
    }

    var onlineClients: [NetClient] { clients.filter(\.online) }
    var offlineClients: [NetClient] { clients.filter { !$0.online } }
    var wifiClients: Int { bands.reduce(0) { $0 + $1.clients } }

    /// 在线设备按接入方式拆开：无线几台、网线几台。
    /// 官方 App 的客户端卡也是这么分的（`gl-clients status` 的 wireless_total / cable_total）。
    var onlineWireless: Int { onlineClients.filter { $0.iface != "有线" }.count }
    var onlineWired: Int { onlineClients.filter { $0.iface == "有线" }.count }

    /// 拓扑三片叶子各自的「通不通」。
    var uplinkOK: Bool { uplink != .none }
    var wifiOK: Bool { bands.contains { $0.up && $0.ssidOn } }

    /// WAN 那一个网口；认不出来时为 `nil`。
    var wanPort: NetPortInfo? { ports.first { $0.role == "WAN" } }

    /// **以太网出口通不通 = WAN 口自己有没有链路。**
    ///
    /// 以前写的是 `ports.contains { $0.up }`，即「随便哪个网口 up 就算通」。
    /// 这台机器的 LAN 口插着设备（eth1，carrier=1 / 1000M），WAN 口（eth0）
    /// 空着，于是网络页写着「已连接」「协商速率 1G」——用户 2026-11-15 的截图，
    /// 原话「我 wan 口都没有接」。端口角色由 `role` 分辨，只认 WAN 那一个。
    var wiredOK: Bool { wanPort?.up ?? false }

    /// 出口那一行最要紧的两个事实：走什么方式、上级地址。
    var uplinkLabel: String {
        switch uplink {
        case .none:
            return "未联网"
        case .repeater:
            return upstreamSSID.isEmpty ? "中继" : "中继 · \(upstreamSSID)"
        case .wired:
            return uplinkIP.isEmpty ? "以太网" : "以太网 · \(uplinkIP)"
        case .tethering:
            // 名字用手机型号（`Xiaomi 14`），读数时比「热点共享」四个字有用得多。
            let name = repeater.usbUplink?.label ?? ""
            let head = name.isEmpty ? "热点共享" : name
            return uplinkIP.isEmpty ? head : "\(head) · \(uplinkIP)"
        }
    }

    /// **WAN 口**的协商速率（2.5G / 1G / 100M）。没插线、读不到时是「—」。
    ///
    /// 以前取「所有端口里最快的那个」：LAN 口接着千兆设备、WAN 空着，也算出 1G，
    /// 和上面「已连接」一起把用户骗了一次（2026-11-15 截图）。速率是某一根线的
    /// 属性，只能取那根线自己。
    var bestPortLabel: String {
        Self.speedLabel(wanPort?.speed ?? 0)
    }

    /// 局域网这一侧的网口（除 WAN 之外的都是 LAN）。
    ///
    /// **拓扑图那片「有线」叶子说的是这一侧**（网线接了几台设备、跑多少速率），
    /// 跟「以太网出口」是两件事：WAN 口可以空着，同时 LAN 口接着一台千兆设备。
    /// v2.9.2 把两件事混成了一个 `wiredOK`，于是拓扑上「有线」写着「未连接」、
    /// 底下却又写「1 个端口」——用户 2026-11-15 说「有线显示逻辑还是有问题」就是这个。
    var lanPorts: [NetPortInfo] { ports.filter { $0.role != "WAN" } }
    var lanUpPorts: [NetPortInfo] { lanPorts.filter(\.up) }
    /// 有线侧有没有设备插着（任意一个 LAN 口有链路）。
    var lanOK: Bool { !lanUpPorts.isEmpty }
    /// 有线侧在用的最高协商速率（多口取最快的那根线）。
    var lanSpeedLabel: String { Self.speedLabel(lanUpPorts.map(\.speed).max() ?? 0) }

    static func speedLabel(_ speed: Int) -> String {
        guard speed > 0 else { return "—" }
        if speed >= 2500 { return "2.5G" }
        if speed >= 1000 { return "1G" }
        return "\(speed)M"
    }

    var protoLabel: String {
        switch uplinkProto {
        case "dhcp": return "DHCP"
        case "pppoe": return "PPPoE"
        case "static": return "静态"
        case "": return uplink == .none ? "—" : "已连接"
        default: return uplinkProto.uppercased()
        }
    }
}

/// 上网方式。官方 App 的 Internet 页顶部就是这三个页签：
/// `internet_repeater` 中继 / `internet_ethernet` 以太网 / `internet_cellular` 蜂窝网络。
/// 官方网页端也是同样的三块（`www/i18n/gl-sdk4-ui-internet.zh-cn.json` 的
/// `repeater` / `cable` / `modem` 三组）。
enum UplinkMode: String, CaseIterable, Identifiable {
    case repeater
    case wired
    case cellular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repeater: return "中继"
        case .wired: return "以太网"
        case .cellular: return "蜂窝网络"
        }
    }

    var icon: String {
        switch self {
        case .repeater: return "wifi"
        case .wired: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// 一个选项（标签 + 存进 uci 的值）。
struct RepeaterChoice: Identifiable {
    var label: String
    var value: String
    var id: String { value }
}

/// 挂在 USB 上的网络设备（手机「USB 热点共享」）。
///
/// 路由器内核里会多出一个网卡（这台机器叫 `usb0`），它的 `device` 指向 USB 总线，
/// 往上两级能读到厂商与型号（实机：`Xiaomi` / `Xiaomi 14`）。
/// **有设备 ≠ 已连上**：手机没点「USB 网络共享」、或路由器这边还没 `ifup tethering` 时，
/// 网卡在、但没有载波、也没有 IPv4——官方网页那页这时给的是「连接」按钮。
struct UsbUplink: Equatable {
    /// 网卡名，实机是 `usb0`（另有 `rndis0` / `ecm0` 这类叫法）。
    var name = ""
    /// 厂商，读不到是空串。
    var manufacturer = ""
    /// 型号，读不到是空串。
    var product = ""
    /// 已经拿到 IPv4（= 这条路真的通了）。
    var ip = ""

    var connected: Bool { !ip.isEmpty }

    /// 界面上一行里用的名字：型号优先，退到厂商，再退到网卡名。
    var label: String {
        if !product.isEmpty { return product }
        if !manufacturer.isEmpty { return manufacturer }
        return name
    }
}

/// 中继（无线中继）的配置与状态。
///
/// **数据只走官方通道**（见 `开发交接.md` 3.0）：配置读 `uci show repeater`，
/// 状态读 `ubus call repeater status`，周边 Wi-Fi 读 `ubus call repeater surveys`。
/// 字段名照官方来：
/// - `allow_change`（允许切换至其它已保存网络）→ `repeater.@main[0].auto`，
///   官方是三态：**0 不切换 / 1 自动切换 / 2 仅没网自动切换**；
/// - `lock_band`（频段选择）→ `repeater.@main[0].lock_band`，空 = 自动；
/// - `enable_disguise`（启用伪装）→ `repeater.@network[*].disguise`；
/// - `allow_auto_portal`（自动启用公共热点认证模式）→ `repeater.@network[*].auto_portal`；
/// - MAC 模式 → `repeater.@network[*].macaddr`，前缀 `r,` 随机 / `c,` 克隆。
struct RepeaterInfo {
    /// 中继整体开关（`repeater.@main[0].disabled` 取反）。
    var enabled = false
    /// 正在连的上级网络名。
    var ssid = ""
    /// 上级网络密码。只在编辑页回填，界面上不显示。
    var key = ""
    /// 锁定的 BSSID（`repeater.@network[*].bssid`）。
    var bssid = ""
    /// MAC 模式：`random` 随机 / `clone` 克隆 / `default` 出厂。
    var macMode = "default"
    var macAddress = ""
    /// 启用伪装：路由器伪装成客户端设备的同款设备。
    var disguise = false
    /// 自动启用公共热点认证模式。
    var autoPortal = false
    /// 切换模式：0 不切换 / 1 自动切换 / 2 仅没网自动切换。
    var switchMode = 1
    /// 智能重连（`repeater.@main[0].smart_reconnect`）。
    var smartReconnect = false
    /// 频段选择：`2g` / `5g` / `6g`，空字符串 = 自动。
    var lockBand = ""
    /// 连接状态（`connected` / `connecting` …）。
    var state = ""
    /// 上游信号（dBm）。
    var signal = 0
    var channel = 0
    var band = ""
    /// 正在连的那个 AP 的 BSSID。
    var currentBSSID = ""
    /// 来自中继的 DNS（官方 App 的 `dns_dnsFromRepeater`）。
    var dns: [String] = []
    /// 已保存的网络（`repeater.@network[*]`）。
    var saved: [RepeaterSavedNetwork] = []
    /// 有没有插 USB Modem（蜂窝模式能不能用）。
    var modemPresent = false
    /// 挂在 USB 上的网络设备——手机「USB 热点共享」走的就是这条。
    ///
    /// 和 `modemPresent` 是**两件事**：Modem 是插 SIM 卡的 4G/5G 棒（`cellular.modem`
    /// 的 `modems` 非空），热点共享是手机用数据线把它的网络分给路由器（内核里多出
    /// 一个 `usb0` 这样的网卡，厂商自报 RNDIS/NCM）。2026-11-18 用户插着小米 14 开了
    /// 热点共享，界面却写「没有检测到 USB Modem」——因为以前只问了前者。
    var usbUplink: UsbUplink?

    var connected: Bool { state == "connected" }

    /// 频段选择的几个档：自动 / 2.4G / 5G / 6G。
    var bandChoices: [RepeaterChoice] {
        [RepeaterChoice(label: "自动", value: ""),
         RepeaterChoice(label: "2.4G", value: "2g"),
         RepeaterChoice(label: "5G", value: "5g"),
         RepeaterChoice(label: "6G", value: "6g")]
    }

    /// MAC 模式的几档（官方 App：`internet_MACModeRandom` / `Clone` / `Real`）。
    var macModeChoices: [RepeaterChoice] {
        [RepeaterChoice(label: "随机", value: "random"),
         RepeaterChoice(label: "克隆", value: "clone"),
         RepeaterChoice(label: "出厂", value: "default")]
    }
}

/// 一条已保存的中继网络（`repeater.@network[*]`）。
struct RepeaterSavedNetwork: Identifiable, Equatable {
    var ssid = ""
    var bssid = ""
    var key = ""
    /// 是不是当前正在用的那一条（`selected='1'`）。
    var selected = false

    /// 同名的网络可能存了好几条（不同 BSSID），所以 id 要带上 BSSID 才不会撞。
    var id: String { "\(ssid)|\(bssid)" }
}

/// 扫描到的一个周边 Wi-Fi（`ubus call repeater surveys` 的一条）。
struct RepeaterSurvey: Identifiable, Equatable {
    var ssid = ""
    var bssid = ""
    /// dBm
    var signal = 0
    /// `2g` / `5g` / `6g`
    var band = ""
    var channel = 0
    /// 是否加密（官方叫「安全性」）。
    var secured = false

    var id: String { "\(ssid)|\(bssid)|\(band)\(channel)" }

    var bandLabel: String {
        switch band {
        case "2g": return "2.4G"
        case "5g": return "5G"
        case "6g": return "6G"
        default: return ""
        }
    }
}

/// 一台客户端（`ubus call gl-clients list` 的一条）。
///
/// **v2.8.1 起这一整块只认官方数据**（用户要求）：名单、名称、IP、接入方式、
/// 实时速率、累计流量、在线状态来自 `gl-clients list`；别名与设备类型来自
/// `gl-client` 的 UCI 配置；拦截状态来自 `gl-black_white_list`。不再抓 iwinfo
/// 关联表、也不再读 `/tmp/dhcp.leases`——那是 LuCI 那一套，随机 MAC 一变就跟
/// 官方列表对不上（本机实测：官方是 9C:…:0D，关联表是 9E:…:8D）。
///
/// 名称顺序：`gl-client.alias`（用户在官方 App 里改的）→ 官方 `name`
/// （这台固件的缓存会串号，4 个 MAC 一起报同一个名字，所以只在全场唯一时才用）
/// → IP（`displayName` 兜底）。
struct NetClient: Identifiable, Equatable {
    var mac = ""
    /// 最终上屏的名字（已经按上面顺序算好，解析时就填进来）。
    var name = ""
    /// 用户在官方 App 里设的别名；编辑页回填用，空字符串表示没设过。
    var alias = ""
    var ip = ""
    /// `2.4G` / `5G` / `6G` / `有线`
    var iface = ""
    /// 官方列表给的接入口名（`rai0` / `ra1` / `wlan3`）。比 `iface` 那三个粗标签精确，
    /// 数某个频段有多少台时按它对——HaLow（`wlan3`）这种 `iface` 认不出来的也能算进去。
    /// 旧固件没这个字段时留空，退回按 `iface` 比。
    var dev = ""
    var online = false
    var totalRx: Double = 0
    var totalTx: Double = 0
    /// 实时速率（字节/秒），`gl-clients` 的 `rx` / `tx`。离线时为 0。
    var rxSpeed: Double = 0
    var txSpeed: Double = 0
    /// 官方 App 判的设备类型（`gl-client.class`）：`phone` / `laptop` / `television`…
    /// 空表示官方还没归类。
    var deviceClass = ""
    /// 已加入黑名单（`gl-black_white_list`），当前不允许访问网络。
    /// 由 `uci show gl-black_white_list` 的 MAC 列表判定，不看缓存，写完立刻能核对。
    var blocked = false
    /// 当前绑定的保留地址（`dhcp` 的 host 段），空表示没绑。
    var reservedIP = ""

    var id: String { mac.isEmpty ? name + ip : mac }

    /// 名字是手机自己报的，经常是空的或者一排 `*`，那就退到 IP 尾号。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != "*" { return trimmed }
        if !ip.isEmpty { return ip }
        return mac.uppercased()
    }

    var trafficLabel: String {
        let total = totalRx + totalTx
        guard total > 0 else { return "—" }
        return formatBytes(total)
    }

    /// 实时速率那一栏：`↓ 12 KB/s`；两头都是 0（离线、或者这一拍没流量）就不显示。
    var rateLabel: String {
        guard online, rxSpeed + txSpeed >= 1 else { return "" }
        return "↓ \(formatBytes(rxSpeed))/s"
    }

    /// 详情页的两个方向速率，离线或没流量时给「—」。
    var downRateLabel: String {
        guard online, rxSpeed >= 1 else { return "—" }
        return "\(formatBytes(rxSpeed))/s"
    }
    var upRateLabel: String {
        guard online, txSpeed >= 1 else { return "—" }
        return "\(formatBytes(txSpeed))/s"
    }

    var wired: Bool { iface == "有线" }

    /// 设备类型的中文名。取值照官方固件 `/www/i18n/gl-sdk4-ui-clients.*.json`
    /// 里的 `clients.*` 键——固件前端就是 `t('clients.' + class)`，键和 class
    /// 是同一套字符串。以前这里抄的是 `gamepad` / `homeAppliances` / `router`
    /// 这些猜出来的名字，固件根本不发（2026-11-16 核对语言包时发现的）。
    var classLabel: String {
        if let known = ClientClass(rawValue: deviceClass) { return known.title }
        if deviceClass.isEmpty { return wired ? "有线设备" : "无线设备" }
        return deviceClass
    }

    /// 图标不在这里给：那一列统一走 `DeviceGlyph`（自绘线条），
    /// 免得 SF Symbols 里实心 / 线框混在一列里（见 `DeviceGlyph` 文件头）。
}

/// 官方固件支持的设备类型。
///
/// 原始值、中文名、顺序都照官方客户端语言包
/// （`/www/i18n/gl-sdk4-ui-clients.zh-cn.json` 的 `clients` 段），也就是官方 App
/// 那个「修改客户端设备」弹窗里能选的 13 项。选中后写回
/// `/etc/config/gl-client` 里那台设备的 `class`。
enum ClientClass: String, CaseIterable {
    case phone
    case pad
    case laptop
    case computer
    case television
    case camera
    case sound
    case printer
    case watch
    case games
    case smartAppliances = "smart_appliances"
    case gateway
    case unknown

    var title: String {
        switch self {
        case .phone: return "手机"
        case .pad: return "平板电脑"
        case .laptop: return "笔记本电脑"
        case .computer: return "台式电脑"
        case .television: return "电视机"
        case .camera: return "摄像头"
        case .sound: return "音响"
        case .printer: return "打印机"
        case .watch: return "可穿戴设备"
        case .games: return "游戏机"
        case .smartAppliances: return "智能家电"
        case .gateway: return "网关"
        case .unknown: return "未知"
        }
    }

    /// 中文名之外的图形不在这里给：图标走 `DeviceGlyph`（自绘线条），
    /// 免得 SF Symbols 里实心/线框混在一起。

    /// 选择器里的排列顺序，照官方 App 那个九宫格（手机 → 笔记本 → 可穿戴 → 电脑 →
    /// 平板 → 相机 → 打印机 → 音响 → 电视 → 游戏机 → 网关 → 智能家电 → 未知）。
    /// `allCases` 是声明顺序，直接用会显得像随手排的。
    static var pickerOrder: [ClientClass] {
        [.phone, .laptop, .watch, .computer, .pad, .camera, .printer,
         .sound, .television, .games, .gateway, .smartAppliances, .unknown]
    }
}

/// 一个 Wi-Fi 频段（一个 radio 一行）。
///
/// **v2.6.6 把「靠频率反推频段」删掉了**：MT3600BE 是 MT7993 + MTK 私有驱动，
/// 没有 `phy80211` 链接，`iw dev` 读不到任何东西（v2.6.5 整张无线卡是空的就栽在这）。
/// 现在频段直接取 UCI 的 `wireless.radioX.band`（`2g` / `5g`），这是配置面的事实，
/// 不依赖驱动实现；取不到时再按接口名前缀判（MTK 固定 ra=2.4G、rai=5G、rax=6G）。
struct WifiBandInfo: Identifiable, Equatable {
    var ifname = ""
    /// `2.4` / `5` / `6`，不带单位，显示时拼 "GHz"。
    var band = ""
    var ssid = ""
    var channel = 0
    /// 频宽，只存数字（`40` / `160`），显示时加 M。
    var width = ""
    var clients = 0
    /// 这个 radio 是否开着（UCI `disabled=1` 为关）。
    var up = false
    /// 主 SSID 是否在广播（`wireless.<主接口>.disabled`）。关掉主 SSID 但留着
    /// 访客 / IoT / MLO 网络是常见操作，两种情况都要能说清。
    var ssidOn = true
    /// `WPA3 混合` / `WPA2` / `无密码`
    var encryption = ""
    /// 发射功率，dBm；0 表示没读到。
    var txPower = 0
    /// 同一 radio 上除主 SSID 之外的网络个数（访客 / IoT / MLO）。
    var extraNets = 0

    // ---- 下面几个只有编辑 Wi-Fi 时才用得到（v2.7.0 起这一页可写）----

    /// 主 SSID 的 UCI 段名（`ra0` / `rai0`）。改名称、密码、开关都写这一段。
    var section = ""
    /// 所属 radio 的 UCI 段名（`MT7993_1_2`）。信道 / 频宽 / 功率写这一段。
    var radio = ""
    /// 当前密码（UCI `key`）；编辑页要回填。读不到就是空，界面上留空表示「不改密码」。
    var key = ""
    /// SSID 是否隐藏（`hidden=1`）。
    var hidden = false
    /// 原始 `htmode`（`EHT40`）。写频宽要保留前面的制式前缀，不能只存数字。
    var htmode = ""
    /// UCI 的发射功率百分比（`txpower=100`）。0 表示这一项没配。
    var txPowerPercent = 0
    /// `channel` 原值：`auto` 或数字。`auto` 时上面那个 `channel` 是实测值。
    var channelMode = ""

    /// 能不能在这一页改：段名都拿不到就不放编辑入口，免得点进去写错段。
    var editable: Bool { !section.isEmpty && !radio.isEmpty }

    var id: String { ifname.isEmpty ? band : ifname }

    /// 官方对 `s1g` 的叫法就是 **Sub-1 GHz**（见 `gl-sdk4-ui-wireless` 里那张频段名表：
    /// `{"2g":"2.4 GHz", …, s1g:"Sub-1 GHz", mld:"MLO"}`）。固件 4.11.0 起这台机器
    /// 可能挂一支 HaLow 外挂（`wireless.halow0`，`band='s1g'`），照旧拼成「S1G GHz」就成了乱码。
    var bandName: String {
        if band.isEmpty { return "无线" }
        if band == "S1G" { return "Sub-1 GHz" }
        return "\(band) GHz"
    }

    var channelLabel: String {
        var parts: [String] = []
        if channel > 0 { parts.append("CH \(channel)") }
        if !width.isEmpty { parts.append("\(width) MHz") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// 信道这一项在界面上的说法：自动时要带出实际落点，否则「自动」等于没说。
    var channelSettingLabel: String {
        if channelMode == "auto" || channelMode.isEmpty {
            return channel > 0 ? "自动 · CH \(channel)" : "自动"
        }
        return "CH \(channelMode)"
    }

    var powerLabel: String {
        txPowerPercent > 0 ? "\(txPowerPercent)%" : (txPower > 0 ? "\(txPower) dBm" : "—")
    }

    /// 这一频段能选的频宽。MT7993 的 2.4G 最高 EHT40、5G 最高 EHT160（固件
    /// `wifi-features-MT7993_1_1/_1_2` 里写死的），列超过上限的选项只会让路由器拒收。
    var widthOptions: [String] {
        // Sub-1 GHz 的带宽写在 `s1g_chanbw`（1/2/4/8 MHz），和 2.4/5/6 的 `htmode`
        // 不是一套东西，所以这里不给选项——那个频段的带宽不在这一页改。
        if band == "S1G" { return [] }
        return band == "2.4" ? ["20", "40"] : ["20", "40", "80", "160"]
    }

    /// 可选信道。5G 只列非 DFS 的那几段——DFS 信道要等 60 秒雷达检测，
    /// 官方 App 也得单独给个「允许 DFS」的开关，这里不摊开。
    var channelOptions: [Int] {
        if band == "2.4" { return Array(1...13) }
        if band == "5" { return [36, 40, 44, 48, 149, 153, 157, 161, 165] }
        return []
    }

    var securityLabel: String {
        switch encryption {
        case "", "none": return "无密码"
        case "psk2", "psk2+ccmp", "psk2+tkip+ccmp": return "WPA2"
        case "psk", "psk+ccmp": return "WPA"
        case "sae", "sae-mixed", "psk3", "sae+ccmp": return encryption == "sae" ? "WPA3" : "WPA3 混合"
        case "psk-mixed", "psk-mixed+ccmp": return "WPA/WPA2 混合"
        default: return encryption.uppercased()
        }
    }
}

/// 一组无线网络：主网络 / 访客 / IoT / 多链路（MLO）。
///
/// 这台机器（GL-MT3600BE，MT7993）每个频段是一条独立的 `wifi-iface`，同一组的两条
/// 只能靠配置里的线索认：访客 / IoT 看 `network=guest|iot`，MLO 看 `wireless.mld0.iface`
/// 里列的那几个网口名，剩下的 `network=lan` 的 AP 就是主网络。
///
/// 三个开关的语义要分清（v3.0.0）：
///   - 成员 `disabled`：这一条 BSS 有没有在广播；
///   - 独立 network 段 `network.guest.disabled`：那个网桥和网段在不在；
///   - 两者都开，用户才认为「这个网络开着」。
struct WifiNetGroup: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case mlo
        case main
        case guest
        case iot

        var title: String {
            switch self {
            case .mlo: return "多链路"
            case .main: return "主网络"
            case .guest: return "访客网络"
            case .iot: return "IoT 网络"
            }
        }

        /// 独立网络段的 UCI 名；主网络与 MLO 没有单独的段。
        var networkName: String {
            switch self {
            case .guest: return "guest"
            case .iot: return "iot"
            default: return ""
            }
        }

        /// 关掉之后要跟着 `ifdown` 的接口名（和 UCI 段同名）。
        var interfaceName: String { networkName }
    }

    var kind: Kind = .main
    var ssid = ""
    var key = ""
    var hidden = false
    /// 组里各频段那条 `wifi-iface`（2.4G / 5G 各一条）。
    var members: [WifiBandInfo] = []
    /// 接在这个组上的在线设备数（按成员网口的关联表相加）。
    var clients = 0
    /// 有没有任何一条成员在广播。
    var broadcasting = false
    /// 独立 network 段（`guest` / `iot`）是否启用；主网络与 MLO 恒为 true。
    var networkOn = true
    /// 段名齐了才能改。
    var editable = true

    var id: String { kind.rawValue }

    var isOn: Bool { broadcasting && networkOn }

    /// 「2.4 GHz + 5 GHz」这种频段串。
    var bandSummary: String {
        let names = members.map(\.bandName).filter { !$0.isEmpty }
        return names.isEmpty ? "未配置" : names.joined(separator: " + ")
    }

    /// 有没有任意一条成员是加密的（决定编辑页要不要密码行）。
    var needsKey: Bool {
        members.contains { !$0.encryption.isEmpty && $0.encryption != "none" }
    }

    /// 加密方式取第一条成员的（同组几条本来就一致）。
    var securityLabel: String { members.first?.securityLabel ?? "" }
}

/// 一个物理网口。
struct NetPortInfo: Identifiable, Equatable {
    var name = ""
    /// `WAN` / `LAN`，按 `ubus` 报的 `l3_device` 判定，判不出时一律 LAN。
    var role = "LAN"
    var up = false
    /// 握手速率（Mbps），断开或读不到时为 0。
    var speed = 0
    /// `full` / `half` / ``（断开时读不到）。
    var duplex = ""

    var id: String { name }

    var speedLabel: String {
        guard speed > 0 else { return up ? "—" : "未连接" }
        if speed >= 1000 { return String(format: "%.0f Gbps", Double(speed) / 1000) }
        return "\(speed) Mbps"
    }

    /// 官方 App 的端口行是「已连接 · 1000 Mbps 全双工」。
    var detailLabel: String {
        guard up else { return "未连接" }
        let bits = speed > 0 ? "\(speed) Mbps" : ""
        let full = duplex == "full" ? "全双工" : ""
        let joined = [bits, full].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? "已连接" : joined
    }
}

/// OpenClash 的运行状态与面板信息。
///
/// **v3.1.9：加了 `Equatable`，用来挡住「值没变也照写一遍」。**
/// 这份结构每 2 秒被重新拼一次（指标脚本里自带 pidof / 端口 / 密钥），
/// 旧代码无条件 `openClash = info`，等于每拍都通知一遍所有观察者：
/// 代理页整页重算，其中「控制面板」那张卡里的按钮也跟着重建 → 闪。
/// 现在只有真变了才赋值（见 `AppModel.applyClashPresence`）。
struct OpenClashInfo: Equatable {
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

    /// 显式写一个初始化器（v2.4.25）。
    ///
    /// 下面那个 `init?(header:)` 把编译器自动生成的 memberwise init 顶掉了，
    /// 而落盘缓存还原时需要「从四个数直接造一个」。没有它就只能拿响应头字符串反序列化，
    /// 那是把「存储格式」和「解析格式」硬绑在一起，改一个准坏另一个。
    init(upload: Int64, download: Int64, total: Int64, expire: TimeInterval?) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

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

    /// 剩余流量 = 总量 − 已用（小于 0 按 0，机场偶尔会给出超额的数据）。
    ///
    /// 不限量（`total == 0`）时没有「剩余」可言，返回 nil —— 卡片上就不写这一行，
    /// 而不是画一个 `剩余 ∞` 让人以为还能算出个数。
    var remaining: Int64? {
        guard total > 0 else { return nil }
        return max(0, total - used)
    }

    /// 卡片 / 列表那一行用的「剩余 89.8 GB」。不限量套餐为 nil。
    var remainingText: String? {
        guard let remaining else { return nil }
        return "剩余 " + Self.bytes(remaining)
    }

    /// 卡片上用的短版本：`剩 21 天` / `已过期` / `长期有效`。
    /// 完整版 `expireText` 带日期，订阅列表那一行放得下；配置卡里要跟用量数字并排，
    /// 多十来个字符就会把数字挤成 `…`。
    var shortExpireText: String? {
        guard let expire else { return nil }
        if expire == 0 { return "长期有效" }
        guard let left = daysLeft() else { return nil }
        return left == 0 ? "已过期" : "剩 \(left) 天"
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
    case network
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .proxy: return "代理"
        case .network: return "网络"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .proxy: return "globe"
        case .network: return "wifi.router"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// TabView 的下标 ↔ 页面。
    ///
    /// v2.6.5 起底栏四项，网络页插在代理与设置之间（用户 2026-11-15 指定位置）。
    /// 改这里的顺序必须同时改 `MainTabs` 里的 `tag`，两处是同一个约定的两半。
    init(tab: Int) {
        switch tab {
        case 1: self = .proxy
        case 2: self = .network
        case 3: self = .settings
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
    case network
    case clashState
    case clashTraffic
    case clashConnections

    var id: String { rawValue }

    var page: AppPage {
        switch self {
        case .core, .sensors, .flash, .devices: return .overview
        case .network: return .network
        case .clashState, .clashTraffic, .clashConnections: return .proxy
        }
    }

    /// 是否跟着刷新间隔反复采集。
    /// OpenClash 的模式和配置文件列表要问 7 次 uci，只在进入代理页时取一次，
    /// 之后每轮只确认运行状态和面板端口，省下的都是路由器的 CPU。
    var isPeriodic: Bool { self != .clashState }
}

/// 采集计划：哪一页该采哪些项。
///
/// v3.1.7 起设置页里的「采集与刷新」整页删掉了，刷新节奏固定成 2 秒
/// （见 `AppModel.pollSeconds`）。所以这里只剩「哪一页采哪些项」，
/// 不再有秒数、也不再去 UserDefaults 读写（老键在 `AppModel.init` 里顺手清掉）。
struct PollConfiguration {
    func items(on page: AppPage) -> [PollItem] {
        // v2.8.2：概览页的「连接设备」卡改读官方客户端列表（`network`），所以概览也要
        // 采这一项；反过来 `devices`（租约 + ARP 那套旧名单）已经没有界面在用，停采。
        PollItem.allCases.filter { item in
            switch item {
            case .network: return page == .network || page == .overview
            case .devices: return false
            default: return item.page == page
            }
        }
    }
}
