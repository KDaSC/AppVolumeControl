# AppVolumeControl · 应用音量控制

轻量级的原生 macOS 菜单栏工具，用于查看并控制正在输出声音的应用。<br>
Native macOS menu bar utility for discovering and controlling apps that are currently producing audio.

## 0.7.0 版本 / Release

| 项目 / Item | 实际大小 / Size |
| --- | ---: |
| 下载包 `AppVolumeControl.zip` / Download archive | **138,838 bytes** · 135.58 KiB · 0.1324 MiB |
| SHA-256 文件 / Checksum file | **87 bytes** · 0.08 KiB · 0.0001 MiB |
| `AppVolumeControl` 二进制 / Executable | **385,872 bytes** · 376.83 KiB · 0.3680 MiB |
| 解压后的 App 磁盘占用 / Unpacked app disk usage | **388 KiB** · 0.3789 MiB |

以上数值来自本地构建的 v0.7.0 / Build 8 资产；ZIP 是推荐下载格式。<br>
The values above are measured from locally built v0.7.0 / Build 8 assets; the ZIP is the recommended download format.

**下载 / Download:** [v0.7.0 Pre-release](https://github.com/KDaSC/AppVolumeControl/releases/tag/v0.7.0)

## 支持平台 / Platform

- 仅提供 Apple Silicon（`arm64`）发布包；Intel Mac 需要另行构建 `x86_64` 或 Universal 版本。<br>
  The release package is Apple Silicon (`arm64`) only; Intel Macs require a separate `x86_64` or Universal build.
- 当前发布包支持 macOS 18、macOS 26 和 macOS 27。<br>
  The current package supports macOS 18, macOS 26, and macOS 27.
- 通用输出增益使用 macOS 18+ 公开的 Core Audio Process Tap API。<br>
  Generic output gain uses the public Core Audio Process Tap API available on macOS 18+.

## 安装与运行 / Install and run

1. 下载 `AppVolumeControl.zip` 并解压到 `/Applications` 等非同步目录。<br>
   Download `AppVolumeControl.zip` and extract it to a non-synced directory such as `/Applications`.
2. 打开 `AppVolumeControl.app`，点击菜单栏滑杆图标。<br>
   Open `AppVolumeControl.app`, then click its menu bar slider icon.
3. 首次启用系统级输出增益时，按 macOS 原生提示授予系统音频捕获权限。<br>
   On first use of system-level output gain, follow the native macOS prompt to grant audio-capture permission.

直接从 `Documents` 文件提供器运行的 `.app` 副本可能带有额外元数据；若遇到签名提示，请重新从 ZIP 解压后运行。构建脚本验证的是干净解压后的 ZIP 副本。<br>
An `.app` copied directly by the `Documents` file provider may carry extra metadata. If macOS reports a signature issue, extract the ZIP again and run that copy; the build script verifies a cleanly extracted ZIP copy.

## 当前能力 / Current capabilities

- **应用发现 / App discovery**：通过公开 CoreAudio 进程对象筛选 `IsRunningOutput == 1` 的音频进程，并沿父进程链归并回主应用。只显示实际正在输出声音的应用。<br>
  Uses public CoreAudio process objects, keeps `IsRunningOutput == 1`, and maps helper processes back to their parent app. Only actively producing apps are shown.
- **应用级音量 / App volume**：Music、Spotify、VLC、QuickTime Player 使用各自公开的 AppleScript 音量接口。<br>
  Music, Spotify, VLC, and QuickTime Player use their public AppleScript volume interfaces.
- **通用输出增益 / Generic output gain**：抖音、浏览器及其他没有独立公开音量接口的应用，点击“启用独立增益”后才建立 Process Tap 会话；默认目标和滑杆基准为 75%。<br>
  For Douyin, browsers, and apps without a public independent-volume API, a Process Tap session starts only after “Enable independent gain” is clicked; the default target and slider baseline are 75%.
- **设置 / Settings**：可设置默认输出增益、是否自动接管新应用、是否记住每个应用的增益，并清除已记住的数值。默认关闭自动接管和应用记忆。<br>
  Configure default output gain, automatic handoff, per-app memory, and clearing remembered values. Automatic handoff and app memory are off by default.
- **面板与定位 / Panel and positioning**：面板按应用数量自动收缩或滚动，使用原生状态栏锚点，兼容 Hidden Bar、无 Hidden Bar 和多屏环境。<br>
  The panel shrinks or scrolls based on app count, uses the native status-bar anchor, and supports Hidden Bar, no Hidden Bar, and multi-display setups.
- **实时性 / Real-time behavior**：音频回调使用无锁原子目标；停止路径等待 CoreAudio 清理完成，避免重复接管和蓝牙输出无声。<br>
  Audio callbacks use lock-free atomic targets; shutdown waits for CoreAudio cleanup to avoid duplicate handoff and silent Bluetooth output.
- **可逆静音 / Reversible mute**：静音会保留本次会话中原先的非零增益；取消静音会恢复该值。<br>
  Mute retains the previous non-zero gain in the current session; unmuting restores it.
- **瞬时零值 / Transient zero**：滑杆降到 0% 只是当前会话的瞬时状态，不会把 0% 作为可恢复的非零增益保存。<br>
  Moving the slider to 0% is a transient current-session state; 0% is not retained as the non-zero value to restore.
- **允许与已连接 / Allowed versus connected**：设置允许独立增益不等于已经建立 Process Tap；只有连接后的会话才实际改变输出增益。<br>
  Allowing independent gain in settings does not mean a Process Tap is connected; only a connected session actually changes output gain.

## 能力边界 / Boundaries

- macOS 公共 SDK 没有适用于任意应用的通用“独立音量”接口；Process Tap 提供的是系统级**输出增益**，不是应用或网页播放器的内部音量。<br>
  The public macOS SDK has no universal independent-volume API for arbitrary apps; Process Tap provides system-level **output gain**, not the app or web player's internal volume.
- Process Tap 按应用进程的输出工作，不能读取或控制任意应用内部播放器的音量；它也不是网页、窗口或标签页级控制。<br>
  Process Tap works on an app process's output and cannot read or control an arbitrary app's internal player volume; it is not webpage-, window-, or tab-level control.
- 浏览器标签页级音量需要浏览器扩展；0.7.0 不会伪造该能力。<br>
  Per-tab browser volume requires a browser extension; 0.7.0 does not emulate that capability.
- 增益只在应用实际播放音频时生效；网页音频仍归属于浏览器进程，无法仅靠 macOS 音频 API 可靠区分网页名称。<br>
  Gain applies while an app is actually playing audio; web audio remains owned by the browser process and cannot be reliably split by webpage name using macOS audio APIs alone.
- 使用 AppleScript 音量接口的受控应用或 AppVolumeControl 任一方若在恢复前退出，恢复命令无法发送或完成，受控应用可能保持在 0%。<br>
  If either an AppleScript-controlled app or AppVolumeControl exits before restore, the restore command cannot be sent or completed and the controlled app may remain at 0%.

## 从源码构建 / Build from source

```sh
./scripts/build-app.sh
open outputs/AppVolumeControl.app
```

构建会生成 `outputs/AppVolumeControl.zip` 及 `outputs/AppVolumeControl.zip.sha256`。<br>
The build creates `outputs/AppVolumeControl.zip` and `outputs/AppVolumeControl.zip.sha256`.

校验文件只写入文件名，因此下载后把 ZIP 与 `.sha256` 放在同一目录即可直接校验：<br>
The checksum file contains only the archive filename, so after download place it beside the ZIP and verify directly:

```sh
shasum -a 256 -c AppVolumeControl.zip.sha256
```

运行测试 / Run tests:

```sh
swift run AppVolumeControlTests
swift build -c release -Xswiftc -warnings-as-errors
```

## 权限与签名 / Permissions and signing

未提供代码签名身份时，构建使用 ad-hoc 签名；重新构建后 macOS 可能要求重新授予系统音频捕获权限。构建脚本不会修改钥匙串或创建证书。<br>
Without a code-signing identity, builds use ad-hoc signing; macOS may request audio-capture permission again after a rebuild. The build script does not modify Keychain or create certificates.

```sh
APP_VOLUME_SIGNING_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
```

## 项目状态 / Project status

当前 `v0.7.0 / Build 8` 是预发布版本，适合 Apple Silicon Mac 的本地试用；它以 ad-hoc 方式签名，尚未经过 Developer ID 公证。<br>
`v0.7.0 / Build 8` is a pre-release intended for local use on Apple Silicon Macs; it is ad-hoc signed and not Developer ID notarized.
