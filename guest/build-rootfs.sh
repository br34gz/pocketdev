#!/bin/bash
# Builds the Debian bookworm aarch64 guest rootfs for Pocket Claude.
# Runs INSIDE a debian:12-slim arm64 container (via qemu binfmt on the
# CI runner). Produces /out/rootfs.tar plus kernel + initramfs for
# direct kernel boot.
#
# Guest image v4 (v0.6.0): Alpine musl -> Debian glibc.
#
# The Bun-installed (v0.5.0, apk claude-code 2.1.108) and Node-installed
# (v0.5.1, npm claude-code 2.1.201) versions BOTH crashed on Alpine
# musl aarch64 with a nul-bytes TypeError inside the AWS SDK
# credential-provider chain. So the bug isn't runtime-specific; it's
# musl-specific (or the way Node.js on musl exposes something to the
# AWS SDK). v0.6.0 swaps the base OS to Debian bookworm, keeping
# everything else the same shape (systemd getty autologin, npm claude,
# 9p workspace mount, virtio-serial control channel).
set -eux

ROOT=/rootfs

# Outer container is debian:12-slim. Refresh + install debootstrap.
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    debootstrap rsync ca-certificates curl xz-utils zstd \
    nodejs npm

# Bootstrap Debian bookworm into $ROOT. --variant=minbase drops
# unnecessary packages; the --include set covers everything we
# actually need at runtime.
debootstrap --arch=arm64 --variant=minbase \
    --include=systemd,systemd-sysv,udev,linux-image-arm64,ifupdown,isc-dhcp-client,ca-certificates,bash,curl,git,openssh-client,nodejs,npm,ripgrep,locales,less,vim-tiny,tzdata \
    bookworm "$ROOT" http://deb.debian.org/debian/

# --- Guest OS configuration ---------------------------------------------

echo pocket-claude > "$ROOT/etc/hostname"
echo debian-12 > "$ROOT/etc/pocket-claude-os"

# claude user
chroot "$ROOT" useradd -m -s /bin/bash claude
chroot "$ROOT" passwd -d claude

# Autologin on ttyAMA0 via systemd override.
mkdir -p "$ROOT/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$ROOT/etc/systemd/system/serial-getty@ttyAMA0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin claude --noclear --keep-baud 115200,38400,9600 ttyAMA0 $TERM
Type=idle
EOF
chroot "$ROOT" systemctl enable serial-getty@ttyAMA0.service

# systemd-networkd for DHCP on virtio-net-device.
mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/10-vm.network" <<'EOF'
[Match]
Name=en*

[Network]
DHCP=ipv4
EOF
chroot "$ROOT" systemctl enable systemd-networkd systemd-resolved

# 9p workspace mount
mkdir -p "$ROOT/workspace"
cat >> "$ROOT/etc/fstab" <<'EOF'
workspace /workspace 9p trans=virtio,version=9p2000.L,msize=512000,nofail 0 0
EOF

# --- Install claude-code from npm --------------------------------------
# Run from the outer container with --prefix into the rootfs (avoids
# chroot needing /proc).
NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false \
    npm install --prefix "$ROOT/usr" -g --unsafe-perm @anthropic-ai/claude-code

if [[ ! -f "$ROOT/usr/bin/claude" ]]; then
    echo "::error::claude shim missing from $ROOT/usr/bin"
    ls "$ROOT/usr/bin" | head
    exit 1
fi

# In-container claude sanity check (arm64 chroot userspace under qemu-user).
test_home=/tmp/smoketest-home
rm -rf "$ROOT$test_home"
mkdir -p "$ROOT$test_home"
PATH="$ROOT/usr/bin:$PATH" HOME="$ROOT$test_home" \
    "$ROOT/usr/bin/claude" --version
CLAUDE_VERSION="$(PATH="$ROOT/usr/bin:$PATH" "$ROOT/usr/bin/claude" --version 2>/dev/null | head -1 || echo '(unknown)')"
CLAUDE_VARIANT="npm:@anthropic-ai/claude-code@${CLAUDE_VERSION}"

echo "$CLAUDE_VARIANT" > "$ROOT/etc/pocket-claude-variant"
echo "$CLAUDE_VERSION" > "$ROOT/etc/pocket-claude-version"
mkdir -p /out
echo "$CLAUDE_VARIANT" > /out/claude-variant.txt
echo "$CLAUDE_VERSION" > /out/claude-version.txt
echo "debian-12" > /out/guest-os.txt

# --- Claude Code environment ------------------------------------------

mkdir -p "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/claude.sh" <<'EOF'
export USE_BUILTIN_RIPGREP=0
EOF
mkdir -p "$ROOT/home/claude/.claude"
cat > "$ROOT/home/claude/.claude/settings.json" <<'EOF'
{"env": {"USE_BUILTIN_RIPGREP": "0"}}
EOF

# Login profile
cat > "$ROOT/home/claude/.profile" <<'EOF'
cd /workspace 2>/dev/null || cd "$HOME"
if [ -f /etc/pocket-claude-variant ]; then
    echo "Pocket Claude guest image"
    echo "  guest_os=$(cat /etc/pocket-claude-os 2>/dev/null || echo unknown)"
    echo "  claude_variant=$(cat /etc/pocket-claude-variant)"
fi
if command -v claude >/dev/null 2>&1; then
    if VERSION_OUT=$(claude --version 2>&1); then
        echo "claude --version: $VERSION_OUT"
    else
        RC=$?
        echo "claude --version FAILED (rc=$RC):"
        echo "$VERSION_OUT"
    fi
fi
if command -v claude >/dev/null 2>&1 && [ -z "$POCKET_CLAUDE_STARTED" ]; then
    export POCKET_CLAUDE_STARTED=1
    if ! claude; then
        RC=$?
        echo ""
        echo "claude exited unexpectedly (rc=$RC)."
        echo "Debug:"
        echo "  claude --version"
        echo "  cat /etc/pocket-claude-variant"
        echo "  cat /etc/pocket-claude-os"
        echo ""
    fi
fi
EOF
chroot "$ROOT" chown -R claude:claude /home/claude

# Control channel emitter as a systemd service.
cat > "$ROOT/etc/systemd/system/pocket-control.service" <<'EOF'
[Unit]
Description=Pocket Claude control channel emitter
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pocket-control.sh

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$ROOT/usr/local/bin"
cat > "$ROOT/usr/local/bin/pocket-control.sh" <<'EOF'
#!/bin/sh
if [ -e /dev/hvc0 ]; then
    echo "BOOT_OK" > /dev/hvc0
    if [ -f /etc/pocket-claude-variant ]; then
        echo "CLAUDE_VARIANT $(cat /etc/pocket-claude-variant)" > /dev/hvc0
    fi
    if [ -f /etc/pocket-claude-os ]; then
        echo "GUEST_OS $(cat /etc/pocket-claude-os)" > /dev/hvc0
    fi
fi
exit 0
EOF
chmod +x "$ROOT/usr/local/bin/pocket-control.sh"
chroot "$ROOT" systemctl enable pocket-control.service

# --- Slim the rootfs --------------------------------------------------
# Debian is larger than Alpine; strip caches, docs, locales.
chroot "$ROOT" apt-get clean
rm -rf "$ROOT/var/lib/apt/lists"/*
rm -rf "$ROOT/var/cache/apt"/*
rm -rf "$ROOT/usr/share/man"/*
rm -rf "$ROOT/usr/share/doc"/*
rm -rf "$ROOT/usr/share/info"/*
# Keep en_US locale, drop everything else (~100 MB save)
find "$ROOT/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
    ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true

# --- Outputs ---------------------------------------------------------

# Kernel + initramfs (Debian installs versioned files under /boot).
cp "$ROOT"/boot/vmlinuz-* /out/vmlinuz-virt
cp "$ROOT"/boot/initrd.img-* /out/initramfs-virt
rm -rf "$ROOT"/boot/*

tar -cf /out/rootfs.tar -C "$ROOT" .
du -sh "$ROOT"
ls -lh /out
echo "==== BUILD SUMMARY ===="
echo "guest_os:       debian-12"
echo "claude_variant: $CLAUDE_VARIANT"
echo "claude_version: $CLAUDE_VERSION"
