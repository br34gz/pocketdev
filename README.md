# PocketDev

**AI coding CLIs in your pocket** — a sideloaded iOS app that runs Claude Code (and, in future, other AI coding CLIs like codex) locally inside a minimal Linux VM via embedded QEMU (aarch64 emulation, serial console only). You open the app, see a terminal, and are inside a Claude Code session; QEMU, the guest OS, disk images and 9p mounts are invisible plumbing.

Historically named **Pocket Claude** — the repo and CI infrastructure still use that name. The v0.6.0 rename to PocketDev reflects the plan to add other AI coding CLIs beyond Claude Code.

Distribution is unsigned-IPA-only by design (JIT requirements + GPL components make the App Store a non-goal). Sideload via LiveContainer, SideStore or AltStore.

## Status: v0.1 — app shell (pre-M0)

What works today:

- SwiftUI app with the three-step setup wizard: workspace folder picker (security-scoped bookmark, persisted), JIT availability probe (RWX `mmap` check with StikDebug pointer), sign-in placeholder.
- Full-screen SwiftTerm terminal with an extra key row (Esc, Tab, Ctrl-C, `/`, arrows), VM state indicator, restart / open-workspace-in-Files / re-run-setup actions.
- A clearly labelled **stub VM engine** behind the `VMEngine` protocol — plays a boot banner and a local echo prompt so the whole terminal I/O path is real; the QEMU call is the only missing link.
- CI: `build-guest.yml` builds the real Alpine aarch64 guest image (rootfs via `apk --root` in an arm64 container, ext4 → qcow2 → zstd, plus kernel/initramfs for direct boot) and publishes it under the rolling `guest-latest` release. `build-ios.yml` embeds those assets into the app bundle when present and publishes the unsigned IPA.

What does not work yet: **the VM does not boot on-device.** See below.

## The QEMU-on-iOS situation (M0 blocker)

Findings as of 2026-07:

- [utmapp/QEMUKit](https://github.com/utmapp/QEMUKit) is a source-only Swift package (QMP monitor, guest agent, launcher/interface protocols). It does **not** ship QEMU binaries and requires linking glib-2.0.
- UTM's CI produces `Sysroot-ios-arm64` artifacts (~268 MB) containing qemu-aarch64-softmmu and all dependencies prebuilt as iOS frameworks — but Actions artifacts expire and need auth to download.
- The most practical binary source is the **`UTM-SE.ipa` release asset** (stable, unauthenticated URL): its `Frameworks/` directory contains the TCTI-interpreter QEMU build, which exactly matches our accepted no-JIT slow mode.

Integration plan (next iteration): add QEMUKit via SPM, extract the QEMU + glib frameworks from UTM-SE in CI, implement QEMUKit's launcher to run qemu-system-aarch64 in-process (UTM's `UTMQemuSystem` is the reference), and replace `StubVMEngine` with a `QEMUVMEngine` wired to virtio-serial. JIT provisioning is explicitly deferred — interpreter mode is the v1 fallback.

## Building

```sh
brew install xcodegen
xcodegen generate
open PocketClaude.xcodeproj
```

CI builds on every push to `main`: the IPA is published at
`https://github.com/br34gz/pocket-claude/releases/latest/download/PocketClaude-unsigned.ipa`.

The guest image builds separately (`guest/` changes or manual dispatch) and lands on the `guest-latest` prerelease as `alpine-claude.qcow2.zst` + `vmlinuz-virt` + `initramfs-virt`.

## Roadmap

- [x] App shell: wizard, SwiftTerm terminal, key row, stub engine (this release)
- [x] Guest image CI: Alpine aarch64 + Claude Code native binary, qcow2 artifact
- [ ] M0: QEMU boots the image to a serial login prompt on-device (QEMUKit + UTM-SE frameworks)
- [ ] M1: Claude Code runs; SLIRP networking against api.anthropic.com
- [ ] M2: virtio-9p workspace mount round-trips with the Files app
- [ ] M3: control channel; guided sign-in (AUTH_URL capture, Safari handoff, paste-back)
- [ ] M4: lifecycle pause/resume, memory tuning, zstd decompress-on-first-launch

## License

MIT
