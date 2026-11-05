import SwiftUI
import UIKit

/// 自定义背景的「唯一真相」（v2.4.1 重写）。
///
/// v2.4.0 是「图落盘 + `UserDefaults` 版本号当信号 + 各视图拿 `.task(id:)` 去读盘」：
/// 挑图 → 写盘 → 版本号 +1 → `@AppStorage` 通知 → 视图重跑 task → 读盘 → 赋值。
/// 这是一串隐式接力，任何一环没接上都**安静地什么都不发生**，而用户看到的就是
/// 「换了壁纸没反应」。实测也确实是这个结果。
///
/// 现在改成：图就存在这个对象里，`@Observable` 直接驱动界面。裁完赋值那一刻，
/// `AppBackground` 和设置页缩略图同时变，不经过「再读一遍磁盘」。磁盘只负责
/// 「下次启动还在」，不参与刷新。
@Observable
final class BackgroundImageStore {
    static let shared = BackgroundImageStore()

    /// 已裁切、正好是整屏比例的那张——背景真正铺的就是它、也只有它。
    /// 因为已经按屏幕比例裁好，铺的时候不会再被二次裁掉，所见即所得。
    var image: UIImage?
    /// 裁切前的原图。留着是为了「调整」：重开 App 也能把原图读回来重新框。
    var original: UIImage?

    var isOn = false

    /// 图片自身的不透明度：0 = 等于没设背景，1 = 原图。
    /// 默认 0.6（v2.4.1 从 0.35 提上来）：0.35 再压一层浅色蒙版，
    /// 浅色壁纸叠在本来的近白渐变上几乎看不出来，正是「换了没生效」的观感来源。
    var opacity: Double = 0.6

    private let defaults = UserDefaults.standard

    /// v2.4.4：这三个键同时是 `@AppStorage` 的刷新信号，所以不能藏在 private enum 里。
    /// `on` / `opacity` 由视图直接读；`version` 每换一次图 +1，专门用来通知
    /// 「同一张开关状态换了一张新图」——只盯 `on` 是看不出换图的。
    static let onKey = "customBackgroundOn"
    static let opacityKey = "customBackgroundOpacity"
    static let versionKey = "customBackgroundVersion"

    /// 沿用 v2.4.0 的文件名，老用户的背景图升级后照样在。
    private static var croppedURL: URL { fileURL("app-background.jpg") }
    private static var originalURL: URL { fileURL("app-background-original.jpg") }

    init() {
        isOn = defaults.bool(forKey: BackgroundImageStore.onKey)
        if let saved = defaults.object(forKey: BackgroundImageStore.opacityKey) as? Double {
            opacity = min(max(saved, 0), 1)
        }
        image = Self.read(Self.croppedURL)
        original = Self.read(Self.originalURL) ?? image
        // 文件没了（清缓存、迁移失败）就别显示「已设置」——卡片跟着空出来。
        if image == nil { isOn = false }
    }

    // MARK: - 改

    /// 裁完调用。`original` 传进来的是裁切前的原图，一起落盘供下次「调整」。
    func apply(cropped: UIImage, original source: UIImage?) {
        let ready = BackgroundCropper.downscale(cropped, maxSide: 2400)
        Self.write(ready, to: Self.croppedURL)
        image = ready

        if let source {
            let kept = BackgroundCropper.downscale(BackgroundCropper.upright(source),
                                                   maxSide: 3000)
            Self.write(kept, to: Self.originalURL)
            original = kept
        } else if original == nil {
            original = ready
        }

        isOn = true
        defaults.set(true, forKey: BackgroundImageStore.onKey)
        // 从没设过背景的人第一次选图，直接给一个「看得出有变化」的默认值。
        if opacity < 0.35 { opacity = 0.6; defaults.set(opacity, forKey: BackgroundImageStore.opacityKey) }
        // 内存里的图已经换好，再发信号让各页的 `@AppStorage(versionKey)` 重画。
        bumpVersion()
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.croppedURL)
        try? FileManager.default.removeItem(at: Self.originalURL)
        image = nil
        original = nil
        isOn = false
        defaults.set(false, forKey: BackgroundImageStore.onKey)
        bumpVersion()
    }

    /// 滑块每动一帧都写一次：UserDefaults 是 `@AppStorage` 的刷新信号，
    /// 只改内存的话背景要等松手才动，用户会以为「拖了没反应」。
    /// `UserDefaults.set` 有内存缓存，不是每帧同步刷盘，这点开销可以接受。
    func setOpacity(_ value: Double) {
        opacity = min(max(value, 0), 1)
        defaults.set(opacity, forKey: BackgroundImageStore.opacityKey)
    }

    /// 换图 / 删图都 +1。只盯 `on` 的话，「同一状态换一张图」是看不出来的。
    private func bumpVersion() {
        let next = defaults.integer(forKey: BackgroundImageStore.versionKey) + 1
        defaults.set(next, forKey: BackgroundImageStore.versionKey)
    }

    // MARK: - 盘

    private static func fileURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        return dir.appendingPathComponent(name)
    }

    private static func read(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 写临时文件再换名：中途被杀掉也不会留下一张写了一半的图。
    private static func write(_ image: UIImage, to url: URL) {
        guard let data = image.jpegData(compressionQuality: 0.86) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(url.lastPathComponent + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            // 换名失败就直写，别让用户裁完了什么都没发生。
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 缩图与裁切。纯几何，不碰状态，方便单独对。
enum BackgroundCropper {
    /// 把 `UIImage` 的方向烘进像素里。
    ///
    /// 相册里带 EXIF 旋转的照片，`cgImage` 是原始朝向，直接拿它算裁切框会歪 90°。
    /// 先重绘一遍，之后所有坐标系都当正常的上下左右来算。
    static func upright(_ image: UIImage, maxSide: CGFloat = 4096) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let longest = max(size.width, size.height)
        let ratio = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * ratio).rounded(),
                            height: (size.height * ratio).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 等比缩到长边不超过 `maxSide`。已经够小就原样返回，不做无谓的重绘。
    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }

        let ratio = maxSide / longest
        let target = CGSize(width: (size.width * ratio).rounded(),
                            height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        // 目标尺寸已经按像素算过，别再让渲染器乘一遍屏幕倍率（3x 会变成 7200）。
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 屏幕比例下「铺满」所需的基准缩放：短边对齐，多出来的部分溢出到框外。
    static func fillScale(image: UIImage, viewport: CGSize) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        return max(viewport.width / image.size.width,
                   viewport.height / image.size.height)
    }

    /// 把偏移夹在「图片始终盖满视口」的范围内。
    static func clamp(_ offset: CGSize,
                      image: UIImage,
                      viewport: CGSize,
                      scale: CGFloat) -> CGSize {
        let s = fillScale(image: image, viewport: viewport) * scale
        let drawnW = image.size.width * s
        let drawnH = image.size.height * s
        let maxX = max(0, (drawnW - viewport.width) / 2)
        let maxY = max(0, (drawnH - viewport.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    /// 按视口看到的画面裁一张图出来。
    ///
    /// `scale` 是用户双指放大的倍数（相对铺满），`offset` 是拖动量（点）。
    /// 裁出来的像素正好对应「屏幕上看到的那一块」，所以背景铺回整屏时不用再裁。
    static func crop(_ image: UIImage,
                     viewport: CGSize,
                     scale: CGFloat,
                     offset: CGSize) -> UIImage? {
        guard viewport.width > 1, viewport.height > 1,
              let cg = image.cgImage, image.size.width > 0 else { return nil }

        let s = fillScale(image: image, viewport: viewport) * scale
        let drawnW = image.size.width * s
        let drawnH = image.size.height * s
        // 图片左上角在视口坐标里的位置（图片中心 = 视口中心 + 偏移）。
        let originX = viewport.width / 2 + offset.width - drawnW / 2
        let originY = viewport.height / 2 + offset.height - drawnH / 2

        // 视口那一块换算回图片自身的点坐标。
        let cropX = -originX / s
        let cropY = -originY / s
        let cropW = viewport.width / s
        let cropH = viewport.height / s

        // 图片点 → 像素。`upright` 之后 scale 已是 1，这里仍然除一次防止意外。
        let perPoint = CGFloat(cg.width) / image.size.width
        let full = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let rect = CGRect(x: cropX * perPoint,
                          y: cropY * perPoint,
                          width: cropW * perPoint,
                          height: cropH * perPoint).integral.intersection(full)
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }

        let output = UIImage(cgImage: cropped, scale: 1, orientation: .up)
        return downscale(output, maxSide: 2400)
    }
}
