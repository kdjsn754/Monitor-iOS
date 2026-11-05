import SwiftUI
import UIKit

/// 裁壁纸（v2.4.1 起）。
///
/// 取景框等于**整块屏幕**（含状态栏、Home 指示条）：背景铺的时候就是整屏
/// `scaledToFill`，裁的时候框成同样比例，铺回去才不会被二次裁掉。
///
/// v2.4.3：用户连续两版反馈「完成 / 取消根本点不了」。根因不是按钮太小，
/// 是坐标系算错了——`GeometryProxy.size` 本来就已经是整屏尺寸（含状态栏），
/// `safeAreaInsets` 只是描述安全区从哪儿开始。v2.4.2 把两者相加，得到一块
/// 比真屏幕还高 90 多 pt 的假「整屏」；更要命的是 `ZStack(.topLeading)` 的
/// 原点依旧是屏幕最顶端，topBar 挂在 (0,0) 上，等于**还压在状态栏里**，
/// 那一带的触摸由系统接管，永远不会传给 App。
///
/// 这一版不再猜：
/// ① 整屏尺寸直接取 `geo.size`，最外层 `.ignoresSafeArea()`，原点就是屏幕左上角；
/// ② 安全区数值从前台 window 读，不掺进尺寸计算，只用来给按钮留边距；
/// ③ 画布（含拖拽/捏合手势）与所有装饰层都在一个 ZStack 里，装饰层一律
///    `allowsHitTesting(false)`，画布上也不再挂双击手势（它会让系统等待第二击，
///    容易吞掉附近的点按）；
/// ④ 交互按钮用 `.overlay` 挂在画布**之外**、明确 `zIndex`，并且整条挪到屏幕底部。
///    状态栏那条永远别放可点的东西。
struct BackgroundCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onUse: (UIImage) -> Void

    /// 用户当前的放大倍数（1 = 铺满，不小于 1，否则会露底）。
    @State private var scale: CGFloat = 1
    /// 手势开始前的倍数 / 偏移，拖动和捏合都在这个基准上叠加。
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    /// 视口尺寸（整屏），裁切算比例要用。
    @State private var viewport: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            let insets = Self.safeInsets
            let fill = BackgroundCropper.fillScale(image: image, viewport: screen)
            let shown = CGSize(width: image.size.width * fill * scale,
                               height: image.size.height * fill * scale)

            ZStack(alignment: .topLeading) {
                Color.black
                    .frame(width: screen.width, height: screen.height)
                    .allowsHitTesting(false)

                // 照片 + 取景框：溢出部分按整屏裁掉。手势只挂在这一层。
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(dragGesture(viewport: screen))
                    .simultaneousGesture(magnifyGesture(viewport: screen))
                    .onAppear { viewport = screen }
                    .onChange(of: screen) { _, new in
                        viewport = new
                        offset = clamped(offset, viewport: new)
                        baseOffset = offset
                    }

                // 上下压暗只做视觉：白字要有底，但绝不能参与命中测试。
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: insets.top + 96)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: insets.bottom + 150)
                }
                .frame(width: screen.width, height: screen.height)
                .allowsHitTesting(false)
            }
            .frame(width: screen.width, height: screen.height)
            .clipped()
            // 顶部只留一句不可点的提示，不再摆任何按钮。
            .overlay(alignment: .top) {
                Text("拖动调整 · 双指缩放")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, insets.top + 12)
                    .allowsHitTesting(false)
            }
            // 交互层挂在 ZStack 之外，永远在手势层上面。
            .overlay(alignment: .bottom) {
                bottomBar(insets: insets)
                    .zIndex(10)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// 从当前前台 window 读安全区，不依赖 `GeometryProxy.safeAreaInsets`：
    /// 视图一旦 `ignoresSafeArea()`，那个值的语义就开始含糊，而按钮位置不能赌。
    /// 这里读到的值只用于 padding，取不到（极端情况）也只是按钮贴底一些，仍能点。
    private static var safeInsets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        return window?.safeAreaInsets ?? .zero
    }

    private func dragGesture(viewport vp: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let raw = CGSize(width: baseOffset.width + value.translation.width,
                                 height: baseOffset.height + value.translation.height)
                offset = clamped(raw, viewport: vp)
            }
            .onEnded { _ in
                offset = clamped(offset, viewport: vp)
                baseOffset = offset
            }
    }

    private func magnifyGesture(viewport vp: CGSize) -> some Gesture {
        // 用 `MagnifyGesture`（iOS 17+）而不是老的 `MagnificationGesture`：
        // 名称和取值字段都换过一轮，新 SDK 上别赌旧的还在。
        MagnifyGesture()
            .onChanged { value in
                // 上限 4 倍：再大就是一堆马赛克，而壁纸本来就是铺满看的。
                scale = min(max(baseScale * value.magnification, 1), 4)
                offset = clamped(offset, viewport: vp)
            }
            .onEnded { _ in
                scale = min(max(scale, 1), 4)
                offset = clamped(offset, viewport: vp)
                baseScale = scale
                baseOffset = offset
            }
    }

    private func clamped(_ value: CGSize, viewport vp: CGSize) -> CGSize {
        BackgroundCropper.clamp(value, image: image, viewport: vp, scale: scale)
    }

    private func reset(viewport vp: CGSize) {
        withAnimation(.easeOut(duration: 0.22)) {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
    }

    // MARK: - 底部操作条

    /// 三个可点区域都是整块 46pt 高的圆角矩形，不是「文字墨迹」。
    /// v2.4.3 起这里取代原来的顶部 topBar：状态栏下方那条系统始终有可能接管，
    /// 挪到底部 + 独立 overlay 才是能一劳永逸的放法。
    private func bottomBar(insets: UIEdgeInsets) -> some View {
        VStack(spacing: 10) {
            Text("画面按整屏比例裁切")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                actionButton("取消", filled: false) { onCancel() }
                actionButton("还原", filled: false) { reset(viewport: viewport) }
                actionButton("完成", filled: true) { finish() }
                    .disabled(viewport.width < 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, insets.bottom + 12)
    }

    private func actionButton(_ title: String, filled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(filled ? .semibold : .regular))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(filled ? Color.blue : Color.white.opacity(0.18))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        guard let cropped = BackgroundCropper.crop(image,
                                                   viewport: viewport,
                                                   scale: scale,
                                                   offset: offset) else {
            onCancel()
            return
        }
        onUse(cropped)
    }
}
