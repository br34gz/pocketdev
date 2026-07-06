#!/bin/bash
# Builds the Debian bookworm aarch64 guest rootfs for Pocket Claude.
# Runs INSIDE a debian:12-slim arm64 container (via qemu binfmt on the
# CI runner). Produces /out/rootfs.tar plus kernel + initramfs for
# direct kernel boot.
#
# Guest image v4 (v0.6.0): Alpine musl -> Debian glibc.
#
# Both v0.5.0 (apk claude, Bun) and v0.5.1 (npm claude, Node) crashed
# interactively with a nul-bytes TypeError inside the AWS SDK
# credential-provider chain on Alpine musl aarch64. Swapping the
# runtime made no difference so the bug isn't Bun-specific; musl is
# the common denominator.
#
# NOTE ON APPROACH: v0.6.0's first attempt used debootstrap inside the
# arm64 container. That double-emulates (qemu-user host -> arm64
# container -> emulated dpkg per package) and hit the 45-minute
# workflow timeout. This rewrite skips debootstrap entirely: the
# arm64 container IS a Debian aarch64 rootfs, so we just install
# what we need and tar it up.
set -eux

export DEBIAN_FRONTEND=noninteractive

# Update + install everything we need at runtime.
apt-get update -q
apt-get install -y --no-install-recommends \
    systemd systemd-sysv udev dbus \
    linux-image-arm64 \
    ifupdown isc-dhcp-client ca-certificates \
    bash curl git openssh-client \
    nodejs npm ripgrep \
    locales less vim-tiny tzdata rsync

# --- Install claude-code from npm ---------------------------------------
# Debian's npm defaults to prefix=/usr/local, so binaries land at
# /usr/local/bin/claude (not /usr/bin/claude like Alpine).
NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false \
    npm install -g --unsafe-perm @anthropic-ai/claude-code

CLAUDE_BIN=""
for candidate in /usr/local/bin/claude /usr/bin/claude; do
    if [[ -f "$candidate" ]]; then CLAUDE_BIN="$candidate"; break; fi
done
if [[ -z "$CLAUDE_BIN" ]]; then
    echo "::error::claude shim not found in /usr/local/bin or /usr/bin"
    find /usr -name claude 2>/dev/null | head
    exit 1
fi
echo "claude installed at $CLAUDE_BIN"

# Sanity check
CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo '(unknown)')"
CLAUDE_VARIANT="npm:@anthropic-ai/claude-code@${CLAUDE_VERSION}"

# --- Guest OS configuration ---------------------------------------------

echo pocket-claude > /etc/hostname
echo debian-12 > /etc/pocket-claude-os
echo "$CLAUDE_VARIANT" > /etc/pocket-claude-variant
echo "$CLAUDE_VERSION" > /etc/pocket-claude-version

# claude user
useradd -m -s /bin/bash claude
passwd -d claude || true

# Autologin on ttyAMA0. v0.6.0's serial-getty@ttyAMA0.service override
# never landed the --autologin arg (systemctl enable inside a
# build-time chroot without a running systemd is unreliable for
# template units, and even manual symlinks didn't cause the drop-in
# to apply). Skip the getty templating layer entirely: mask
# serial-getty@ttyAMA0 so it can't fight for the tty, then run our
# own pocket-console.service that invokes /bin/login -f claude
# on ttyAMA0 directly. login(1) -f skips password auth and still
# sources /etc/profile + ~/.profile so all our env setup works.
ln -sf /dev/null /etc/systemd/system/serial-getty@ttyAMA0.service

cat > /etc/systemd/system/pocket-console.service <<'EOF'
[Unit]
Description=PocketDev console (autologin as claude on ttyAMA0)
After=systemd-user-sessions.service pocket-control.service
Conflicts=serial-getty@ttyAMA0.service
Before=getty.target
RefuseManualStop=no

[Service]
Type=idle
Environment=TERM=vt100
TTYPath=/dev/ttyAMA0
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=tty
StandardError=tty
ExecStart=/bin/login -f claude
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/pocket-console.service \
    /etc/systemd/system/multi-user.target.wants/pocket-console.service

# systemd-networkd for DHCP on virtio-net-device.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-vm.network <<'EOF'
[Match]
Name=en*

[Network]
DHCP=ipv4
EOF
systemctl enable systemd-networkd
# systemd-resolved not shipped by default in this Debian package set;
# rely on the SLIRP-provided /etc/resolv.conf (systemd-networkd may
# write a NetworkManager-style one but we set nameserver 10.0.2.3
# explicitly).
mkdir -p /etc
cat > /etc/resolv.conf <<'EOF'
nameserver 10.0.2.3
EOF

# 9p workspace mount
mkdir -p /workspace
cat >> /etc/fstab <<'EOF'
workspace /workspace 9p trans=virtio,version=9p2000.L,msize=512000,nofail 0 0
EOF

# --- Claude Code environment ------------------------------------------

mkdir -p /etc/profile.d
cat > /etc/profile.d/claude.sh <<'EOF'
export USE_BUILTIN_RIPGREP=0
EOF
mkdir -p /home/claude/.claude
cat > /home/claude/.claude/settings.json <<'EOF'
{"env": {"USE_BUILTIN_RIPGREP": "0"}}
EOF

# Login profile
cat > /home/claude/.profile <<'EOF'
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
chown -R claude:claude /home/claude

# Control channel emitter as a systemd oneshot.
cat > /etc/systemd/system/pocket-control.service <<'EOF'
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
mkdir -p /usr/local/bin
cat > /usr/local/bin/pocket-control.sh <<'EOF'
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
chmod +x /usr/local/bin/pocket-control.sh
systemctl enable pocket-control.service

# --- Slim ----------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*
rm -rf /usr/share/man/*
rm -rf /usr/share/doc/*
rm -rf /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
    ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true

# --- Outputs -------------------------------------------------------
# Kernel + initramfs land in /boot after linux-image-arm64 install.
mkdir -p /out
cp /boot/vmlinuz-* /out/vmlinuz-virt
cp /boot/initrd.img-* /out/initramfs-virt

echo "$CLAUDE_VARIANT" > /out/claude-variant.txt
echo "$CLAUDE_VERSION" > /out/claude-version.txt
echo "debian-12" > /out/guest-os.txt

# Tar up /, excluding runtime mounts + our /out mount + /boot (already copied).
tar --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./tmp/*' --exclude='./run/*' --exclude='./mnt/*' \
    --exclude='./out' --exclude='./boot/*' \
    --exclude='./var/log/*' --exclude='./var/cache/*' \
    -cf /out/rootfs.tar -C / .

du -sh /out
ls -lh /out
echo "==== BUILD SUMMARY ===="
echo "guest_os:       debian-12"
echo "claude_variant: $CLAUDE_VARIANT"
echo "claude_version: $CLAUDE_VERSION"
