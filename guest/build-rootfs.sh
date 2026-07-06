#!/bin/sh
# Builds the Alpine aarch64 guest rootfs for Pocket Claude (spec section 4).
# Runs INSIDE an arm64 alpine:3.21 container (via qemu binfmt on the CI
# runner). Produces /out/rootfs.tar plus the kernel + initramfs for direct
# kernel boot (-kernel/-initrd, console=ttyAMA0).
set -eux

ROOT=/rootfs
MIRROR=https://dl-cdn.alpinelinux.org/alpine/v3.21
CLAUDE_REPO=https://downloads.claude.ai/claude-code/apk/stable

mkdir -p "$ROOT/etc/apk"
cp -r /etc/apk/keys "$ROOT/etc/apk/keys"
printf '%s/main\n%s/community\n' "$MIRROR" "$MIRROR" > "$ROOT/etc/apk/repositories"

# Base system: alpine-base + virt kernel + Claude Code runtime deps
# (libgcc/libstdc++/ripgrep per spec) + agetty for autologin + zram swap.
apk --root "$ROOT" --initdb --no-cache add \
    alpine-base linux-virt bash git curl openssh-client ca-certificates \
    libgcc libstdc++ ripgrep zram-init agetty

# Claude Code native binary (linux-arm64-musl) from the official apk repo.
# TODO: verify the repo signature once the public key location is
# documented (the index is signed with claude-code.rsa.pub but the key is
# not published at a discoverable URL as of 2026-07). Transport is HTTPS.
apk --root "$ROOT" --no-cache --allow-untrusted -X "$CLAUDE_REPO" add claude-code \
    || echo "WARNING: claude-code install failed; image boots to plain shell"

# --- Guest configuration -------------------------------------------------

echo pocket-claude > "$ROOT/etc/hostname"

# SLIRP user-mode networking defaults
echo "nameserver 10.0.2.3" > "$ROOT/etc/resolv.conf"
cat > "$ROOT/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF

# claude user with bash shell
chroot "$ROOT" /usr/sbin/adduser -D -s /bin/bash claude

# Autologin on the PL011 serial console (spec section 4.5)
cat > "$ROOT/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyAMA0::respawn:/sbin/agetty --autologin claude --noclear ttyAMA0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# 9p workspace mount (host exports the security-scoped folder as "workspace")
mkdir -p "$ROOT/workspace"
cat >> "$ROOT/etc/fstab" <<'EOF'
workspace /workspace 9p trans=virtio,version=9p2000.L,msize=512000,nofail 0 0
EOF

# Claude Code environment (native ripgrep, spec section 4.3-4.4)
mkdir -p "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/claude.sh" <<'EOF'
export USE_BUILTIN_RIPGREP=0
EOF
mkdir -p "$ROOT/home/claude/.claude"
cat > "$ROOT/home/claude/.claude/settings.json" <<'EOF'
{"env": {"USE_BUILTIN_RIPGREP": "0"}}
EOF

# Login profile: land in /workspace and run claude; exiting claude drops to
# a plain shell (escape hatch for debugging) rather than respawn-looping.
cat > "$ROOT/home/claude/.profile" <<'EOF'
cd /workspace 2>/dev/null || cd "$HOME"
if command -v claude >/dev/null 2>&1 && [ -z "$POCKET_CLAUDE_STARTED" ]; then
    export POCKET_CLAUDE_STARTED=1
    claude
    echo "claude exited - you are in a plain shell (run 'claude' to restart)"
fi
EOF
chroot "$ROOT" chown -R claude:claude /home/claude

# Control channel (spec section 4.6): emit BOOT_OK on the second
# virtio-serial port once boot completes. AUTH_URL / CLAUDE_EXIT events are
# TODO for M3.
mkdir -p "$ROOT/etc/local.d"
cat > "$ROOT/etc/local.d/pocket-control.start" <<'EOF'
#!/bin/sh
[ -e /dev/hvc0 ] && echo "BOOT_OK" > /dev/hvc0
exit 0
EOF
chmod +x "$ROOT/etc/local.d/pocket-control.start"

# Enable services: local (control channel), zram swap, networking
chroot "$ROOT" rc-update add local default || true
chroot "$ROOT" rc-update add zram-init boot || true
chroot "$ROOT" rc-update add networking boot || true
cat > "$ROOT/etc/conf.d/zram-init" <<'EOF'
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
size0=256
EOF

# --- Outputs -------------------------------------------------------------

# Kernel + initramfs leave the image; QEMU boots them directly (-kernel).
cp "$ROOT"/boot/vmlinuz-virt /out/vmlinuz-virt
cp "$ROOT"/boot/initramfs-virt /out/initramfs-virt
rm -rf "$ROOT"/boot/*

tar -cf /out/rootfs.tar -C "$ROOT" .
du -sh "$ROOT"
ls -lh /out
