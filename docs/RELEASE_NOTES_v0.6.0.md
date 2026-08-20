# AppVolumeControl 0.6.0

发布日期 / Release date: 2026-08-16<br>
状态 / Status: **预发布 / Pre-release**<br>
架构 / Architecture: **Apple Silicon arm64**

## 下载与空间占用 / Download and disk footprint

| 资产 / Asset | 实际大小 / Measured size |
| --- | ---: |
| `AppVolumeControl.zip` | **178,626 bytes** · 174.44 KiB · 0.1786 MB |
| `AppVolumeControl.zip.sha256` | **149 bytes** · 0.1455 KiB · 0.000149 MB |
| 解压后的 `.app` / Unpacked `.app` | **约 636 KiB** · 0.62 MiB（磁盘占用 / disk usage） |

ZIP 是推荐下载格式；它避免了同步目录给 `.app` 添加额外文件提供器元数据。<br>
The ZIP is the recommended download format because it avoids extra file-provider metadata being attached to an `.app` in a synced directory.

## 重点修复 / Highlights

- 默认不再自动接管新应用的声音路径。打开 AppVolumeControl 不会为抖音、浏览器等应用创建 Process Tap。<br>
  New apps are no longer handed off automatically by default. Opening AppVolumeControl does not create a Process Tap for Douyin, browsers, or similar apps.
- 没有公开独立音量接口的应用显示“原始输出 · 未启用独立增益”；用户点击“启用独立增益”后才建立系统级输出增益会话。<br>
  Apps without a public independent-volume API show “Raw output · Independent gain off”; a system-level output-gain session starts only after the user enables it.
- 默认输出增益固定为 75%。关闭“记住每个应用的输出增益”时，新的接管会话不会继承上一次的数值。<br>
  The default output gain is 75%. When per-app gain memory is off, a new handoff session does not inherit the previous value.

## 设置 / Settings

- 面板右上角新增设置入口，可设置默认输出增益、自动接管新应用、是否记住每个应用的输出增益，并清除已记住的数值。<br>
  The new settings entry controls default output gain, automatic handoff, per-app gain memory, and clearing remembered values.
- 自动接管和应用记忆默认关闭，避免播放刚开始时发生不必要的声音路径切换。<br>
  Automatic handoff and app memory are off by default to avoid unnecessary audio-path changes when playback begins.

## 能力边界 / Boundaries

- 抖音和浏览器的控制项是公开 Core Audio Process Tap 提供的“输出增益”，不是应用或网页播放器自己的内部音量。<br>
  Douyin and browser controls are “output gain” provided by the public Core Audio Process Tap API, not the app or web player's internal volume.
- 浏览器标签页级音量需要独立的浏览器扩展；0.6.0 不会伪造该能力。<br>
  Per-tab browser volume requires a separate browser extension; 0.6.0 does not fake this capability.
- 公开 API 无法可靠读取任意 Electron 应用或网页播放器的内部音量数值。<br>
  Public APIs cannot reliably read the internal volume value of arbitrary Electron apps or web players.

## 验证 / Verification

本版本已通过以下本地验证 / This release passed the following local checks:

```sh
swift run AppVolumeControlTests
swift build -c release -Xswiftc -warnings-as-errors
./scripts/build-app.sh
shasum -a 256 -c outputs/AppVolumeControl.zip.sha256
unzip -t outputs/AppVolumeControl.zip
```

构建使用 ad-hoc 签名时，版本应保持为预发布；正式签名和 Developer ID 公证不包含在本版本中。<br>
With ad-hoc signing, this version remains a pre-release; production signing and Developer ID notarization are not included.
