import SwiftUI
import UIKit

/// 调滚动手感：**保留橡皮筋回弹**，但只在「内容真的比一屏长」时才允许下拉；
/// 同时把滚动视图的四条内容边距**冻结**住，不让系统在回弹收尾那一下改写它们。
///
/// 历史（别踩回去）：
/// - v2.1.13 删掉 `.refreshable` 之后，用户连着两次反馈「下拉还是会跳一下」。
/// - v2.1.17 干脆把 `bounces` 关了 —— 下拉彻底不动。用户回：
///   「需要回弹效果，但是不要下拉刷新，保留现在布局」。
/// - v2.1.18 改成只关 `alwaysBounceVertical`（短内容不弹、长内容正常弹）。
///   长页的回弹是对的，但**收尾那一下仍然是硬跳**，用户 2026-11-02 又提了一次。
///
/// 那一版之后把用户的录屏按 30fps 逐帧量了位移（402×874 的渲染帧，1px = 1pt）：
///
/// ```
/// t=1.00  内容下移 35pt     ← 手指往下拉
/// t=1.13  120pt             ← 拉到橡皮筋上限
/// t=1.40  118 → 93 → 76 → 67 → 60 → 56 → 54 → 53   ← 松手，正常回弹（有减速过程）
/// t=1.87  53 → 53 → 53 → 53                        ← 停在半路不动
/// t=2.00  0                                        ← **一帧之内**归位，没有过渡
/// ```
///
/// 关键点：停下来之后是**整屏像素完全一致**的静帧，然后下一帧直接到终点。
/// 有减速的弹簧不会这样收尾，只有一种解释：`contentInset` 在这中间被改过一次，
/// 系统为了维持「可见区域」把 `contentOffset` 平移了同样的量（= 那 53pt）。
/// 逐帧对比还确认了两件事：状态栏一像素没动、底栏也没动，所以不是导航栏/底栏的出现动画；
/// 内容本身也没变（把前后两帧对齐后差异只有抗锯齿级别），所以也不是数据刷新导致的重排。
///
/// 所以这里做两件事：
/// 1. `alwaysBounceVertical = false`（等价于 `.scrollBounceBehavior(.basedOnSize)`），
///    内容不足一屏时不给拉出空白——那种空白背后没有可滚动范围，松手只能硬 clamp。
/// 2. **冻结内容边距**：把系统当时实际生效的 `adjustedContentInset`（顶 = 状态栏/导航栏，
///    底 = 悬浮底栏）抄进 `contentInset`，然后 `contentInsetAdjustmentBehavior = .never`，
///    让系统再也不能自己改这两个值。抄的是「实际生效总量」，所以画面位置一像素不变。
///
/// 用法：挂在**滚动内容**（`ScrollView` 里那个 `VStack`）的 background 上：
///
/// ```swift
/// ScrollView { VStack { … }.background(ScrollBounceTuning()) }
/// ```
///
/// 不能挂在 `ScrollView` 自己的 `.background` 上——那样 UIView 在 UIScrollView **外面**，
/// 顺父链找不到它。为什么在 `didMoveToWindow` / `layoutSubviews` 里做、而不是 `updateUIView`：
/// SwiftUI 会复用这个 UIView，进窗口那一刻父链和边距才稳定。
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

    /// 边距只冻结一次；冻结之后每次 `apply` 只做两件轻活（读两个布尔）。
    private var insetsFrozen = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            cachedScroll = nil
            insetsFrozen = false
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

    func apply() {
        guard let scroll = scrollView() else { return }
        // 只在确实需要时才写，避免每次布局都触发一次 setter。
        if !scroll.bounces { scroll.bounces = true }
        if scroll.alwaysBounceVertical { scroll.alwaysBounceVertical = false }
        freezeInsets(scroll)
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

    /// 把系统当时生效的内容边距抄进 `contentInset` 并锁死。
    ///
    /// 顺序很重要：**先**读 `adjustedContentInset`（= contentInset + 安全区，这是屏幕上
    /// 真正生效的量），**再**把 `contentInsetAdjustmentBehavior` 切成 `.never`，
    /// **最后**才写 `contentInset`。切到 `.never` 之后 adjusted 就等于 contentInset 本身，
    /// 所以写进去的是同一个数，画面不会挪位。
    ///
    /// 如果 SwiftUI 本来就把边距写在 `contentInset` 里（非零），那就不动数值，只切 `.never`，
    /// 以免 62pt 的安全区被算两遍（那是这版唯一可能翻车的地方，实机先看标题有没有下移一截）。
    private func freezeInsets(_ scroll: UIScrollView) {
        guard !insetsFrozen else { return }
        let adjusted = scroll.adjustedContentInset
        // 还没进窗口时读到的全是 0，等下一次 layoutSubviews 再冻。
        guard adjusted.top > 0 || adjusted.bottom > 0 else { return }

        scroll.contentInsetAdjustmentBehavior = .never

        if scroll.contentInset.top < 1, adjusted.top > 0 {
            scroll.contentInset.top = adjusted.top
        }
        if scroll.contentInset.bottom < 1, adjusted.bottom > 0 {
            scroll.contentInset.bottom = adjusted.bottom
        }
        insetsFrozen = true
    }
}
