import Foundation
import SwiftUI
import UIKit

/// 底栏三枚图标（b90 起：旧自绘路径渲染成 UIImage，塞进原生 TabView 的 tabItem）。
///
/// 图形沿用旧自绘底栏那一套：24×24 设计框、1.7 的线宽、圆头圆角，
/// 未选中画空心、选中换实心（实心不是把空心加粗，而是另一套闭合路径）。
/// 实心版都留了「洞」：齿轮的中心孔、盾牌里的对勾、球上的两条经纬圈，
/// 避免选中后只剩一团纯色。
///
/// 为什么画成 UIImage：原生 tabItem 的 icon 只认 Image，自绘 View 会被丢掉；
/// 而 SF Symbol 的 fill 变体（b89 试过）是另一套形状，比例对不上旧图形，
/// 用户明确否掉。用 .alwaysTemplate 输出，未选中灰 / 选中着色由系统底栏自己上，
/// 这里只负责「空心 ↔ 实心」的形状变化。
enum TabGlyphKind {
    case overview
    case proxy
    case network
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
        case (.network, false): return networkIdle
        case (.network, true): return networkFilled
        case (.settings, false): return settingsIdle
        case (.settings, true): return settingsFilled
        }
    }

    // 八张图全部预生成（每次都是同一像素，没必要重复画）。
    private static let overviewIdle = render(.overview, filled: false)
    private static let overviewFilled = render(.overview, filled: true)
    private static let proxyIdle = render(.proxy, filled: false)
    private static let proxyFilled = render(.proxy, filled: true)
    private static let networkIdle = render(.network, filled: false)
    private static let networkFilled = render(.network, filled: true)
    private static let settingsIdle = render(.settings, filled: false)
    private static let settingsFilled = render(.settings, filled: true)

    /// 24×24pt 设计框、3x 位图。颜色无所谓——template 模式只取 alpha 当蒙版。
    private static func render(_ kind: TabGlyphKind, filled: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        // clear 混合模式要往 alpha 通道里擦，必须是透明底。
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let glyph = designPath(kind, filled: filled)
            cg.addPath(glyph.outline.cgPath)
            if filled {
                // even-odd：齿轮的中心孔是「挖」出来的，不是叠一个白圆
                // （深色模式下叠白色会穿帮）。
                cg.setFillColor(UIColor.black.cgColor)
                cg.fillPath(using: .evenOdd)

                // 实心态必须沿同一条路径再描一遍 1.7（v3.3.6）：
                // 空心是「描边」，笔画有一半涨在轮廓外面（0.85）；实心只填不描，
                // 外形就比空心小一圈。四枚图标在 24pt 画布里差 7~8%
                // （实心跨度 20.8~21.0，空心 22.5~22.7），切换标签时看着
                // 就是「选中之后图标变小了」（用户 2026-11-23 反馈）。
                //
                // **这笔描边必须排在擦除之前（v3.4.4）**。以前它排在擦除之后，
                // 于是球边缘 0.85 的宽度被重新涂黑，正好盖住经纬线伸到边缘的那一段：
                // 网络图标选中后四个方向的白色端点全被削平，看着像「内部白色的四角
                // 不完整」（用户 2026-11-27 截图指出）。挪到前面之后白线能一直通到
                // 球边，四个断口补齐，粗细和位置都不用动。
                cg.addPath(glyph.outline.cgPath)
                cg.setStrokeColor(UIColor.black.cgColor)
                cg.setLineWidth(1.7)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.strokePath()

                if let cut = glyph.cut {
                    // 对勾不走 even-odd：它的带状轮廓在拐角处会自交，
                    // even-odd 把重叠区少数一次，就在钩尖下漏出那一小块
                    // （用户 2026-11-03 在底栏看到的「多一点点」）。
                    // 改成直接擦：沿折线用 clear 描一遍，按 alpha 擦除，
                    // 自交与否都不影响结果。
                    cg.setBlendMode(.clear)
                    cg.setLineWidth(2.1)
                    cg.setLineCap(.round)
                    cg.setLineJoin(.round)
                    cg.addPath(cut.cgPath)
                    cg.strokePath()
                    cg.setBlendMode(.normal)
                }
            } else {
                cg.setStrokeColor(UIColor.black.cgColor)
                cg.setLineWidth(1.7)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.strokePath()
                // 未选中态的「实心笔画」：盾牌里那枚对勾。
                // v2.8.2 之前空心态只描一个空盾，24pt 下看着像个空壳（用户：
                // 「代理图标没选时太空了，没选时里面有个黑色实心勾，跟选中时反着的」）。
                // 现在未选中 = 空盾 + 实心勾，选中 = 实心盾 + 挖空的勾，正好反过来。
                if let ink = glyph.ink {
                    cg.addPath(ink.cgPath)
                    cg.setLineWidth(2.1)
                    cg.strokePath()
                }
            }
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 路径（与 backup-tabbar-b87 的 TabGlyph 同一套，只是去掉了缩放变换）

    /// 一张图的三层：外形、实心态要挖掉的笔画、空心态额外描的笔画。
    private struct GlyphPaths {
        let outline: Path
        var cut: Path?
        var ink: Path?
    }

    /// 24 单位设计框下的原始路径。旧 View 里按显示尺寸缩放，这里固定 24pt 一次画死。
    ///
    /// `outline` 是外形（实心时整片填、空心时描边），`cut` 是实心态要擦掉的笔画
    /// （盾牌里的对勾、球上的经纬圈），`ink` 是空心态要额外描的笔画（目前只有代理的对勾）。
    private static func designPath(_ kind: TabGlyphKind, filled: Bool) -> GlyphPaths {
        switch kind {
        case .overview:
            return GlyphPaths(outline: overviewPath())
        case .proxy:
            // 选中：实心盾 + 挖空的对勾；未选中：空盾 + 实心对勾。
            return filled
                ? GlyphPaths(outline: proxyPath(), cut: proxyCheckStroke())
                : GlyphPaths(outline: proxyPath(), ink: proxyCheckStroke())
        case .network:
            // 球不能三条子路径一起填：even-odd 会把圈内的区域挖成条带。
            // 实心版只填外圆，两条圈交给 `cut` 擦出来（和盾牌的对勾同一招）。
            return filled
                ? GlyphPaths(outline: globeDisc(), cut: globeWire(inset: 1.1))
                : GlyphPaths(outline: networkPath())
        case .settings:
            return GlyphPaths(outline: settingsPath())
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
    /// 所以实心版在中间擦一枚对勾（安全/通过的含义也正好对得上「代理」），
    /// 对勾单独由 `proxyCheckStroke()` 给出，见 `render` 里的擦除逻辑。
    private static func proxyPath() -> Path {
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
        return p
    }

    /// 实心盾里那枚对勾的中线（2.1 宽、圆头圆角）。
    ///
    /// 只给折线，不带宽度——宽度交给 `render` 描边时给，擦除才不会
    /// 因为「带状轮廓自交」而多出一块。
    private static func proxyCheckStroke() -> Path {
        var check = Path()
        check.move(to: CGPoint(x: 8.80, y: 11.25))
        check.addLine(to: CGPoint(x: 11.10, y: 13.60))
        check.addLine(to: CGPoint(x: 15.50, y: 8.90))
        return check
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

    /// 网络（v2.8.0）：球形网络——一个球，正面两条经纬圈。
    ///
    /// 之前画的是「带两根天线的路由器」，24pt 下那两根天线只有 1.6 宽、6.4 长，
    /// 用户看着就是一坨（2026-11-15：「太丑了换球形网络那个图标」）。
    /// 现在改成球：外圆 + 一条经圈（竖椭圆）+ 一条纬圈（横椭圆），三笔就够，
    /// 空心只剩线条、实心是一整片球上擦出两条圈，两种状态都认得出是球。
    private static func networkPath() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 2.4, y: 2.4, width: 19.2, height: 19.2))
        p.addEllipse(in: meridianRect())
        p.addEllipse(in: latitudeRect())
        return p
    }

    /// 实心球：只有外圆，靠 even-odd 填成一整片（三条子路径一起填会被挖成条带）。
    private static func globeDisc() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 2.4, y: 2.4, width: 19.2, height: 19.2))
        return p
    }

    /// 实心球上要擦掉的两条圈（经圈 + 纬圈）。
    ///
    /// `inset` 是给实心态用的：擦除笔画有宽度，圈如果正好落在外圆上，
    /// 擦出来的亮线会把球边缘啃掉四个口子。往里收半个笔画宽就干净了。
    private static func globeWire(inset: CGFloat = 0) -> Path {
        var p = Path()
        p.addEllipse(in: meridianRect().insetBy(dx: inset, dy: inset))
        p.addEllipse(in: latitudeRect().insetBy(dx: inset, dy: inset))
        return p
    }

    /// 经圈：竖椭圆，宽 8.6、高 19.2，正好贴在外圆上。
    private static func meridianRect() -> CGRect {
        CGRect(x: 12 - 4.3, y: 2.4, width: 8.6, height: 19.2)
    }

    /// 纬圈：横椭圆，宽 19.2、高 8.2。比经圈扁一点，看着才像赤道而不是第二个经圈。
    private static func latitudeRect() -> CGRect {
        CGRect(x: 2.4, y: 12 - 4.1, width: 19.2, height: 8.2)
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
