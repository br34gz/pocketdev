#!/usr/bin/env python3
"""
Full system-mode QEMU boot smoke test for the guest qcow2.

Runs on ubuntu-latest CI. Boots the packed image with the same layout
the iOS app uses (direct kernel, virtio-net-device MMIO, virtio-serial
control channel, unix-socket console + control chardevs) and watches
the console for either:

  PASS - "claude --version: X.Y.Z" printed by the .profile probe
         WITHOUT any of the known Bun-crash markers appearing.
  FAIL - "Module not found" / "TypeError" / "null bytes" seen on
         the console at any point before PASS.

Times out after TIMEOUT_S seconds; interpreter-mode boot of Alpine +
Node.js startup on x86_64 CI is slow but should be well under 5 min.
"""
from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
import time

TIMEOUT_S = 600  # 10 minutes hard ceiling
CONSOLE_SOCK = "/tmp/smoke-console.sock"
CONTROL_SOCK = "/tmp/smoke-control.sock"
SUCCESS_RE = re.compile(rb"claude --version:\s*([0-9]+\.[0-9]+\.[0-9]+)")
# The .profile prints "claude --version" FIRST, then runs interactive
# `claude`. v0.5.1 got a clean version line but interactive claude
# still hit the null-bytes crash. Watch for the crash for INTERACTIVE_WATCH_S
# after seeing the version line and only declare PASS at the end of that
# window if nothing bad printed.
INTERACTIVE_WATCH_S = 60
FAIL_MARKERS = [
    b"Module not found",
    b"null bytes",
    b"TypeError",
    b"Kernel panic",
    b"Segmentation fault",
    b"claude --version FAILED",
    b"claude exited unexpectedly",
]


def start_qemu(qcow2: str, kernel: str, initrd: str) -> subprocess.Popen:
    """Boot the guest with the same argv shape the iOS app uses."""
    for p in (CONSOLE_SOCK, CONTROL_SOCK):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    args = [
        "qemu-system-aarch64",
        "-M", "virt",
        "-cpu", "cortex-a72",
        "-smp", "2",
        "-m", "1024",
        "-display", "none",
        "-nodefaults",
        "-no-user-config",
        "-kernel", kernel,
        "-initrd", initrd,
        "-append", "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw quiet",
        "-drive", f"file={qcow2},if=virtio,format=qcow2",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-device,netdev=net0",
        "-chardev", f"socket,id=console0,path={CONSOLE_SOCK},server=on,wait=off",
        "-serial", "chardev:console0",
        "-device", "virtio-serial-device,id=vser0",
        "-chardev", f"socket,id=ctrl0,path={CONTROL_SOCK},server=on,wait=off",
        "-device", "virtserialport,chardev=ctrl0,name=pocket.control",
    ]
    print("== launching qemu ==")
    print(" ".join(args))
    return subprocess.Popen(args)


def connect_sock(path: str, retries: int = 60, delay: float = 0.5):
    for _ in range(retries):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.setblocking(False)
            return s
        except OSError:
            time.sleep(delay)
    return None


def main() -> int:
    if len(sys.argv) < 4:
        print(f"usage: {sys.argv[0]} <qcow2> <vmlinuz> <initramfs>", file=sys.stderr)
        return 2
    qcow2, kernel, initrd = sys.argv[1:4]

    qemu = start_qemu(qcow2, kernel, initrd)
    try:
        console = connect_sock(CONSOLE_SOCK)
        control = connect_sock(CONTROL_SOCK)
        if not console or not control:
            print("SMOKE FAIL: could not connect chardev sockets")
            return 1

        console_buffer = b""
        control_buffer = b""
        deadline = time.time() + TIMEOUT_S
        boot_ok = False
        claude_variant = None
        guest_os = None
        detected_version = None
        version_seen_at = None  # timestamp when we first saw --version

        while time.time() < deadline:
            for name, sock, buf_name in (
                ("console", console, "console_buffer"),
                ("control", control, "control_buffer"),
            ):
                try:
                    data = sock.recv(4096)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    print(f"SMOKE FAIL: {name} sock err {exc}")
                    return 1
                if not data:
                    continue
                if name == "console":
                    console_buffer += data
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                else:
                    control_buffer += data
                    # Handle CR+LF or LF
                    while b"\n" in control_buffer:
                        line, control_buffer = control_buffer.split(b"\n", 1)
                        line = line.strip()
                        text = line.decode("utf-8", "replace")
                        print(f"[control] {text}")
                        if text == "BOOT_OK":
                            boot_ok = True
                        elif text.startswith("CLAUDE_VARIANT "):
                            claude_variant = text[len("CLAUDE_VARIANT "):]
                        elif text.startswith("GUEST_OS "):
                            guest_os = text[len("GUEST_OS "):]

            for marker in FAIL_MARKERS:
                if marker in console_buffer:
                    print(f"\nSMOKE FAIL: caught fail marker: {marker.decode()}")
                    print(f"  boot_ok={boot_ok}, claude_variant={claude_variant}, "
                          f"guest_os={guest_os}, detected_version={detected_version}")
                    return 1

            if version_seen_at is None:
                m = SUCCESS_RE.search(console_buffer)
                if m:
                    detected_version = m.group(1).decode()
                    version_seen_at = time.time()
                    print(
                        f"\n[smoke] --version -> {detected_version}. "
                        f"Watching interactive claude for {INTERACTIVE_WATCH_S}s..."
                    )
            elif time.time() - version_seen_at > INTERACTIVE_WATCH_S:
                # Held the interactive window open long enough with no fail
                # markers - declare PASS.
                print(
                    f"\nSMOKE PASS: claude --version -> {detected_version} "
                    f"and interactive claude survived {INTERACTIVE_WATCH_S}s "
                    f"without a crash marker "
                    f"(claude_variant={claude_variant}, guest_os={guest_os}, "
                    f"boot_ok={boot_ok})"
                )
                return 0

            time.sleep(0.1)

        print(f"\nSMOKE FAIL: timed out after {TIMEOUT_S}s")
        print(f"boot_ok={boot_ok}, claude_variant={claude_variant}")
        return 1
    finally:
        try:
            qemu.terminate()
            qemu.wait(timeout=10)
        except Exception:
            qemu.kill()


if __name__ == "__main__":
    sys.exit(main())
