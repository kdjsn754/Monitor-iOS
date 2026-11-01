import Foundation
import SwiftUI
import UIKit

/// 底栏三枚图标（b90 起：旧自绘路径渲染成 UIImage，塞进原生 TabView 的 tabItem）。
///
/// 图形沿用旧自绘底栏那一套：24×24 设计框、1.7 的线宽、圆头圆角，
/// 未选中画空心、选中换实心（实心不是把空心加粗，而是另一套闭合路径）。
/// 实心版都留了「洞」：齿轮的中心孔、盾牌里的对勾，避免选中后只剩一团纯色。
///
/// 为什么画成 UIImage：原生 tabItem 的 icon 只认 Image，自绘 View 会被丢掉；
/// 而 SF Symbol 的 fill 变体（b89 试过）是另一套形状，比例对不上旧图形，
/// 用户明确否掉。用 .alwaysTemplate 输出，未选中灰 / 选中着色由系统底栏自己上，
/// 这里只负责「空心 ↔ 实心」的形状变化。
enum TabGlyphKind {
    case overview
    case proxy
    case settings
}

enum TabGlyphImage {
    /// 取某页的图标。selected 换实心版本。
    static func image(_ kind: TabGlyphKind, selected: Bool) -> UIImage {
        switch (kind, selected) {
        case (.overview, false): return overviewIdle
        case (.overview, true): return overviewFilled
        case (.proxy, false): return proxyIdle
        case (.proxy, true): return proxyFilled
        case (.settings, false): return settingsIdle
        case (.settings, true): return settingsFilled
        }
    }

    // 六张图全部预生成（每次都是同一像素，没必要重复画）。
    private static let overviewIdle = render(.overview, filled: false)
    private static let overviewFilled = render(.overview, filled: true)
    private static let proxyIdle = render(.proxy, filled: false)
    private static let proxyFilled = render(.proxy, filled: true)
    private static let settingsIdle = render(.settings, filled: false)
    private static let settingsFilled = render(.settings, filled: true)

    /// 24×24pt 设计框、3x 位图。颜色无所谓——template 模式只取 alpha 当蒙版。
    private static func render(_ kind: TabGlyphKind, filled: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.addPath(designPath(kind, filled: filled).cgPath)
            if filled {
                // even-odd：齿轮的中心孔、盾牌的对勾都是「挖」出来的，
                // 不是叠一个白圆/白勾（深色模式下会穿帮）
                cg.setFillColor(UIColor.black.cgColor)
                cg.fillPath(using: .evenOdd)
            } else {
                cg.setStrokeColor(UIColor.black.cgColor)
                cg.setLineWidth(1.7)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.strokePath()
            }
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 路径（与 backup-tabbar-b87 的 TabGlyph 同一套，只是去掉了缩放变换）

    /// 24 单位设计框下的原始路径。旧 View 里按显示尺寸缩放，这里固定 24pt 一次画死。
    private static func designPath(_ kind: TabGlyphKind, filled: Bool) -> Path {
        switch kind {
        case .overview: return overviewPath()
        case .proxy: return proxyPath(filled: filled)
        case .settings: return settingsPath()
        }
    }

    /// 概览：2×2 圆角方块。
    private static func overviewPath() -> Path {
        var p = Path()
        let side: CGFloat = 9.3
        let gap: CGFloat = 2.4
        let pitch = side + gap
        let corner: CGFloat = 2.7
        for sx in [-1, 1] {
            for sy in [-1, 1] {
                let cx = 12 + CGFloat(sx) * pitch / 2
                let cy = 12 + CGFloat(sy) * pitch / 2
                p.addRoundedRect(
                    in: CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side),
                    cornerSize: CGSize(width: corner, height: corner),
                    style: .continuous
                )
            }
        }
        return p
    }

    /// 代理：盾牌。上边两角圆角、两侧直下、底部收成一个圆头的尖。
    ///
    /// 选中态不是简单填满：纯色盾缩到 23pt 就只剩一团黑，分不清是盾还是水滴。
    /// 所以实心版在中间用 even-odd 挖一枚对勾（安全/通过的含义也正好对得上「代理」）。
    private static func proxyPath(filled: Bool) -> Path {
        var p = Path()
        let half: CGFloat = 9.15      // 半宽
        let top: CGFloat = 2.0
        let tip: CGFloat = 22.2
        let shoulder: CGFloat = 13.2  // 直边结束、开始收尖的位置
        let r: CGFloat = 4.1          // 上圆角

        p.move(to: CGPoint(x: 12 - half, y: top + r))
        // 左上圆角：180° → 270°（注意 Path.addArc 在翻转坐标系里方向是反的，
        // 所以这里一律用折线自己描，不再用 addArc）
        addArc(&p, center: CGPoint(x: 12 - half + r, y: top + r), radius: r, from: 180, to: 270, moveFirst: false)
        p.addLine(to: CGPoint(x: 12 + half - r, y: top))
        addArc(&p, center: CGPoint(x: 12 + half - r, y: top + r), radius: r, from: 270, to: 360, moveFirst: false)
        p.addLine(to: CGPoint(x: 12 + half, y: shoulder))
        p.addCurve(to: CGPoint(x: 12, y: tip),
                   control1: CGPoint(x: 12 + half, y: shoulder + 4.3),
                   control2: CGPoint(x: 12 + half * 0.52, y: tip - 1.5))
        p.addCurve(to: CGPoint(x: 12 - half, y: shoulder),
                   control1: CGPoint(x: 12 - half * 0.52, y: tip - 1.5),
                   control2: CGPoint(x: 12 - half, y: shoulder + 4.3))
        p.closeSubpath()

        if filled {
            // 对勾先描成带宽度的轮廓，再并进主路径交给 even-odd 挖空；
            // 直接手算带状多边形的话，两头和拐点的圆角要另外补圆，容易画歪。
            var check = Path()
            check.move(to: CGPoint(x: 8.80, y: 11.25))
            check.addLine(to: CGPoint(x: 11.10, y: 13.60))
            check.addLine(to: CGPoint(x: 15.50, y: 8.90))
            p.addPath(check.strokedPath(StrokeStyle(lineWidth: 2.1,
                                                    lineCap: .round,
                                                    lineJoin: .round)))
        }
        return p
    }

    /// 设置：8 齿齿轮，中间一个圆孔。
    private static func settingsPath() -> Path {
        var p = Path()
        let teeth = 8
        let step: CGFloat = 360 / 8
        let rOut: CGFloat = 10.4
        let rRoot: CGFloat = 7.9
        let head: CGFloat = 11.5   // 齿顶半角
        let base: CGFloat = 17.5   // 齿根半角
        let hole: CGFloat = 3.9

        for i in 0..<teeth {
            let a = CGFloat(i) * step - 90
            let pts = [
                point(rRoot, a - base), point(rOut, a - head),
                point(rOut, a + head), point(rRoot, a + base)
            ]
            if i == 0 {
                p.move(to: pts[0])
            } else {
                p.addLine(to: pts[0])
            }
            for q in pts.dropFirst() { p.addLine(to: q) }
            // 谷底：沿齿根圆走到下一个齿（最后一个齿也要走，否则收尾处会缺一小段弧、
            // 变成一条直弦，在齿根上留个平角）
            addArc(&p, center: CGPoint(x: 12, y: 12), radius: rRoot,
                   from: a + base, to: a + step - base, moveFirst: false, steps: 8)
        }
        p.closeSubpath()

        // 中心孔：单独一条子路径，实心时靠 even-odd 挖空，空心时被描成一圈
        p.addEllipse(in: CGRect(x: 12 - hole, y: 12 - hole, width: hole * 2, height: hole * 2))
        return p
    }

    // MARK: - 小工具

    private static func point(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
        let rad = deg * .pi / 180
        return CGPoint(x: 12 + r * cos(rad), y: 12 + r * sin(rad))
    }

    /// 用折线描圆弧。SwiftUI 里 `Path.addArc` 的顺/逆时针在翻转坐标系下会反着走，
    /// 1.28.4 已经被它画成过「一只眼睛」，所以这里坚持自己采样。
    private static func addArc(_ p: inout Path,
                               center: CGPoint,
                               radius: CGFloat,
                               from a0: CGFloat,
                               to a1: CGFloat,
                               moveFirst: Bool,
                               steps: Int = 16) {
        for i in 0...steps {
            let deg = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let rad = deg * .pi / 180
            let q = CGPoint(x: center.x + radius * cos(rad), y: center.y + radius * sin(rad))
            if i == 0 && moveFirst {
                p.move(to: q)
            } else {
                p.addLine(to: q)
            }
        }
    }
}
