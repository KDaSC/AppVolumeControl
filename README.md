# 应用音量（AppVolumeControl）

面向 Apple Silicon Mac 的轻量级菜单栏工具。当前目标设备已验证为 MacBook Air (M1, 8 GB)，系统为 macOS 26.6。

兼容性：本发布包只支持 macOS 18、macOS 26 和 macOS 27；当前交付包为 Apple Silicon（arm64）版本，Intel Mac 需要另行构建 x86_64 或 Universal 版本。通用输出增益使用 macOS 18+ 的公开 Core Audio Process Tap API。

## 运行

```sh
./scripts/build-app.sh
open outputs/AppVolumeControl.app
```

构建也会输出 `outputs/AppVolumeControl.zip` 和对应的 `outputs/AppVolumeControl.zip.sha256`。若 `Documents` 的文件提供器会给 `.app` 添加元数据，请将 ZIP 解压到非同步目录（例如 `/Applications`）后再运行，以保持签名不被目录元数据改写。

点击菜单栏滑杆图标即可打开控制面板。

核心吸附逻辑检查：

```sh
swift run AppVolumeControlTests
```

## 当前能力

- 应用发现：使用 macOS CoreAudio 的公开进程对象接口，只保留 `IsRunningOutput == 1` 的音频进程，并沿父进程链把音频辅助进程归并回主应用；没有正在输出声音的应用不会显示。
- 应用级音量：对 Music、Spotify、VLC、QuickTime Player 使用各自公开的 AppleScript 音量接口。
- 通用输出增益：抖音、浏览器和其他没有 AppleScript 独立音量接口的应用统一使用 macOS 18+ 的公开 Core Audio Process Tap API；每个正在输出的应用拥有独立增益会话，默认目标和滑杆基准为 75%。
- 权限提示：系统级输出增益只依赖 macOS 的系统音频捕获授权。首次启动实际 Tap 时由系统显示原生授权提示；应用不会把屏幕录制权限当作前置条件。
- 基准音量：所有可控应用的吸附基准固定为 75%，拖到基准线前后 3% 会轻微吸附；不再提供右键菜单。
- 刷新策略：打开面板时读取一次音量；应用启动、激活、退出以及面板打开期间只刷新轻量进程列表。
- 面板：只保留应用音量标题和紧凑列表，移除“只显示各应用音量...”副标题和刷新按钮；应用少时自动收缩，应用多时列表滚动。
- 窗口定位：使用 macOS 原生状态栏锚点，并做小幅安全上移，让箭头贴近黑色菜单栏下沿；兼容 Hidden Bar、无 Hidden Bar 和多屏环境。
- 未提供独立音量接口的应用显示“正在输出 · 无独立音量接口”或“已识别 · 无独立音量接口”，不会伪造音量值。
- Tap 生命周期：停止路径保持引擎到 CoreAudio 清理完成，避免重复静音接管器和蓝牙输出无声。

## 平台限制

- macOS 公共 SDK 没有适用于任意应用的通用“独立音量”接口；抖音这类 Electron 应用通过公开 Process Tap（macOS 18+）实现系统级输出增益。
- 抖音的滑杆控制的是“输出增益”（在抖音自身音量之上再乘一个系数），不是抖音界面里显示的内部音量值；抖音不对外暴露内部音量，读取不到该数值是系统限制。
- Process Tap 需要系统音频捕获授权；授权后即可使用。
- 增益只在应用实际播放音频时生效（CoreAudio 只有播放时才注册音频进程）；暂停时滑杆值会保留，恢复播放后自动重新接入。
- 浏览器里的抖音网页音频仍归属于浏览器进程，无法仅靠 macOS 音频 API 可靠区分成网页名称。

## 权限持久性

当前机器没有可用的代码签名身份，默认构建会使用 ad-hoc 签名，因此每次重新构建后 macOS 可能要求重新授予系统音频捕获权限。没有修改钥匙串；如果机器上已有稳定签名身份，可这样构建：

```sh
APP_VOLUME_SIGNING_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
```
