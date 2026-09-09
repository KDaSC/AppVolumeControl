import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: VolumeSettingsStore,
        permission: AudioPermissionController,
        onRetry: @escaping @MainActor () -> Void,
        onAutomaticAttachmentChange: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let view = SettingsView(
            store: store,
            permission: permission,
            onRetry: onRetry,
            onAutomaticAttachmentChange: onAutomaticAttachmentChange
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private struct SettingsView: View {
    @ObservedObject var store: VolumeSettingsStore
    @ObservedObject var permission: AudioPermissionController
    let onRetry: @MainActor () -> Void
    let onAutomaticAttachmentChange: @MainActor @Sendable (Bool) -> Void
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新应用").font(.headline)
            HStack {
                Text("默认音量刻度")
                Spacer()
                Text("\(Int((store.settings.defaultOutputGain * 100).rounded()))%")
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { store.settings.defaultOutputGain },
                set: { store.settings.defaultOutputGain = $0 }
            ), in: 0...1)
            Toggle("自动接管新应用", isOn: Binding(
                get: { store.settings.automaticallyAttachNewApps },
                set: { value in onAutomaticAttachmentChange(value) }
            ))
            Text("75% = 原声；100% ≈ 原声的 133%。自动就绪由系统音频事件唤醒，关闭面板后仍生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("音频授权").font(.headline)
            HStack {
                Button("授权音频控制") { permission.request() }
                    .disabled(permission.isRequesting)
                Button("打开权限设置") { permission.openSettings() }
                Button("重新连接") { onRetry() }
            }
            Text(permission.message).font(.caption).foregroundStyle(.secondary)
            Text("请在 macOS 原生窗口中点允许；系统要求密码时也在系统窗口输入，本程序不收集密码。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("应用记忆").font(.headline)
            Toggle("记住每个应用的输出增益", isOn: Binding(
                get: { store.settings.rememberPerAppProcessTapGain },
                set: { store.settings.rememberPerAppProcessTapGain = $0 }
            ))
            Button("清除已记住的增益") { showingClearConfirmation = true }
            Divider()
            Text("网页音量：需要浏览器扩展；当前版本不伪造网页独立音量。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 440, height: 420)
        .alert("清除已记住的增益？", isPresented: $showingClearConfirmation) {
            Button("清除", role: .destructive) { store.clearRememberedGains() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后的新会话将使用当前设置的默认刻度，75% 表示原声。")
        }
    }
}
