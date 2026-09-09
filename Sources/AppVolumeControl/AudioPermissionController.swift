import AppKit
import CoreAudio
import SwiftUI

/// 只触发系统音频授权，不接收密码。 / Request native consent without handling credentials.
@MainActor
final class AudioPermissionController: ObservableObject {
    @Published private(set) var message = "首次调节时按系统提示允许音频控制"
    @Published private(set) var isRequesting = false

    func request() {
        guard !isRequesting else { return }
        guard #available(macOS 18, *) else {
            message = "此系统不支持应用输出增益"
            return
        }
        isRequesting = true
        message = "正在请求系统授权…"
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                // 空进程集合、非静音 Tap；不保存、不路由任何音频。 / No sources, no muting or recording.
                let description = CATapDescription(stereoMixdownOfProcesses: [])
                description.name = "AppVolumeControl Permission"
                description.isPrivate = true
                description.muteBehavior = .unmuted
                var tap = AudioObjectID(kAudioObjectUnknown)
                let result = AudioHardwareCreateProcessTap(description, &tap)
                if result == noErr { AudioHardwareDestroyProcessTap(tap) }
                return result
            }.value
            isRequesting = false
            // 创建 Tap 成功并不证明授权已生效。 / Tap creation alone is not proof of consent.
            message = status == noErr
                ? "已发起授权；若未弹窗，请打开权限设置。授权后点“重新连接”。"
                : "授权请求未完成（\(status)）；请打开权限设置后重新连接。"
        }
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
