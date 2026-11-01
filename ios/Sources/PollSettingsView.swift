import SwiftUI

/// 二级页：只剩刷新间隔可以调 —— 一个加减的细调，加三档预设。
///
/// 以前这里还挂着一张「采集内容」清单，把 7 个采集项、各自属于哪一页、是每轮采
/// 还是进页面采一次全列出来。那是给开发者看的信息：普通用户既改不了，也不会因为
/// 知道了「OpenClash 状态要问 7 次 uci」就少一点等待。删掉之后这一页只剩两件事：
/// 调多快、为什么这么快也不费路由器。
struct PollSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var seconds: Double { model.pollSeconds }

    /// 三档预设：只区分「要更细 / 够用 / 省一点」三种人，
    /// 不再摆一排 1/2/3/5/10 的刻度让人自己挑。
    private struct Preset: Identifiable {
        let id: Int
        let title: String
        let icon: String
    }

    private let presets: [Preset] = [
        Preset(id: 1, title: "灵敏", icon: "hare.fill"),
        Preset(id: 2, title: "标准", icon: "equal.circle.fill"),
        Preset(id: 5, title: "省电", icon: "tortoise.fill")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                secondsCard
                presetCard
                noteCard
            }
            .padding(16)
        }
        .background(Color.clear)
        .navigationTitle("采集与刷新")
        .navigationBarTitleDisplayMode(.inline)
        // 根页面把导航栏隐藏了，这里显式要求显示，免得推上来没有返回按钮。
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认") {
                    model.setPollSeconds(2)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - 刷新间隔

    private var secondsCard: some View {
        SectionCard("刷新间隔", icon: "timer") {
            HStack(spacing: 18) {
                Button {
                    model.setPollSeconds(seconds - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 27))
                }
                .buttonStyle(.plain)
                .foregroundStyle(seconds > PollConfiguration.range.lowerBound
                                 ? Color.blue : Color(.tertiaryLabel))
                .disabled(seconds <= PollConfiguration.range.lowerBound)

                VStack(spacing: 2) {
                    Text("\(Int(seconds))")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("秒一轮")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button {
                    model.setPollSeconds(seconds + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 27))
                }
                .buttonStyle(.plain)
                .foregroundStyle(seconds < PollConfiguration.range.upperBound
                                 ? Color.blue : Color(.tertiaryLabel))
                .disabled(seconds >= PollConfiguration.range.upperBound)
            }
        }
    }

    // MARK: - 预设

    private var presetCard: some View {
        SectionCard("预设", icon: "slider.horizontal.3") {
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    ForEach(presets) { preset in
                        presetTile(preset)
                    }
                }

                Text("三档只是把间隔设成 1 / 2 / 5 秒，中间的数字仍然可以自己加减。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func presetTile(_ preset: Preset) -> some View {
        let selected = abs(seconds - Double(preset.id)) < 0.5
        return Button {
            model.setPollSeconds(Double(preset.id))
        } label: {
            VStack(spacing: 4) {
                Image(systemName: preset.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(height: 18)
                Text("\(preset.id) 秒")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(preset.title)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.blue : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(selected ? Color.blue : Color.primary)
            .background(
                selected ? Color.blue.opacity(0.16) : Color.blue.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? Color.blue.opacity(0.5) : Color.blue.opacity(0.14),
                        lineWidth: 1
                    )
            }
            .cardTapShape()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title)，每 \(preset.id) 秒")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 说明

    private var noteCard: some View {
        SectionCard("省在哪儿", icon: "leaf") {
            VStack(alignment: .leading, spacing: 7) {
                bullet("只采当前页面：在概览页就只取 CPU、内存、网速、温度、闪存和设备，切到「设置」页完全停止采集。")
                bullet("同一页的数据拼成一条命令、一个 shell 跑完，所以 2 秒一轮也只创建一次进程。")
                bullet("所有脚本都以 nice -n 19 执行，永远不抢路由转发和代理的 CPU。")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Color.blue.opacity(0.5))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
