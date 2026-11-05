import SwiftUI
import UIKit

/// 裁壁纸（v2.4.1）。
///
/// 为什么让视口等于**整块屏幕**（含状态栏、底栏、Home 指示条下面的部分）：
/// 背景铺的时候就是整屏 `scaledToFill`，裁的时候框成同样的比例，裁出来
/// 铺回去才不会被二次裁掉，拖动时看到的就是最终效果。
/// 按钮浮在图上，底下压一层渐变——不然深色壁纸配白字、浅色壁纸配白字都难看。
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
        ZStack {
            Color.black.ignoresSafeArea()
            canvas
            controls
        }
        .background(Color.black)
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            let vp = geo.size
            let fill = BackgroundCropper.fillScale(image: image, viewport: vp)
            let shown = CGSize(width: image.size.width * fill * scale,
                               height: image.size.height * fill * scale)

            Image(uiImage: image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .offset(offset)
                // 外面再套一层视口大小，把溢出部分居中裁掉——这一层就是「取景框」。
                .frame(width: vp.width, height: vp.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(viewport: vp))
                .simultaneousGesture(magnifyGesture(viewport: vp))
                .onTapGesture(count: 2) { reset(viewport: vp) }
                .onAppear { viewport = vp }
                .onChange(of: vp) { _, new in
                    viewport = new
                    offset = clamped(offset, viewport: new)
                    baseOffset = offset
                }
        }
        .ignoresSafeArea()
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

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onCancel() }
                    .font(.body)
                    .foregroundStyle(.white)

                Spacer()

                Text("拖动调整 · 双指缩放")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))

                Spacer()

                Button("完成") { finish() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .disabled(viewport.width < 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)

            Text("画面按整屏比例裁切，双击可以还原")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 10)
        }
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
