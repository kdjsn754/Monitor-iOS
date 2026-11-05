import SwiftUI
import UIKit

/// Lightweight, flat surface styling. No blur/material layers, so scrolling
/// stays smooth on older iPhones.
///
/// v2.4.0：底下多垫一层「自定义背景图」（设置页选的，见 `BackgroundImageStore`）。
/// 渐变始终在：图没选、透明度拉到 0、或者图片还没读上来的时候，它就是兜底，
/// 界面不会出现「一片透明露出黑底」的中间态。
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// v2.4.4：刷新信号改走 `@AppStorage`，不再只赌 `@Observable` 的追踪。
    /// `on` / `opacity` 由 UserDefaults 直接驱动，`version` 专门通知「换了一张新图」；
    /// 图片本身仍从 `BackgroundImageStore.shared` 的内存对象取，磁盘只管重启恢复。
    @AppStorage(BackgroundImageStore.onKey) private var onFlag = false
    @AppStorage(BackgroundImageStore.opacityKey) private var opacityFlag = 0.6
    @AppStorage(BackgroundImageStore.versionKey) private var version = 0
    @State private var shownImage: UIImage?

    var body: some View {
        ZStack {
            gradient
            if onFlag, let shownImage, opacityFlag > 0.01 {
                // 明确量尺寸，不用 `Color.clear.overlay`——完全透明的底视图拿到多大
                // 尺寸全看父容器心情，之前「一层都没画出来」也有它的份。
                GeometryReader { proxy in
                    Image(uiImage: shownImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
                // 图上压一层极淡的主题色：挑到深色壁纸时黑字不至于糊进图里。
                .overlay(colorScheme == .dark
                         ? Color.black.opacity(0.22)
                         : Color.white.opacity(0.10))
                // 这个值是「图片的不透明度」：0 = 等于没设背景，1 = 原图。
                .opacity(opacityFlag)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // 背景永远只是背景，整层都不参与命中测试。
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: onFlag)
        // `task(id:)` 管首次挂载与重启恢复，`onChange` 管换图当下这一拍。
        .task(id: version) { reload() }
        .onChange(of: version) { _, _ in reload() }
        .onChange(of: onFlag) { _, _ in reload() }
    }

    private func reload() {
        shownImage = onFlag ? BackgroundImageStore.shared.image : nil
    }

    private var gradient: some View {
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
    }
}

struct GlassCardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    // v2.4.4：和 `AppBackground` 一样改走 `@AppStorage`，不然背景图变了卡片
    // 却还是全实心，壁纸只能在页边距那条 16pt 的缝里露出来，看着就像没设。
    @AppStorage(BackgroundImageStore.onKey) private var onFlag = false
    @AppStorage(BackgroundImageStore.opacityKey) private var opacityFlag = 0.6

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color(.secondarySystemGroupedBackground).opacity(cardOpacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.55), lineWidth: 0.5)
            }
    }

    /// 卡片的实心程度：背景图越实，卡片越透，但**保底 0.55**——
    /// 再透下去，正文压在花里胡哨的图上就开始看不清了。
    /// v2.4.4 从「保底 0.62 / 系数 0.35」调透一档：默认图 60% 时约 0.70，
    /// 拉满 100% 时 0.55，卡片之间能明显看出壁纸，不再像只换了条边。
    private var cardOpacity: Double {
        guard onFlag, opacityFlag > 0.01 else { return 1 }
        return max(0.55, 1 - opacityFlag * 0.5)
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
/// **v2.3.3 起三个根页都不再用它**（标题搬进了导航栏，见 `pageChrome`），
/// 但版式数值留在这儿：30pt 粗体 + `tracking(-0.4)`，`pageChrome` 里那枚标题就是照它写的。
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

// MARK: - 页头搬进导航栏（v2.3.3）

/// 三个根页（概览 / 代理 / 设置）原来把 30pt 大标题画在滚动内容里，同时用
/// `.toolbar(.hidden, for: .navigationBar)` 把整条导航栏藏掉。
///
/// **v2.3.3 起改成「导航栏一直在，标题和右上角按钮挂在栏里」**：视觉几乎不动
/// （同一枚 30pt 粗体、同一颗 `HeaderButton`、卡片起始位置照旧——原来标题在内容里占的
/// 那 40pt，正好被 44pt 导航栏接住），但把「返回主页跳一下 / 下拉跳一下」的病根拔掉了。
///
/// 病根是什么：根页藏栏时顶部安全区 = 状态栏（59pt），二级页显栏时 = 59 + 44（103pt）。
/// push/pop 之间这个值被改一次，`UIScrollView` 就重算 `adjustedContentInset` 并把
/// `contentOffset` 夹一下 —— 一帧位移、没有过渡，看着就是「跳」。
/// 前两版的下场记在这儿，别再走：
/// - v2.3.0 冻结 `contentInset`：跳压住了，但整片界面触控错位（覆盖层没跟着挪）。
/// - v2.3.2 给滚动视图加 `.ignoresSafeArea(.container, edges: .top)`：标题被 iOS 26 的
///   顶部柔边糊掉，而且 SwiftUI 底层照样按安全区调 inset，跳还在。
/// 现在导航栏**永远在**：根页和二级页的顶部安全区一样大，push/pop 没有可变的量。
extension View {
    /// 只有标题、没有右上角按钮的版本（设置页 v2.3.14 起去掉了刷新钮：
    /// 那页没有需要手动催的数据，按钮白占一个位置）。
    func pageChrome(_ title: String) -> some View {
        pageChrome(title) { EmptyView() }
    }

    /// 把页头标题 + 右侧按钮挂到系统导航栏上（三个根页统一用它）。
    func pageChrome<Trailing: View>(_ title: String,
                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        self
            // 这串标题只用于给二级页的返回按钮取文案（左上角显示「‹ 概览」）。
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                // 唯一一枚标题：30pt 左对齐，和原来 `PageHeader` 里那枚完全一致。
                //
                // ⚠️ `.sharedBackgroundVisibility(.hidden)` 一句都不能少（iOS 26）：
                // 系统默认会给导航栏里的每一项**自动套一层玻璃胶囊**（同一组还共用一层）。
                // v2.3.3 第一次上机就是这个下场：30pt 的「概览」被包成一颗药丸、刷新圆钮
                // 外面又套一圈，用户原话「这标题和刷新太丑了」。隐藏掉之后才是裸文字 / 裸圆钮，
                // 和原来画在内容里的页头一模一样。见 7.1.2。
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)

                // 1×1 透明片顶在 .principal 上，把系统那枚 17pt 居中标题压掉，
                // 否则会并排出现两个「概览」（v2.1.14 被否的原因之一就是那枚变小又居中的标题）。
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .topBarTrailing) {
                    trailing()
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}

/// 标题右边的小圆按钮（刷新之类），代替原来导航栏右上角的图标。
///
/// **v2.2.0 去掉了 `glassEffect`**：这块按钮在滚动内容里，滚动时它背后的画面
/// 每帧都在变，玻璃就得每帧重新采样 + 模糊一次，是缓慢滑动掉帧的直接来源之一。
/// 现在改成白底圆钮 + separator 细边，和卡片、行格子同一套语言（`plainTile` 风格），
/// 静态图层，滚动时零成本。按下的形变也没了，但 38pt 的小按钮本来就不靠它。
/// 要找回玻璃版：`git` 里 v2.1.19 的 `HeaderButtonSurface` 就是。
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
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                Circle().fill(colorScheme == .dark
                              ? Color(.tertiarySystemBackground)
                              : Color(.systemBackground))
            }
            .overlay {
                Circle().strokeBorder(Color(.separator), lineWidth: 0.75)
            }
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

struct GlassProminentButtonStyle: ButtonStyle {
    /// 用不了的时候（比如「没有待应用的改动」）换成灰底灰字。
    ///
    /// 别用 `.opacity(0.45)` 代替：那会把白字也一起压成半透明，白字压在半透明蓝底上
    /// 对比度只剩 1.x:1，按钮上根本读不出字来（v1.28.28 出预览图时才发现的）。
    /// 灰底 + 次要色文字是系统里「不可用主按钮」的样子，一眼就知道是灰的、也能读清。
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(dimmed ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.white))
            .background(dimmed ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(Color.blue),
                        in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
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

/// 浮层卡片底部的等宽按钮。`tint` 为空是次要按钮（浅灰底黑字），
/// 传了颜色就是主按钮（实色底白字），删除用 `.red`。
struct SheetOverlayButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint == nil ? Color(uiColor: .label) : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    tint ?? Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
