import SwiftUI

struct ModuleSettingsView: View {
    @Environment(AppModel.self) private var model: AppModel
    @State private var editMode: EditMode = .active

    private var visibleCount: Int {
        model.moduleOrder.count - model.hiddenModules.count
    }

    var body: some View {
        List {
            Section {
                ForEach(model.moduleOrder) { module in
                    HStack(spacing: 12) {
                        Image(systemName: module.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .background(
                                Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title)
                                .font(.subheadline)
                            Text(module.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Toggle("", isOn: Binding(
                            get: { model.isVisible(module) },
                            set: { model.setModule(module, visible: $0) }
                        ))
                        .labelsHidden()
                        // 开关一律显式给蓝。底栏为了变黑在 MainTabs 上挂了 `.tint(.primary)`，
                        // 那是往下传的环境值；sheet / push 出来的页面拿不到根页那句 `.tint(.blue)`，
                        // 开关就跟着 label 色变成黑的了（v2.1.17）。
                        .tint(.blue)
                    }
                    .padding(.vertical, 2)
                    // v2.4.10：行底逐行挂，`.themedFormBackground()` 里那句不传递。
                    .adaptiveRowBackground()
                }
                .onMove { source, destination in
                    model.moveModules(from: source, to: destination)
                }
            } header: {
                HStack {
                    Text("共 \(model.moduleOrder.count) 个模块，已显示 \(visibleCount) 个")
                    Spacer()
                }
            } footer: {
                Text("拖动右侧手柄调整顺序；关掉的模块不会出现在概览页，也不影响采集。")
            }
        }
        .environment(\.editMode, $editMode)
        // v2.4.6：行底从死白改成跟着滑块变透，页面自己铺一层壁纸。
        .themedFormBackground()
        .navigationTitle("概览模块")
        .navigationBarTitleDisplayMode(.inline)
        // 根页面把导航栏隐藏了，这里显式要求显示，免得推上来没有返回按钮。
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认") {
                    model.resetModules()
                }
                .font(.caption)
                .navBarTint()
            }
        }
    }
}
