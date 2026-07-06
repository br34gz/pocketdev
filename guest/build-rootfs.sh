#!/bin/sh
# Builds the Alpine aarch64 guest rootfs for Pocket Claude (spec section 4).
# Runs INSIDE an arm64 alpine:3.21 container (via qemu binfmt on the CI
# runner). Produces /out/rootfs.tar plus the kernel + initramfs for direct
# kernel boot (-kernel/-initrd, console=ttyAMA0).
#
# Guest image v3 (v0.5.1): every apk build of claude-code is Bun-compiled
# and both versions we've tried (2.1.193 -> null-bytes crash, 2.1.108 ->
# 'Module not found /$bunfs/root/src/entrypoints/cli.js') fail on
# Alpine musl aarch64 in different ways. Bun's embedded-filesystem
# virtualisation appears fundamentally broken in that combination.
#
# v0.5.1 pivots to the npm-registry variant: same claude-code source but
# installed on top of Node.js, so it never touches Bun's bunfs. Different
# runtime, different fs code path, doesn't share the failing property.
set -eux

ROOT=/rootfs
MIRROR=https://dl-cdn.alpinelinux.org/alpine/v3.21

mkdir -p "$ROOT/etc/apk"
cp -r /etc/apk/keys "$ROOT/etc/apk/keys"
printf '%s/main\n%s/community\n' "$MIRROR" "$MIRROR" > "$ROOT/etc/apk/repositories"

# Install nodejs + npm in BOTH the outer arm64 container and the rootfs.
# We install claude-code globally from the outer container's npm with
# --prefix pointing at $ROOT/usr (avoids the chroot-npm-needs-/proc
# problem that killed our first two attempts). At runtime the guest
# runs the rootfs's copy of node.
apk add --no-cache nodejs npm

# Base system + Node.js/npm + native ripgrep (spec section 4.3).
apk --root "$ROOT" --initdb --no-cache add \
    alpine-base linux-virt bash git curl openssh-client ca-certificates \
    libgcc libstdc++ ripgrep zram-init agetty \
    nodejs npm

# --- Install claude-code from the npm registry ---------------------------
# Runs from the OUTER container with --prefix pointing into the rootfs.
# --unsafe-perm lets npm run install scripts as root (default refuses).
# DNS matters here for registry.npmjs.org resolution; outer container
# already has working DNS via Docker.
NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false \
    npm install --prefix "$ROOT/usr" -g --unsafe-perm @anthropic-ai/claude-code

# Fixup any host-container symlinks that npm may have baked in - the
# `claude` bin should point to the module in $ROOT/usr/lib, which it
# does by virtue of --prefix. Verify.
ls -la "$ROOT/usr/bin/claude" || {
    echo "::error::claude shim missing from $ROOT/usr/bin"
    ls "$ROOT/usr/bin" | head
    exit 1
}

# In-container smoke check. We use the rootfs's node (arm64) rather than
# the outer container's (also arm64 under qemu-user binfmt but a
# different install). Setting PATH ensures /usr/bin/env node in claude's
# shebang resolves to the rootfs binary.
test_home=/tmp/smoketest-home
rm -rf "$ROOT$test_home"
mkdir -p "$ROOT$test_home/.config/anthropic"
PATH="$ROOT/usr/bin:$PATH" HOME="$ROOT$test_home" \
    "$ROOT/usr/bin/claude" --version
CLAUDE_VERSION="$(PATH="$ROOT/usr/bin:$PATH" "$ROOT/usr/bin/claude" --version 2>/dev/null | head -1 || echo '(unknown)')"
CLAUDE_VARIANT="npm:@anthropic-ai/claude-code@${CLAUDE_VERSION}"

echo "$CLAUDE_VARIANT" > "$ROOT/etc/pocket-claude-variant"
echo "$CLAUDE_VERSION" > "$ROOT/etc/pocket-claude-version"
mkdir -p /out
echo "$CLAUDE_VARIANT" > /out/claude-variant.txt
echo "$CLAUDE_VERSION" > /out/claude-version.txt

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

# Login profile: banner, sanity-check claude --version, then run claude
# interactively. On non-zero exit print a helpful diagnostic and drop to
# a plain shell so the user can poke at what went wrong.
cat > "$ROOT/home/claude/.profile" <<'EOF'
cd /workspace 2>/dev/null || cd "$HOME"
if [ -f /etc/pocket-claude-variant ]; then
    echo "Pocket Claude guest image (claude_variant=$(cat /etc/pocket-claude-variant))"
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
        echo "  which claude && head -2 \$(which claude)"
        echo ""
    fi
fi
EOF
chroot "$ROOT" chown -R claude:claude /home/claude

# Control channel (spec section 4.6): emit BOOT_OK on hvc0 once boot
# completes, plus the claude variant tag.
mkdir -p "$ROOT/etc/local.d"
cat > "$ROOT/etc/local.d/pocket-control.start" <<'EOF'
#!/bin/sh
if [ -e /dev/hvc0 ]; then
    echo "BOOT_OK" > /dev/hvc0
    if [ -f /etc/pocket-claude-variant ]; then
        echo "CLAUDE_VARIANT $(cat /etc/pocket-claude-variant)" > /dev/hvc0
    fi
fi
exit 0
EOF
chmod +x "$ROOT/etc/local.d/pocket-control.start"

# Enable services
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

cp "$ROOT"/boot/vmlinuz-virt /out/vmlinuz-virt
cp "$ROOT"/boot/initramfs-virt /out/initramfs-virt
rm -rf "$ROOT"/boot/*

tar -cf /out/rootfs.tar -C "$ROOT" .
du -sh "$ROOT"
ls -lh /out
echo "==== BUILD SUMMARY ===="
echo "claude_variant: $CLAUDE_VARIANT"
echo "claude_version: $CLAUDE_VERSION"
