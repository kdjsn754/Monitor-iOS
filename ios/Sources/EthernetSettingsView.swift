import SwiftUI

/// 以太网设置（二级页，v3.3.13 新增）。
///
/// ## 为什么要有这一页
///
/// 用户 2026-11-25：「你只做了中继，其他几个模式没参考官方改。」
/// 官方 App 的以太网是一整页（`ethernet_settings_page.dart` +
/// `ethernet_protocol_set_page.dart`）：先说**怎么拿地址**，再填地址本身。
/// 我们以前在「上网」页只摆了两行读数加一个「切换到以太网」，等于不能配。
///
/// 这一页照着官方那两页的字段来，但只做这台机器真支持的：
///
/// | 官方项 | 这里 | 说明 |
/// | --- | --- | --- |
/// | 自动设置（DHCP） | ✅ | `proto='dhcp'` |
/// | 手动配置静态 IP | ✅ | `ipaddr` / `netmask` / `gateway` / `dns` |
/// | PPPoE | ❌ | 固件 `/lib/netifd/proto/` 里没有 `pppoe.sh`，写了也起不来 |
/// | IPv6 | ❌ | 这台机器 `wan.ipv6='0'`，开了也没有上游 |
/// | MAC 模式 | ❌ | 要先把固件对 `macaddr` 前缀的处理摸清（同中继那一页） |
///
/// 写入走 `AppModel.applyEthernetConfig`，写完回读 `uci`；以太网正在当出口时
/// 还会把 `wan` 重新拉起来（写配置 → 隔两秒 → 起接口，v3.2.3 那条时序）。
struct EthernetSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    private var info: NetworkInfo { model.network }

    @State private var seeded = false
    /// `dhcp` / `static`
    @State private var proto = "dhcp"
    @State private var ip = ""
    @State private var mask = ""
    @State private var gateway = ""
    @State private var dns1 = ""
    @State private var dns2 = ""

    @State private var busy = false
    @State private var errorText: String?

    private var isStatic: Bool { proto == "static" }

    /// 和路由器上的值比，有任何一项不同就算「未保存」。
    private var dirty: Bool {
        guard seeded else { return false }
        if proto != info.wanProto { return true }
        guard isStatic else { return false }
        let servers = info.wanDNSServers
        return ip != info.wanIP || mask != info.wanMask || gateway != info.wanGateway
            || dns1 != (servers.first ?? "") || dns2 != (servers.count > 1 ? servers[1] : "")
    }

    /// 静态 IP 的必填项缺不缺（缺了保存按钮直接是灰的，不用等报错）。
    private var formComplete: Bool {
        !isStatic || (!ip.isEmpty && !mask.isEmpty && !gateway.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UI.cardSpacing) {
                protoCard
                if isStatic { addressCard }
                portCard
                if let errorText { errorCard(errorText) }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 44)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScrollBackground()
        .primaryButtons()
        .navigationTitle("以太网设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if dirty, formComplete {
                    Button("保存") { Task { await save() } }
                        .fontWeight(.semibold)
                        .navBarTint()
                }
            }
        }
        .onAppear(perform: seed)
    }

    // MARK: - 怎么拿地址

    private var protoCard: some View {
        CardPanel("地址获取方式", icon: "network") {
            HStack(spacing: 8) {
                Text("方式").font(UI.row())
                Spacer(minLength: 8)
                Picker("方式", selection: $proto) {
                    Text("自动（DHCP）").tag("dhcp")
                    Text("手动配置静态 IP").tag("static")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.primary)
                .disabled(busy)
            }
            .padding(.vertical, UI.rowPadding)

            Text(isStatic
                 ? "手动填写下面四项。地址、掩码、网关写错会导致这根网线上不了网。"
                 : "由上级网络（光猫、上级路由）分配 IP 地址，插上就能用。")
                .font(UI.label())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
    }

    // MARK: - 静态 IP

    private var addressCard: some View {
        CardPanel("静态 IP 设置", icon: "number") {
            field("IP 地址", text: $ip, placeholder: "192.168.1.10")
            CardRule()
            field("子网掩码", text: $mask, placeholder: "255.255.255.0")
            CardRule()
            field("默认网关", text: $gateway, placeholder: "192.168.1.1")
            CardRule()
            field("首选 DNS", text: $dns1, placeholder: "选填")
            CardRule()
            field("备用 DNS", text: $dns2, placeholder: "选填")
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(UI.row())
                .frame(width: 78, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 14.5))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .disabled(busy)
        }
        .padding(.vertical, UI.rowPadding)
    }

    // MARK: - 端口（只读）

    private var portCard: some View {
        CardPanel("WAN 口", icon: "cable.connector", trailing: info.wanCable ? "已插网线" : "未插网线") {
            HStack(alignment: .top, spacing: 12) {
                MetricCell(label: "端口", value: info.wanPort?.name ?? "—")
                MetricCell(label: "协商速率", value: info.bestPortLabel)
            }
            .padding(.vertical, UI.rowPadding)
            if info.uplink == .wired {
                CardRule()
                HStack(alignment: .top, spacing: 12) {
                    MetricCell(label: "当前地址", value: info.uplinkIP.isEmpty ? "—" : info.uplinkIP)
                    MetricCell(label: "网关", value: info.uplinkGateway.isEmpty ? "—" : info.uplinkGateway)
                }
                .padding(.vertical, UI.rowPadding)
            } else {
                Text("以太网现在没有当出口；这里改的是配置，切过去就生效。")
                    .font(UI.label())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
        }
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

    private func refill() {
        proto = info.wanProto == "static" ? "static" : "dhcp"
        ip = info.wanIP
        mask = info.wanMask
        gateway = info.wanGateway
        let servers = info.wanDNSServers
        dns1 = servers.first ?? ""
        dns2 = servers.count > 1 ? servers[1] : ""
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        let dns = [dns1, dns2].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let problem = await model.applyEthernetConfig(proto: proto,
                                                      ip: ip,
                                                      mask: mask,
                                                      gateway: gateway,
                                                      dns: dns)
        busy = false
        guard let problem else {
            model.notice = Notice(kind: .ok, title: "已保存",
                                 detail: isStatic ? "静态 IP · \(ip)" : "自动获取（DHCP）")
            await model.manualRefresh()
            refill()
            return
        }
        errorText = problem
    }
}
