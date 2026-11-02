import SwiftUI
import UIKit

// MARK: - 顶部固定留白
/// 顶部固定留白用（v2.3.2 修「返回主页跳一下」）。
///
/// 三个根页的 `ScrollView` 都用 `.ignoresSafeArea(.container, edges: .top)` 顶到屏幕最上面，
/// 内容再用这个值把留白补回来。**为什么不用 `.safeAreaPadding` / `GeometryReader.safeAreaInsets`**：
/// 那些值会跟着「导航栏显隐」变——根页隐藏导航栏时只含状态栏，二级页显示导航栏时是
/// 状态栏 + 导航栏高度。返回时这个值被改一次，`UIScrollView` 就重算 `adjustedContentInset`
/// 并把 `contentOffset` 夹一下，肉眼就是「跳一下」。v2.3.0 用冻结 contentInset 的办法压住过，
/// 代价是整片界面错位（见文件头），所以这次改成「根本不让它随导航栏变」。
///
/// 窗口的 `safeAreaInsets.top` 只含状态栏那一层，不随导航栏显隐变化，才拿它当常量。
/// 值只取一次并缓存（本项目只支持竖屏 iPhone，不用管旋转/分屏）。
@MainActor
enum SafeAreaMetrics {
    /// 带灵动岛的 iPhone 状态栏高度兜底值。窗口还没就绪时先用它排版，下一次 body 会改成真值。
    private static let fallback: CGFloat = 59
    private static var cached: CGFloat?

    static var statusBarTop: CGFloat {
        if let cached { return cached }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        if let top = window?.safeAreaInsets.top, top > 0 {
            cached = top
            return top
        }
        return fallback
    }
}

/// 调滚动手感：**保留橡皮筋回弹**，但只在「内容真的比一屏长」时才允许下拉。
///
/// 历史（别踩回去）：
/// - v2.1.13 删掉 `.refreshable` 之后，用户连着两次反馈「下拉还是会跳一下」。
/// - v2.1.17 干脆把 `bounces` 关了 —— 下拉彻底不动。用户回：
///   「需要回弹效果，但是不要下拉刷新，保留现在布局」。
/// - v2.1.18 改成只关 `alwaysBounceVertical`（短内容不弹、长内容正常弹）。
/// - **v2.3.0 曾在这里「冻结内容边距」**：读 `adjustedContentInset` → 切成 `.never`
///   → 再手工写 `contentInset`，想让系统没法在回弹收尾时改边距。
///   结果整片界面坏掉：页面内容整体挪位（标题被顶到状态栏下、最后一张卡被底栏压住），
///   **而且所有触控都错位** —— 手指点的位置和实际响应的地方对不上。
///
///   为什么错位：内容是按 `contentInset` 挪过去的，但系统给「滚动边缘效果」（顶部那层
///   柔边模糊）和悬浮底栏的玻璃层算的还是**原来那份**安全区/边距。于是画面挪了、
///   遮在画面上的那两层没挪，两层在它们原来占的矩形里继续吃点击 ——
///   用户点页面顶部的刷新按钮，命中的是那条模糊带；点底栏上方的卡片，命中的是底栏。
///   **`contentInsetAdjustmentBehavior` 和 `contentInset` 这两个东西，
///   SwiftUI 的 ScrollView 不能碰。** 想要什么位置就用 SwiftUI 自己的布局去要。
///
/// 所以 v2.3.1 把冻结整段删了，只留下面两件纯开关。
/// 那一跳（53pt）v2.3.2 换了个不动边距的办法治：根页滚动视图 `.ignoresSafeArea(.container, edges: .top)`
/// 顶到屏幕最上面、留白由内容自己补 —— 顶部安全区再怎么随导航栏变，也影响不到它。见 `SafeAreaMetrics`。
///
/// 用法：挂在**滚动内容**（`ScrollView` 里那个 `VStack`）的 background 上：
///
/// ```swift
/// ScrollView { VStack { … }.background(ScrollBounceTuning()) }
/// ```
///
/// 不能挂在 `ScrollView` 自己的 `.background` 上——那样 UIView 在 UIScrollView **外面**，
/// 顺父链找不到它。为什么在 `didMoveToWindow` / `layoutSubviews` 里做、而不是 `updateUIView`：
/// SwiftUI 会复用这个 UIView，进窗口那一刻父链才稳定。
struct ScrollBounceTuning: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = BounceTuningView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? BounceTuningView)?.apply()
    }
}

private final class BounceTuningView: UIView {
    /// 上限：防止父链异常时死循环。
    private static let maxDepth = 12

    /// 找到的滚动视图，缓存下来（弱持有：真被换掉就自动失效，重新爬链）。
    /// v2.2.0 加的：`layoutSubviews` 在滚动/数据刷新时会被反复调用，
    /// 每次都从 superview 往上爬三四层纯属白烧 CPU，缓存之后每次只读两个布尔值。
    private weak var cachedScroll: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            cachedScroll = nil
            return
        }
        apply()
    }

    /// 兜底：SwiftUI 在内容尺寸变化时会重排这个 UIView，顺手再设一次，
    /// 防止系统在某次布局里把 `alwaysBounceVertical` 改回 true（`apply` 里有判断，不会重复写）。
    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    /// 只碰这两个开关。
    ///
    /// ⚠️ **绝对不要**在这里写 `contentInset` / `contentInsetAdjustmentBehavior` /
    /// `contentOffset` / `transform`。v2.3.0 试过，整片界面的点击全部错位（原因见文件头注释）。
    func apply() {
        guard let scroll = scrollView() else { return }
        // 只在确实需要时才写，避免每次布局都触发一次 setter。
        if !scroll.bounces { scroll.bounces = true }
        if scroll.alwaysBounceVertical { scroll.alwaysBounceVertical = false }
    }

    private func scrollView() -> UIScrollView? {
        if let scroll = cachedScroll { return scroll }
        var node: UIView? = superview
        var depth = 0
        while let current = node, depth < Self.maxDepth {
            if let scroll = current as? UIScrollView {
                cachedScroll = scroll
                return scroll
            }
            node = current.superview
            depth += 1
        }
        return nil
    }
}
