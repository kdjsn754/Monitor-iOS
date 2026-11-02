import SwiftUI
import UIKit

/// 关掉滚动视图的橡皮筋回弹。
///
/// 为什么需要（v2.1.17）：概览页、代理页把整条导航栏藏了（标题自己画），
/// 下拉时内容会跟着手指往下走、松手再弹回去。用户连着两次反馈「下拉还是跳动」，
/// 确认后他的意思就是这段回弹本身——他要的是「下拉别动」。
///
/// 系统没有「只关顶部、保留底部」的公开 API（`bounces` 是整条开关），
/// 所以这里整条关掉：顶部下拉不位移，底部也不会弹。滚动本身不受影响。
///
/// 用法：挂在**滚动内容**（ScrollView 里那个 VStack）的 background 上：
///
/// ```swift
/// ScrollView { VStack { … }.background(ScrollBounceOff()) }
/// ```
///
/// 不能挂在 `ScrollView` 自己的 `.background` 上——那样 UIView 在 UIScrollView **外面**，
/// 顺父链找不到它。挂在内容上就一定在 UIScrollView 内部，父链第一层容器就是它。
/// 为什么在 `didMoveToWindow` 里做、而不是 `updateUIView`：SwiftUI 会复用这个 UIView，
/// 进窗口那一刻父链才稳定。找不到就静默放弃，不影响页面。
struct ScrollBounceOff: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = BounceOffView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? BounceOffView)?.apply()
    }
}

private final class BounceOffView: UIView {
    /// 上限：防止父链异常时死循环。
    private static let maxDepth = 12

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        apply()
    }

    /// 兜底：SwiftUI 在内容尺寸变化时会重排这个 UIView，顺手再设一次，
    /// 防止系统在某次布局里把 `bounces` 改回 true（改一次就够，`apply` 里有判断）。
    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    func apply() {
        var node: UIView? = superview
        var depth = 0
        while let current = node, depth < Self.maxDepth {
            if let scroll = current as? UIScrollView {
                // 只在确实需要时才写，避免每次布局都触发一次 setter。
                if scroll.bounces {
                    scroll.bounces = false
                    scroll.alwaysBounceVertical = false
                }
                return
            }
            node = current.superview
            depth += 1
        }
    }
}
