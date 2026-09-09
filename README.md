# AppVolumeControl · 应用音量控制

轻量原生 macOS 菜单栏工具：自动发现发声应用，独立调节输出音量。<br>
A lightweight native macOS menu bar utility that discovers audio-producing apps and adjusts their output independently.

**下载 / Download:** [v0.8.0 Pre-release](https://github.com/KDaSC/AppVolumeControl/releases/tag/v0.8.0)

## 新变化 / What's new

- **自动就绪 / Automatic readiness**：默认自动接管，无须逐个点击启用。关闭面板后仍监听 CoreAudio 事件，100 ms 合并通知；没有定时轮询、额外常驻进程或第三方依赖。<br>
  Automatic attachment is on by default. CoreAudio subscriptions remain active with the panel closed, with 100 ms event coalescing; no polling timer, helper daemon or third-party dependency.
- **75% = 原声 / Original level**：实际增益 = 显示刻度 ÷ 75%。75% 不建立音频 Tap，直接保持原声；100% 约为原声的 133%。<br>
  Actual gain = displayed level ÷ 75%. At 75%, audio passes through unchanged without a tap; 100% applies about 133% gain.
- **统一逻辑 / Consistent control**：所有应用均使用相对输出增益，不再改写 Music、Spotify 等播放器的内部音量。<br>
  All apps use relative output gain; internal player volumes are no longer modified.
- **权限入口 / Permission controls**：设置中提供授权、系统权限设置和重新连接按钮；本程序不接收管理员密码。<br>
  Settings includes native consent, system permission settings and reconnect buttons; the app never accepts administrator passwords.

| 显示 / Display | 实际倍率 / Actual multiplier |
| --- | ---: |
| 0% | 0 · 静音 / Mute |
| 37.5% | 0.5× |
| 75% | 1× · 原声 / Unchanged |
| 100% | 1.333× |

超过 75% 放大的是波形，不保证主观响度同比增加。输出峰值限制在 ±1；接近满幅的音源可能削波失真，这不是动态限制器。<br>
Boost scales waveform amplitude, not perceived loudness proportionally. Peaks are capped at ±1; loud material can clip. This is not a dynamic limiter.

## 大小与资源 / Size and resources

| 项目 / Item | 实测大小 / Measured size |
| --- | ---: |
| 下载包 / `AppVolumeControl.zip` | **144,347 bytes · 140.96 KiB · 0.1377 MiB** |
| 校验文件 / SHA-256 file | **87 bytes** |
| 可执行文件 / Executable | **389,872 bytes · 380.73 KiB · 0.3718 MiB** |
| 解压 App 磁盘占用 / Unpacked app | **392 KiB · 0.3828 MiB** |

以上来自 v0.8.0 / Build 9 的本机构建。多次后台空闲抽样为 0.0% CPU、约 12.6–29.5 MiB RSS、无额外子进程；这是单机瞬时测量，不是所有电脑的保证值。<br>
Measured from the local v0.8.0 / Build 9 build. Repeated idle snapshots showed 0.0% CPU, about 12.6–29.5 MiB RSS and no helper child process; these are point measurements, not a universal guarantee.

75% 原声模式不运行音频处理回调。非 75% 的活动应用各自需要音频路由，CPU 随应用数、采样率和设备变化。面板打开时保留窗口定位计时器，关闭后停止。<br>
Unity mode runs no audio processing callback. Active non-unity apps each need a route; CPU depends on app count, sample rate and device. The panel-position timer runs only while visible.

## 安装与授权 / Install and authorize

1. 下载 ZIP，解压到 `/Applications` 等非同步目录，打开 App。<br>
   Download the ZIP, extract to a non-synced directory such as `/Applications`, and open the app.
2. 点击菜单栏滑杆图标；发声应用自动出现，默认 75% 原声。<br>
   Click the menu bar slider icon. Audio-producing apps appear automatically at 75%, unchanged.
3. 首次调节需音频权限：在设置中点“授权音频控制”，按 macOS 提示操作。若未弹窗或曾拒绝，点“打开权限设置”，允许系统音频录制后返回点“重新连接”。<br>
   Choose the audio authorization button in Settings and follow macOS prompts. If no prompt appears or access was denied, open permission settings, allow system audio recording, then reconnect.

创建 Tap 成功不等于授权已生效，本程序不会伪报授权状态。管理员密码不能代替音频隐私授权。操作说明参见 [Apple 支持 / Apple Support](https://support.apple.com/en-gb/guide/mac-help/mchl2844ecab/mac)。<br>
Successful tap creation is not proof of consent. An administrator password cannot replace audio privacy consent, which remains under macOS control.

## 设置与升级 / Settings and migration

- 可关闭自动接管、设置新会话默认刻度、开启应用记忆（记忆默认关闭）。<br>
  Disable automatic attachment, set the default level, or enable per-app memory (off by default).
- 静音保留之前的非零值，取消静音恢复。拖到 0% 不覆盖记忆中的非零音量。<br>
  Mute preserves the previous non-zero level; unmute restores it. Zero does not overwrite remembered non-zero volume.
- 从 0.7 升级时开启自动接管一次；之后尊重用户选择。标准默认刻度保持 75%；已记住的旧增益和自定义默认值换算以保留实际倍率，旧偏好不删除。<br>
  Upgrade enables automatic attachment once, then respects later choices. The stock default stays 75%; remembered gains and custom defaults are converted to preserve actual amplitude. Legacy preferences remain intact.
- “重新连接”可重试失败会话。音频服务重启后重建订阅和路由；停止接管或退出时清理 Tap，恢复原始输出。<br>
  Reconnect retries failures. Audio-service restart rebuilds subscriptions and routes; disabling control or quitting cleans up taps and restores original output.

## 支持与限制 / Support and limitations

- 发布包仅 Apple Silicon (`arm64`)，包内最低系统限制为 macOS 18.0；本次验证环境为 macOS 26.6.2。未验证 Intel 或其他系统版本。<br>
  Apple Silicon (`arm64`) only, with a macOS 18.0 bundle minimum. Tested on macOS 26.6.2; Intel and other OS versions were not verified.
- CoreAudio 的输出活动指活动输出流，不保证其中有可听信号；应用暂停后可能仍保持流。辅助进程归并到主应用。<br>
  CoreAudio activity means an active output stream, not necessarily audible samples. Some apps retain streams while paused. Helpers are grouped under their host app.
- 按进程控制，不是网页、标签页或内部播放器音量。75% 不建立 Tap；其他刻度需系统音频权限。<br>
  Control is per process, not per webpage, browser tab or internal player. Unity needs no tap; other levels require audio consent.
- ad-hoc 签名、未经过 Developer ID 公证；更新后可能需要重新授权。不会修改钥匙串、TCC 数据库或 sudoers。<br>
  Ad-hoc signed, not Developer ID notarized. Updates may need renewed consent. No Keychain, TCC database or sudoers modifications.
- 蓝牙/USB 设备切换和真实听感仍需在用户设备验证，自动就绪不代表所有设备已经验证。<br>
  Bluetooth/USB switching and audible results still need validation on users' devices.

## 构建与验证 / Build and verify

```sh
swift run -j 1 AppVolumeControlTests
swift run -j 1 AppVolumeControl --self-check
swift build -j 1 -c release -Xswiftc -warnings-as-errors
./scripts/build-app.sh
```

`--self-check` 仅在调试构建：隔离偏好和无效音频对象验证模型，零值音频流验证真实通知，不播放测试音。<br>
Debug-only self-check uses isolated preferences and invalid audio objects for model checks, plus a zero-valued stream for real notifications without an audible tone.

产物为 `outputs/AppVolumeControl.zip` 和同名 `.sha256`，验证包含干净目录解压后的 App。Documents 文件提供器可能附加影响验签的元数据，优先使用 ZIP。<br>
The build produces a ZIP and checksum under `outputs`, verified after clean extraction. Prefer ZIP because Documents file-provider metadata may affect direct app copies.

```sh
shasum -a 256 -c AppVolumeControl.zip.sha256
# 可选稳定签名身份 / Optional stable signing identity
APP_VOLUME_SIGNING_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
```
