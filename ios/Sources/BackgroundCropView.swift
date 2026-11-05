import SwiftUI
import UIKit

/// 裁壁纸（v2.4.1 起）。
///
/// 为什么让视口等于**整块屏幕**（含状态栏、底栏、Home 指示条下面的部分）：
/// 背景铺的时候就是整屏 `scaledToFill`，裁的时候框成同样的比例，裁出来
/// 铺回去才不会被二次裁掉，拖动时看到的就是最终效果。
/// 按钮浮在图上，顶上压一层渐变——不然浅色壁纸配白字根本看不见。
///
/// v2.4.2：整屏与安全区拆成两套坐标算，按钮回到状态栏下面（v2.4.1 压在状态栏里点不动）。
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
        // 这一页要同时满足两件互相打架的事：
        // ① 取景框必须**整屏**（含状态栏、Home 条那两条），否则裁出来的比例和背景
        //    铺上去的比例对不上，会再被切一次；
        // ② 「取消 / 完成」必须落在安全区里。
        //
        // v2.4.1 用 ZStack + `.ignoresSafeArea()` 同时干这两件事，结果画布把 ZStack
        // 撑成整屏，按钮跟着排到屏幕最顶上——正好压在状态栏里。**状态栏那块由系统接管，
        // 点击传不进来**，所以用户看到的就是「按钮在状态栏上，点不了」（v2.4.2 实测）。
        //
        // 现在改成显式算：外层 GeometryReader **不**忽略安全区，量出真实的
        // `safeAreaInsets`；整屏尺寸 = 安全区尺寸 + 上下内边距，自己拼出来。
        // 只有整屏那几层（黑底 / 照片 / 渐变）往上顶 insets.top；按钮留在
        // GeometryReader 的框里，天然就在状态栏下面。
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width,
                                height: geo.size.height + insets.top + insets.bottom)
            let fill = BackgroundCropper.fillScale(image: image, viewport: screen)
            let shown = CGSize(width: image.size.width * fill * scale,
                               height: image.size.height * fill * scale)

            ZStack(alignment: .topLeading) {
                Color.black
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: -insets.leading, y: -insets.top)

                // 照片 + 取景框：溢出部分按整屏裁掉。
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(dragGesture(viewport: screen))
                    .simultaneousGesture(magnifyGesture(viewport: screen))
                    .onTapGesture(count: 2) { reset(viewport: screen) }
                    .onAppear { viewport = screen }
                    .onChange(of: screen) { _, new in
                        viewport = new
                        offset = clamped(offset, viewport: new)
                        baseOffset = offset
                    }
                    .offset(x: -insets.leading, y: -insets.top)

                // 顶部压一层黑，白字才有底。单独一层、只铺到状态栏下面 96pt，
                // 不跟着按钮走——按钮的高度会随字体变，不该由它决定渐变多高。
                LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: screen.width, height: insets.top + 96)
                    .offset(x: -insets.leading, y: -insets.top)
                    .allowsHitTesting(false)

                topBar
                    .frame(width: geo.size.width)

                bottomHint
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
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

    // MARK: - 浮在上面的按钮

    /// 顶栏：取消 / 提示 / 完成。
    ///
    /// 两件事必须一起做，否则按钮「看得见点不着」：
    /// ① 留在 GeometryReader 的框里（= 安全区内），别跟着整屏那几层一起顶上去，
    ///    详见 `body` 的注释；
    /// ② `.contentShape` 把可点区域从「文字墨迹」扩到整块按钮区——
    ///    只给 Text 上色时，可点范围只有那几个字，「取消」左边那一截空白是点不动的。
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                onCancel()
            } label: {
                Text("取消")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("拖动调整 · 双指缩放")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .allowsHitTesting(false)

            Spacer(minLength: 0)

            Button {
                finish()
            } label: {
                Text("完成")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewport.width < 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var bottomHint: some View {
        Text("画面按整屏比例裁切，双击可以还原")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .allowsHitTesting(false)
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
