import SwiftUI

/// 设备类型的线条图标（自绘）。
///
/// **为什么不用 SF Symbols**：那套里 `hifispeaker` / `applewatch` / `gamecontroller` /
/// `wifi.router` 是实心笔画，`iphone` / `laptopcomputer` / `tv` / `camera` 是线框，
/// 13 个并排看下去像东拼西凑（用户 2026-11-16：「图标风格不一样，有的实心有的线条」）。
/// SF Symbols 里找不到 13 个统一笔画的设备图标，于是自己画：24×24 的画布、
/// 一支笔（round cap / round join / 同一个线宽），只有图形本身不同。
///
/// 画布尺寸按 `size` 等比缩放，线宽跟着缩放，所以 17pt（列表）和 15pt（类型选择器）
/// 观感一致。没归类的设备（`kind == nil` 或 `.unknown`）画一个问号——
/// 和类型选择器里「未知」那一行是同一个图形（用户 2026-11-16：「未知用问号」）。
struct DeviceGlyph: View {
    let kind: ClientClass?
    var size: CGFloat = 18
    var weight: CGFloat = 1.6

    var body: some View {
        Path { path in
            let k = size / 24
            if let kind, kind != .unknown {
                GlyphBuilder.build(kind, scale: k, into: &path)
            } else {
                GlyphBuilder.question(scale: k, into: &path)
            }
        }
        .stroke(style: StrokeStyle(lineWidth: weight * size / 24,
                                   lineCap: .round,
                                   lineJoin: .round))
        .frame(width: size, height: size)
    }
}

/// 13 个图形，坐标全在 24×24 的网格上（乘 `k` 换算成实际点）。
/// 统一规则：外形是圆角矩形，内部用线或小圆点作区分，**不填色**。
private enum GlyphBuilder {
    /// 未知类型：一个问号。钩子从左上起弧、绕到右下角再折回中线，
    /// 接一小段竖，最后是一个点。和上面 12 个图形同一支笔，所以并排看是一致的。
    static func question(scale k: CGFloat, into path: inout Path) {
        path.move(to: CGPoint(x: 8.9 * k, y: 9.8 * k))
        path.addCurve(to: CGPoint(x: 12.0 * k, y: 5.9 * k),
                      control1: CGPoint(x: 8.9 * k, y: 7.2 * k),
                      control2: CGPoint(x: 10.2 * k, y: 5.9 * k))
        path.addCurve(to: CGPoint(x: 15.1 * k, y: 9.8 * k),
                      control1: CGPoint(x: 13.8 * k, y: 5.9 * k),
                      control2: CGPoint(x: 15.1 * k, y: 7.3 * k))
        path.addCurve(to: CGPoint(x: 12.0 * k, y: 12.7 * k),
                      control1: CGPoint(x: 15.1 * k, y: 11.7 * k),
                      control2: CGPoint(x: 13.9 * k, y: 12.7 * k))
        path.move(to: CGPoint(x: 12.0 * k, y: 12.7 * k))
        path.addLine(to: CGPoint(x: 12.0 * k, y: 14.6 * k))
        path.addEllipse(in: CGRect(x: 10.7 * k, y: 17.1 * k,
                                   width: 2.6 * k, height: 2.6 * k))
    }

    static func build(_ kind: ClientClass, scale k: CGFloat, into path: inout Path) {
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            path.addRoundedRect(
                in: CGRect(x: x * k, y: y * k, width: w * k, height: h * k),
                cornerSize: CGSize(width: r * k, height: r * k),
                style: .continuous
            )
        }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: x1 * k, y: y1 * k))
            path.addLine(to: CGPoint(x: x2 * k, y: y2 * k))
        }
        func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: (cx - r) * k, y: (cy - r) * k,
                                       width: 2 * r * k, height: 2 * r * k))
        }

        switch kind {
        case .phone:
            box(8, 2.5, 8, 19, 2.4)
            line(10.6, 18.2, 13.4, 18.2)

        case .pad:
            box(4.5, 2.5, 15, 19, 2.4)
            line(10.6, 18.6, 13.4, 18.6)

        case .laptop:
            box(4.5, 4.2, 15, 10.2, 1.8)
            line(2.5, 18.4, 21.5, 18.4)

        case .computer:
            box(3, 4.2, 18, 11.4, 1.8)
            line(12, 15.6, 12, 19)
            line(7.5, 19.4, 16.5, 19.4)

        case .television:
            box(2.5, 6.4, 19, 11.4, 2)
            line(12, 17.8, 9.4, 21)
            line(12, 17.8, 14.6, 21)

        case .camera:
            box(2.5, 7.6, 19, 11.8, 2.6)
            dot(12, 13.5, 3.3)
            path.move(to: CGPoint(x: 8.4 * k, y: 7.6 * k))
            path.addLine(to: CGPoint(x: 9.7 * k, y: 5.2 * k))
            path.addLine(to: CGPoint(x: 14.3 * k, y: 5.2 * k))
            path.addLine(to: CGPoint(x: 15.6 * k, y: 7.6 * k))

        case .sound:
            box(7.5, 2.5, 9, 19, 2.6)
            dot(12, 8.4, 1.6)
            dot(12, 15.4, 2.4)

        case .printer:
            box(4, 9, 16, 7, 1.8)
            box(7.5, 3.5, 9, 5.5, 1.2)
            box(7.5, 15.2, 9, 5.3, 1.2)

        case .watch:
            box(7.6, 6, 8.8, 12, 2.6)
            line(9.8, 6, 9.8, 3.2)
            line(14.2, 6, 14.2, 3.2)
            line(9.8, 18, 9.8, 20.8)
            line(14.2, 18, 14.2, 20.8)

        case .games:
            box(2, 8.2, 20, 8.6, 4.3)
            line(7.4, 10.4, 7.4, 14.6)
            line(5.3, 12.5, 9.5, 12.5)
            dot(16.2, 11.5, 0.85)
            dot(18.3, 13.6, 0.85)

        case .smartAppliances:
            dot(12, 9.2, 4.7)
            line(9.9, 13.6, 9.9, 17.2)
            line(14.1, 13.6, 14.1, 17.2)
            line(9.9, 17.8, 14.1, 17.8)
            line(10.8, 19.8, 13.2, 19.8)

        case .gateway:
            box(2.5, 13, 19, 7, 2)
            line(7.2, 13, 7.2, 8.8)
            line(7.2, 8.8, 4.6, 6.4)
            line(16.8, 13, 16.8, 8.8)
            line(16.8, 8.8, 19.4, 6.4)
            dot(7.2, 16.5, 0.8)
            dot(11, 16.5, 0.8)

        case .unknown:
            question(scale: k, into: &path)
        }
    }
}
