import SwiftUI
import UIKit

/// 调滚动手感：**保留橡皮筋回弹**，但只在「内容真的比一屏长」时才允许下拉。
///
/// 历史（别踩回去）：
/// - v2.1.13 删掉 `.refreshable` 之后，用户连着两次反馈「下拉还是会跳一下」。
///   追问后他描述得很清楚：「不是慢慢回弹，而是一下弹回去」。
/// - v2.1.17 干脆把 `bounces` 关了 —— 下拉彻底不动。用户 2026-11-02 回：
///   「需要回弹效果，但是不要下拉刷新，保留现在布局」。
///   也就是他要的是**正常的橡皮筋**，不是「拉不动」。
///
/// 「一下弹回去」的真正原因：iOS 17 起 SwiftUI 把 ScrollView 的 `alwaysBounceVertical`
/// 设成了 true，内容**不到一屏**也能拉出一片空白；这种空白背后没有可滚动范围，
/// 松手时系统只是把 contentOffset 直接 clamp 回去，没有减速过程 —— 观感就是「一下」。
/// 内容超过一屏的页面本来就有真实滚动范围，回落是正常的弹簧动画。
///
/// 所以这里只改一项：`alwaysBounceVertical = false`（等价于 SwiftUI 的
/// `.scrollBounceBehavior(.basedOnSize)`），`bounces` 保持 true。
/// 短页面拉不动，长页面正常回弹，两条都不碰刷新。布局、padding、安全区一概不动。
///
/// 用法：挂在**滚动内容**（ScrollView 里那个 VStack）的 background 上：
///
/// ```swift
/// ScrollView { VStack { … }.background(ScrollBounceTuning()) }
/// ```
///
/// 不能挂在 `ScrollView` 自己的 `.background` 上——那样 UIView 在 UIScrollView **外面**，
/// 顺父链找不到它。挂在内容上就一定在 UIScrollView 内部，父链第一层容器就是它。
/// 为什么在 `didMoveToWindow` 里做、而不是 `updateUIView`：SwiftUI 会复用这个 UIView，
/// 进窗口那一刻父链才稳定。找不到就静默放弃，不影响页面。
///
/// 页面侧同时写了 `.scrollBounceBehavior(.basedOnSize)`，跟这里设的是同一件事：
/// 声明式那句是给读代码的人看的，这个 UIView 是兜底（防止 SwiftUI 某次布局把它改回去）。
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

    func apply() {
        if let scroll = cachedScroll {
            tune(scroll)
            return
        }
        var node: UIView? = superview
        var depth = 0
        while let current = node, depth < Self.maxDepth {
            if let scroll = current as? UIScrollView {
                cachedScroll = scroll
                tune(scroll)
                return
            }
            node = current.superview
            depth += 1
        }
    }

    private func tune(_ scroll: UIScrollView) {
        // 只在确实需要时才写，避免每次布局都触发一次 setter。
        if !scroll.bounces { scroll.bounces = true }
        if scroll.alwaysBounceVertical { scroll.alwaysBounceVertical = false }
    }
}
