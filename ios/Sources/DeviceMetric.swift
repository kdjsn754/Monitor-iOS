import SwiftUI

/// 设备行右侧那两列数字：实时速率在上、累计流量在下。
///
/// 概览的「连接设备」和网络页的「设备」共用这一个视图——同一台设备在两页里
/// 必须长得一样，否则切页时数字会「跳一下」。
///
/// **为什么拆成三列定宽**：以前是两行各自把整串右对齐，`↓ 378 B/s` 和
/// `↓ 42.9 KB/s` 宽度差好几个字符，于是箭头一列忽左忽右、单位也错开，
/// 一列数字看着是歪的（用户 2026-11-16：「小字和网速长短不一样看着很乱」）。
/// 现在固定成「箭头 10pt | 数字右对齐 | 单位左对齐 26pt」，每一列各在各的位置：
/// 所有箭头同一条竖线，所有数字右端同一条竖线，所有单位起点同一条竖线。
struct ClientMetricColumn: View {
    let client: NetClient
    let rateColor: Color
    var rateSize: CGFloat = 13

    /// 实时速率。优先报下载，下载这拍为 0 才报上传——不然在线但没下载的设备
    /// 会一直显示「↓ 0 B/s」，比空着还难看。
    private var rate: (number: String, unit: String, down: Bool)? {
        guard client.online else { return nil }
        if client.rxSpeed >= 1 {
            let parts = splitBytes(client.rxSpeed)
            return (parts.number, parts.unit + "/s", true)
        }
        if client.txSpeed >= 1 {
            let parts = splitBytes(client.txSpeed)
            return (parts.number, parts.unit + "/s", false)
        }
        return nil
    }

    private var traffic: (number: String, unit: String)? {
        let total = client.totalRx + client.totalTx
        guard total > 0 else { return nil }
        return splitBytes(total)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: rate?.down == false ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10, alignment: .leading)
                    .opacity(rate == nil ? 0 : 1)
                Text(rate?.number ?? "—")
                    .font(.system(size: rateSize))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
                Text(rate?.unit ?? "")
                    .font(.system(size: rateSize - 2))
                    .frame(width: 26, alignment: .leading)
            }
            .foregroundStyle(rate == nil ? Color.secondary : rateColor)

            HStack(spacing: 2) {
                Color.clear.frame(width: 10, height: 1)
                Text(traffic?.number ?? "—")
                    .font(.system(size: rateSize - 1))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
                Text(traffic?.unit ?? "")
                    .font(.system(size: rateSize - 2))
                    .frame(width: 26, alignment: .leading)
            }
            .foregroundStyle(Color.secondary)
        }
    }
}

/// 设备名下面那行小字：`192.168.8.11 · 有线`。
///
/// 只留「地址 · 接入」两段，**不再写设备类型**——左边那个图标圆底就是按类型给的
/// （笔记本 / 手机 / 电视 / 无线），再拿文字讲一遍只会把每行拉成不同的长度，
/// 一列小字参参差差（用户 2026-11-16）。
/// 「固定」是保留 IP 的状态，不占正文长度，做成一个小胶囊跟在后面。
struct ClientDetailLine: View {
    let client: NetClient
    var size: CGFloat = 12

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
                    .background { Capsule().fill(Color(.systemGray5)) }
            }
            Spacer(minLength: 0)
        }
    }
}
