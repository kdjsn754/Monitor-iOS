import SwiftUI

/// 设备类型的线条图标。
///
/// **v3.3.5 起直接用官方的**：15 个类型是路由器网页版 iconfont 里的字形
/// （见 `OfficialGlyph`，生成脚本 `tmp/font2swift.py`），和官方 App「设备类型」
/// 弹窗上那套同源——相机是摄像头、音响是音箱、电视带 TV 字样、NAS 是四个盘位、
/// 服务器是机架、交换机是带交叉箭头的盒子。v3.0.6 那套是照 Lucide 拼的近似图形，
/// 形状对不上，用户 2026-11-23：「这些图标使用官方的」。
///
/// **v3.3.12 起「默认」也是官方字形**（用户 2026-11-25：「默认图标很丑你照着官方的做」）。
/// 字体里 `clients`（`0xe9ff`）就是官方那格「显示器 + 手机」：显示器在左带底座、
/// 手机竖在右，笔触和另外 15 个一模一样。v3.3.11 那版是自己按印象描的边，
/// 比例、圆角、线宽都不对，19pt 下看着别扭；现在整页 16 个图标全是同一套轮廓，
/// 不再有「手绘一条 + 官方十五条」混在一起。
struct DeviceGlyph: View {
    let kind: ClientClass?
    var size: CGFloat = 18
    /// 笔画宽度，以 24×24 网格计。**保留但不再使用**：官方字形是实心轮廓，
    /// 线宽已经画在字形里了；留着这个参数是为了不动既有调用点的签名。
    var weight: CGFloat = 2

    var body: some View {
        // 官方字形是「把约 2px 描边展开成的实心轮廓」，必须 `fill`（非零环绕）；
        // 用 `stroke` 去描它，每根线两侧会再多出一圈。
        Path { p in
            OfficialGlyph.draw(kind ?? .auto, into: &p, scale: size / 24)
        }
        .fill(style: FillStyle(eoFill: false))
        .frame(width: size, height: size)
    }
}
