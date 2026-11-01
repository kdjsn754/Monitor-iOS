import SwiftUI

/// 连接弹窗所处阶段。弹窗只负责把状态演出来，连接动作仍由 AppModel 执行。
enum ConnectionPhase: Equatable {
    case connecting
    case connected
    case failed(String)

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// 打开 App 自动连接时盖在界面上的进度卡：
/// 握手 → 读信息 → 完成，成功后自动收起，失败则给出重试。
struct ConnectionPopupView: View {
    let phase: ConnectionPhase
    let routerTitle: String
    let routerSubtitle: String
    let startedAt: Date?
    let onDismiss: () -> Void
    let onRetry: () -> Void
    /// 主动中止这次连接，并退回连接前的状态。
    let onCancel: () -> Void

    @State private var spin = false

    private var tint: Color {
        switch phase {
        case .connecting: return .blue
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var headline: String {
        switch phase {
        case .connecting: return "正在连接路由器"
        case .connected: return "连接成功"
        case .failed: return "连接失败"
        }
    }

    private var detail: String? {
        switch phase {
        case .connecting, .connected:
            return routerSubtitle.isEmpty ? routerTitle : "\(routerTitle)\n\(routerSubtitle)"
        case .failed:
            return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.26)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 16) {
                badge

                VStack(spacing: 6) {
                    Text(headline)
                        .font(.headline)
                    if let text = detail {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                switch phase {
                case .failed(let message):
                    failedDetail(message)
                case .connecting, .connected:
                    steps
                }

                buttons
            }
            .frame(width: 266)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .glassCard(padding: 0, cornerRadius: 24)
            .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
        }
    }

    // MARK: - 顶部图标

    private var badge: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 72, height: 72)

            if phase.isConnecting {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(tint.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 62, height: 62)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                               value: spin)
                    .onAppear { spin = true }
            }

            if phase.isConnecting {
                // 连接中画的就是这台路由器，用和桌面图标同一枚线稿。
                RouterGlyph(size: 30, tint: tint)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    /// 连接中已经改用 RouterGlyph，这里只剩「成功 / 失败」两种符号。
    private var iconName: String {
        phase.isConnected ? "checkmark" : "exclamationmark"
    }

    // MARK: - 步骤

    private enum StepState: Equatable {
        case done
        case active
        case idle
    }

    private var steps: some View {
        VStack(spacing: 9) {
            stepRow("建立 SSH 会话",
                    state: phase.isConnecting ? .active : .done)
            stepRow("读取路由器信息",
                    state: phase.isConnected ? .done : .idle)
            stepRow("开始实时监控",
                    state: phase.isConnected ? .done : .idle)
            if phase.isConnecting, let start = startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("已等待 \(max(0, Int(context.date.timeIntervalSince(start)))) 秒")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func stepRow(_ text: String, state: StepState) -> some View {
        HStack(spacing: 9) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .active:
                    ProgressView()
                        .scaleEffect(0.6)
                case .idle:
                    Image(systemName: "circle")
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .font(.caption)
            .frame(width: 16, height: 16)

            Text(text)
                .font(.caption)
                .foregroundStyle(state == .idle ? Color.secondary : Color.primary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 失败说明

    private func failedDetail(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text("请检查地址、密码，或确认路由器已开启 SSH。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(8)
                .softTile(.red, radius: 9)
        }
    }

    // MARK: - 按钮

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .connecting:
            VStack(spacing: 9) {
                Button {
                    onCancel()
                } label: {
                    Text("停止连接")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    onDismiss()
                } label: {
                    Text("在后台继续")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        case .connected:
            EmptyView()
        case .failed:
            VStack(spacing: 8) {
                Button {
                    onRetry()
                } label: {
                    Text("重试")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(GlassProminentButtonStyle())

                Button {
                    onDismiss()
                } label: {
                    Text("关闭")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
