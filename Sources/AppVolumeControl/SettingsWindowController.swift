import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: VolumeSettingsStore,
        onAutomaticAttachmentChange: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let view = SettingsView(
            store: store,
            onAutomaticAttachmentChange: onAutomaticAttachmentChange
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
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
    let onAutomaticAttachmentChange: @MainActor @Sendable (Bool) -> Void
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新应用").font(.headline)
            HStack {
                Text("默认输出增益")
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
            Text("关闭时，新应用只显示正在输出，不改变原始声音路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .frame(width: 430, height: 300)
        .alert("清除已记住的增益？", isPresented: $showingClearConfirmation) {
            Button("清除", role: .destructive) { store.clearRememberedGains() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后未开启记忆的应用将使用默认 75%。")
        }
    }
}
