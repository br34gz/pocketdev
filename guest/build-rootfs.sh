#!/bin/bash
# Builds the Debian bookworm aarch64 guest rootfs for PocketDev.
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

echo pocketdev > /etc/hostname
echo debian-12 > /etc/pocketdev-os
echo "$CLAUDE_VARIANT" > /etc/pocketdev-variant
echo "$CLAUDE_VERSION" > /etc/pocketdev-version

# dev user
useradd -m -s /bin/bash dev
passwd -d dev || true

# Autologin: bypass systemd's init entirely. Both v0.6.0's serial-getty
# override and v0.6.1's pocket-console.service failed to preempt the
# systemd-getty-generator's auto-spawn of serial-getty@ttyAMA0 (the
# `pocketdev login:` prompt from agetty kept winning the tty). Ship
# our own /pocket-init as the kernel's PID 1: it handles the minimum
# viable Linux userspace we need (proc/sys/dev mounts, loopback, DHCP,
# 9p workspace mount, control-channel emit) then execs bash as the
# dev user with a fresh login shell that sources ~/.profile.
#
# systemd is still installed for the odd shell utility we may want
# later, but we never run it as init - the kernel append gets
# init=/pocket-init.

cat > /pocket-init <<'INIT_EOF'
#!/bin/bash
# PocketDev VM init - runs as PID 1. Sets up minimum viable userspace
# then hands the console tty to the dev user's shell.
set +e  # tolerate individual step failures; boot into shell regardless
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM=vt100

mount -t proc     proc     /proc     2>/dev/null
mount -t sysfs    sysfs    /sys      2>/dev/null
mount -t devtmpfs devtmpfs /dev      2>/dev/null
mkdir -p /dev/pts /dev/shm /run
mount -t devpts   devpts   /dev/pts  2>/dev/null
mount -t tmpfs    tmpfs    /dev/shm  2>/dev/null
mount -t tmpfs    tmpfs    /run      2>/dev/null

# Apply hostname from /etc/hostname (systemd would do this; we don't
# run systemd, so we do it manually).
if [ -f /etc/hostname ]; then
    hostname "$(cat /etc/hostname)" 2>/dev/null
fi

# Bring up loopback + DHCP on the virtio-net-device iface (name is
# usually enp0s* under systemd but with our own init it comes up as
# eth0). Try common names.
ip link set lo up 2>/dev/null
for iface in eth0 enp0s1 enp0s2 ens1 ens2; do
    if ip link show "$iface" >/dev/null 2>&1; then
        ip link set "$iface" up 2>/dev/null
        dhclient -1 -v "$iface" >/tmp/dhclient.log 2>&1 && break
    fi
done

# Static DNS for SLIRP (dhclient may or may not populate resolv.conf).
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# 9p workspace (optional in CI, present on-device).
mkdir -p /workspace
mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 workspace /workspace 2>/dev/null

# Control channel: emit BOOT_OK + variant + os on hvc0 if present.
if [ -e /dev/hvc0 ]; then
    (
        echo "BOOT_OK"
        [ -f /etc/pocketdev-variant ] && echo "CLAUDE_VARIANT $(cat /etc/pocketdev-variant)"
        [ -f /etc/pocketdev-os ]      && echo "GUEST_OS $(cat /etc/pocketdev-os)"
    ) > /dev/hvc0 2>/dev/null &
fi

# Hand the console over to the user's shell. login(1) -f dev:
#   - skips password auth
#   - preserves ~/.profile execution
#   - creates a real login session with proper $HOME etc
# setsid --ctty gives login a controlling tty so signals + job control
# work correctly.
cd /home/dev 2>/dev/null || cd /

# On PID 1 we need to become the session leader on our ctty. The
# kernel already has /dev/console wired to ttyAMA0 (because of the
# console=ttyAMA0 kernel arg), so our stdin/stdout/stderr are that.
exec setsid --ctty /bin/login -f dev </dev/console >/dev/console 2>&1
INIT_EOF
chmod +x /pocket-init

# Skip systemd entirely - see kernel append below.

# Static SLIRP resolv.conf (also written by /pocket-init at boot).
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# 9p workspace fstab entry retained for reference / manual mount use,
# but /pocket-init does the mount at boot before /etc/fstab is read.
mkdir -p /workspace
cat >> /etc/fstab <<'EOF'
workspace /workspace 9p trans=virtio,version=9p2000.L,msize=512000,nofail 0 0
EOF

# --- Claude Code environment ------------------------------------------

mkdir -p /etc/profile.d
cat > /etc/profile.d/claude.sh <<'EOF'
export USE_BUILTIN_RIPGREP=0
# v0.7.3: Bun runs claude-code. Its embedded JavaScriptCore hits
# increasingly obscure assertions under QEMU TCTI aarch64 emulation
# as we disable higher tiers:
#   v0.7.1 -> DFG SpeculativeJIT isFlushed() assertion. Killed DFG.
#   v0.7.2 -> concurrent GC "Block marks not empty" race. Killed here.
# Bun bails on the FIRST invalid JSC option name it sees (verified in
# v0.7.3 CI where useThreadedGC didn't exist and Bun refused to start).
# Only ship options we've confirmed exist in this Bun version:
export BUN_JSC_useJIT=0                # Kill ALL JIT tiers -> LLInt only.
export BUN_JSC_useConcurrentGC=0       # Kills the concurrent-marking race.
# Belt-and-braces heap cap so we don't push against the guest's RAM.
export NODE_OPTIONS="--max-old-space-size=512"
EOF
mkdir -p /home/dev/.claude
cat > /home/dev/.claude/settings.json <<'EOF'
{"env": {"USE_BUILTIN_RIPGREP": "0"}}
EOF

# Login profile
cat > /home/dev/.profile <<'EOF'
cd /workspace 2>/dev/null || cd "$HOME"
if [ -f /etc/pocketdev-variant ]; then
    echo "PocketDev guest image"
    echo "  guest_os=$(cat /etc/pocketdev-os 2>/dev/null || echo unknown)"
    echo "  claude_variant=$(cat /etc/pocketdev-variant)"
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
if command -v claude >/dev/null 2>&1 && [ -z "$POCKETDEV_STARTED" ]; then
    export POCKETDEV_STARTED=1
    if ! claude; then
        RC=$?
        echo ""
        echo "claude exited unexpectedly (rc=$RC)."
        echo "Debug:"
        echo "  claude --version"
        echo "  cat /etc/pocketdev-variant"
        echo "  cat /etc/pocketdev-os"
        echo ""
    fi
fi
EOF
chown -R dev:dev /home/dev

# Control channel is now emitted directly by /pocket-init (see above),
# so no separate service is needed. The systemd unit that used to live
# here has been removed in v0.7.0 since we no longer run systemd.

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
