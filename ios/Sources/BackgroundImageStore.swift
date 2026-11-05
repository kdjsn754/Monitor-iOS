import SwiftUI
import UIKit

/// 自定义背景的存与取（v2.4.0）。
///
/// 为什么图片不塞 `UserDefaults`：一张铺满屏幕的 jpg 少说百来 KB，塞进去之后
/// **每一次读设置**（包括启动时的 `@AppStorage` 初始化）都要解码这一坨 Data；
/// 而背景图本来就是「一张、固定名字、随时可删」的东西，落在 Application Support
/// 下的 `app-background.jpg` 更合适。`UserDefaults` 只留三个小值：
/// 开没开、不透明度、版本号。
///
/// 版本号（`customBackgroundVersion`）是给 `AppBackground` 用的信号：
/// 每次换图 / 删图都 +1，它拿这个值当 `.task(id:)` 的 id，变了就重新读盘。
/// 不这么做的话，`@AppStorage` 里那几个布尔量看不出「换了一张图」。
enum BackgroundImageStore {
    static let onKey = "customBackgroundOn"
    static let opacityKey = "customBackgroundOpacity"
    static let versionKey = "customBackgroundVersion"

    /// 背景是铺满屏幕看的，不必留原图尺寸。
    /// 2400 足够 3x 的 Pro Max（1290×2796）铺满还不糊，压成 jpg 也就一两百 KB。
    private static let maxSide: CGFloat = 2400

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask)[0]
        return dir.appendingPathComponent("app-background.jpg")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// 存图：先缩到长边 ≤ 2400、再转 jpg，最后把「开」和版本号推上去。
    /// 写盘走临时文件 + rename：中途被杀掉也不会留下一张写了一半的图。
    static func save(_ image: UIImage) {
        let scaled = downscale(image, maxSide: maxSide)
        guard let data = scaled.jpegData(compressionQuality: 0.86) else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("app-background.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            // 替换失败就直写，别让用户点了「选择图片」却什么都没发生。
            try? data.write(to: fileURL, options: .atomic)
        }

        UserDefaults.standard.set(true, forKey: onKey)
        bumpVersion()
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.set(false, forKey: onKey)
        bumpVersion()
    }

    private static func bumpVersion() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: versionKey) + 1, forKey: versionKey)
    }

    /// 等比缩到长边不超过 `maxSide`。已经够小就原样返回，不做无谓的重绘。
    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }

        let ratio = maxSide / longest
        let target = CGSize(width: (size.width * ratio).rounded(),
                            height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        // 目标尺寸已经是按像素算的，别再让渲染器乘一遍屏幕倍率（3x 会变成 7200）。
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
