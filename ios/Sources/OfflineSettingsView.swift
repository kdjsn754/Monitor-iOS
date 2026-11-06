import SwiftUI

/// 离线设备的三项设置：自动清理开关 / 离线多久算「够久」/ 已隐藏 N 台 + 恢复。
///
/// v2.0.3 从「设置」页整张卡搬到「连接设备」面板，v2.0.4 又在那个面板里收进这一页——
/// 列表页只留设备，设置走右上角的齿轮（用户：「这个界面右上角做个设置按钮，点按钮设置」）。
///
/// 版式跟着面板本来的系统 `Form` 走，和「切换连接」「选择配置文件」两个面板是同一套；
/// 也不做「完成」按钮——它是 push 出来的二级页，左上角自带返回。
struct OfflineSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel

    var body: some View {
        // @Observable 模型不能直接 `$model.xxx`，要先用 @Bindable 包一层
        // 才能拿到 Binding（Toggle / Picker 用）。只在这一页有两处绑定。
        @Bindable var model = model
        return Form {
            Section {
                Toggle("自动清理离线设备", isOn: $model.autoRemoveOffline)
                    .tint(.blue)
                    .adaptiveRowBackground()

                if model.autoRemoveOffline {
                    // 时长做成菜单选择，不做滑条——「离线多久算久」是几档常识值，不是连续量。
                    Picker("离线超过", selection: $model.offlineRemoveMinutes) {
                        ForEach(Self.choices, id: \.self) { minutes in
                            Text(Self.label(minutes)).tag(minutes)
                        }
                    }
                    .adaptiveRowBackground()
                }

                // 「已隐藏」跟自动清理开关无关：手动点垃圾桶删掉的设备也记在这里，
                // 所以这一行不受上面开关控制。
                if model.hiddenDeviceCount > 0 {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已隐藏 \(model.hiddenDeviceCount) 台")
                                .font(.subheadline)
                            Text("设备重新连上会自动回到列表")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("恢复") {
                            model.restoreHiddenDevices()
                        }
                        .font(.subheadline.weight(.medium))
                        // borderless：不加这行，点这一行任何位置都会触发恢复。
                        .buttonStyle(.borderless)
                    }
                    .adaptiveRowBackground()
                }
            } footer: {
                Text("离线够久就从列表里移除，不影响路由器租约。")
            }
        }
        .themedFormBackground()
        .navigationTitle("离线设备")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let choices = [15, 60, 360, 1440]

    private static func label(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 1440 { return "\(minutes / 60) 小时" }
        return "\(minutes / 1440) 天"
    }
}
