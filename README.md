# 应用音量（AppVolumeControl）

面向 Apple Silicon Mac 的轻量级菜单栏工具。

兼容性：本发布包只支持 macOS 18、macOS 26 和 macOS 27；当前交付包为 Apple Silicon（arm64）版本，Intel Mac 需要另行构建 x86_64 或 Universal 版本。通用输出增益使用 macOS 18+ 的公开 Core Audio Process Tap API。

## 运行

```sh
./scripts/build-app.sh
open outputs/AppVolumeControl.app
```

构建也会输出 `outputs/AppVolumeControl.zip` 和对应的 `outputs/AppVolumeControl.zip.sha256`。若 `Documents` 的文件提供器给直接 `.app` 副本添加元数据，请优先使用 ZIP，并将它解压到非同步目录（例如 `/Applications`）后再运行；构建脚本验证的是干净解压后的 ZIP 副本，以保持签名有效。

点击菜单栏滑杆图标即可打开控制面板。

核心吸附逻辑检查：

```sh
swift run AppVolumeControlTests
```

## 当前能力

- 应用发现：使用 macOS CoreAudio 的公开进程对象接口，只保留 `IsRunningOutput == 1` 的音频进程，并沿父进程链把音频辅助进程归并回主应用；没有正在输出声音的应用不会显示。
- 应用级音量：对 Music、Spotify、VLC、QuickTime Player 使用各自公开的 AppleScript 音量接口。
- 通用输出增益：抖音、浏览器和其他没有 AppleScript 独立音量接口的应用可使用 macOS 18+ 的公开 Core Audio Process Tap API。默认不会接管新应用：面板显示“原始输出 · 未启用独立增益”，只有点击“启用独立增益”后才建立该应用的增益会话；默认目标和滑杆基准均为 75%。
- 权限提示：系统级输出增益只依赖 macOS 的系统音频捕获授权。首次启动实际 Tap 时由系统显示原生授权提示；应用不会把屏幕录制权限当作前置条件。
- 基准音量：所有可控应用的吸附基准固定为 75%，拖到基准线前后 3% 会轻微吸附；不再提供右键菜单。
- 刷新策略：打开面板时读取一次音量；应用启动、激活、退出以及面板打开期间只刷新轻量进程列表。面板关闭后不会为了发现新应用而创建 Process Tap。
- 面板：只保留应用音量标题和紧凑列表，移除“只显示各应用音量...”副标题和刷新按钮；应用少时自动收缩，应用多时列表滚动。
- 窗口定位：使用 macOS 原生状态栏锚点，并做小幅安全上移，让箭头贴近黑色菜单栏下沿；兼容 Hidden Bar、无 Hidden Bar 和多屏环境。
- 未提供独立音量接口的应用不会伪造内部音量；未启用时明确显示原始输出状态，成功接入后显示“输出增益”，权限或创建失败时显示实际错误状态。
- 滑块语义：Music、Spotify、VLC、QuickTime 显示应用公开的内部音量；其他应用显示的是“输出增益”，不伪造应用内部音量。原生音量尚未读回时显示“音量未知”，不会用 75% 占位。
- Tap 生命周期：停止路径保持引擎到 CoreAudio 清理完成，避免重复静音接管器和蓝牙输出无声；实时音频回调使用无锁原子目标，不在回调线程执行锁、分配或进程操作。
- 设置：面板右上角齿轮可设置默认输出增益、是否自动接管新应用、是否记住每个应用的输出增益，以及清除已记住的增益。默认关闭自动接管和应用记忆，因此每个新应用从 75% 开始且不受上次设置影响。

## 平台限制

- macOS 公共 SDK 没有适用于任意应用的通用“独立音量”接口；抖音这类 Electron 应用通过公开 Process Tap（macOS 18+）实现系统级输出增益。
- 抖音的滑杆控制的是“输出增益”（在抖音自身音量之上再乘一个系数），不是抖音界面里显示的内部音量值；抖音不对外暴露内部音量，读取不到该数值是系统限制。
- Process Tap 需要系统音频捕获授权；授权后即可使用。
- 增益只在应用实际播放音频时生效（CoreAudio 只有播放时才注册音频进程）；暂停时应用不会显示，恢复播放后重新识别并接入已保存的目标增益。
- 浏览器里的抖音网页音频仍归属于浏览器进程，无法仅靠 macOS 音频 API 可靠区分成网页名称。

## 权限持久性

如果未提供代码签名身份，构建会使用 ad-hoc 签名，因此每次重新构建后 macOS 可能要求重新授予系统音频捕获权限。稳定的 Apple Development 或 Developer ID 身份可以让系统把授权绑定到稳定签名；构建脚本不会自动修改钥匙串，也不会创建证书。

```sh
APP_VOLUME_SIGNING_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
```
