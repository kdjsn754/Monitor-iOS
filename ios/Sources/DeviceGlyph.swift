import SwiftUI

/// 设备类型的线条图标。
///
/// **v3.3.5 起直接用官方的**：15 个类型是路由器网页版 iconfont 里的字形
/// （见 `OfficialGlyph`，生成脚本 `tmp/font2swift.py`），和官方 App「设备类型」
/// 弹窗上那套同源——相机是摄像头、音响是音箱、电视带 TV 字样、NAS 是四个盘位、
/// 服务器是机架、交换机是带交叉箭头的盒子。v3.0.6 那套是照 Lucide 拼的近似图形，
/// 形状对不上，用户 2026-11-23：「这些图标使用官方的」。
///
/// 「默认」（`nil` 或 `.auto`）字体里没有对应字形（网页端根本没这一项），
/// 仍按官方 App 那格「显示器 + 手机」自己画，走描边；两种画法在 24 网格上
/// 粗细一致（约 2pt），并排看不出是两套。
///
/// 画布尺寸按 `size` 等比缩放，所以 19pt（列表）、34pt（类型选择器）观感一致。
struct DeviceGlyph: View {
    let kind: ClientClass?
    var size: CGFloat = 18
    /// 笔画宽度，以 24×24 网格计。**只有「默认」那条手绘路径用得到**：
    /// 官方字形是实心轮廓，线宽已经画在字形里了。
    var weight: CGFloat = 2

    var body: some View {
        Group {
            if let kind, kind != .auto {
                Path { p in
                    OfficialGlyph.draw(kind, into: &p, scale: size / 24)
                }
                .fill(style: FillStyle(eoFill: false))
            } else {
                Path { p in
                    DeviceGlyph.defaultMark(into: &p, scale: size / 24)
                }
                .stroke(style: StrokeStyle(lineWidth: weight * size / 24,
                                           lineCap: .round,
                                           lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }

    /// 「默认」那一格：一台显示器 + 一部手机**并排**。
    ///
    /// v3.3.11：旧版把手机压在显示器右下角，两个描边的圆角框在交界处互相穿过，
    /// 19pt 下列表里看着像一团乱线（用户 2026-11-25：「默认的图标很别扭」）。
    /// 现在两个设备各画各的完整轮廓、中间留 2pt 空隙：显示器在左（占左三分之二），
    /// 手机竖着在右。含义还是「多台设备 / 未归类」，但线不再打架。
    /// 只改这一条手绘路径，15 个官方字形和其余代码一行没动。
    static func defaultMark(into p: inout Path, scale k: CGFloat) {
        // 显示器（左）
        p.addRoundedRect(in: CGRect(x: 1.5 * k, y: 5.5 * k, width: 12 * k, height: 9 * k),
                         cornerSize: CGSize(width: 1.6 * k, height: 1.6 * k),
                         style: .continuous)
        // 底座
        p.move(to: pt(7.5, 14.5, k))
        p.addLine(to: pt(7.5, 17.8, k))
        p.move(to: pt(5, 17.8, k))
        p.addLine(to: pt(10, 17.8, k))
        // 手机（右，与显示器分开）
        p.addRoundedRect(in: CGRect(x: 15.5 * k, y: 3.5 * k, width: 7 * k, height: 14 * k),
                         cornerSize: CGSize(width: 1.5 * k, height: 1.5 * k),
                         style: .continuous)
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) -> CGPoint {
        CGPoint(x: x * k, y: y * k)
    }
}
