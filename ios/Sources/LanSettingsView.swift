import SwiftUI

/// 局域网与端口（v2.9.0）。
///
/// **入口只有拓扑图中间那个路由器**（「有线」那片叶子也进同一页，端口就在这儿看）。
/// 以前这些内容占网络页最后一张卡，既挤又没人找得到；用户 2026-11-15 让把它收成
/// 二级页，并且「点路由器才进」，所以网络页正文只剩拓扑 / 上网 / 设备三块。
///
/// 能改的只有 DHCP 地址池（起止 + 租期）。**LAN IP 是只读的**：改它等于换掉这条
/// SSH 的对端，保存成功的下一帧就再也连不上，不是一次「保存」该干的事
/// （原因写在 `AppModel.saveLanDHCP` 上）。端口那一组是硬件状态，也没得改。
struct LanSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 地址末段（`192.168.8.` 那截前缀从当前 LAN IP 里取，不用重复输入）。
    @State private var startText = ""
    @State private var endText = ""
    @State private var lease = "12h"
    @State private var busy = false
    @State private var errorText: String?
    /// 输入框已经按采集结果填过一次。之后不再回填——刷新把用户刚敲的数冲掉是最烦的一类 bug。
    @State private var seeded = false

    private var info: NetworkInfo { model.network }

    /// `192.168.8.1` → `192.168.8`
    private var prefix: String {
        let parts = info.lanIP.split(separator: ".")
        guard parts.count == 4 else { return "" }
        return parts.dropLast().joined(separator: ".")
    }

    private static let leaseOptions = ["1h", "12h", "1d", "7d", "infinite"]

    private var dirty: Bool {
        guard seeded,
              let start = Int(info.dhcpStart),
              let limit = Int(info.dhcpLimit), limit > 0 else { return false }
        let originalLease = info.dhcpLease.isEmpty ? "12h" : info.dhcpLease
        return startText != String(start)
            || endText != String(start + limit - 1)
            || lease != originalLease
    }

    var body: some View {
        Form {
            portsSection
            lanSection
            dhcpSection
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
        // 推上来的页面拿不到根页的环境值，这里自己说一遍：
        // 按钮文字主色、开关蓝（`ButtonStyles.swift`）；本页没有开关。
        .primaryButtons()
        .navigationTitle("局域网与端口")
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
        .onAppear(perform: loadDefaults)
        .onChange(of: info.dhcpStart) { _, _ in
            loadDefaults()
        }
    }

    // MARK: - 端口（只读）

    private var portsSection: some View {
        Section("网络端口") {
            if info.ports.isEmpty {
                Text("—")
                    .foregroundStyle(.secondary)
                    .adaptiveRowBackground()
            } else {
                ForEach(info.ports) { port in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(port.up ? Color(red: 0.13, green: 0.66, blue: 0.38)
                                          : Color(.systemGray3))
                            .frame(width: 7, height: 7)
                        Text(portLabel(port))
                        Spacer(minLength: 8)
                        Text(portValue(port))
                            .foregroundStyle(port.up ? Color.primary : Color.secondary)
                            .monospacedDigit()
                    }
                    .adaptiveRowBackground()
                }
            }
        }
    }

    private func portLabel(_ port: NetPortInfo) -> String {
        port.name.isEmpty ? port.role : "\(port.role) \(port.name)"
    }

    /// WAN 没插线时写「未插网线」——比「未连接」多一个有用的判断（和原来那张卡一致）。
    private func portValue(_ port: NetPortInfo) -> String {
        if port.role == "WAN" && !port.up {
            return info.wanCable ? "已插网线，未联网" : "未插网线"
        }
        return port.detailLabel
    }

    // MARK: - 局域网（只读）

    private var lanSection: some View {
        Section("局域网") {
            valueRow("路由器", info.lanIP.isEmpty ? "—" : info.lanIP)
            valueRow("子网掩码", info.lanMask.isEmpty ? "—" : info.lanMask)
            valueRow("已用租约", info.leaseCount > 0 ? "\(info.leaseCount) 个" : "—")
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .adaptiveRowBackground()
    }

    // MARK: - DHCP（可改）

    private var dhcpSection: some View {
        Section("DHCP") {
            octetRow("起始地址", text: $startText)
            octetRow("结束地址", text: $endText)
            Picker("租期", selection: $lease) {
                ForEach(leaseChoices, id: \.self) { value in
                    Text(leaseLabel(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .disabled(busy)
            .adaptiveRowBackground()

            valueRow("地址池", poolLabel)
        }
    }

    /// 一行「标签 + `192.168.8.` + 末段输入框」。前缀是只读灰字，只让改最后一段。
    private func octetRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 2) {
            Text(label)
            Spacer(minLength: 8)
            if !prefix.isEmpty {
                Text(prefix + ".")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .monospacedDigit()
                .frame(width: 46)
                .disabled(busy)
        }
        .adaptiveRowBackground()
    }

    /// 当前库里没有的租期值（比如手动改过 `48h`）也要能显示，否则选择器会空着。
    private var leaseChoices: [String] {
        Self.leaseOptions.contains(lease) ? Self.leaseOptions : [lease] + Self.leaseOptions
    }

    private func leaseLabel(_ value: String) -> String {
        switch value {
        case "1h": return "1 小时"
        case "12h": return "12 小时"
        case "1d": return "1 天"
        case "7d": return "7 天"
        case "infinite": return "永久"
        default: return value
        }
    }

    /// `start=100` + `limit=150` → `192.168.8.100 – 192.168.8.249`
    private var poolLabel: String {
        guard let start = Int(startText), let end = Int(endText), info.loaded else { return "—" }
        guard !prefix.isEmpty else { return "\(start) – \(end)" }
        return "\(prefix).\(start) – \(prefix).\(end)"
    }

    // MARK: - 读 / 写

    private func loadDefaults() {
        guard !seeded,
              let start = Int(info.dhcpStart),
              let limit = Int(info.dhcpLimit), limit > 0 else { return }
        startText = String(start)
        endText = String(start + limit - 1)
        lease = info.dhcpLease.isEmpty ? "12h" : info.dhcpLease
        seeded = true
    }

    private func save() async {
        guard !busy else { return }

        guard let start = Int(startText), let end = Int(endText),
              (2...254).contains(start), (2...254).contains(end) else {
            errorText = "地址只能是 2–254 之间的数字"
            return
        }
        guard start < end else {
            errorText = "起始地址必须小于结束地址"
            return
        }
        if let routerOctet = info.lanIP.split(separator: ".").last.flatMap({ Int($0) }),
           (start...end).contains(routerOctet) {
            errorText = "地址池不能包含路由器自己的地址"
            return
        }

        busy = true
        errorText = nil
        let problem = await model.saveLanDHCP(start: start, end: end, lease: lease)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok,
                                  title: "已保存",
                                  detail: "\(prefix).\(start) – \(prefix).\(end)")
            await model.manualRefresh()
            dismiss()
            return
        }
        errorText = problem
    }
}
