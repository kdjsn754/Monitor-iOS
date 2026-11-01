import SwiftUI

/// Lightweight, flat surface styling. No blur/material layers, so scrolling
/// stays smooth on older iPhones.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.035, green: 0.05, blue: 0.075),
                    Color(red: 0.055, green: 0.075, blue: 0.11)
                ]
                : [
                    Color(red: 0.985, green: 0.99, blue: 1.0),
                    Color(red: 0.945, green: 0.965, blue: 0.99)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct GlassCardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.55), lineWidth: 0.5)
            }
    }
}

extension View {
    func glassCard(padding: CGFloat = 16,
                   cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

/// 卡片里的「小块底色」。
///
/// 以前这些格子一律用 `Color(.tertiarySystemFill)`——一块偏冷的灰。
/// 白卡上叠几块灰，页面看着像没做完：灰和主色蓝不是一族，格子多的时候整页发脏。
/// 现在改成「同色极浅填充 + 同色细描边」：填的是每个格子自己的主色（CPU 橙、内存靛、
/// 下载蓝、上传紫…），块面感还在，颜色也和图标、数字对上了。
/// 深色模式下提一点不透明度，否则叠在深色卡上会看不见。
struct SoftTileModifier<S: InsettableShape>: ViewModifier {
    let color: Color
    let shape: S

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(color.opacity(colorScheme == .dark ? 0.16 : 0.05))
            }
            .overlay {
                shape.strokeBorder(color.opacity(colorScheme == .dark ? 0.28 : 0.15),
                                   lineWidth: 1)
            }
    }
}

extension View {
    /// 任意形状的浅色底。
    func softTile<S: InsettableShape>(_ color: Color = .blue, in shape: S) -> some View {
        modifier(SoftTileModifier(color: color, shape: shape))
    }

    /// 圆角矩形的浅色底（最常用）。
    func softTile(_ color: Color = .blue, radius: CGFloat = 12) -> some View {
        softTile(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 白底 + `separator` 细边：`softTile` 的「无色版」，形状任意。
///
/// 为什么要有它（v1.28.27，用户：「去掉这几个的背景色改成白底」）：
/// 概览的 CPU / 内存 / 温度 / 风扇四格、代理页的配置行和访问检查四格，原来都是
/// `softTile`——5% 主色底 + 16% 主色边。单看一块还行，一屏铺开七八块之后整片发蓝，
/// 格子的边界糊在一起，反而看不出哪几块是一组。
/// 这些格子的主色**已经由圆环弧、图标、数字各表达过一遍**，底再染一层纯属重复。
/// 换成白底之后靠一圈 `separator` 划界，颜色全部让给数据。
///
/// 和 `rowTile` 是同一种观感，区别只有两点：`rowTile` 固定圆角矩形，这个能接任意
/// shape（重测按钮、「更换」是胶囊）；`rowTile` 圆角写死 14，这个由调用方给。
struct PlainTileModifier<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                // 深色下不能用 `systemBackground`——那是纯黑（#000），压在 #1C1C1E 的卡片上
                // 像挖了个洞，格子边框比文字还抢眼。`tertiarySystemBackground`（#2C2C2E）
                // 比卡片亮一档，层级才对。这个坑 rowTile 已经踩过一次了。
                shape.fill(colorScheme == .dark
                           ? Color(.tertiarySystemBackground)
                           : Color(.systemBackground))
            }
            .overlay {
                shape.strokeBorder(Color(.separator), lineWidth: 0.75)
            }
    }
}

extension View {
    /// 任意形状的白底 + 细边（胶囊按钮用这个）。
    func plainTile<S: InsettableShape>(in shape: S) -> some View {
        modifier(PlainTileModifier(shape: shape))
    }

    /// 圆角矩形的白底 + 细边（格子用这个）。
    func plainTile(radius: CGFloat = 12) -> some View {
        plainTile(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 面板 / 卡片里的「行」：和卡片同色 + 一圈细边。
///
/// 这些行以前用 `softTile(.blue)`：5% 蓝底 + 15% 蓝边。一行两行还像块面，
/// 一屏四五行叠起来整片发蓝，跟卡片的白底互相打架，行里的 IP / MAC 也被衬得发蓝，
/// 看着像「一排提示卡」而不是普通列表。
/// 现在统一回到白底黑字：填充就是 `systemBackground`（和卡片同色），
/// 只留一圈 `separator` 细边划出行界。
///
/// 深色模式不能再跟浅色一样取 `systemBackground`——那是**纯黑**（#000），
/// 而外层卡片是 `secondarySystemGroupedBackground`（#1C1C1E），黑行压在深灰卡上
/// 会像挖了一个洞，行与卡片的边界比文字还抢眼。深色用 `tertiarySystemBackground`
/// （#2C2C2E）比卡片亮一档，层级才对。
struct RowTileModifier: ViewModifier {
    var radius: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                shape.fill(colorScheme == .dark
                           ? Color(.tertiarySystemBackground)
                           : Color(.systemBackground))
            }
            .overlay {
                shape.strokeBorder(Color(.separator), lineWidth: 0.75)
            }
    }
}

extension View {
    func rowTile(radius: CGFloat = 14) -> some View {
        modifier(RowTileModifier(radius: radius))
    }
}

/// 页面大标题，直接画在内容里，不用系统的大标题。
///
/// 系统大标题占的位置很死：状态栏 59pt + 导航栏 44pt + 标题，标题顶边要到屏幕
/// 109pt 才出现，中间那几十 pt 全是空白。自己排之后标题顶边在 63pt 左右，
/// 省下将近 46pt，也不会再有导航栏那条材质和内容之间的接缝。
struct PageHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// 标题右边的小圆按钮（刷新之类），代替原来导航栏右上角的图标。
///
/// iOS 26 起用系统液态玻璃（`glassEffect`）：玻璃会自己把背后的页面渐变、卡片
/// 折进按钮里，按下还有回弹式的形变，和系统自己的玻璃按钮一致。
/// 最低版本即 iOS 26，不再为低版本做浅蓝圆钮退回。
struct HeaderButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    init(_ systemImage: String, label: String = "刷新", action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .modifier(HeaderButtonSurface())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct HeaderButtonSurface: ViewModifier {
    func body(content: Content) -> some View {
        // interactive：按下时玻璃会被按下去一点，松手弹回，不用自己写按压态。
        content.glassEffect(.regular.interactive(), in: Circle())
    }
}

/// 一条可关闭的错误提示。
///
/// 旧版把错误直接当三行红字贴在卡片底部，既占地方又不会自己消失。
/// 现在收成一条浅红底的横幅：最多两行、带叉，点掉就没了。
struct ErrorBanner: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red.opacity(0.85))
                        .frame(width: 20, height: 20)
                        .background(Color.red.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 液态玻璃按钮

/// 全 App 的按钮统一走 iOS 26 原生液态玻璃。
///
/// 为什么推翻自绘（v2.1.9，用户：「能把按钮都改成使用 ios 原生液态玻璃那种吗」）：
/// 这里原来有个叫 `GlassProminentButtonStyle` 的结构体——名字带 Glass，画出来的却是
/// **实色蓝胶囊 + 白字**，和玻璃没有半点关系。系统自带的玻璃按钮会把背后的卡片、
/// 渐变折进按钮里，按下还有形变，这是自绘做不出来的。
///
/// 只用一个样式：`.glass`。`glassProminent`（着色玻璃）试过一版，用户回「不要色块，
/// 就用原生白色透明那种」——着色玻璃在浅色页面上看仍是一块颜色。所以现在
/// **没有任何按钮带底色**，颜色只出现在文字上。
///
/// 四条硬约束（系统定的，绕了就会变形）：
/// 1. **别给 label 加 `.background` / `.padding`**：玻璃自带约 13pt 内边距，
///    形状由 `.buttonBorderShape` 决定。再叠一层底色就变成「玻璃壳里塞了块色块」。
/// 2. **别用带圈的 SF Symbol**（`plus.circle.fill` 这种）：玻璃壳本身就是容器，
///    套两层圈显得笨重。要圆就用 `.buttonBorderShape(.circle)`。
/// 3. **禁用交给 `.disabled()`**：玻璃按钮自己会变灰变淡，别再手动 `.opacity()`——
///    那会把文字一起压透（v1.28.28 踩过）。
/// 4. **别在滚动容器里堆玻璃**：Form / List 里放一两个没关系，一屏七八块会持续重算折射。
extension View {
    /// 全 App 唯一的按钮外壳：系统中性玻璃，不上色。
    ///
    /// 为什么不留着色版（v2.1.10，用户：「不要色块就用原生白色透明那种」）：
    /// 上一版用 `.glassProminent` + `.tint()` 做主按钮，画出来仍是**有色玻璃**——
    /// 在浅色页面上看就是「一块蓝」，和原来自己画的实色胶囊差别很小，等于没换成玻璃。
    /// 现在统一走 `.glass`：玻璃只做折射和高光，不携带任何底色，
    /// **主次不靠底色区分，靠字重、字号和位置**。
    /// 需要强调的颜色一律写在 label 的 `foregroundStyle` 上（红字删除、蓝字选中），
    /// 那是文字，不是色块。
    func glassButton() -> some View {
        self.buttonStyle(.glass)
    }
}

// MARK: - 面板内的浮层

/// 面板里浮一层遮罩，正中放一张卡片。点遮罩关闭，点卡片本身不关闭。
///
/// **sheet 内部不要用系统的 `alert` / `confirmationDialog`。**
/// iOS 26 会把这两个浮层锚到页面上方（看起来像贴在半空的气泡），
/// 有时候干脆不展示——表现出来就是「弹窗位置不对」和「点了没反应」。
/// 两者都是 v1.28.20 实测踩到的（设备列表的删除确认、改名输入框）。
/// 自绘这套之后位置永远落在这一屏正中，样式也能跟着 App 的卡片走。
struct SheetOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            content()
                .frame(maxWidth: 330)
                .padding(.horizontal, 28)
        }
    }
}

/// 浮层中间那张白卡片：20 内边距、22 圆角、一圈细边 + 一层柔影。
/// 末尾那个空手势是为了把卡片范围内的点击吃掉，
/// 否则会穿透到后面的遮罩上，被当成「点了外面」而误关。
struct SheetOverlayCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.systemBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {}
    }
}

/// 浮层卡片底部的等宽按钮。全部是中性玻璃，`tint` 只决定**文字颜色**
/// （删除给红、确认给蓝），不再当作底色——v2.1.10 起没有色块了。
struct SheetOverlayButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint ?? Color(uiColor: .label))
                .frame(maxWidth: .infinity)
        }
        .glassButton()
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }
}

extension View {
    /// 整行可点：点击区域跟着圆角走，四个角的空白才不会误响应。
    ///
    /// 设备入口、轮询预设、配置行、网页后台按钮四处原本各写一遍
    /// `.contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))`，
    /// 圆角数值散在四个文件里，改一处样式要翻四遍。
    func cardTapShape(radius: CGFloat = 14) -> some View {
        contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
