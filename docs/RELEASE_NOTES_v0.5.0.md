# AppVolumeControl v0.5.0 — macOS 18/26/27（Apple Silicon）

## 重点更新

- 仅显示正在实际输出声音的应用，减少空闲应用干扰。
- 默认音量与滑杆基准统一为 75%，在基准线前后 3% 轻微吸附。
- 对抖音、浏览器等没有公开应用内音量接口的软件，使用 macOS 18+ 的公开 Core Audio Process Tap 提供独立输出增益；不会改动系统总音量。
- 精简菜单栏面板：移除说明副标题和刷新按钮，按内容自动收缩。
- 修复聚合设备未正确读取输出设备缓冲帧数的问题，降低外接设备和蓝牙设备下的延迟/稳定性风险。

## 兼容性与安装

- 系统：macOS 18、macOS 26 或 macOS 27。
- 架构：当前资产仅支持 Apple Silicon（arm64）；Intel Mac 不适用。
- 下载 `AppVolumeControl.zip`，校验 `AppVolumeControl.zip.sha256` 后，将应用解压到 `/Applications` 等非同步目录。
- 首次使用通用输出增益时，按系统提示授予系统音频捕获权限。

## 已知限制

- 浏览器网页音频只能按浏览器进程控制，不能可靠地区分单个网页或标签页。
- 抖音等 Electron 应用的滑杆是输出增益，不是其界面中的内部音量读数。
- 此构建为 ad-hoc 签名，未使用 Developer ID 签名和 Apple 公证；应作为预发布测试资产，不应标记为正式稳定版。

## 验证

- `swift run AppVolumeControlTests`
- `swift build -c release -Xswiftc -warnings-as-errors`
- `./scripts/build-app.sh`
- 解压后的应用已通过 `codesign --verify --deep --strict`。
