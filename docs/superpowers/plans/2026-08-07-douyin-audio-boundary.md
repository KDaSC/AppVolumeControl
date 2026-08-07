# 抖音应用音频边界修正计划

**目标：** 让应用明确区分应用自身音量、Process Tap 输出增益和仅可识别的音频进程，不伪造抖音音量值。

**方案：** 保留 macOS 14.2+ 公开 Core Audio Process Tap 作为可选的进程级输出增益；原生媒体应用继续使用其公开 AppleScript 音量接口；其他应用只显示真实的输出状态和“无独立音量接口”。补齐捕获权限声明、输出状态映射、严格编译问题和回归测试。

**约束：** 不播放抖音音频；不改系统总音量；不使用私有 API；不扩展到浏览器标签页级控制；完成后运行指定测试、构建和打包命令，并检查首次启动和子进程清理。

## 执行任务

- [x] 先为“正在输出”和“已识别但未输出”的无独立音量应用状态写失败测试。
- [x] 实现状态文案、Core Audio 输出状态采集和 UI 映射。
- [x] 修复 Process Tap 的严格编译错误并补充 `NSAudioCaptureUsageDescription`。
- [x] 把 Process Tap 行文案改为“输出增益”，同步更新 README 的能力边界。
- [x] 运行 `swift run AppVolumeControlTests`、严格 release build、`./scripts/build-app.sh`。
- [x] 检查首次启动无自动面板、抖音识别、Process Tap 无残留子进程/死循环；构建脚本内签名检查通过。
