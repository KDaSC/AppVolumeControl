# Passive automatic gain implementation plan

Goal: detect newly audible applications while the panel is closed, make every app automatically adjustable, use 75% as unity and 100% as 4/3 gain, and provide native audio-consent entry points. User approved amplification and continuing through publication.

Design decisions:

- Reuse the existing menu-bar process. Subscribe to the CoreAudio process list, each process's output state/device list, and the default output device. Coalesce notifications for 100 ms without indefinitely postponing delivery. A single delayed expiry handles the existing inactive grace period. Remove the one-second discovery timer.
- Display levels remain 0…1. The audio backend receives `display / 0.75`. Unity bypasses Tap creation; attenuation, boost and mute use the same existing Process Tap. Clamp boosted samples to [-1, 1]; this can distort already loud peaks and is not a dynamic limiter.
- All apps use relative process output control. Remove the AppleScript backend so internal player volume is left alone and Automation permission is unnecessary.
- Default auto-ready is true. Upgrade v4 defaults once; migrate saved actual gains to the new display scale, retain original v4 data, preserve v5 choices on subsequent launches. The stock 75% default becomes unity; customized old defaults preserve their amplitude.
- Request audio consent using a temporary private, unmuted Tap with no source processes. Destroy it immediately. Report request results honestly: Tap creation success does not prove capture authorization. Offer a direct System Settings link and explicit retry. No credential field, root helper, sudoers or TCC edits.
- Use a fresh checkout from released main because the older Documents checkout contains dataless cloud files. Preserve both previous checkouts.

Implementation and verification:

1. Add failing scale/automatic-default tests, then implement conversion, actual C gain range and peak bounding. Verify unity, mute, 4/3 gain and saved-gain migration.
2. Add/remove native listeners symmetrically; coalesce refreshes and queue a refresh when discovery is already running. Handle grace expiry without periodic polling. Verify actual CoreAudio notifications with a silent generated audio source, without playing user media.
3. Wire settings consent, retry, automatic-state UI, lifecycle notifications and error reporting. Add debug-only model and isolated preferences checks; no self-test code in the release build.
4. Build with `swift run -j 1 AppVolumeControlTests`, debug integration checks and `swift build -j 1 -c release -Xswiftc -warnings-as-errors`. Package with `scripts/build-app.sh`, verify ZIP SHA, clean-extract codesign, architecture/version and measured sizes. Inspect UI and sample open/closed CPU/RSS.
5. Update bilingual README and release notes for v0.8.0 / Build 9. Publish reviewed branch through PR, merge, publish pre-release, download the remote assets and verify against local artifacts. Update About link and report limits.

Permission reference: [Apple audio consent](https://support.apple.com/en-gb/guide/mac-help/mchl2844ecab/mac). The likely [StayAwake reference](https://github.com/TY-teo/StayAwake) uses privileged pmset commands; that is a different authority from system-audio privacy consent.
