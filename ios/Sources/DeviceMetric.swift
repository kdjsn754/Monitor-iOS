import SwiftUI

/// 设备图标：一个圆角方块，底色是类型色的 12%，符号统一一个字重。
///
/// **为什么要有这一个组件**：以前每行各写各的 `Image(systemName:)`，
/// 符号大小 13 / 12.5 混着来，`video`（摄像头）和 `wifi` 是实心笔画，
/// 设备类全是线框，有线还是个尖角连接头——一列看下去像东拼西凑
/// （用户 2026-11-16：「各种设备类型的图标风格都不统一」）。
/// 现在所有类型共用同一个容器、同一个字重、同一个光学尺寸，唯一的变量是符号本身。
struct ClientBadgeIcon: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(tint.opacity(0.12))
            }
    }
}

/// 设备行右侧那两行数字：实时速率在上、累计流量在下。
///
/// 概览的「连接设备」和网络页的「设备」共用这一个视图——同一台设备在两页里
/// 必须长得一样，否则切页时数字会「跳一下」。
///
/// **v3.0.4 的两次纠偏**：
/// 1. 上一版把右列拆成「箭头 | 数字 | 单位」三列定宽，数字列只给了 34pt，
///    于是 `289.3` 被挤成两行（`289.` 换行 `3`），一行比一行高（用户：「还是很乱」）。
///    现在整块 `.fixedSize()` —— 宁可让左边的名字截断，也绝不让数字折行。
/// 2. 速率原来染成无线青 / 有线紫，一屏四个颜色在跳。现在两行数字都用灰阶
///    （速率次灰、流量三级灰），**颜色只留在左边的图标上**，数字退成安静的背景。
///
/// 箭头也去掉了：`0 B/s` 和 `63.2 KB/s` 混在一起时，箭头列本身就是歪的。
/// 只有「只在上传」这一种情况才在数字前加一个 `↑`，正常下载不占位。
struct ClientMetricColumn: View {
    let client: NetClient
    var rateSize: CGFloat = 12.5

    private var rate: String {
        guard client.online else { return "—" }
        if client.rxSpeed >= 1 {
            let parts = splitBytes(client.rxSpeed)
            return "\(parts.number) \(parts.unit)/s"
        }
        if client.txSpeed >= 1 {
            let parts = splitBytes(client.txSpeed)
            return "↑ \(parts.number) \(parts.unit)/s"
        }
        return "0 B/s"
    }

    private var traffic: String {
        let total = client.totalRx + client.totalTx
        guard total >= 1 else { return "—" }
        let parts = splitBytes(total)
        return "\(parts.number) \(parts.unit)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(rate)
                .font(.system(size: rateSize, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(traffic)
                .font(.system(size: rateSize - 1))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }
}

/// 设备名下面那行小字：`192.168.8.11 · 有线`。
///
/// 只留「地址 · 接入」两段，**不再写设备类型**——左边那个图标就是按类型给的
/// （笔记本 / 手机 / 电视 / 无线），再拿文字讲一遍只会把每行拉成不同的长度，
/// 一列小字参参差差（用户 2026-11-16）。
/// 「固定」是保留 IP 的状态，做成一个小小的灰底胶囊跟在后面，不占正文长度。
struct ClientDetailLine: View {
    let client: NetClient
    var size: CGFloat = 11.5

    private var text: String {
        var bits: [String] = []
        if !client.ip.isEmpty { bits.append(client.ip) }
        if !client.iface.isEmpty { bits.append(client.iface) }
        return bits.isEmpty ? client.mac : bits.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
            if !client.reservedIP.isEmpty {
                Text("固定")
                    .font(.system(size: size - 2.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0.5)
                    .background { Capsule().fill(Color(.quaternarySystemFill)) }
            }
            Spacer(minLength: 0)
        }
    }
}
