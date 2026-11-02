import SwiftUI

/// 导航栏上按钮的颜色。
///
/// 全 App 的环境 tint 是蓝的（`RootView` 的 `.tint(.blue)`，开关、进度条、滑条都用它），
/// 于是导航栏上的「订阅 / 添加 / 保存 / 完成 / 刷新 / 恢复默认」也全成了蓝字。
/// 用户 2026-11-02 要求「蓝色配色换成黑」，指的是这些栏上的字（浅色下要跟标题同色）。
/// `.primary` 浅色下是黑、深色下是白，禁用态由系统自己降透明度，不用另写。
///
/// 用法：`Button { … } label: { … }.navBarTint()`，
/// 只加在**单个 toolbar 按钮**上，别加在 `NavigationStack` 或整页上——
/// 那会把页面里的开关、进度条一起改掉（它们的蓝由页面自己的 `.tint(.blue)` 保着）。
///
/// 单独成文件是有原因的：交接 3.5 的「返回蓝色按钮版 / 换回玻璃」要整文件覆盖
/// `Glass.swift`，把这段留在 `Glass.swift` 里会被一起冲掉。
extension View {
    func navBarTint() -> some View {
        self.tint(.primary)
    }
}
