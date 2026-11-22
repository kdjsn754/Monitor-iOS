import SwiftUI

/// 设备类型的线条图标。
///
/// **为什么不用 SF Symbols**：那套里 `hifispeaker` / `applewatch` / `gamecontroller` /
/// `wifi.router` 是实心笔画，`iphone` / `laptopcomputer` / `tv` / `camera` 是线框，
/// 这一排并排看下去像东拼西凑（用户 2026-11-16：「图标风格不一样，有的实心有的线条」）。
///
/// **为什么也不是手画的**：上一版我在 24×24 网格上凭手感写了 13 组坐标，比例和圆角
/// 都不对，缩到 18pt 之后糊成一团（用户：「重画图标太丑了」）。现在改用 **Lucide**
/// 那套（ISC 许可，可商用）的现成几何：全系列同一张 24 网格、同一支 2px 笔、
/// round cap/join，本身就是按「一套」设计的。路径是机械翻译过来的，一个点没改。
///
/// 画布尺寸按 `size` 等比缩放，线宽跟着缩放，所以 19pt（列表）、34pt（类型选择器）
/// 观感一致。没归类的设备（`kind == nil`）画官方那个「默认」图形（屏幕 + 手机）。
struct DeviceGlyph: View {
    let kind: ClientClass?
    var size: CGFloat = 18
    /// 笔画宽度，以 24×24 网格计。Lucide 原图就是 2，跟着 `size` 一起缩。
    var weight: CGFloat = 2

    var body: some View {
        Path { p in
            GlyphBuilder.build(kind ?? .auto, into: &p, scale: size / 24)
        }
        .stroke(style: StrokeStyle(lineWidth: weight * size / 24,
                                   lineCap: .round,
                                   lineJoin: .round))
        .frame(width: size, height: size)
    }
}

/// 16 个图形，几何取自 Lucide（github.com/lucide-icons/lucide）。
/// 坐标都在 24×24 网格上，乘 `k` 换算成实际点；一律只描边、不填色。
private enum GlyphBuilder {
    static func build(_ kind: ClientClass, into p: inout Path, scale k: CGFloat) {
        switch kind {
        case .auto: monitorPhone(&p, k)
        case .phone: phone(&p, k)
        case .pad: pad(&p, k)
        case .laptop: laptop(&p, k)
        case .computer: computer(&p, k)
        case .television: television(&p, k)
        case .camera: camera(&p, k)
        case .sound: sound(&p, k)
        case .printer: printer(&p, k)
        case .watch: watch(&p, k)
        case .games: games(&p, k)
        case .smartAppliances: smartAppliances(&p, k)
        case .gateway: gateway(&p, k)
        case .nas: nas(&p, k)
        case .server: server(&p, k)
        case .networkSwitch: networkSwitch(&p, k)
        }
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) -> CGPoint {
        CGPoint(x: x * k, y: y * k)
    }

    private static func phone(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 5 * k, y: 2 * k, width: 14 * k, height: 20 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(12, 18, k))
        p.addLine(to: pt(12.01, 18, k))
    }

    private static func pad(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 4 * k, y: 2 * k, width: 16 * k, height: 20 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(12, 18, k))
        p.addLine(to: pt(12.01, 18, k))
    }

    private static func laptop(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(18, 5, k))
        p.addCurve(to: pt(20, 7, k), control1: pt(19.105, 5, k), control2: pt(20, 5.895, k))
        p.addLine(to: pt(20, 15.526, k))
        p.addCurve(to: pt(20.212, 16.423, k), control1: pt(20, 15.837, k), control2: pt(20.072, 16.145, k))
        p.addLine(to: pt(21.28, 18.55, k))
        p.addCurve(to: pt(21.237, 19.527, k), control1: pt(21.437, 18.861, k), control2: pt(21.42, 19.231, k))
        p.addCurve(to: pt(20.38, 20, k), control1: pt(21.053, 19.823, k), control2: pt(20.728, 20.002, k))
        p.addLine(to: pt(3.62, 20, k))
        p.addCurve(to: pt(2.763, 19.527, k), control1: pt(3.272, 20.002, k), control2: pt(2.947, 19.823, k))
        p.addCurve(to: pt(2.72, 18.55, k), control1: pt(2.58, 19.231, k), control2: pt(2.563, 18.861, k))
        p.addLine(to: pt(3.788, 16.423, k))
        p.addCurve(to: pt(4, 15.526, k), control1: pt(3.928, 16.145, k), control2: pt(4, 15.837, k))
        p.addLine(to: pt(4, 7, k))
        p.addCurve(to: pt(6, 5, k), control1: pt(4, 5.895, k), control2: pt(4.895, 5, k))
        p.closeSubpath()
        p.move(to: pt(20.054, 15.987, k))
        p.addLine(to: pt(3.946, 15.987, k))
    }

    private static func computer(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 3 * k, width: 20 * k, height: 14 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(8, 21, k))
        p.addLine(to: pt(16, 21, k))
        p.move(to: pt(12, 17, k))
        p.addLine(to: pt(12, 21, k))
    }

    private static func television(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(17, 2, k))
        p.addLine(to: pt(12, 7, k))
        p.addLine(to: pt(7, 2, k))
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 7 * k, width: 20 * k, height: 15 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
    }

    private static func camera(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(13.997, 4, k))
        p.addCurve(to: pt(15.757, 5.05, k), control1: pt(14.732, 4, k), control2: pt(15.408, 4.403, k))
        p.addLine(to: pt(16.243, 5.95, k))
        p.addCurve(to: pt(18.003, 7, k), control1: pt(16.592, 6.597, k), control2: pt(17.268, 7, k))
        p.addLine(to: pt(20, 7, k))
        p.addCurve(to: pt(22, 9, k), control1: pt(21.105, 7, k), control2: pt(22, 7.895, k))
        p.addLine(to: pt(22, 18, k))
        p.addCurve(to: pt(20, 20, k), control1: pt(22, 19.105, k), control2: pt(21.105, 20, k))
        p.addLine(to: pt(4, 20, k))
        p.addCurve(to: pt(2, 18, k), control1: pt(2.895, 20, k), control2: pt(2, 19.105, k))
        p.addLine(to: pt(2, 9, k))
        p.addCurve(to: pt(4, 7, k), control1: pt(2, 7.895, k), control2: pt(2.895, 7, k))
        p.addLine(to: pt(5.997, 7, k))
        p.addCurve(to: pt(7.756, 5.952, k), control1: pt(6.731, 7, k), control2: pt(7.406, 6.598, k))
        p.addLine(to: pt(8.245, 5.048, k))
        p.addCurve(to: pt(10.004, 4, k), control1: pt(8.595, 4.402, k), control2: pt(9.27, 4, k))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 9 * k, y: 10 * k, width: 6 * k, height: 6 * k))
    }

    private static func sound(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 4 * k, y: 2 * k, width: 16 * k, height: 20 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(12, 6, k))
        p.addLine(to: pt(12.01, 6, k))
        p.addEllipse(in: CGRect(x: 8 * k, y: 10 * k, width: 8 * k, height: 8 * k))
        p.move(to: pt(12, 14, k))
        p.addLine(to: pt(12.01, 14, k))
    }

    private static func printer(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(6, 18, k))
        p.addLine(to: pt(4, 18, k))
        p.addCurve(to: pt(2, 16, k), control1: pt(2.895, 18, k), control2: pt(2, 17.105, k))
        p.addLine(to: pt(2, 11, k))
        p.addCurve(to: pt(4, 9, k), control1: pt(2, 9.895, k), control2: pt(2.895, 9, k))
        p.addLine(to: pt(20, 9, k))
        p.addCurve(to: pt(22, 11, k), control1: pt(21.105, 9, k), control2: pt(22, 9.895, k))
        p.addLine(to: pt(22, 16, k))
        p.addCurve(to: pt(20, 18, k), control1: pt(22, 17.105, k), control2: pt(21.105, 18, k))
        p.addLine(to: pt(18, 18, k))
        p.move(to: pt(6, 9, k))
        p.addLine(to: pt(6, 3, k))
        p.addCurve(to: pt(7, 2, k), control1: pt(6, 2.448, k), control2: pt(6.448, 2, k))
        p.addLine(to: pt(17, 2, k))
        p.addCurve(to: pt(18, 3, k), control1: pt(17.552, 2, k), control2: pt(18, 2.448, k))
        p.addLine(to: pt(18, 9, k))
        p.addRoundedRect(in: CGRect(x: 6 * k, y: 14 * k, width: 12 * k, height: 8 * k), cornerSize: CGSize(width: 1 * k, height: 1 * k), style: .continuous)
    }

    private static func watch(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(12, 10, k))
        p.addLine(to: pt(12, 12.2, k))
        p.addLine(to: pt(13.6, 13.2, k))
        p.move(to: pt(16.13, 7.66, k))
        p.addLine(to: pt(15.32, 3.61, k))
        p.addCurve(to: pt(13.32, 2, k), control1: pt(15.131, 2.66, k), control2: pt(14.289, 1.981, k))
        p.addLine(to: pt(10.64, 2, k))
        p.addCurve(to: pt(8.64, 3.61, k), control1: pt(9.671, 1.981, k), control2: pt(8.829, 2.66, k))
        p.addLine(to: pt(7.86, 7.66, k))
        p.move(to: pt(7.88, 16.36, k))
        p.addLine(to: pt(8.68, 20.36, k))
        p.addCurve(to: pt(10.68, 21.97, k), control1: pt(8.869, 21.31, k), control2: pt(9.711, 21.989, k))
        p.addLine(to: pt(13.4, 21.97, k))
        p.addCurve(to: pt(15.4, 20.36, k), control1: pt(14.369, 21.989, k), control2: pt(15.211, 21.31, k))
        p.addLine(to: pt(16.21, 16.31, k))
        p.addEllipse(in: CGRect(x: 6 * k, y: 6 * k, width: 12 * k, height: 12 * k))
    }

    private static func games(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(6, 11, k))
        p.addLine(to: pt(10, 11, k))
        p.move(to: pt(8, 9, k))
        p.addLine(to: pt(8, 13, k))
        p.move(to: pt(15, 12, k))
        p.addLine(to: pt(15.01, 12, k))
        p.move(to: pt(18, 10, k))
        p.addLine(to: pt(18.01, 10, k))
        p.move(to: pt(17.32, 5, k))
        p.addLine(to: pt(6.68, 5, k))
        p.addCurve(to: pt(2.702, 8.59, k), control1: pt(4.63, 5, k), control2: pt(2.912, 6.551, k))
        p.addCurve(to: pt(2.685, 8.742, k), control1: pt(2.696, 8.642, k), control2: pt(2.692, 8.691, k))
        p.addCurve(to: pt(2, 16, k), control1: pt(2.604, 9.416, k), control2: pt(2, 14.456, k))
        p.addCurve(to: pt(5, 19, k), control1: pt(2, 17.657, k), control2: pt(3.343, 19, k))
        p.addCurve(to: pt(7, 18, k), control1: pt(6, 19, k), control2: pt(6.5, 18.5, k))
        p.addLine(to: pt(8.414, 16.586, k))
        p.addCurve(to: pt(9.828, 16, k), control1: pt(8.789, 16.211, k), control2: pt(9.298, 16, k))
        p.addLine(to: pt(14.172, 16, k))
        p.addCurve(to: pt(15.586, 16.586, k), control1: pt(14.702, 16, k), control2: pt(15.211, 16.211, k))
        p.addLine(to: pt(17, 18, k))
        p.addCurve(to: pt(19, 19, k), control1: pt(17.5, 18.5, k), control2: pt(18, 19, k))
        p.addCurve(to: pt(22, 16, k), control1: pt(20.657, 19, k), control2: pt(22, 17.657, k))
        p.addCurve(to: pt(21.315, 8.742, k), control1: pt(22, 14.455, k), control2: pt(21.396, 9.416, k))
        p.addCurve(to: pt(21.298, 8.591, k), control1: pt(21.308, 8.692, k), control2: pt(21.304, 8.642, k))
        p.addCurve(to: pt(17.32, 5, k), control1: pt(21.088, 6.551, k), control2: pt(19.37, 5.001, k))
        p.closeSubpath()
    }

    private static func smartAppliances(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(15, 14, k))
        p.addCurve(to: pt(16.5, 11.5, k), control1: pt(15.2, 13, k), control2: pt(15.7, 12.3, k))
        p.addCurve(to: pt(18, 8, k), control1: pt(17.5, 10.6, k), control2: pt(18, 9.3, k))
        p.addCurve(to: pt(12, 2, k), control1: pt(18, 4.686, k), control2: pt(15.314, 2, k))
        p.addCurve(to: pt(6, 8, k), control1: pt(8.686, 2, k), control2: pt(6, 4.686, k))
        p.addCurve(to: pt(7.5, 11.5, k), control1: pt(6, 9, k), control2: pt(6.2, 10.2, k))
        p.addCurve(to: pt(9, 14, k), control1: pt(8.2, 12.2, k), control2: pt(8.8, 13, k))
        p.move(to: pt(9, 18, k))
        p.addLine(to: pt(15, 18, k))
        p.move(to: pt(10, 22, k))
        p.addLine(to: pt(14, 22, k))
    }

    private static func gateway(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 14 * k, width: 20 * k, height: 8 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(6.01, 18, k))
        p.addLine(to: pt(6, 18, k))
        p.move(to: pt(10.01, 18, k))
        p.addLine(to: pt(10, 18, k))
        p.move(to: pt(15, 10, k))
        p.addLine(to: pt(15, 14, k))
        p.move(to: pt(17.84, 7.17, k))
        p.addCurve(to: pt(15.01, 5.997, k), control1: pt(17.09, 6.419, k), control2: pt(16.072, 5.997, k))
        p.addCurve(to: pt(12.18, 7.17, k), control1: pt(13.948, 5.997, k), control2: pt(12.93, 6.419, k))
        p.move(to: pt(20.66, 4.34, k))
        p.addCurve(to: pt(9.35, 4.34, k), control1: pt(17.536, 1.218, k), control2: pt(12.474, 1.218, k))
    }

    /// 「默认」：显示器 + 一台手机（Lucide `monitor-smartphone`），
    /// 和官方列表第一格那个图形一致；以前这里画的是问号，看着像「出错了」。
    private static func monitorPhone(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(18, 8, k))
        p.addLine(to: pt(18, 6, k))
        p.addCurve(to: pt(16, 4, k), control1: pt(18, 4.895, k), control2: pt(17.105, 4, k))
        p.addLine(to: pt(4, 4, k))
        p.addCurve(to: pt(2, 6, k), control1: pt(2.895, 4, k), control2: pt(2, 4.895, k))
        p.addLine(to: pt(2, 13, k))
        p.addCurve(to: pt(4, 15, k), control1: pt(2, 14.105, k), control2: pt(2.895, 15, k))
        p.addLine(to: pt(12, 15, k))
        p.move(to: pt(9, 19, k))
        p.addLine(to: pt(9, 15, k))
        p.move(to: pt(6, 19, k))
        p.addLine(to: pt(11, 19, k))
        p.addRoundedRect(in: CGRect(x: 16 * k, y: 12 * k, width: 6 * k, height: 10 * k),
                         cornerSize: CGSize(width: 1.5 * k, height: 1.5 * k), style: .continuous)
    }

    /// NAS：方框里四根竖条（官方格子里就是这个「盘位」样子）。
    private static func nas(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 3 * k, y: 3 * k, width: 18 * k, height: 18 * k),
                         cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        for x in [CGFloat(7.5), 10.5, 13.5, 16.5] {
            p.move(to: pt(x, 7, k))
            p.addLine(to: pt(x, 17, k))
        }
    }

    /// 服务器：两层机架 + 各自一颗指示灯（Lucide `server`）。
    private static func server(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 2 * k, width: 20 * k, height: 8 * k),
                         cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 14 * k, width: 20 * k, height: 8 * k),
                         cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        p.move(to: pt(6, 6, k))
        p.addLine(to: pt(6.01, 6, k))
        p.move(to: pt(6, 18, k))
        p.addLine(to: pt(6.01, 18, k))
    }

    /// 交换机：扁机箱 + 四个网口。
    private static func networkSwitch(_ p: inout Path, _ k: CGFloat) {
        p.addRoundedRect(in: CGRect(x: 2 * k, y: 5 * k, width: 20 * k, height: 14 * k),
                         cornerSize: CGSize(width: 2 * k, height: 2 * k), style: .continuous)
        for x in [CGFloat(5.5), 9.5, 13.5, 17.5] {
            p.addRoundedRect(in: CGRect(x: (x - 1) * k, y: 12 * k, width: 2 * k, height: 3 * k),
                             cornerSize: CGSize(width: 0.4 * k, height: 0.4 * k), style: .continuous)
        }
    }
}
