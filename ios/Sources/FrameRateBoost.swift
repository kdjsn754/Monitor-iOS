import SwiftUI
import UIKit

/// 滚动期间把整屏刷新率顶到 120（v3.3.7）。
///
/// 背景：用户 2026-11-24「缓慢滑动只有 80，快速滑动有 120，我需要滑动就是 120」。
///
/// 80Hz 是 **iPhone 独有**的档位（iPad Pro 的五档里没有它），也是 Core Animation
/// 在慢速滚动时的省电选择：每帧 12.5ms，视觉上够顺，功耗还低。Apple 文档写得很死——
/// 「the system insulates the ProMotion display's actual refresh rate from your app —
/// you can't force a ProMotion display to show your content at any specific rate」，
/// 所以 App 侧只能给 hint，不能强制。
///
/// 这里给的是能给的最强 hint：滚动期间挂一个 `(120, 120, 120)` 的 `CADisplayLink`。
/// 屏幕刷新率是全局的——只要有一个 display link 在按 120 要回调，同一节拍上的
/// UIScrollView 滚动也就是 120。停止滚动后 0.2 秒内释放，不留常驻开销。
final class ScrollBoostCenter: NSObject {
    static let shared = ScrollBoostCenter()

    /// 弱引用表：页面重建时旧的滚动视图自动出表，不用手工清理。
    private let tracked = NSHashTable<UIScrollView>.weakObjects()

    /// 滚动期间占位用的 display link。它**不画任何东西**（`tick` 是空实现），
    /// 存在的意义只是让 Core Animation 手上有一个「每 8.33ms 必须回调一次」的需求。
    private var link: CADisplayLink?

    /// 「等滚动停下来」的轮询是否已经在跑。
    ///
    /// ⚠️ 必须拦：`panChanged` 在 `.changed` 里每帧都会调 `beginIfNeeded()`，
    /// 不拦一下就会在手指移动的每一帧都新起一条 `asyncAfter` 链，
    /// 慢滑一秒能堆出上百条同时在跑，白白烧 CPU。
    private var polling = false

    /// 幂等登记一个滚动视图。
    func adopt(_ scroll: UIScrollView) {
        guard !tracked.contains(scroll) else { return }
        tracked.add(scroll)
        // 只加观察者，**绝对不碰 delegate**：UIScrollView 的 delegate 是 SwiftUI 自己在用
        // （滚动、回弹、键盘避让、`scrollTo` 定位全靠它），抢过来整片界面都会坏。
        // `addTarget` 是纯追加，不动识别逻辑、也不吞事件。
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
    }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        beginIfNeeded()
    }

    private func beginIfNeeded() {
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            // ⚠️ 三个值必须都是 120，**不要**照抄 Apple 给「高冲击动画」的 (80, 120, 120)。
            //
            // `minimum` 不是「保底」而是「我接受的最低帧率」：写 80 就等于告诉系统
            // 「80 也行」，它省电时就挑 80 —— 那正是用户反馈的「缓慢滑动只有 80」。
            // 要它别低于 120，下限也得写 120。系统真给不了（过热 / 低电量）时
            // 会自己选最接近的档，不会把回调饿死；停止滚动由 `poll` 负责，
            // 不依赖这个 link 有没有回调。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120,
                                                            maximum: 120,
                                                            preferred: 120)
            // 必须 `.common`：`.default` 在手势跟踪期间会被 RunLoop 暂停，
            // 而慢速滚动正是「手指一直按着、慢慢往下摸」的场景。
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        guard !polling else { return }
        polling = true
        poll()
    }

    /// 空实现：这个 display link 只负责占位提频，不渲染。
    @objc private func tick() {}

    /// 用主队列轮询判断滚动结束，而不是在 `tick` 里判断。
    ///
    /// 原因：万一系统一帧回调都不给（极端省电状态），`tick` 不跑就永远停不下来，
    /// 屏幕会被一直顶在 120 白耗电。主队列延迟和 display link 无关，一定跑得到。
    private func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard self.link != nil else {
                self.polling = false
                return
            }
            let active = self.tracked.allObjects.contains {
                $0.isDragging || $0.isDecelerating
            }
            if active {
                self.poll()
            } else {
                self.stop()
            }
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        polling = false
    }
}

/// 挂在根视图的 `.background` 上：定时扫描窗口，把滚动视图登记给 `ScrollBoostCenter`。
///
/// 为什么用扫描而不是逐页挂：SwiftUI 没有「滚动开始」的通知，而项目里
/// `ScrollView` / `Form` / `List` 一共 24 处（4 个根页 + 一堆二级页），
/// 逐个挂必然漏，漏一个用户就会觉得「有的页面还是 80」。
/// 扫窗口视图树一次覆盖全部，以后新增页面也不用改任何东西。
struct FrameRateBoostProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = ProbeView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class ProbeView: UIView {
    private var timer: Timer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard let window = window else { return }
        walk(window)
        // 0.25 秒：切页本身有 0.25s 动画，手指真正开始拖之前必然已经扫过一轮，
        // 不会出现「刚切过来那一下没有 boost」。再短只是白烧 CPU。
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.walk(window)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 不写 deinit 去 invalidate：`UIView` 的 deinit 是 nonisolated，在 Swift 5.9 下
    /// 摸 MainActor 隔离的 `timer` 会有隔离警告。而视图被移除时 `didMoveToWindow`
    /// 一定会带着 `window == nil` 先跑一遍，上面第一行就把 timer 停掉了，够用。

    /// 递归登记视图树里的 UIScrollView。视图树深度通常几十层，
    /// 0.25 秒扫一遍（几千次类型判断）的开销可以忽略。
    private func walk(_ view: UIView, depth: Int = 0) {
        guard depth < 64 else { return }
        if let scroll = view as? UIScrollView {
            ScrollBoostCenter.shared.adopt(scroll)
        }
        for sub in view.subviews {
            walk(sub, depth: depth + 1)
        }
    }
}
