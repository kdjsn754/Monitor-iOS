import SwiftUI

/// 全 App 共用的一套版式（v3.3.0）。
///
/// **为什么非要有这个文件**：用户 2026-11-18 22:02 的原话是「都丑，你看看整个软件
/// 各层级字号啊字重布局什么的，网络页各模块的布局都重做一下。软件现在的问题就是
/// 每个导航页各是各的风格一点都不统一」。
///
/// 当时四个根页确实是四套尺子：
///   - 卡片圆角 18（网络）/ 20 / 22（概览）/ 24（代理面板）；
///   - 卡片标题 13 灰（网络）/ 15 黑 + 蓝图标（设置、代理）/ 17 黑 + 图标（概览）；
///   - 正文 15 显式 / `subheadline` / `headline` / `caption` / `caption2` 混着来；
///   - 页边距 16（概览、代理、设置）/ 18（网络），卡间距 14 / 16。
/// 翻一页就像换了个 App。
///
/// **现在只有这一套**（新增页面一律从这里取，别再写字面量）：
/// ```
/// 30 bold      页面标题（导航栏，见 pageChrome）
/// 22 semibold  卡片里的主数字：速率、台数
/// 17 semibold  卡片头部的大名字：路由器名、OpenClash
/// 16 semibold  **卡片标题**（主色 + 15pt 蓝色图标；用户 2026-11-19 明确要回来）
/// 15           行标题 / 值（行标题 semibold，值 regular）
/// 13 semibold  **瓦片标题**（主色，不再 11pt 灰字）
/// 12           标签、次行、右上角数字
/// 11           胶囊、徽标、脚注
/// 10 semibold  角标（已拦截、偏高、当前…）
/// ```
/// 块面：圆角 20、页边距 18、卡间距 14、行上下各 10。
///
/// **v3.3.1 纠错**（用户 2026-11-19：「把我各模块标题图标全弄没了，各瓦片的标题
/// 不应该最首要吗现在又小又灰」）：v3.3.0 那次统一把四页卡头一律压成 13pt 灰字、
/// 还丢掉了 `icon` 形参不渲染，主次颠倒。现在卡头统一为**图标 + 16 半粗主色字**，
/// 瓦片标题也不再是 11pt 灰字，而是 13 半粗主色字。统一的是尺子，不是把信息抹平。
enum UI {
    // 字号
    static let heroSize: CGFloat = 22
    static let titleSize: CGFloat = 17
    static let rowSize: CGFloat = 15
    static let tileTitleSize: CGFloat = 13
    static let cardTitleSize: CGFloat = 16
    static let labelSize: CGFloat = 12
    static let microSize: CGFloat = 11
    static let badgeSize: CGFloat = 10

    // 间距
    static let pagePadding: CGFloat = 18
    static let cardSpacing: CGFloat = 14
    static let cardRadius: CGFloat = 20
    static let rowPadding: CGFloat = 10

    // 字号快捷方式（写法统一成 UI.row(.semibold)，读代码时不用猜这是哪一档）
    static func hero(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: heroSize, weight: weight)
    }

    static func title(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: titleSize, weight: weight)
    }

    static func row(_ weight: Font.Weight = .regular) -> Font {
        .system(size: rowSize, weight: weight)
    }

    static func tileTitle(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: tileTitleSize, weight: weight)
    }

    static func cardTitle() -> Font {
        .system(size: cardTitleSize, weight: .semibold)
    }

    static func label(_ weight: Font.Weight = .regular) -> Font {
        .system(size: labelSize, weight: weight)
    }

    static func micro(_ weight: Font.Weight = .medium) -> Font {
        .system(size: microSize, weight: weight)
    }

    static func badge(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: badgeSize, weight: weight)
    }
}

/// 卡片里的分隔线：0.5pt、和卡片同宽，颜色跟 `Divider()` 一个系。
///
/// 以前四个页各写一套：`Divider()`、`Divider().opacity(0.6)`、
/// `Divider().opacity(0.5)`、还有一条手搓的 `Rectangle().fill(separator, 0.45)`。
/// 同屏扫一眼能看出三种深浅。
struct CardRule: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.45))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

/// 卡片里的竖分隔线：0.5pt 宽，与 `CardRule` 同色同粗细。
struct CardVerticalRule: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.45))
            .frame(width: 0.5)
    }
}

/// 卡片标题本身：**图标 + 16pt 半粗主色字**。
///
/// 标题是每张卡最该先被看见的东西（用户 2026-11-19 原话）。图标固定 18pt 宽、
/// 蓝色半粗，标题超长中间省略，不许把右侧的开关/结论挤掉。
/// `CardHead` 与设置/代理的 `SectionCard` 共用这一个，四页卡头才真的一致。
struct CardTitle: View {
    let title: String
    var icon: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 18, alignment: .leading)
            }
            Text(title)
                .font(UI.cardTitle())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
        }
    }
}

/// 卡片标题行：左边 `CardTitle`，右边挂一句 12pt 的结论或一颗「更多 ›」。
struct CardHead: View {
    let title: String
    var icon: String = ""
    var trailing: String = ""
    /// 传了动作就是一颗「更多 ›」；不传就是纯文字结论（不加箭头）。
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CardTitle(title: title, icon: icon)

            Spacer(minLength: 8)

            if !trailing.isEmpty {
                if let action {
                    Button(action: action) {
                        HStack(spacing: 3) {
                            Text(trailing)
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(UI.label())
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(trailing)
                        .font(UI.label())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// 卡片本体：标题行 + 内容 + 统一的底（圆角 20、细边、跟滑块变透）。
///
/// 四个根页的卡片全部走这一个容器，不要再自己拼 padding 和背景。
struct CardPanel<Content: View>: View {
    private let title: String
    private let icon: String
    private let trailing: String
    private let action: (() -> Void)?
    private let content: Content

    init(_ title: String,
         icon: String = "",
         trailing: String = "",
         action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHead(title: title, icon: icon, trailing: trailing, action: action)
                .padding(.bottom, 8)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// 卡片 / 浮层共用的底：内边距、圆角、细边。
///
/// 数值集中在 `UI` 里，四个根页和二级页一律走 `cardSurface()`，
/// 别再各写一套 `glassCard(padding:cornerRadius:)`。
struct CardSurfaceModifier: ViewModifier {
    var horizontal: CGFloat = 16
    var top: CGFloat = 14
    var bottom: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
        return content
            .padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background {
                AdaptiveFill(shape: shape,
                             color: Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                AdaptiveBorder(shape: shape, width: 0.6, strength: 0.45)
            }
    }
}

extension View {
    /// 卡片底（v3.3.0 起全 App 只有这一种）。
    func cardSurface(horizontal: CGFloat = 16,
                     top: CGFloat = 14,
                     bottom: CGFloat = 12) -> some View {
        modifier(CardSurfaceModifier(horizontal: horizontal, top: top, bottom: bottom))
    }
}

/// 一格「标签 + 值」：标签 12 灰、值 15（数值等宽）。
///
/// 网络页的上网卡、代理页的实时状态、概览的硬件格都用它，
/// 标签列和值列的字号、字重、行距才不会再各走各的。
struct MetricCell: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var valueWeight: Font.Weight = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(UI.label())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: UI.rowSize, weight: valueWeight))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 骨架微呼吸修饰符：只在展示期间柔和起伏；内容加载完毕后随视图销毁，零常驻开销。
private struct SkeletonPulseModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && !reduceMotion && dimmed ? 0.55 : 1)
            .onAppear {
                guard active, !reduceMotion, !dimmed else { return }
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// 首帧占位条（v3.4.10 重做）。
///
/// **为什么需要**：数据是 SSH 采回来的，从「页面出现」到「第一轮采集到手」之间
/// 有 0.3–2 秒。这段空窗里如果照默认值渲染，用户看到的就是「CPU 0%、温度无传感器、
/// 0 台在线、闪存正在读取…」，等数据一到整页数字一起跳——就是「打开软件有些数据会
/// 等一会突然闪出来」。
///
/// 规矩（所有页面共用）：**没采到过一次就画占位，不画默认值**；占位必须和真实内容
/// 同高，卡片高度不许跳；数据到手后平滑淡入，不「啪」地出现。
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6
    var animated: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .frame(width: width, height: height)
            .modifier(SkeletonPulseModifier(active: animated))
    }
}

/// 一组占位条（几行不等宽的灰条），放在卡片正文的位置上。
struct SkeletonLines: View {
    var count: Int = 3
    var height: CGFloat = 12
    var spacing: CGFloat = 10
    /// 每一行占可用宽度的比例，长度不一才像文字。
    var widths: [CGFloat] = [0.62, 0.86, 0.48]

    var body: some View {
        let ratios = widths.isEmpty ? [1] : widths
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<max(1, count), id: \.self) { index in
                GeometryReader { proxy in
                    SkeletonBar(width: proxy.size.width * ratios[index % ratios.count],
                                height: height)
                }
                .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「占位 → 真实内容」的切换：数据第一次到手时淡入，之后原地更新不再有过渡动画。
///
/// 用淡入而不是默认的「直接换」：卡里突然出现一片彩色数字，视觉上是「闪」；
/// 0.24 秒的透明度过渡把它变成「浮现」，同时不会像移动/缩放那样把布局推来推去。
struct LoadedSwap<Content: View, Placeholder: View>: View {
    private let loaded: Bool
    private let alignment: Alignment
    private let content: () -> Content
    private let placeholder: () -> Placeholder

    init(loaded: Bool,
         alignment: Alignment = .topLeading,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.loaded = loaded
        self.alignment = alignment
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if loaded {
                content()
                    .transition(.opacity)
            } else {
                placeholder()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.24), value: loaded)
    }
}

/// 状态胶囊（已拦截 / 当前 / 偏高…）：10pt 半粗 + 12% 同色底。
struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(UI.badge())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background { Capsule().fill(color.opacity(0.12)) }
    }
}
