import Foundation
import SwiftUI

/// 拓扑图中心那台路由器用的是**官方那张图**，不是我画的。
///
/// 图来自路由器自己的固件：`/www/model.svg`——GL.iNet 用 Illustrator 导出的产品线稿，
/// 固件的 Web 面板和官方 App 都取这一张（App 里那个薄荷绿的就是它上了色）。
/// 2026-11-16 用户：「官方软件有这样的实图用官方软件的」。
///
/// **为什么不用位图**：它是矢量，路径坐标写死在 186.2×130 的网格上，缩到 52pt 依旧清晰；
/// 位图要么糊，要么得存两三套尺寸。
///
/// **只搬了主轮廓那 14 条路径**。原图还有 13 条散热格栅细条和天线上的「WiFi 7」字样，
/// 在 52pt 下它们只剩一团脏点（同一天的对照图里看到的就是这个），所以没搬。
///
/// 画法：**填充 + 同色描边**。官方原图的线宽换算到 52pt 只有 0.4pt 左右，屏幕上看是发丝、
/// 会发灰，所以给每条轮廓再补一圈描边（`boldness`，以 186 坐标计），既保住原来的形，
/// 又比官方原图厚一点，小尺寸下不至于糊掉。
struct RouterModelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let k = min(rect.width / RouterModelOutline.canvas.width,
                    rect.height / RouterModelOutline.canvas.height)
        RouterModelOutline.build(&p, k)
        // 图形在内容框里居中，别在圆圈里偏到一边
        let dx = rect.minX + (rect.width - RouterModelOutline.canvas.width * k) / 2
        let dy = rect.minY + (rect.height - RouterModelOutline.canvas.height * k) / 2
        return p.applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// 图标本体：宽 `width`，高按官方图的比例推出来（186.2 : 130）。
struct RouterModelGlyph: View {
    var width: CGFloat = 52
    var tint: Color
    /// 加粗量，以官方图的 186 宽坐标为 1，随尺寸一起缩放。
    /// 1.4 是试出来的：官方原线到 56pt 只有 0.4pt 宽，屏幕上发灰；
    /// 再往上（2.0）圆角和接缝会糊在一起，形体也变胖。
    var boldness: CGFloat = 1.4

    private var height: CGFloat {
        width * RouterModelOutline.canvas.height / RouterModelOutline.canvas.width
    }

    var body: some View {
        RouterModelShape()
            .fill(tint)
            .overlay {
                RouterModelShape()
                    .stroke(tint,
                            style: StrokeStyle(
                                lineWidth: boldness * width / RouterModelOutline.canvas.width,
                                lineCap: .round,
                                lineJoin: .round
                            ))
            }
            .frame(width: width, height: height)
    }
}

/// 官方 `/www/model.svg` 的路径，机械搬过来（M/L/C/Q/Z 逐条对应），一个控制点没改。
/// 坐标是官方图的原始坐标系，`pt(_:_:_:)` 先把内容框左上角 (7, 35) 挪到原点，再乘缩放。
private enum RouterModelOutline {
    /// 内容框：官方图 200×200 里图形实际占的那块。
    static let canvas = CGSize(width: 186.2, height: 130)

    static func pt(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) -> CGPoint {
        CGPoint(x: (x - 7) * k, y: (y - 35) * k)
    }

    /// 一台 GL-MT3600BE 的主轮廓（机身、两根桨状天线、机身接缝、脚垫、散热口边框）。
    static func build(_ p: inout Path, _ k: CGFloat) {
        p.move(to: pt(131.4, 162.2, k))
        p.addCurve(to: pt(122.3, 161.3, k), control1: pt(126.9, 162.2, k), control2: pt(122.6, 161.4, k))
        p.addLine(to: pt(33.3, 143.5, k))
        p.addCurve(to: pt(14, 123.2, k), control1: pt(33.1, 143.5, k), control2: pt(15.1, 139.6, k))
        p.addCurve(to: pt(23.6, 102.5, k), control1: pt(13.2, 111.1, k), control2: pt(19.7, 105.1, k))
        p.addCurve(to: pt(27.1, 100.9, k), control1: pt(24.7, 101.8, k), control2: pt(25.9, 101.3, k))
        p.addLine(to: pt(71, 88.5, k))
        p.addCurve(to: pt(91.8, 88.1, k), control1: pt(71.3, 88.5, k), control2: pt(79.3, 85.9, k))
        p.addCurve(to: pt(97.8, 89.1, k), control1: pt(94, 88.5, k), control2: pt(95.9, 88.8, k))
        p.addLine(to: pt(138.8, 95.2, k))
        p.addCurve(to: pt(139.3, 95.9, k), control1: pt(139.1, 95.2, k), control2: pt(139.4, 95.6, k))
        p.addCurve(to: pt(138.6, 96.4, k), control1: pt(139.2, 96.2, k), control2: pt(138.9, 96.5, k))
        p.addLine(to: pt(97.6, 90.3, k))
        p.addCurve(to: pt(91.6, 89.3, k), control1: pt(95.7, 90, k), control2: pt(93.8, 89.7, k))
        p.addCurve(to: pt(71.4, 89.7, k), control1: pt(79.5, 87.2, k), control2: pt(71.5, 89.7, k))
        p.addLine(to: pt(27.5, 102.1, k))
        p.addCurve(to: pt(24.3, 103.5, k), control1: pt(26.4, 102.4, k), control2: pt(25.3, 102.9, k))
        p.addCurve(to: pt(15.3, 123, k), control1: pt(20.6, 105.9, k), control2: pt(14.5, 111.6, k))
        p.addCurve(to: pt(33.6, 142.2, k), control1: pt(16.4, 138.5, k), control2: pt(33.4, 142.2, k))
        p.addLine(to: pt(122.6, 160, k))
        p.addCurve(to: pt(137.8, 160, k), control1: pt(122.6, 160, k), control2: pt(132.4, 161.9, k))
        p.addLine(to: pt(147.6, 156, k))
        p.addCurve(to: pt(148.4, 156.3, k), control1: pt(147.9, 155.9, k), control2: pt(148.3, 156, k))
        p.addCurve(to: pt(148.1, 157.1, k), control1: pt(148.5, 156.6, k), control2: pt(148.4, 157, k))
        p.addLine(to: pt(138.3, 161.1, k))
        p.addCurve(to: pt(131.4, 162.2, k), control1: pt(136.2, 162, k), control2: pt(133.7, 162.2, k))
        p.addLine(to: pt(131.4, 162.2, k))
        p.closeSubpath()
        p.move(to: pt(38.4, 146.4, k))
        p.addCurve(to: pt(34.4, 145.4, k), control1: pt(36.8, 146.4, k), control2: pt(35.4, 146.1, k))
        p.addCurve(to: pt(32.8, 143.1, k), control1: pt(33, 144.4, k), control2: pt(32.8, 143.1, k))
        p.addCurve(to: pt(33.3, 142.4, k), control1: pt(32.8, 142.8, k), control2: pt(33, 142.4, k))
        p.addCurve(to: pt(34, 142.9, k), control1: pt(33.6, 142.3, k), control2: pt(33.9, 142.6, k))
        p.addCurve(to: pt(35.1, 144.4, k), control1: pt(34, 142.9, k), control2: pt(34, 143.7, k))
        p.addCurve(to: pt(43.2, 144.4, k), control1: pt(36.2, 145.1, k), control2: pt(38.5, 145.7, k))
        p.addCurve(to: pt(44, 144.8, k), control1: pt(43.5, 144.3, k), control2: pt(43.9, 144.5, k))
        p.addCurve(to: pt(43.6, 145.6, k), control1: pt(44, 145.1, k), control2: pt(44, 145.5, k))
        p.addCurve(to: pt(38.4, 146.4, k), control1: pt(41.6, 146.1, k), control2: pt(39.8, 146.4, k))
        p.closeSubpath()
        p.move(to: pt(130, 165, k))
        p.addCurve(to: pt(123.8, 161.1, k), control1: pt(124.4, 165, k), control2: pt(123.8, 161.1, k))
        p.addCurve(to: pt(124.3, 160.4, k), control1: pt(123.8, 160.8, k), control2: pt(124, 160.4, k))
        p.addCurve(to: pt(125, 160.9, k), control1: pt(124.6, 160.4, k), control2: pt(125, 160.6, k))
        p.addCurve(to: pt(131.3, 163.7, k), control1: pt(125, 161.2, k), control2: pt(125.6, 164.2, k))
        p.addCurve(to: pt(135.8, 162.1, k), control1: pt(134.6, 163.4, k), control2: pt(135.6, 162.5, k))
        p.addCurve(to: pt(135.9, 161.4, k), control1: pt(136, 161.7, k), control2: pt(135.9, 161.4, k))
        p.addCurve(to: pt(136.2, 160.6, k), control1: pt(135.8, 161.1, k), control2: pt(135.9, 160.7, k))
        p.addCurve(to: pt(137, 160.9, k), control1: pt(136.5, 160.5, k), control2: pt(136.9, 160.6, k))
        p.addCurve(to: pt(136.9, 162.7, k), control1: pt(137, 161, k), control2: pt(137.4, 161.8, k))
        p.addCurve(to: pt(131.4, 165, k), control1: pt(136.2, 163.9, k), control2: pt(134.4, 164.7, k))
        p.addLine(to: pt(130, 165, k))
        p.closeSubpath()
        p.move(to: pt(130.9, 145, k))
        p.addCurve(to: pt(118.9, 143.9, k), control1: pt(125.2, 145, k), control2: pt(119.3, 144, k))
        p.addLine(to: pt(113.9, 143, k))
        p.addLine(to: pt(22.2, 126.2, k))
        p.addCurve(to: pt(21, 126, k), control1: pt(21.8, 126.2, k), control2: pt(21.4, 126.2, k))
        p.addCurve(to: pt(14.4, 123.4, k), control1: pt(18.6, 125.6, k), control2: pt(16.2, 125.2, k))
        p.addCurve(to: pt(14.4, 123, k), control1: pt(14.3, 123.4, k), control2: pt(14.3, 123.1, k))
        p.addCurve(to: pt(14.8, 123, k), control1: pt(14.5, 122.9, k), control2: pt(14.7, 123, k))
        p.addCurve(to: pt(21.1, 125.4, k), control1: pt(16.4, 124.7, k), control2: pt(18.8, 125.1, k))
        p.addCurve(to: pt(22.3, 125.6, k), control1: pt(21.5, 125.4, k), control2: pt(21.9, 125.4, k))
        p.addLine(to: pt(118.9, 143.4, k))
        p.addCurve(to: pt(138.6, 143.4, k), control1: pt(118.9, 143.4, k), control2: pt(132.7, 145.8, k))
        p.addCurve(to: pt(138.9, 143.5, k), control1: pt(138.7, 143.3, k), control2: pt(138.9, 143.4, k))
        p.addCurve(to: pt(138.8, 143.8, k), control1: pt(139, 143.6, k), control2: pt(138.9, 143.8, k))
        p.addCurve(to: pt(130.9, 145, k), control1: pt(136.8, 144.7, k), control2: pt(133.9, 145, k))
        p.closeSubpath()
        p.move(to: pt(75, 138.2, k))
        p.addLine(to: pt(74.7, 138.2, k))
        p.addCurve(to: pt(61.6, 135.8, k), control1: pt(74.7, 138.2, k), control2: pt(64.4, 136.4, k))
        p.addCurve(to: pt(58.7, 132.7, k), control1: pt(58.6, 135.1, k), control2: pt(58.7, 132.8, k))
        p.addCurve(to: pt(59, 132.5, k), control1: pt(58.7, 132.6, k), control2: pt(58.7, 132.5, k))
        p.addCurve(to: pt(59.2, 132.8, k), control1: pt(59.3, 132.5, k), control2: pt(59.2, 132.6, k))
        p.addCurve(to: pt(61.7, 135.3, k), control1: pt(59.2, 133, k), control2: pt(59.2, 134.8, k))
        p.addCurve(to: pt(74.8, 137.7, k), control1: pt(64.5, 135.9, k), control2: pt(74.7, 137.7, k))
        p.addCurve(to: pt(75.7, 137.5, k), control1: pt(74.8, 137.7, k), control2: pt(75.2, 137.8, k))
        p.addCurve(to: pt(76.5, 135.9, k), control1: pt(76.1, 137.2, k), control2: pt(76.4, 136.7, k))
        p.addCurve(to: pt(76.8, 135.7, k), control1: pt(76.5, 135.8, k), control2: pt(76.7, 135.7, k))
        p.addCurve(to: pt(77, 136, k), control1: pt(76.9, 135.7, k), control2: pt(77, 135.9, k))
        p.addCurve(to: pt(75.9, 137.9, k), control1: pt(76.8, 136.9, k), control2: pt(76.5, 137.6, k))
        p.addCurve(to: pt(75, 138.2, k), control1: pt(75.5, 138.1, k), control2: pt(75.2, 138.2, k))
        p.closeSubpath()
        p.move(to: pt(16.9, 131.9, k))
        p.addLine(to: pt(16.9, 131.9, k))
        p.addCurve(to: pt(8.9, 121.6, k), control1: pt(16.8, 131.9, k), control2: pt(9.4, 131.2, k))
        p.addCurve(to: pt(7, 49.3, k), control1: pt(8.4, 113.1, k), control2: pt(7.2, 55.8, k))
        p.addCurve(to: pt(7.2, 46.6, k), control1: pt(7, 48.4, k), control2: pt(7, 47.4, k))
        p.addCurve(to: pt(16.6, 35, k), control1: pt(7.7, 43.6, k), control2: pt(9.6, 36.5, k))
        p.addLine(to: pt(23.5, 35, k))
        p.addCurve(to: pt(31.7, 48.6, k), control1: pt(23.8, 35, k), control2: pt(31.4, 35.4, k))
        p.addLine(to: pt(33.1, 100.1, k))
        p.addCurve(to: pt(32.5, 100.7, k), control1: pt(33.1, 100.4, k), control2: pt(32.8, 100.7, k))
        p.addCurve(to: pt(31.9, 100.1, k), control1: pt(32.2, 100.7, k), control2: pt(31.9, 100.4, k))
        p.addLine(to: pt(30.5, 48.6, k))
        p.addCurve(to: pt(23.5, 36.2, k), control1: pt(30.2, 36.6, k), control2: pt(23.6, 36.2, k))
        p.addLine(to: pt(16.8, 36.2, k))
        p.addCurve(to: pt(8.5, 46.7, k), control1: pt(10.8, 37.5, k), control2: pt(9, 43.3, k))
        p.addCurve(to: pt(8.3, 49.2, k), control1: pt(8.4, 47.5, k), control2: pt(8.3, 48.4, k))
        p.addCurve(to: pt(10.1, 121.5, k), control1: pt(8.4, 55.7, k), control2: pt(9.7, 113, k))
        p.addCurve(to: pt(16.9, 130.6, k), control1: pt(10.6, 130, k), control2: pt(16.7, 130.5, k))
        p.addCurve(to: pt(17.5, 131.3, k), control1: pt(17.2, 130.6, k), control2: pt(17.5, 130.9, k))
        p.addCurve(to: pt(16.9, 131.9, k), control1: pt(17.5, 131.7, k), control2: pt(17.2, 131.9, k))
        p.closeSubpath()
        p.move(to: pt(14.1, 121.6, k))
        p.addCurve(to: pt(13.9, 121.4, k), control1: pt(14, 121.6, k), control2: pt(13.9, 121.6, k))
        p.addCurve(to: pt(12.2, 48.8, k), control1: pt(13.9, 120.8, k), control2: pt(11.5, 60.6, k))
        p.addCurve(to: pt(21.9, 35.4, k), control1: pt(12.9, 36.8, k), control2: pt(21.8, 35.4, k))
        p.addCurve(to: pt(22.2, 35.6, k), control1: pt(22, 35.4, k), control2: pt(22.2, 35.4, k))
        p.addCurve(to: pt(22, 35.9, k), control1: pt(22.2, 35.8, k), control2: pt(22.1, 35.9, k))
        p.addCurve(to: pt(12.7, 48.9, k), control1: pt(21.6, 35.9, k), control2: pt(13.4, 37.3, k))
        p.addCurve(to: pt(14.4, 121.4, k), control1: pt(12, 60.7, k), control2: pt(14.4, 120.8, k))
        p.addCurve(to: pt(14.1, 121.6, k), control1: pt(14.4, 122, k), control2: pt(14.4, 121.6, k))
        p.addLine(to: pt(14.1, 121.6, k))
        p.closeSubpath()
        p.move(to: pt(15.4, 115.1, k))
        p.addCurve(to: pt(15.2, 114.9, k), control1: pt(15.3, 115.1, k), control2: pt(15.2, 115.1, k))
        p.addLine(to: pt(13.7, 50.8, k))
        p.addCurve(to: pt(18.6, 39.1, k), control1: pt(13.7, 50.5, k), control2: pt(13.4, 42.7, k))
        p.addCurve(to: pt(26.9, 39.8, k), control1: pt(21.2, 37.3, k), control2: pt(24.7, 37.6, k))
        p.addCurve(to: pt(30, 51, k), control1: pt(29.8, 42.8, k), control2: pt(29.9, 47.2, k))
        p.addLine(to: pt(30, 51, k))
        p.addCurve(to: pt(30.1, 55.2, k), control1: pt(30, 52.5, k), control2: pt(30.1, 53.8, k))
        p.addLine(to: pt(31.3, 100.6, k))
        p.addLine(to: pt(30.8, 100.6, k))
        p.addLine(to: pt(29.6, 55.2, k))
        p.addCurve(to: pt(29.5, 51.1, k), control1: pt(29.6, 53.8, k), control2: pt(29.5, 52.5, k))
        p.addLine(to: pt(29.5, 51.1, k))
        p.addCurve(to: pt(26.5, 40.1, k), control1: pt(29.4, 47.2, k), control2: pt(29.3, 43, k))
        p.addCurve(to: pt(18.9, 39.4, k), control1: pt(24.5, 38, k), control2: pt(21.3, 37.8, k))
        p.addCurve(to: pt(14.3, 50.6, k), control1: pt(14, 42.8, k), control2: pt(14.3, 50.6, k))
        p.addLine(to: pt(15.8, 114.7, k))
        p.addCurve(to: pt(15.4, 115.1, k), control1: pt(15.6, 115, k), control2: pt(15.5, 115.1, k))
        p.addLine(to: pt(15.4, 115.1, k))
        p.closeSubpath()
        p.move(to: pt(158.2, 153.2, k))
        p.addCurve(to: pt(157.6, 152.8, k), control1: pt(158, 153.2, k), control2: pt(157.7, 153.1, k))
        p.addCurve(to: pt(157.9, 152, k), control1: pt(157.5, 152.5, k), control2: pt(157.6, 152.1, k))
        p.addLine(to: pt(181.2, 141.7, k))
        p.addCurve(to: pt(191.6, 122.6, k), control1: pt(185.8, 139.1, k), control2: pt(191.3, 133.7, k))
        p.addCurve(to: pt(175.8, 102.1, k), control1: pt(192, 104.9, k), control2: pt(176.5, 102.2, k))
        p.addLine(to: pt(161.4, 99.2, k))
        p.addCurve(to: pt(160.9, 98.5, k), control1: pt(161.1, 99.2, k), control2: pt(160.8, 98.8, k))
        p.addCurve(to: pt(161.6, 98, k), control1: pt(161, 98.2, k), control2: pt(161.3, 97.9, k))
        p.addLine(to: pt(175.9, 100.9, k))
        p.addCurve(to: pt(192.7, 122.7, k), control1: pt(176, 100.9, k), control2: pt(193.2, 103.9, k))
        p.addCurve(to: pt(181.6, 142.9, k), control1: pt(192.4, 134.4, k), control2: pt(186.5, 140.1, k))
        p.addLine(to: pt(158.3, 153.2, k))
        p.addCurve(to: pt(158.3, 153.2, k), control1: pt(158.4, 153.2, k), control2: pt(158.3, 153.2, k))
        p.addLine(to: pt(158.3, 153.2, k))
        p.closeSubpath()
        p.move(to: pt(154.3, 156.8, k))
        p.addLine(to: pt(145.1, 156.8, k))
        p.addCurve(to: pt(142.4, 156.1, k), control1: pt(144.2, 156.8, k), control2: pt(143.2, 156.6, k))
        p.addCurve(to: pt(138.1, 147.5, k), control1: pt(137.6, 153.5, k), control2: pt(138.1, 147.7, k))
        p.addLine(to: pt(139.1, 64.8, k))
        p.addCurve(to: pt(139.9, 58.7, k), control1: pt(139.1, 62.7, k), control2: pt(139.4, 60.6, k))
        p.addCurve(to: pt(147.8, 48.7, k), control1: pt(141.7, 51.6, k), control2: pt(145.6, 49.4, k))
        p.addCurve(to: pt(150.4, 48.5, k), control1: pt(148.6, 48.4, k), control2: pt(149.5, 48.4, k))
        p.addLine(to: pt(156.9, 49.6, k))
        p.addCurve(to: pt(157.4, 50.3, k), control1: pt(157.2, 49.6, k), control2: pt(157.5, 50, k))
        p.addCurve(to: pt(156.7, 50.8, k), control1: pt(157.3, 50.6, k), control2: pt(157, 50.9, k))
        p.addLine(to: pt(150.2, 49.7, k))
        p.addLine(to: pt(148.2, 49.7, k))
        p.addCurve(to: pt(141.2, 58.8, k), control1: pt(146.3, 50.3, k), control2: pt(142.8, 52.3, k))
        p.addCurve(to: pt(140.5, 64.6, k), control1: pt(140.7, 60.6, k), control2: pt(140.5, 62.5, k))
        p.addLine(to: pt(139.5, 147.4, k))
        p.addCurve(to: pt(143.1, 154.9, k), control1: pt(139.5, 147.7, k), control2: pt(139.1, 152.7, k))
        p.addCurve(to: pt(145.2, 155.4, k), control1: pt(143.7, 155.2, k), control2: pt(144.4, 155.4, k))
        p.addLine(to: pt(154.4, 155.4, k))
        p.addCurve(to: pt(155, 156, k), control1: pt(154.7, 155.4, k), control2: pt(155, 155.7, k))
        p.addCurve(to: pt(154.3, 156.7, k), control1: pt(155, 156.3, k), control2: pt(154.6, 156.7, k))
        p.addLine(to: pt(154.3, 156.7, k))
        p.closeSubpath()
        p.move(to: pt(153, 156.9, k))
        p.addCurve(to: pt(148.6, 155.2, k), control1: pt(151.3, 156.9, k), control2: pt(149.8, 156.3, k))
        p.addCurve(to: pt(145.7, 147.3, k), control1: pt(145.7, 152.5, k), control2: pt(145.7, 147.5, k))
        p.addCurve(to: pt(145.7, 67.9, k), control1: pt(145.7, 146.7, k), control2: pt(145.6, 86.7, k))
        p.addCurve(to: pt(154.1, 49.5, k), control1: pt(145.8, 53.4, k), control2: pt(151, 50.1, k))
        p.addCurve(to: pt(156.9, 49.7, k), control1: pt(155, 49.3, k), control2: pt(156, 49.5, k))
        p.addLine(to: pt(156.9, 49.7, k))
        p.addCurve(to: pt(162.9, 61.5, k), control1: pt(163.3, 51.8, k), control2: pt(162.9, 60.9, k))
        p.addLine(to: pt(161.8, 141, k))
        p.addCurve(to: pt(153.5, 157, k), control1: pt(161.8, 141.7, k), control2: pt(161.1, 156.5, k))
        p.addCurve(to: pt(153, 156.9, k), control1: pt(153.3, 156.9, k), control2: pt(153.2, 156.9, k))
        p.closeSubpath()
        p.move(to: pt(155.2, 50.9, k))
        p.addLine(to: pt(154.4, 50.9, k))
        p.addCurve(to: pt(147.2, 67.9, k), control1: pt(152.2, 51.4, k), control2: pt(147.2, 54, k))
        p.addCurve(to: pt(147.2, 147.3, k), control1: pt(147.1, 86.7, k), control2: pt(147.2, 146.7, k))
        p.addCurve(to: pt(149.6, 154.1, k), control1: pt(147.2, 147.3, k), control2: pt(147.2, 151.9, k))
        p.addCurve(to: pt(153.4, 155.3, k), control1: pt(150.6, 155, k), control2: pt(151.8, 155.4, k))
        p.addCurve(to: pt(160.3, 140.8, k), control1: pt(159.7, 154.9, k), control2: pt(160.3, 140.9, k))
        p.addLine(to: pt(161.4, 61.3, k))
        p.addLine(to: pt(161.4, 61.3, k))
        p.addCurve(to: pt(156.4, 51, k), control1: pt(161.4, 61.3, k), control2: pt(161.8, 52.8, k))
        p.addLine(to: pt(156.4, 51, k))
        p.addCurve(to: pt(155.2, 50.8, k), control1: pt(156, 51, k), control2: pt(155.6, 50.8, k))
        p.addLine(to: pt(155.2, 50.8, k))
        p.closeSubpath()
        p.move(to: pt(154.8, 134.5, k))
        p.addLine(to: pt(154.6, 134.5, k))
        p.addCurve(to: pt(151.3, 133, k), control1: pt(153.2, 134.5, k), control2: pt(152.1, 134, k))
        p.addCurve(to: pt(149.5, 126.8, k), control1: pt(149.3, 130.8, k), control2: pt(149.5, 126.9, k))
        p.addLine(to: pt(149.5, 69.7, k))
        p.addCurve(to: pt(154.2, 52.5, k), control1: pt(149.7, 61, k), control2: pt(150.5, 55.1, k))
        p.addCurve(to: pt(157.4, 51.7, k), control1: pt(155.2, 51.8, k), control2: pt(156.3, 51.5, k))
        p.addCurve(to: pt(161.3, 54.7, k), control1: pt(159.7, 52.1, k), control2: pt(161.2, 54.6, k))
        p.addCurve(to: pt(161.2, 55, k), control1: pt(161.4, 54.7, k), control2: pt(161.3, 55, k))
        p.addLine(to: pt(160.9, 55, k))
        p.addCurve(to: pt(157.3, 52.3, k), control1: pt(160.9, 55, k), control2: pt(159.4, 52.7, k))
        p.addCurve(to: pt(154.5, 53, k), control1: pt(156.3, 52.1, k), control2: pt(155.4, 52.3, k))
        p.addCurve(to: pt(150, 69.8, k), control1: pt(151, 55.5, k), control2: pt(150.2, 61.3, k))
        p.addLine(to: pt(150, 126.9, k))
        p.addCurve(to: pt(151.7, 132.8, k), control1: pt(150, 126.9, k), control2: pt(149.8, 130.7, k))
        p.addCurve(to: pt(154.7, 134.1, k), control1: pt(152.5, 133.6, k), control2: pt(153.5, 134.1, k))
        p.addCurve(to: pt(160.8, 127, k), control1: pt(159, 134.2, k), control2: pt(160.4, 129.2, k))
        p.addLine(to: pt(160.8, 126.8, k))
        p.addCurve(to: pt(161.1, 126.8, k), control1: pt(160.9, 126.8, k), control2: pt(161, 126.6, k))
        p.addCurve(to: pt(161.2, 127.1, k), control1: pt(161.2, 127, k), control2: pt(161.3, 127, k))
        p.addLine(to: pt(161.2, 127.1, k))
        p.addCurve(to: pt(154.8, 134.7, k), control1: pt(160.9, 129, k), control2: pt(159.5, 134.7, k))
        p.addLine(to: pt(154.8, 134.5, k))
        p.closeSubpath()
        p.move(to: pt(160.4, 147.7, k))
        p.addCurve(to: pt(159.7, 147.3, k), control1: pt(160.1, 147.7, k), control2: pt(159.8, 147.5, k))
        p.addCurve(to: pt(160.1, 146.3, k), control1: pt(159.5, 146.9, k), control2: pt(159.7, 146.5, k))
        p.addLine(to: pt(184.4, 135.4, k))
        p.addCurve(to: pt(185.1, 135, k), control1: pt(184.7, 135.3, k), control2: pt(184.9, 135.2, k))
        p.addCurve(to: pt(190, 122.7, k), control1: pt(186.5, 134, k), control2: pt(189.7, 130.7, k))
        p.addCurve(to: pt(188.1, 114.6, k), control1: pt(190.2, 117.5, k), control2: pt(189.1, 115.4, k))
        p.addCurve(to: pt(186.4, 114, k), control1: pt(187.3, 113.9, k), control2: pt(186.6, 114, k))
        p.addLine(to: pt(161.8, 122.9, k))
        p.addCurve(to: pt(160.8, 122.4, k), control1: pt(161.4, 122.9, k), control2: pt(161, 122.9, k))
        p.addCurve(to: pt(161.3, 121.4, k), control1: pt(160.7, 122, k), control2: pt(160.9, 121.6, k))
        p.addLine(to: pt(186, 112.5, k))
        p.addLine(to: pt(186.1, 112.5, k))
        p.addCurve(to: pt(189.1, 113.4, k), control1: pt(186.2, 112.5, k), control2: pt(187.7, 112.2, k))
        p.addCurve(to: pt(191.6, 122.7, k), control1: pt(190.9, 114.9, k), control2: pt(191.7, 118.1, k))
        p.addCurve(to: pt(186.1, 136.2, k), control1: pt(191.3, 131.4, k), control2: pt(187.7, 135, k))
        p.addCurve(to: pt(185.1, 136.8, k), control1: pt(185.8, 136.4, k), control2: pt(185.5, 136.6, k))
        p.addLine(to: pt(160.8, 147.7, k))
        p.addCurve(to: pt(160.4, 147.7, k), control1: pt(160.6, 147.6, k), control2: pt(160.5, 147.7, k))
        p.addLine(to: pt(160.4, 147.7, k))
        p.closeSubpath()
        p.move(to: pt(161.6, 119.5, k))
        p.addCurve(to: pt(161.4, 119.3, k), control1: pt(161.5, 119.5, k), control2: pt(161.4, 119.5, k))
        p.addCurve(to: pt(161.6, 119, k), control1: pt(161.4, 119.1, k), control2: pt(161.4, 119, k))
        p.addLine(to: pt(185.9, 110.3, k))
        p.addCurve(to: pt(191.2, 113.1, k), control1: pt(185.9, 110.3, k), control2: pt(189.4, 109.1, k))
        p.addCurve(to: pt(191.1, 113.4, k), control1: pt(191.3, 113.1, k), control2: pt(191.2, 113.4, k))
        p.addLine(to: pt(190.8, 113.4, k))
        p.addCurve(to: pt(186.2, 110.9, k), control1: pt(189.2, 109.9, k), control2: pt(186.3, 110.9, k))
        p.addLine(to: pt(161.6, 119.6, k))
        p.addLine(to: pt(161.6, 119.6, k))
        p.closeSubpath()
    }
}

// MARK: - 通用路由器线稿（App 内其它位置用它）

//
// 2026-11-16：拓扑中心换成了官方线稿（`RouterModelGlyph`，见上），
// 但设置页的「路由器」卡、概览的当前路由器行、连接弹窗、启动页这四处还是这一枚——
// 它和桌面图标是同一套几何，属于品牌标识，跟拓扑图里那台具体机型不是一件事。
// 每一版都别再把它删掉：v3.0.7 重写本文件时漏了它，CI 直接报
// `cannot find 'RouterGlyph' in scope`（4 个文件 5 处引用）。
//
// 下面是 v3.0.6 及以前的实现，原样保留。
//
/// App 内统一使用的路由器线稿。
///
/// 和桌面图标（`Assets.xcassets/AppIcon.appiconset/icon-1024.png`）是同一套几何：
/// 方盒 + 两根天线 + 大小两道弧 + 面板线 + 指示灯。那枚图标的画布是 1024，
/// 图形内容（含笔宽）宽 562；这里把同一组坐标按比例画进任意尺寸的框里，
/// 线条粗细固定为图形宽度的 4.6% —— 这样 19pt 的列表行和 34pt 的卡片图标
/// 是同一枚图形，不会像 SF Symbols 那样换个字号就换一种粗细。
///
/// 小尺寸会掉细节：低于 24pt 时面板线和指示灯会糊成一片浅灰，这时只保留盒子、
/// 天线和两道弧（仍能认出是路由器）。
struct RouterGlyph: View {
    var size: CGFloat
    var tint: Color = .blue

    /// 面板线与指示灯至少要这么多点才画得清。
    private var showsDetails: Bool { size >= 24 }

    private var lineWidth: CGFloat {
        // 4.6% 是图标里的比例（笔宽 26 / 内容 562）；细到 1.25pt 以下就发虚，给个下限。
        max(1.25, size * 0.046)
    }

    var body: some View {
        ZStack {
            RouterGlyphShape(showsDetails: showsDetails)
                .stroke(tint,
                        style: StrokeStyle(lineWidth: lineWidth,
                                           lineCap: .round,
                                           lineJoin: .round))
            if showsDetails {
                RouterGlyphLamp().fill(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 几何

/// 图标坐标 → 目标框的换算。
///
/// 原图是 1024 画布，那枚图标里图形整体上移过 38pt 才视觉居中，
/// 这里直接沿用上移后的坐标，省得两处各算一遍。
private enum RouterGeometry {
    /// 图形内容的边长：机身最宽，536 + 两侧各半个笔宽 = 562。
    /// 注意别按天线的跨度去算 —— 天线（306…718）比机身窄，按它裁会把机身两边切掉。
    static let content: CGFloat = 562
    /// 内容中心：x 居中，y 由「主弧最高点 325」与「机身底边 716」取中。
    static let center = CGPoint(x: 512, y: 520.5)

    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / content
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// 朝上凸的圆弧：圆心一定在弦的下方。
    ///
    /// 这里**不用** `Path.addArc(center:radius:startAngle:endAngle:clockwise:)`。
    /// 那个 API 的 `clockwise` 在 SwiftUI 的翻转坐标系里方向是反的：起角 -129°、
    /// 终角 -51° 时它不会走「经过 -90°（正上方）」的那一小段，而是绕远路从下方兜一圈，
    /// 两道弧于是变成一只闭合的「眼睛」——2026-10-30 实机上就是这个样子。
    /// 改成按角度等分取点连折线：方向由我们自己定，48 段在 34pt 下已经看不出棱角。
    static func addArc(_ path: inout Path, from a: CGPoint, to b: CGPoint, radius: CGFloat) {
        let ax = Double(a.x), ay = Double(a.y)
        let bx = Double(b.x), by = Double(b.y)
        let r = Double(radius)

        let mx = (ax + bx) / 2, my = (ay + by) / 2
        let half = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot() / 2
        // 半径比弦还短时开方会得到 NaN，夹一下免得整条路径失效。
        let height = (max(0, r * r - half * half)).squareRoot()
        // 圆心在弦的下方（y 越大越靠下），弧才是往上凸的。
        let cy = my + height

        let start = atan2(ay - cy, ax - mx)
        let end = atan2(by - cy, bx - mx)

        let steps = 48
        for i in 0...steps {
            let t = start + (end - start) * Double(i) / Double(steps)
            let point = CGPoint(x: mx + r * cos(t), y: cy + r * sin(t))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
}

private struct RouterGlyphShape: Shape {
    var showsDetails: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 机身
        path.addRoundedRect(in: CGRect(x: 244, y: 503, width: 536, height: 200),
                            cornerSize: CGSize(width: 62, height: 62))

        // 两根天线
        path.move(to: CGPoint(x: 356, y: 503))
        path.addLine(to: CGPoint(x: 306, y: 359))
        path.move(to: CGPoint(x: 668, y: 503))
        path.addLine(to: CGPoint(x: 718, y: 359))

        // 主弧 + 小弧
        RouterGeometry.addArc(&path,
                              from: CGPoint(x: 386, y: 383),
                              to: CGPoint(x: 638, y: 383),
                              radius: 200)
        RouterGeometry.addArc(&path,
                              from: CGPoint(x: 448, y: 454),
                              to: CGPoint(x: 576, y: 454),
                              radius: 96)

        // 前面板的一道分缝
        if showsDetails {
            path.move(to: CGPoint(x: 300, y: 624))
            path.addLine(to: CGPoint(x: 470, y: 624))
        }

        return path.applying(RouterGeometry.transform(in: rect))
    }
}

/// 指示灯：图标里是实心点，不能并进描边路径（描边会画成一圈粗环）。
private struct RouterGlyphLamp: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 669, y: 609, width: 30, height: 30))
        return path.applying(RouterGeometry.transform(in: rect))
    }
}
