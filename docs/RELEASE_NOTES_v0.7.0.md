# AppVolumeControl 0.7.0

发布日期 / Release date: 2026-08-24<br>
状态 / Status: **预发布 / Pre-release**<br>
版本 / Version: **0.7.0 / Build 8**<br>
架构 / Architecture: **Apple Silicon arm64**<br>
系统 / System: **macOS 18+**

## 重点更新 / Highlights

- 会话输出增益在播放状态变化期间保持稳定；统一的附着状态清楚区分“已允许”与“已连接”。<br>
  Session output gain remains stable across playback-state changes; the unified attachment state clearly distinguishes “allowed” from “connected”.
- 新增可逆静音：静音保留当前会话中原先的非零增益，取消静音恢复该值。<br>
  Reversible mute is new: muting retains the prior non-zero gain in the current session, and unmuting restores it.
- 滑杆降到 0% 是瞬时零值，不会被保存为后续恢复所用的非零增益。<br>
  Moving the slider to 0% is a transient zero and is not saved as the non-zero gain used for later restoration.
- SHA-256 文件现在只包含归档文件名，下载后与 ZIP 放在同一目录即可直接用 `shasum -c` 校验。<br>
  The SHA-256 file now contains only the archive filename, so it can be verified directly with `shasum -c` when placed beside the downloaded ZIP.

## 安全与能力边界 / Safety and boundaries

- Process Tap 施加的是应用进程的输出增益，不是任意应用、播放器或网页的内部音量，也不提供窗口或浏览器标签页级控制。<br>
  Process Tap applies gain to an app process's output; it is not an internal volume control for arbitrary apps, players, or webpages, and it does not provide window- or browser-tab-level control.
- 浏览器标签页级音量需要浏览器扩展；网页音频仍归属于浏览器进程，无法仅用 macOS 音频 API 可靠地按网页名称拆分。<br>
  Per-tab browser volume requires a browser extension; web audio remains owned by the browser process and cannot be reliably separated by webpage name using macOS audio APIs alone.
- 对采用 AppleScript 音量接口的应用，若应用在恢复前退出，恢复命令无法发送，应用可能保持在 0%。<br>
  For apps using AppleScript volume interfaces, if the app exits before restore, the restore command cannot be sent and the app may remain at 0%.
- 本构建为 ad-hoc 签名，未经过 Developer ID 公证；它是本地预发布版本。<br>
  This build is ad-hoc signed and not Developer ID notarized; it is a local pre-release.

## 安装 / Install

1. 下载 `AppVolumeControl.zip` 和 `AppVolumeControl.zip.sha256`，并放在同一个目录。<br>
   Download `AppVolumeControl.zip` and `AppVolumeControl.zip.sha256`, and put them in the same directory.
2. 在该目录运行 `shasum -a 256 -c AppVolumeControl.zip.sha256`；成功时会显示 `AppVolumeControl.zip: OK`。<br>
   Run `shasum -a 256 -c AppVolumeControl.zip.sha256` there; success prints `AppVolumeControl.zip: OK`.
3. 解压 ZIP，并将 `AppVolumeControl.app` 放到 `/Applications` 等非同步目录后打开。<br>
   Extract the ZIP, then open `AppVolumeControl.app` from a non-synced directory such as `/Applications`.

## 验证 / Verification

以下本地构建与产物检查已通过；未执行真实扬声器、耳机或蓝牙的声音路径测试。<br>
The following local build and artifact checks passed; no live speaker, headphone, or Bluetooth sound-path test was performed.

```sh
./scripts/build-app.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' outputs/AppVolumeControl.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' outputs/AppVolumeControl.app/Contents/Info.plist
(cd outputs && shasum -a 256 -c AppVolumeControl.zip.sha256)
```

结果：`0.7.0`、`8` 和 `AppVolumeControl.zip: OK`。<br>
Results: `0.7.0`, `8`, and `AppVolumeControl.zip: OK`.

## 文件与精确大小 / Files and exact sizes

| 资产 / Asset | 实际大小 / Measured size |
| --- | ---: |
| `AppVolumeControl.zip` | **194,548 bytes** · 189.99 KiB · 0.1855 MiB |
| `AppVolumeControl.zip.sha256` | **87 bytes** · 0.08 KiB · 0.0001 MiB |
| `AppVolumeControl.app/Contents/MacOS/AppVolumeControl` | **706,464 bytes** · 689.91 KiB · 0.6737 MiB |
| `AppVolumeControl.app` 磁盘占用 / disk usage | **700 KiB** · 0.6836 MiB |

SHA-256：`734572cb100ac379a69877ac060dce54300d1bd1ac1e37b47b7658460f3b32bf`。<br>
SHA-256: `734572cb100ac379a69877ac060dce54300d1bd1ac1e37b47b7658460f3b32bf`.
