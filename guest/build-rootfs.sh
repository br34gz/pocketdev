#!/bin/sh
# Builds the Alpine aarch64 guest rootfs for Pocket Claude (spec section 4).
# Runs INSIDE an arm64 alpine:3.21 container (via qemu binfmt on the CI
# runner). Produces /out/rootfs.tar plus the kernel + initramfs for direct
# kernel boot (-kernel/-initrd, console=ttyAMA0).
#
# Guest image v2 (v0.5.0): the previous image installed claude-code
# 2.1.193 from the official apk repo. That version deterministically
# crashes at interactive-startup with:
#   TypeError: The argument 'path' must be a string, Uint8Array, or URL
#   without null bytes. Received "/home/claude/.config/anthropic/active_config"
# It appears to be a Bun + Alpine musl + aarch64 compat bug in the
# credential-provider chain. This script now tries a priority-ordered
# list of install strategies with an in-container smoke test after each,
# and only publishes the image with a strategy that survives the test.
set -eux

ROOT=/rootfs
MIRROR=https://dl-cdn.alpinelinux.org/alpine/v3.21
CLAUDE_REPO=https://downloads.claude.ai/claude-code/apk/stable

mkdir -p "$ROOT/etc/apk"
cp -r /etc/apk/keys "$ROOT/etc/apk/keys"
printf '%s/main\n%s/community\n' "$MIRROR" "$MIRROR" > "$ROOT/etc/apk/repositories"

# Base system + nodejs/npm (needed for the last-resort npm strategy).
apk --root "$ROOT" --initdb --no-cache add \
    alpine-base linux-virt bash git curl openssh-client ca-certificates \
    libgcc libstdc++ ripgrep zram-init agetty \
    nodejs npm

# --- claude install with smoke test + fallback ---------------------------

install_apk_claude() {
    local pin="$1"   # e.g. claude-code=2.1.108-r1 or plain claude-code
    apk --root "$ROOT" --no-cache del claude-code 2>/dev/null || true
    rm -rf "$ROOT/usr/lib/node_modules/@anthropic-ai" "$ROOT/usr/bin/claude" 2>/dev/null || true
    if apk --root "$ROOT" --no-cache --allow-untrusted -X "$CLAUDE_REPO" add "$pin"; then
        return 0
    fi
    return 1
}

install_npm_claude() {
    apk --root "$ROOT" --no-cache del claude-code 2>/dev/null || true
    rm -rf "$ROOT/usr/lib/node_modules/@anthropic-ai" "$ROOT/usr/bin/claude" 2>/dev/null || true
    # npm needs to write to /root/.npm inside the rootfs; run it under
    # chroot so paths line up with what the guest will see at runtime.
    # --unsafe-perm is needed because npm as root refuses postinstall
    # scripts by default in a chroot without the invoking user's home.
    chroot "$ROOT" sh -c "npm config set fund false && \
                          npm config set audit false && \
                          npm install -g --unsafe-perm @anthropic-ai/claude-code" || return 1
    return 0
}

# Smoke test: --version and --help must both succeed, and neither may
# print the null-bytes error the user reported. If they do, this
# strategy is broken; caller moves on to the next candidate.
smoke_test() {
    local test_home=/tmp/smoketest-home
    rm -rf "$ROOT$test_home"
    mkdir -p "$ROOT$test_home/.config/anthropic"
    if ! chroot "$ROOT" env HOME="$test_home" /usr/bin/claude --version 2>/tmp/sm.err >/tmp/sm.out; then
        echo "smoke: --version exited nonzero"
        cat /tmp/sm.err || true
        return 1
    fi
    if ! grep -qE "^[0-9]|Claude" /tmp/sm.out; then
        echo "smoke: --version output looks wrong"
        cat /tmp/sm.out
        return 1
    fi
    if ! chroot "$ROOT" env HOME="$test_home" /usr/bin/claude --help 2>/tmp/sm.err >/tmp/sm.out; then
        echo "smoke: --help exited nonzero"
        cat /tmp/sm.err
        # not fatal by itself
    fi
    if grep -qE "null bytes|TypeError" /tmp/sm.err /tmp/sm.out; then
        echo "smoke: BUG reproduced (null bytes / TypeError in output)"
        return 1
    fi
    # Also try to force the credential-provider chain to init. `claude
    # config list` and `claude auth status` both hit the same startup
    # path where the bug fires.
    for probe in "config list" "auth status"; do
        chroot "$ROOT" env HOME="$test_home" timeout 5 /usr/bin/claude $probe \
            >/tmp/sm.out 2>/tmp/sm.err || true
        if grep -qE "null bytes|TypeError" /tmp/sm.err /tmp/sm.out; then
            echo "smoke: BUG reproduced via '$probe'"
            return 1
        fi
    done
    echo "smoke: passed"
    return 0
}

# Priority list of install strategies. Format:
#   apk:<pin>        installs via apk from the official repo
#   npm              installs @anthropic-ai/claude-code from npmjs
# First one that passes smoke_test wins. Order chosen to try apk-old
# first (smallest install, native binary), fall through the apk range,
# and only reach for npm when everything else is broken.
STRATEGIES="\
apk:claude-code=2.1.108-r1
apk:claude-code=2.1.128-r1
apk:claude-code=2.1.150-r1
apk:claude-code=2.1.170-r1
apk:claude-code
npm"

CLAUDE_VARIANT=""
CLAUDE_VERSION=""
for strategy in $STRATEGIES; do
    echo "==== trying strategy: $strategy ===="
    case "$strategy" in
        apk:*)
            pin="${strategy#apk:}"
            install_apk_claude "$pin" || continue
            ;;
        npm)
            install_npm_claude || continue
            ;;
    esac
    if smoke_test; then
        CLAUDE_VARIANT="$strategy"
        CLAUDE_VERSION="$(chroot "$ROOT" /usr/bin/claude --version 2>/dev/null | head -1)"
        break
    fi
done

if [ -z "$CLAUDE_VARIANT" ]; then
    echo "::warning::no working claude variant survived smoke tests -- shell-only image"
    apk --root "$ROOT" --no-cache del claude-code 2>/dev/null || true
    CLAUDE_VARIANT="none"
    CLAUDE_VERSION="(no claude installed)"
fi

# Stash the variant so the guest can broadcast it over the control channel
# and the release-notes writer can see which strategy landed.
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

# Login profile: land in /workspace and run claude; exiting claude drops
# to a plain shell (escape hatch for debugging).
cat > "$ROOT/home/claude/.profile" <<'EOF'
cd /workspace 2>/dev/null || cd "$HOME"
if [ -f /etc/pocket-claude-variant ]; then
    echo "Pocket Claude guest image (claude_variant=$(cat /etc/pocket-claude-variant))"
fi
if command -v claude >/dev/null 2>&1 && [ -z "$POCKET_CLAUDE_STARTED" ]; then
    export POCKET_CLAUDE_STARTED=1
    claude
    echo "claude exited - you are in a plain shell (run 'claude' to restart)"
fi
EOF
chroot "$ROOT" chown -R claude:claude /home/claude

# Control channel (spec section 4.6): emit BOOT_OK on the second
# virtio-serial port once boot completes, plus the claude variant tag.
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
