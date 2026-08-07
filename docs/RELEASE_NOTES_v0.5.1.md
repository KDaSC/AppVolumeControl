# AppVolumeControl v0.5.1

## 修复

- 修复 Process Tap 异步停止时引擎提前释放，导致旧聚合设备和静音接管器残留的问题。
- 避免抖音、浏览器等应用在切换音频状态后累积多个 CoreAudio 接管器。
- 保持 macOS 系统总音量控制独立，不播放测试音频。

## 兼容性

- macOS 18、macOS 26、macOS 27
- Apple Silicon（arm64）
- 需要系统音频捕获权限

## 发布状态

这是预发布版本。应用使用 ad-hoc 签名，未使用 Apple Developer ID 公证；首次运行可能需要在系统设置中允许打开。
