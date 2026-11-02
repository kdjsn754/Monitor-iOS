import SwiftUI

/// 导航栏按钮的外观。**单独成文件是有意的**：交接文档 3.5 里「返回蓝色按钮版」那套
/// 回退流程会整文件覆盖 `Glass.swift`（它装着按钮外壳），但导航栏这套不该跟着回退，
/// 分开之后覆盖 `Glass.swift` 不会把它一起冲掉。

/// 导航栏右上角按钮的颜色。
///
/// 全 App 的环境 tint 是蓝的（`RootView` 的 `.tint(.blue)`，开关、进度条都用它），
/// 于是导航栏上的「订阅 / 添加 / 完成 / 刷新 / 恢复默认」也全成了蓝字。
/// 浅色玻璃栏上那片蓝和黑色标题撞在一起，用户要的是「跟标题同色」。
/// `.primary` 浅色下是黑、深色下是白，禁用态由系统自己降透明度，不用另写。
///
/// 用法：`Button { … } label: { … }.navBarTint()`，只加在 toolbar 里的按钮上，
/// **别加在 NavigationStack 或整页上**——那会把开关、进度条一起改掉。
extension View {
    func navBarTint() -> some View {
        self.tint(.primary)
    }
}
