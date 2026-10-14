#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VenaX 2.0 ISO builder  --  plug-and-play local AI server OS
# ============================================================
# Boot from USB -> NetworkManager brings up whatever link exists
# (Wi-Fi LAN, laptop/phone hotspot, Ethernet) -> the VenaX web UI on
# :8080 becomes the control panel -> Ollama runs locally on
# 127.0.0.1:11434 and is only reachable through the web proxy.
#
# Architecture (see also the notes printed at the end of the build):
#
#   client browser --HTTP:8080--> venax-web (user venax-web, unprivileged)
#                                   |-- 127.0.0.1:11434 --> ollama (user ollama)
#                                   '-- /run/venax/agent.sock --> venax-agent (root,
#                                        whitelisted operations only, no shell API)
#   systemd orders: venax-data -> ollama / venax-agent -> venax-web (venax.target)
#   venax-console (tty1) only OBSERVES and shows the URL; it starts nothing.
#
# Ollama archive: kept in  VenaX/ollama/  and copied from there on every build.
# It is only downloaded if no local archive is present. Download it once with:
#   mkdir -p ollama && cd ollama
#   wget -c --progress=bar:force \
#     https://github.com/ollama/ollama/releases/download/v0.5.4/ollama-linux-amd64.tgz
#
# Changes vs 1.1.x are listed in RELEASE_NOTES.txt (generated).
# Build overrides (environment): OLLAMA_VERSION, OLLAMA_SHA256,
#   VENAX_SKIP_NFT_CHECK=1, VENAX_SKIP_UNIT_VERIFY=1, VENAX_SKIP_RUNTIME_TEST=1
# ============================================================

# ------------------------------------------------------------------
# Root privilege handling (re-exec under sudo exactly once)
# ------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "Root privileges are required (debootstrap/mount/chroot). Re-running with sudo..."
    exec sudo -E -- "$0" "$@"
fi
ORIG_USER="${SUDO_USER:-root}"

VERSION="2.0.0"
ARCH="amd64"
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="https://deb.debian.org/debian"
SECURITY_MIRROR="https://security.debian.org/debian-security"

# Ollama is installed from the official release archive (not the
# curl|sh installer, which may try to install GPU drivers into the image
# when the BUILD host has a GPU). Bump deliberately; override with
#   OLLAMA_VERSION=x.y.z sudo -E ./build-iso.sh
# Optionally pin the archive hash: OLLAMA_SHA256=<hex>
OLLAMA_VERSION="${OLLAMA_VERSION:-0.5.4}"
OLLAMA_SHA256="${OLLAMA_SHA256:-}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$PROJECT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOTFS="$PROJECT_DIR/rootfs"
ISO_DIR="$PROJECT_DIR/iso"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
CACHE_DIR="$PROJECT_DIR/cache"
OLLAMA_DIR="$PROJECT_DIR/ollama"
ISO_NAME="VenaX-${VERSION}-x86_64.iso"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------------
# Logging: FATAL / WARNING / DEGRADED MODE / READY
# ------------------------------------------------------------------
info()     { printf '[INFO] %s\n' "$*"; }
warn()     { printf '[WARNING] %s\n' "$*" >&2; }
degraded() { printf '[DEGRADED MODE] %s\n' "$*" >&2; }
ready()    { printf '[READY] %s\n' "$*"; }
fatal()    { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
step()     { printf '\n[%s] %s\n' "$1" "$2"; }

ERR_LINE=""; ERR_CMD=""
trap 'ERR_LINE=$LINENO; ERR_CMD=$BASH_COMMAND' ERR

# Unmount everything below $ROOTFS (deepest first). Safe to call twice.
unmount_chroot() {
    local t left
    while read -r t; do
        [[ -n "$t" ]] || continue
        umount "$t" 2>/dev/null && continue
        warn "normal unmount of $t failed; retrying lazily"
        umount -l "$t" 2>/dev/null || warn "could not unmount $t"
    done < <(findmnt -rn -o TARGET 2>/dev/null | awk -v p="$ROOTFS/" 'index($0,p)==1' | sort -r)
    left="$(findmnt -rn -o TARGET 2>/dev/null | awk -v p="$ROOTFS/" 'index($0,p)==1' || true)"
    [[ -z "$left" ]]
}

# Hand the project's non-rootfs directories back to the user who ran sudo.
# Called on EVERY exit (success or failure) so a failed build can never leave
# root-owned files that later break plain-user commands such as wget.
# The rootfs is deliberately excluded: its ownership must stay as built.
fix_ownership() {
    if [[ "$ORIG_USER" != "root" ]] && id -u "$ORIG_USER" >/dev/null 2>&1; then
        chown -R "$ORIG_USER":"$ORIG_USER" "$OUTPUT_DIR" "$ISO_DIR" "$BUILD_DIR" "$CACHE_DIR" "$OLLAMA_DIR" 2>/dev/null || true
        chown "$ORIG_USER":"$ORIG_USER" "$PROJECT_DIR" 2>/dev/null || true
    fi
}

# EXIT trap only (always ends in exit).
cleanup() {
    local rc=$?
    set +e
    if ((rc != 0)); then
        printf '\n[FATAL] build failed (exit %s) near line %s: %s\n' "$rc" "${ERR_LINE:-?}" "${ERR_CMD:-?}" >&2
    fi
    unmount_chroot || warn "mounts under $ROOTFS may remain; inspect with: findmnt | grep rootfs"
    fix_ownership
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

require_host_tools() {
    local missing=() cmd
    for cmd in debootstrap grub-mkrescue mksquashfs xorriso mformat python3 curl sha256sum findmnt chroot awk tar gzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        echo "Missing host build tools: ${missing[*]}"
        echo "Install them with:"
        echo "  sudo apt update && sudo apt install -y debootstrap grub-pc-bin grub-efi-amd64-bin grub-common xorriso mtools squashfs-tools python3 curl zstd"
        exit 1
    fi
    [[ -d /usr/lib/grub/i386-pc ]]     || warn "grub-pc-bin missing: the ISO will not boot in BIOS mode"
    [[ -d /usr/lib/grub/x86_64-efi ]]  || warn "grub-efi-amd64-bin missing: the ISO will not boot in UEFI mode"
}

# Run a command inside the target rootfs with a clean environment.
in_chroot() {
    chroot "$ROOTFS" /usr/bin/env -i HOME=/root TERM=dumb \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 "$@"
}

# install_file DEST MODE  < content   (creates parent dirs)
install_file() {
    local dest="$1" mode="$2"
    install -d "$(dirname "$dest")"
    cat > "$dest"
    chmod "$mode" "$dest"
}

echo "============================================================"
echo "                 Building VenaX ${VERSION}"
echo "============================================================"
require_host_tools

# ------------------------------------------------------------------
step "1/14" "Cleaning previous build (rerunnable)"
# ------------------------------------------------------------------
unmount_chroot || fatal "stale mounts under $ROOTFS could not be unmounted; refusing to rm -rf"
# NOTE: $OLLAMA_DIR is intentionally NOT removed: it holds the cached archive.
rm -rf "$ROOTFS" "$ISO_DIR" "$BUILD_DIR"
mkdir -p "$ROOTFS" "$ISO_DIR/live" "$ISO_DIR/boot/grub" "$BUILD_DIR" "$OUTPUT_DIR" "$CACHE_DIR" "$OLLAMA_DIR"

# ------------------------------------------------------------------
step "2/14" "Creating minimal Debian (${DEBIAN_RELEASE}) root filesystem"
# ------------------------------------------------------------------
debootstrap --arch="$ARCH" --variant=minbase "$DEBIAN_RELEASE" "$ROOTFS" "$DEBIAN_MIRROR"

# ------------------------------------------------------------------
step "3/14" "Base configuration"
# ------------------------------------------------------------------
echo "venax" > "$ROOTFS/etc/hostname"

install_file "$ROOTFS/etc/hosts" 644 <<'EOF'
127.0.0.1 localhost
127.0.1.1 venax
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

install_file "$ROOTFS/etc/apt/sources.list" 644 <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb ${SECURITY_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

install_file "$ROOTFS/etc/motd" 644 <<EOF
============================================================
                         VenaX ${VERSION}
                 Local AI Server OS
============================================================
EOF

install_file "$ROOTFS/etc/venax-release" 644 <<EOF
VENAX_VERSION=${VERSION}
BUILD_DATE=${BUILD_DATE}
DEBIAN_RELEASE=${DEBIAN_RELEASE}
OLLAMA_VERSION=${OLLAMA_VERSION}
EOF

install_file "$ROOTFS/etc/default/locale" 644 <<'EOF'
LANG=C.UTF-8
EOF

# Keep journald in RAM and bounded (live system).
install_file "$ROOTFS/etc/systemd/journald.conf.d/venax.conf" 644 <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF

install_file "$ROOTFS/etc/tmpfiles.d/venax.conf" 644 <<'EOF'
d /run/venax 0755 root root -
EOF

# Prevent services from starting inside the build chroot.
install_file "$ROOTFS/usr/sbin/policy-rc.d" 755 <<'EOF'
#!/bin/sh
exit 101
EOF

# ------------------------------------------------------------------
step "4/14" "Preparing chroot mounts (private /run, no host /run bind)"
# ------------------------------------------------------------------
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount -t tmpfs tmpfs "$ROOTFS/run"

# ------------------------------------------------------------------
step "5/14" "Installing packages"
# ------------------------------------------------------------------
# netbase provides /etc/protocols and /etc/services. A minbase Debian has
# neither, and nftables cannot resolve protocol names (ipv6-icmp, ...) without
# them: that broke both the build-time ruleset check and the firewall at boot.
PKGS=(
    linux-image-amd64 live-boot systemd-sysv udev dbus kmod
    sudo bash coreutils procps iproute2 iputils-ping isc-dhcp-client
    network-manager wpasupplicant iw rfkill wireless-regdb
    pciutils usbutils lshw ethtool util-linux e2fsprogs dosfstools ntfs-3g exfatprogs
    curl ca-certificates python3 python3-minimal jq
    avahi-daemon libnss-mdns nftables openssh-client netbase
    less nano kbd console-setup console-setup-linux fonts-terminus-otb
    zstd xz-utils pci.ids usb.ids
    firmware-linux-free firmware-iwlwifi firmware-realtek firmware-atheros
    firmware-brcm80211 firmware-misc-nonfree
)
in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends "${PKGS[@]}"
in_chroot apt-get clean

# ------------------------------------------------------------------
step "6/14" "Users, groups, console defaults, base services"
# ------------------------------------------------------------------
# venax        : physical console/admin user (autologin tty1, not network-facing)
# venax-web    : network-facing web process; no shell, no sudo, no home
# ollama       : created with the Ollama install below
# venax-ctl    : group allowed to talk to the agent socket (venax-web, venax)
in_chroot /bin/bash -euc '
id venax >/dev/null 2>&1 || useradd -m -s /bin/bash venax
echo "venax:venax" | chpasswd
groupadd -f venax-ctl
id venax-web >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin venax-web
usermod -aG venax-ctl venax-web
usermod -aG venax-ctl venax
mkdir -p /etc/sudoers.d
printf "venax ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/venax
chmod 440 /etc/sudoers.d/venax
'

install_file "$ROOTFS/etc/default/console-setup" 644 <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Terminus"
FONTSIZE="16x32"
EOF

install_file "$ROOTFS/etc/default/keyboard" 644 <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# NetworkManager is the only network authority: no networkd/resolved,
# and no wait-online (VenaX must boot without any network).
in_chroot systemctl set-default multi-user.target
in_chroot systemctl enable NetworkManager.service avahi-daemon.service nftables.service
in_chroot systemctl mask NetworkManager-wait-online.service systemd-networkd.service \
    systemd-networkd.socket systemd-networkd-wait-online.service systemd-resolved.service

# ------------------------------------------------------------------
step "7/14" "Installing Ollama ${OLLAMA_VERSION} (local archive in VenaX/ollama)"
# ------------------------------------------------------------------
install_ollama() {
    local base="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}"
    local cand file="" dst
    mkdir -p "$OLLAMA_DIR"

    # 1) Prefer a local copy in VenaX/ollama (no download, no re-install from scratch)
    for cand in ollama-linux-amd64.tar.zst ollama-linux-amd64.tgz; do
        if [[ -s "$OLLAMA_DIR/$cand" ]]; then
            file="$OLLAMA_DIR/$cand"
            info "Using local Ollama archive: $file"
            break
        fi
    done

    # 2) Otherwise download it into VenaX/ollama (visible progress, resumable)
    if [[ -z "$file" ]]; then
        warn "no local Ollama archive in $OLLAMA_DIR; downloading (large file, this can take a while)"
        for cand in ollama-linux-amd64.tar.zst ollama-linux-amd64.tgz; do
            dst="$OLLAMA_DIR/$cand"
            info "Downloading $base/$cand"
            if curl -fL --retry 3 --connect-timeout 20 -C - -# -o "${dst}.part" "$base/$cand"; then
                mv "${dst}.part" "$dst"; file="$dst"; break
            fi
            [[ -s "${dst}.part" ]] || rm -f "${dst}.part"
        done
    fi
    [[ -n "$file" ]] || fatal "no Ollama archive found in $OLLAMA_DIR and download from $base failed"

    # Integrity: catch truncated/corrupt files before extracting
    info "Verifying archive integrity (can take a few seconds for a large file)..."
    case "$file" in
        *.tar.zst) command -v zstd >/dev/null || fatal "zstd is required on the host for $file"
                   zstd -t "$file" >/dev/null 2>&1 || fatal "$file is corrupt/incomplete; delete it and re-download" ;;
        *.tgz)     gzip -t "$file" 2>/dev/null     || fatal "$file is corrupt/incomplete; delete it and re-download" ;;
    esac

    if [[ -n "$OLLAMA_SHA256" ]]; then
        echo "${OLLAMA_SHA256}  ${file}" | sha256sum -c - >/dev/null || fatal "Ollama archive SHA256 mismatch"
        ready "Ollama archive hash verified"
    else
        info "Archive sha256=$(sha256sum "$file" | cut -d' ' -f1) (set OLLAMA_SHA256 to pin it)"
    fi

    info "Extracting $(basename "$file") into the image (a large archive takes a minute or two)..."
    case "$file" in
        *.tar.zst) zstd -dc "$file" | tar -x --no-same-owner -C "$ROOTFS/usr" ;;
        *.tgz)     tar -xzf "$file" --no-same-owner -C "$ROOTFS/usr" ;;
    esac
    [[ -x "$ROOTFS/usr/bin/ollama" ]] || fatal "ollama binary missing after extraction"

    in_chroot /bin/bash -euc '
        id ollama >/dev/null 2>&1 || useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
        getent group render >/dev/null && usermod -aG render ollama || true
        getent group video  >/dev/null && usermod -aG video ollama  || true
        install -d -o ollama -g ollama /var/lib/venax-ephemeral-models'
    in_chroot /usr/bin/ollama --version 2>&1 | grep -F "$OLLAMA_VERSION" >/dev/null \
        || fatal "installed ollama does not report version ${OLLAMA_VERSION} (the archive in $OLLAMA_DIR must match OLLAMA_VERSION)"
    ready "Ollama ${OLLAMA_VERSION} installed from $(basename "$file")"
}
install_ollama

# ------------------------------------------------------------------
step "8/14" "Shared library and venax-agent (the only privileged VenaX process)"
# ------------------------------------------------------------------
install_file "$ROOTFS/usr/local/lib/venax/venaxlib.py" 644 <<'EOF_LIB'
"""Shared helpers for VenaX components (standard library only)."""
import json
import os
import socket

VERSION = "@VERSION@"
RUN_DIR = "/run/venax"
AGENT_SOCK = os.environ.get("VENAX_AGENT_SOCK", RUN_DIR + "/agent.sock")
STORAGE_STATUS_FILE = RUN_DIR + "/storage-status"
PERSIST_MOUNT = "/mnt/venax-data"
WEB_PORT = 8080
OLLAMA_PORT = 11434
MAX_AGENT_REPLY = 8 * 1024 * 1024


class AgentError(Exception):
    def __init__(self, message, code="AGENT_ERROR", hint=None, status=500):
        super().__init__(message)
        self.message = message
        self.code = code
        self.hint = hint
        self.status = status


def read_kv(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    out[k.strip()] = v
    except OSError:
        pass
    return out


def storage_info():
    kv = read_kv(STORAGE_STATUS_FILE)
    state = kv.get("STATUS", "UNKNOWN")
    free = kv.get("FREE_KB", "")
    return {
        "state": state,
        "persistent": state == "READY",
        "reason": kv.get("REASON", "" if state == "READY" else "storage status has not been recorded yet"),
        "device": kv.get("DEVICE", ""),
        "fstype": kv.get("FSTYPE", ""),
        "models_path": kv.get("MODELS_PATH", ""),
        "free_kb": int(free) if free.isdigit() else None,
    }


def _down(detail):
    return AgentError("VenaX agent is not reachable (%s)" % detail, "AGENT_DOWN",
                      "Check the Services page, or run: systemctl status venax-agent", 503)


def agent_call(op, args=None, timeout=30):
    payload = (json.dumps({"op": op, "args": args or {}}) + "\n").encode("utf-8")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    chunks, total = [], 0
    try:
        s.connect(AGENT_SOCK)
        s.sendall(payload)
        s.shutdown(socket.SHUT_WR)
        while True:
            b = s.recv(65536)
            if not b:
                break
            total += len(b)
            if total > MAX_AGENT_REPLY:
                raise AgentError("agent reply too large", "AGENT_PROTOCOL", None, 502)
            chunks.append(b)
    except socket.timeout:
        raise AgentError("VenaX agent did not answer in time", "AGENT_TIMEOUT",
                         "The operation may still be running; check again shortly.", 504)
    except OSError as e:
        raise _down(e.strerror or str(e))
    finally:
        s.close()
    try:
        resp = json.loads(b"".join(chunks).decode("utf-8"))
    except ValueError:
        raise AgentError("agent returned malformed data", "AGENT_PROTOCOL", None, 502)
    if not resp.get("ok"):
        err = resp.get("error") or {}
        raise AgentError(err.get("message", "agent error"), err.get("code", "AGENT_ERROR"),
                         err.get("hint"), int(err.get("status", 500)))
    return resp.get("data")
EOF_LIB
sed -i "s|@VERSION@|${VERSION}|g" "$ROOTFS/usr/local/lib/venax/venaxlib.py"

install_file "$ROOTFS/usr/local/sbin/venax-agent" 755 <<'EOF_AGENT'
#!/usr/bin/env python3
"""VenaX agent: whitelisted privileged operations for the unprivileged web
service. Line-delimited JSON over a unix socket (root:venax-ctl, 0660).
There is NO arbitrary command execution: every operation validates its
inputs, uses argument lists (never a shell) and fixed unit/command names.
Request arguments are never logged (they may contain Wi-Fi passwords)."""
import concurrent.futures
import grp
import hashlib
import http.client
import json
import os
import re
import shlex
import socket
import socketserver
import subprocess
import sys
import threading
import time
import traceback
import uuid

sys.path.insert(0, "/usr/local/lib/venax")
import venaxlib as vx

NM_DIR = "/etc/NetworkManager/system-connections"
PERSIST = vx.PERSIST_MOUNT
PERSIST_NM = PERSIST + "/nm-connections"
PROFILE_PREFIX = "venax-wifi-"
MAX_REQ = 64 * 1024
ENV = dict(os.environ, LC_ALL="C", LANG="C")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")

UNITS = {
    "networkmanager": "NetworkManager.service", "venax-data": "venax-data.service",
    "venax-agent": "venax-agent.service", "ollama": "ollama.service",
    "venax-web": "venax-web.service", "nftables": "nftables.service",
    "avahi": "avahi-daemon.service", "performance": "venax-performance.service",
}
RESTARTABLE = {"ollama", "venax-web", "avahi", "networkmanager"}
LOG_UNITS = dict(UNITS, kernel=None)


def log(msg):
    sys.stderr.write("[agent] %s\n" % msg)
    sys.stderr.flush()


class OpError(Exception):
    def __init__(self, message, code="ERROR", hint=None, status=400):
        super().__init__(message)
        self.message, self.code, self.hint, self.status = message, code, hint, status


def run(argv, timeout=15, input_text=None):
    try:
        p = subprocess.run(argv, capture_output=True, encoding="utf-8", errors="replace",
                           timeout=timeout, input=input_text, env=ENV)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except OSError as e:
        return 127, "", str(e)


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def nm_split(line):
    out, cur, esc = [], [], False
    for c in line:
        if esc:
            cur.append(c); esc = False
        elif c == "\\":
            esc = True
        elif c == ":":
            out.append("".join(cur)); cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return out


_cache, _cache_lock = {}, threading.Lock()


def cached(key, ttl, fn):
    now = time.monotonic()
    with _cache_lock:
        e = _cache.get(key)
        if e and now - e[0] < ttl:
            return e[1]
    val = fn()
    with _cache_lock:
        _cache[key] = (time.monotonic(), val)
    return val


def invalidate():
    with _cache_lock:
        _cache.clear()


# ------------------------------------------------------------ network probing
def phys_devices():
    base, devs = "/sys/class/net", []
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return devs
    for n in names:
        p = "%s/%s" % (base, n)
        if n == "lo" or not os.path.exists(p + "/device"):
            continue
        kind = "wifi" if (os.path.isdir(p + "/wireless") or os.path.isdir(p + "/phy80211")) else "ethernet"
        devs.append({"name": n, "kind": kind, "carrier": read_file(p + "/carrier") == "1",
                     "operstate": read_file(p + "/operstate"), "mac": read_file(p + "/address"),
                     "driver": os.path.basename(os.path.realpath(p + "/device/driver"))})
    return devs


def nm_running():
    rc, out, _ = run(["nmcli", "-t", "-f", "RUNNING", "general"], timeout=5)
    return rc == 0 and out.strip() == "running"


def nm_devices():
    rc, out, _ = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], timeout=8)
    d = {}
    if rc == 0:
        for line in out.splitlines():
            f = nm_split(line)
            if len(f) >= 4:
                d[f[0]] = {"type": f[1], "state": f[2], "connection": "" if f[3] == "--" else f[3]}
    return d


def ip_json(*args):
    rc, out, _ = run(["ip", "-j"] + list(args), timeout=8)
    if rc != 0:
        return []
    try:
        return json.loads(out)
    except ValueError:
        return []


def classify(name):
    if name.startswith(("tun", "tap", "wg", "tailscale", "zt", "ppp")):
        return "vpn"
    return "virtual"


def collect_interfaces():
    phys = {d["name"]: d for d in phys_devices()}
    nm = nm_devices()
    addr_by = {}
    for i in ip_json("-4", "addr", "show"):
        name = i.get("ifname")
        if not name or name == "lo":
            continue
        lst = []
        for a in i.get("addr_info", []):
            if a.get("family") != "inet" or not a.get("local"):
                continue
            lst.append({"ip": a["local"], "prefix": a.get("prefixlen"), "scope": a.get("scope"),
                        "linklocal": a["local"].startswith("169.254.")})
        addr_by[name] = (lst, i.get("operstate", ""))
    default, gateway, linkroute = {}, {}, set()
    for r in ip_json("-4", "route", "show"):
        dev = r.get("dev")
        if r.get("dst") == "default":
            m = r.get("metric", 0)
            if dev not in default or m < default[dev]:
                default[dev], gateway[dev] = m, r.get("gateway")
        elif r.get("scope") == "link":
            linkroute.add(dev)
    out = []
    for n in sorted(set(phys) | set(addr_by)):
        p = phys.get(n)
        lst, oper = addr_by.get(n, ([], ""))
        info = nm.get(n, {})
        out.append({
            "name": n, "kind": p["kind"] if p else classify(n),
            "state": info.get("state") or oper or "unknown", "connection": info.get("connection", ""),
            "carrier": p["carrier"] if p else None, "mac": p["mac"] if p else "",
            "driver": p["driver"] if p else "", "ipv4": lst,
            "gateway": gateway.get(n), "has_default": n in default,
            "metric": default.get(n), "has_local_route": n in linkroute,
        })
    return out


def pick_primary(ifaces):
    c = [i for i in ifaces if i["kind"] in ("wifi", "ethernet") and i["ipv4"]]

    def key(i):
        gl = [a for a in i["ipv4"] if not a["linklocal"]]
        return (0 if gl else 1, 0 if i["has_default"] else 1,
                i["metric"] if i["metric"] is not None else 9999,
                0 if i["kind"] == "ethernet" else 1, i["name"])
    c.sort(key=key)
    return c[0] if c else None


def primary_ip(i):
    gl = [a["ip"] for a in i["ipv4"] if not a["linklocal"]]
    return gl[0] if gl else i["ipv4"][0]["ip"]


def web_listening(ip):
    try:
        c = http.client.HTTPConnection(ip, vx.WEB_PORT, timeout=1.5)
        c.request("GET", "/healthz")
        ok = c.getresponse().status == 200
        c.close()
        return ok
    except (OSError, http.client.HTTPException):
        return False


def _tcp(host, port):
    try:
        socket.create_connection((host, port), timeout=1.5).close()
        return True
    except OSError:
        return False


def _internet():
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
        futs = [ex.submit(_tcp, h, p) for h, p in (("1.1.1.1", 443), ("9.9.9.9", 443), ("8.8.8.8", 53))]
        try:
            for f in concurrent.futures.as_completed(futs, timeout=2.5):
                if f.result():
                    return True
        except concurrent.futures.TimeoutError:
            pass
    return False


def internet_ok():
    return cached("internet", 8, _internet)


def nm_dns(dev):
    rc, out, _ = run(["nmcli", "-t", "-f", "IP4.DNS", "device", "show", dev], timeout=8)
    res = []
    if rc == 0:
        for line in out.splitlines():
            if line.startswith("IP4.DNS"):
                res.append(line.split(":", 1)[1])
    return res


def norm_sec(raw):
    s = (raw or "").upper().strip()
    if not s or s == "--":
        return "open"
    if "802.1X" in s:
        return "enterprise"
    if "WEP" in s:
        return "wep"
    if "OWE" in s:
        return "owe"
    sae = "WPA3" in s or "SAE" in s
    psk = "WPA2" in s or "WPA1" in s or ("WPA" in s and "WPA3" not in s)
    if sae and not psk:
        return "sae"
    return "wpa-psk"


def list_wifi(dev, rescan=False):
    if rescan:
        run(["nmcli", "device", "wifi", "rescan", "ifname", dev], timeout=10)
        time.sleep(2.5)
    rc, out, _ = run(["nmcli", "-t", "--escape", "yes", "-f", "IN-USE,SSID,SECURITY,SIGNAL,CHAN,FREQ",
                      "device", "wifi", "list", "ifname", dev, "--rescan", "no"], timeout=15)
    nets = {}
    if rc != 0:
        return []
    for line in out.splitlines():
        f = nm_split(line)
        if len(f) < 6 or not f[1]:
            continue
        inuse, ssid, sec, sig, chan, freq = f[:6]
        sig = int(sig) if sig.isdigit() else 0
        n = norm_sec(sec)
        cur = nets.get(ssid)
        if cur is None or sig > cur["signal"]:
            nets[ssid] = {"ssid": ssid, "security": n, "security_raw": sec or "--", "signal": sig,
                          "channel": chan, "freq": freq, "in_use": inuse == "*",
                          "supported": n in ("open", "wpa-psk", "sae")}
        if inuse == "*":
            nets[ssid]["in_use"] = True
    return sorted(nets.values(), key=lambda x: -x["signal"])


HINTS = {
    "NO_INTERFACE": "No network adapter was detected. Plug in Ethernet, a USB-tethered phone or a USB Wi-Fi adapter (some adapters need firmware this image lacks).",
    "INTERFACE_AVAILABLE": "An adapter is present but not connected. Plug in Ethernet, or join a Wi-Fi network / laptop or phone hotspot.",
    "CONNECTING": "Connecting: waiting for link and an IPv4 address (DHCP).",
    "LOCAL_CONNECTED": "An IPv4 address was obtained but the VenaX web service is not answering on it yet.",
    "LOCAL_READY": "Ready for devices on this network. Internet is not reachable; local AI keeps working offline.",
    "INTERNET_AVAILABLE": "Ready. Internet is reachable.",
}


def _network_status():
    ifaces = collect_interfaces()
    phys = [i for i in ifaces if i["kind"] in ("wifi", "ethernet")]
    prim = pick_primary(ifaces)
    connecting = any(str(i["state"]).startswith("connecting") for i in phys)
    st = {"state": "NO_INTERFACE", "interface": None, "kind": None, "ssid": None, "signal": None,
          "ipv4": None, "prefix": None, "gateway": None, "dns": [], "internet": False, "urls": [],
          "addresses": [], "mdns": "http://venax.local:%d" % vx.WEB_PORT,
          "networkmanager": "running" if nm_running() else "not running",
          "saved_wifi": saved_profiles(), "checked_at": int(time.time())}
    cand = [i for i in phys if i["ipv4"]]
    for i in sorted(cand, key=lambda x: (x is not prim, x["name"])):
        for a in i["ipv4"]:
            st["addresses"].append({"interface": i["name"], "kind": i["kind"], "ipv4": a["ip"], "linklocal": a["linklocal"]})
            u = "http://%s:%d" % (a["ip"], vx.WEB_PORT)
            if u not in st["urls"]:
                st["urls"].append(u)
    if not phys:
        state = "NO_INTERFACE"
    elif prim is None:
        state = "CONNECTING" if connecting else "INTERFACE_AVAILABLE"
    else:
        ip = primary_ip(prim)
        st.update(interface=prim["name"], kind=prim["kind"], ipv4=ip, gateway=prim["gateway"],
                  dns=nm_dns(prim["name"]),
                  prefix=next((a["prefix"] for a in prim["ipv4"] if a["ip"] == ip), None))
        if prim["kind"] == "wifi":
            for n in list_wifi(prim["name"]):
                if n["in_use"]:
                    st["ssid"], st["signal"] = n["ssid"], n["signal"]
        st["internet"] = internet_ok()
        state = "LOCAL_CONNECTED"
        if prim["has_local_route"] and web_listening(ip):
            state = "INTERNET_AVAILABLE" if st["internet"] else "LOCAL_READY"
    st["state"], st["hint"] = state, HINTS[state]
    if not phys:
        pass
    return st


def network_status(fresh=False):
    if fresh:
        invalidate()
    return cached("net", 2, _network_status)


# --------------------------------------------------------------- wifi helpers
def pick_wifi(iface):
    devs = [d for d in phys_devices() if d["kind"] == "wifi"]
    if iface is not None:
        if not isinstance(iface, str) or not IFACE_RE.match(iface):
            raise OpError("Invalid interface name", "BAD_INTERFACE")
        for d in devs:
            if d["name"] == iface:
                return iface
        raise OpError("Wi-Fi adapter %s was not found" % iface, "NO_WIFI_ADAPTER")
    if not devs:
        raise OpError("No Wi-Fi adapter detected", "NO_WIFI_ADAPTER",
                      "If it is a USB adapter its firmware may be missing (see Diagnostics: dmesg firmware lines).")
    return devs[0]["name"]


def ensure_wifi_radio():
    run(["rfkill", "unblock", "wifi"], timeout=5)
    run(["nmcli", "radio", "wifi", "on"], timeout=5)
    _, out, _ = run(["rfkill", "list", "wifi"], timeout=5)
    if "Hard blocked: yes" in out:
        raise OpError("Wi-Fi is switched off by a hardware switch", "WIFI_HARD_BLOCKED",
                      "Use the laptop's Wi-Fi switch / Fn key, then try again.", 409)
    if not nm_running():
        raise OpError("NetworkManager is not running", "NM_DOWN", "Restart it from the Services page.", 503)


def kf_escape(v):
    v = v.replace("\\", "\\\\")
    if v.startswith(" "):
        v = "\\s" + v[1:]
    if v.endswith(" "):
        v = v[:-1] + "\\s"
    return v


def profile_id(ssid):
    return PROFILE_PREFIX + hashlib.sha1(ssid.encode("utf-8")).hexdigest()[:12]


def parse_ssid(val):
    val = val.strip()
    if re.fullmatch(r"[0-9;]+", val):
        try:
            return bytes(int(x) for x in val.split(";") if x).decode("utf-8", "replace")
        except ValueError:
            pass
    return val


def saved_profiles():
    res = []
    try:
        names = sorted(os.listdir(NM_DIR))
    except OSError:
        return res
    for n in names:
        if not (n.startswith(PROFILE_PREFIX) and n.endswith(".nmconnection")):
            continue
        ssid = ""
        try:
            with open(os.path.join(NM_DIR, n), encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("ssid="):
                        ssid = parse_ssid(line[5:])
                        break
        except OSError:
            continue
        res.append({"id": n[:-len(".nmconnection")], "ssid": ssid})
    return res


def write_profile(ssid, sec, password, hidden):
    pid = profile_id(ssid)
    path = "%s/%s.nmconnection" % (NM_DIR, pid)
    ssid_ints = "".join("%d;" % b for b in ssid.encode("utf-8"))
    lines = ["[connection]", "id=" + pid, "uuid=" + str(uuid.uuid4()), "type=wifi",
             "autoconnect=true", "autoconnect-priority=10", "",
             "[wifi]", "mode=infrastructure", "ssid=" + ssid_ints, "powersave=2",
             "cloned-mac-address=preserve"]
    if hidden:
        lines.append("hidden=true")
    if sec != "open":
        lines += ["", "[wifi-security]", "key-mgmt=" + sec, "psk=" + kf_escape(password)]
    lines += ["", "[ipv4]", "method=auto", "may-fail=false", "dhcp-timeout=30",
              "", "[ipv6]", "method=auto", "may-fail=true", ""]
    os.makedirs(NM_DIR, mode=0o700, exist_ok=True)
    tmp = "%s/.venax-tmp-%d-%s" % (NM_DIR, os.getpid(), uuid.uuid4().hex[:8])
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return pid, path


def persist_profile(path):
    info = vx.storage_info()
    if info["state"] != "READY" or not os.path.ismount(PERSIST):
        return False, "Saved for this session only: persistent storage (VENAXDATA) is not available."
    try:
        os.makedirs(PERSIST_NM, exist_ok=True)
        dst = os.path.join(PERSIST_NM, os.path.basename(path))
        with open(path, "rb") as s:
            data = s.read()
        tmp = dst + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, dst)
        return True, "Saved to persistent storage."
    except OSError as e:
        return False, "Could not save to persistent storage: %s" % e.strerror


def forget_profile(pid):
    run(["nmcli", "connection", "delete", "id", pid], timeout=15)
    for d in (NM_DIR, PERSIST_NM):
        try:
            os.unlink("%s/%s.nmconnection" % (d, pid))
        except OSError:
            pass
    run(["nmcli", "connection", "reload"], timeout=10)


def map_nm_error(text):
    t = text.lower()
    if "secrets were required" in t or "no secrets" in t or "4-way" in t:
        return ("WRONG_PASSWORD", "The Wi-Fi password was rejected (or the security type does not match).",
                "Check the password and try again.")
    if "ip configuration could not be reserved" in t or "dhcp" in t:
        return ("DHCP_FAILED", "Connected to the access point but DHCP failed: no IPv4 address was offered within 30 seconds.",
                "If this is a laptop or phone hotspot, make sure hotspot sharing is switched on.")
    if "no network with ssid" in t or "could not be found" in t or "not found" in t:
        return ("NOT_FOUND", "The Wi-Fi network was not found.", "Move closer, rescan, or add it as a hidden network.")
    if "no suitable device" in t or "not available" in t:
        return ("NO_DEVICE", "The Wi-Fi adapter is not available.", "Check Wi-Fi is enabled (rfkill) and the adapter is detected.")
    if "timeout" in t or "timed out" in t:
        return ("TIMEOUT", "The connection attempt timed out.", "Check signal strength and that the access point is reachable.")
    return ("CONNECT_FAILED", "Network connection failed: " + (text.strip().replace("\n", " ")[:200] or "unknown error"),
            "See Network diagnostics for details.")


MANUAL = {"disconnected": False}
NET_LOCK = threading.Lock()


def op_connect(a):
    ssid = a.get("ssid")
    if not isinstance(ssid, str) or not ssid or "\x00" in ssid or len(ssid.encode("utf-8")) > 32:
        raise OpError("Invalid SSID (1-32 bytes required)", "BAD_SSID")
    pw = a.get("password") or ""
    if not isinstance(pw, str) or len(pw) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in pw):
        raise OpError("Invalid password", "BAD_PASSWORD")
    hidden = bool(a.get("hidden", False))
    sec = a.get("security", "auto")
    if sec not in ("auto", "open", "wpa-psk", "sae"):
        raise OpError("Unsupported security setting", "BAD_SECURITY")
    if not NET_LOCK.acquire(blocking=False):
        raise OpError("Another network change is already in progress", "BUSY", "Wait a few seconds and retry.", 409)
    try:
        dev = pick_wifi(a.get("interface"))
        ensure_wifi_radio()
        run(["nmcli", "device", "set", dev, "managed", "yes"], timeout=5)
        if sec == "auto":
            found = next((n for n in list_wifi(dev) if n["ssid"] == ssid), None)
            if found:
                sec = found["security"]
                if sec in ("enterprise", "wep", "owe"):
                    raise OpError("%s networks are not supported by VenaX Wi-Fi setup" % sec, "UNSUPPORTED_SECURITY",
                                  "Use a WPA2/WPA3 or open network, or a hotspot from your laptop/phone.")
            else:
                sec = "wpa-psk" if pw else "open"
        if sec == "open":
            pw = ""
        else:
            n = len(pw.encode("utf-8"))
            if not pw:
                raise OpError("This network needs a password", "PASSWORD_REQUIRED")
            if sec == "wpa-psk" and not (8 <= n <= 63 or re.fullmatch(r"[0-9A-Fa-f]{64}", pw)):
                raise OpError("WPA2 passwords must be 8-63 characters", "BAD_PASSWORD")
            if sec == "sae" and n < 8:
                raise OpError("WPA3 passwords must be at least 8 characters", "BAD_PASSWORD")
        pid, path = write_profile(ssid, sec, pw, hidden)
        pw = ""
        run(["nmcli", "connection", "reload"], timeout=10)
        rc, out, err = run(["nmcli", "--wait", "50", "connection", "up", "id", pid, "ifname", dev], timeout=70)
        ip = None
        if rc == 0:
            for _ in range(15):
                for i in collect_interfaces():
                    if i["name"] == dev and i["ipv4"]:
                        ip = i["ipv4"][0]["ip"]
                if ip:
                    break
                time.sleep(1)
            if not ip:
                rc, err = 1, "DHCP: no IPv4 address obtained"
        if rc != 0 or not ip:
            forget_profile(pid)
            code, msg, hint = map_nm_error(err or out)
            raise OpError(msg, code, hint, 502)
        MANUAL["disconnected"] = False
        persisted, note = persist_profile(path)
        invalidate()
        st = network_status(fresh=True)
        return {"connected": True, "ssid": ssid, "interface": dev, "ipv4": ip, "persisted": persisted,
                "note": note, "state": st["state"], "urls": st["urls"]}
    finally:
        NET_LOCK.release()


def op_scan(a):
    dev = pick_wifi(a.get("interface"))
    ensure_wifi_radio()
    nets = []
    for attempt in range(3):
        nets = list_wifi(dev, rescan=not a.get("cached") or attempt > 0)
        if nets:
            break
    return {"interface": dev, "networks": nets}


def _target_iface(a):
    iface = a.get("interface")
    if iface is None:
        p = pick_primary(collect_interfaces())
        if not p:
            raise OpError("No connected interface", "NO_INTERFACE")
        return p["name"], p["kind"]
    if not isinstance(iface, str) or not IFACE_RE.match(iface):
        raise OpError("Invalid interface name", "BAD_INTERFACE")
    for d in phys_devices():
        if d["name"] == iface:
            return iface, d["kind"]
    raise OpError("Interface %s not found" % iface, "NO_INTERFACE", status=404)


def op_disconnect(a):
    dev, _ = _target_iface(a)
    with NET_LOCK:
        rc, out, err = run(["nmcli", "device", "disconnect", dev], timeout=20)
        if rc != 0:
            raise OpError("Disconnect failed: " + (err or out).strip()[:200], "DISCONNECT_FAILED", status=502)
        MANUAL["disconnected"] = True
    invalidate()
    return {"disconnected": dev}


def op_reconnect(a):
    dev, kind = _target_iface(a)
    if not NET_LOCK.acquire(blocking=False):
        raise OpError("Another network change is already in progress", "BUSY", status=409)
    try:
        MANUAL["disconnected"] = False
        if kind == "wifi":
            ensure_wifi_radio()
        argv = ["nmcli", "--wait", "45", "device", "connect", dev]
        if kind == "ethernet":
            argv = ["nmcli", "--wait", "45", "connection", "up", "id", "VenaX Ethernet (DHCP)", "ifname", dev]
        rc, out, err = run(argv, timeout=60)
        if rc != 0 and kind == "ethernet":
            rc, out, err = run(["nmcli", "--wait", "30", "device", "connect", dev], timeout=45)
        if rc != 0:
            code, msg, hint = map_nm_error(err or out)
            raise OpError(msg, code, hint, 502)
    finally:
        NET_LOCK.release()
    invalidate()
    return {"reconnected": dev, "state": network_status(fresh=True)["state"]}


def op_forget(a):
    ssid = a.get("ssid")
    if not isinstance(ssid, str) or not ssid or len(ssid.encode("utf-8")) > 32:
        raise OpError("Invalid SSID", "BAD_SSID")
    forget_profile(profile_id(ssid))
    invalidate()
    return {"forgotten": ssid}


def op_net_diag(_a):
    st = network_status(fresh=True)
    checks = []

    def add(name, status, msg, hint=None):
        checks.append({"name": name, "status": status, "message": msg, "hint": hint})
    add("NetworkManager", "PASS" if st["networkmanager"] == "running" else "FAIL",
        "NetworkManager is " + st["networkmanager"], "Restart it from the Services page.")
    devs = phys_devices()
    add("Adapters", "PASS" if devs else "FAIL",
        ", ".join("%s (%s)" % (d["name"], d["kind"]) for d in devs) or "no adapters detected",
        "Plug in Ethernet or a supported USB Wi-Fi adapter.")
    _, rf, _ = run(["rfkill", "list"], timeout=5)
    blocked = "yes" in rf.lower() and "blocked: yes" in rf.lower()
    add("rfkill", "WARN" if blocked else "PASS", "radio is blocked" if blocked else "no radio is blocked",
        "Unblock it from the console: sudo rfkill unblock all")
    for d in devs:
        if d["kind"] == "ethernet":
            add("Link " + d["name"], "PASS" if d["carrier"] else "WARN",
                "cable connected" if d["carrier"] else "no carrier (cable unplugged?)")
    add("IPv4 address", "PASS" if st["ipv4"] else "FAIL", st["ipv4"] or "no IPv4 address", st["hint"])
    if st["ipv4"]:
        ifc = next((i for i in collect_interfaces() if i["name"] == st["interface"]), None)
        add("Local route", "PASS" if ifc and ifc["has_local_route"] else "WARN",
            "subnet route present" if ifc and ifc["has_local_route"] else "no connected-subnet route")
        gw = st["gateway"]
        if gw:
            rc, _, _ = run(["ping", "-c", "1", "-W", "2", gw], timeout=6)
            add("Gateway", "PASS" if rc == 0 else "WARN", "%s %s" % (gw, "answers ping" if rc == 0 else "did not answer ping (may be normal)"))
        else:
            add("Gateway", "PASS", "no default gateway (isolated local network is fine)")
        add("Web listener", "PASS" if web_listening(st["ipv4"]) else "FAIL",
            "http://%s:%d/healthz" % (st["ipv4"], vx.WEB_PORT), "Restart venax-web from the Services page.")
        rc, out, _ = run(["getent", "ahostsv4", "registry.ollama.ai"], timeout=5)
        add("DNS", "PASS" if rc == 0 else "WARN", "resolves registry.ollama.ai" if rc == 0 else "cannot resolve names (needed for model downloads only)")
        add("Internet", "PASS" if st["internet"] else "WARN",
            "reachable" if st["internet"] else "offline (not an error: installed models still work)")
    rc, jl, _ = run(["journalctl", "-u", "NetworkManager", "-n", "30", "--no-pager", "-o", "short"], timeout=10)
    return {"state": st["state"], "checks": checks, "journal": redact(jl)}


def redact(text):
    return re.sub(r"(?i)(psk|password|secret|passphrase)([^\n]{0,3})[=:][^\n]*", r"\1=[REDACTED]", text)


# ------------------------------------------------------------ other operations
def op_hardware(_a):
    cpu = {"model": "", "threads": None, "cores": None, "sockets": None, "arch": "", "max_mhz": None}
    _, out, _ = run(["lscpu"], timeout=8)
    kv = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            kv[k.strip()] = v.strip()
    toint = lambda s: int(s) if s and s.isdigit() else None
    cpu.update(model=kv.get("Model name", ""), arch=kv.get("Architecture", ""), threads=toint(kv.get("CPU(s)")),
               sockets=toint(kv.get("Socket(s)")), cores=(toint(kv.get("Core(s) per socket")) or 0) * (toint(kv.get("Socket(s)")) or 1) or None)
    try:
        cpu["max_mhz"] = int(float(kv.get("CPU max MHz", "")))
    except ValueError:
        pass
    mem = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        if k in ("MemTotal", "MemAvailable", "SwapTotal"):
            mem[k] = int(v.split()[0]) // 1024
    gpus = []
    _, out, _ = run(["lspci", "-mm"], timeout=8)
    for line in out.splitlines():
        try:
            f = shlex.split(line)
        except ValueError:
            continue
        if len(f) >= 4 and re.search(r"VGA|3D|Display", f[1]):
            vend = f[2]
            v = "NVIDIA" if "NVIDIA" in vend else "AMD" if ("AMD" in vend or "ATI" in vend) else "Intel" if "Intel" in vend else vend
            gpus.append({"slot": f[0], "vendor": v, "name": "%s %s" % (vend, f[3])})
    disks = []
    rc, out, _ = run(["lsblk", "-J", "-d", "-o", "NAME,SIZE,MODEL,RM,TYPE,TRAN"], timeout=8)
    if rc == 0:
        try:
            disks = [d for d in json.loads(out).get("blockdevices", []) if d.get("type") in ("disk",)]
        except ValueError:
            pass
    return {"cpu": cpu, "memory": {"total_mb": mem.get("MemTotal"), "available_mb": mem.get("MemAvailable")},
            "gpus": gpus, "network_adapters": phys_devices(), "disks": disks,
            "kernel": os.uname().release}


def op_storage(_a):
    rc, out, _ = run(["lsblk", "-J", "-o", "NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,RM,MODEL"], timeout=8)
    devices = []
    if rc == 0:
        try:
            devices = json.loads(out).get("blockdevices", [])
        except ValueError:
            pass
    info = vx.storage_info()
    space = {}
    for name, p in (("root", "/"), ("models", info["models_path"] or "/var/lib/venax-ephemeral-models")):
        try:
            s = os.statvfs(p)
            space[name] = {"path": p, "total_mb": s.f_blocks * s.f_frsize // 1048576,
                           "free_mb": s.f_bavail * s.f_frsize // 1048576}
        except OSError:
            pass
    return {"status": info, "devices": devices, "space": space,
            "note": None if info["persistent"] else
            "Models downloaded now are stored in RAM and are LOST at reboot. Label a partition VENAXDATA (ext4 recommended) and use Retry detection."}


def op_storage_rescan(_a):
    run(["systemctl", "--no-block", "restart", "venax-data.service"], timeout=10)
    return {"accepted": True, "note": "Re-detecting VENAXDATA; Ollama restarts automatically when storage changes."}


def op_services(_a):
    keys = list(UNITS)
    rc, out, _ = run(["systemctl", "show"] + [UNITS[k] for k in keys] +
                     ["-p", "Id,ActiveState,SubState,Result,NRestarts,ActiveEnterTimestamp"], timeout=10)
    blocks = [b for b in out.strip().split("\n\n") if b.strip()]
    by_id = {}
    for b in blocks:
        d = dict(l.split("=", 1) for l in b.splitlines() if "=" in l)
        by_id[d.get("Id")] = d
    res = []
    for k in keys:
        d = by_id.get(UNITS[k], {})
        res.append({"key": k, "unit": UNITS[k], "active": d.get("ActiveState", "unknown"),
                    "sub": d.get("SubState", ""), "result": d.get("Result", ""),
                    "restarts": d.get("NRestarts", ""), "since": d.get("ActiveEnterTimestamp", ""),
                    "restartable": k in RESTARTABLE})
    return {"services": res}


def op_restart(a):
    key = a.get("service")
    if not isinstance(key, str) or key not in RESTARTABLE:
        raise OpError("Service cannot be restarted from the API", "NOT_ALLOWED", "Allowed: " + ", ".join(sorted(RESTARTABLE)), 403)
    rc, out, err = run(["systemctl", "--no-block", "restart", UNITS[key]], timeout=15)
    if rc != 0:
        raise OpError("Restart failed: " + (err or out).strip()[:200], "RESTART_FAILED", status=502)
    invalidate()
    return {"restarting": key}


def op_logs(a):
    key = a.get("unit", "ollama")
    if key not in LOG_UNITS:
        raise OpError("Unknown log source", "BAD_UNIT", "Allowed: " + ", ".join(sorted(LOG_UNITS)))
    try:
        n = max(20, min(500, int(a.get("lines", 150))))
    except (TypeError, ValueError):
        n = 150
    argv = ["journalctl", "-k"] if key == "kernel" else ["journalctl", "-u", UNITS[key]]
    rc, out, err = run(argv + ["-n", str(n), "--no-pager", "-o", "short-iso"], timeout=15)
    return {"unit": key, "text": redact(out if rc == 0 else err)}


def op_diagnostics(_a):
    rc, out, err = run(["/usr/local/sbin/venax-diagnostics"], timeout=90)
    return {"report": redact(out or err), "generated": int(time.time())}


OPS = {
    "ping": lambda a: {"version": vx.VERSION, "time": time.time()},
    "network.status": lambda a: network_status(fresh=bool(a.get("fresh"))),
    "network.interfaces": lambda a: {"interfaces": collect_interfaces(), "wifi_adapters": [d for d in phys_devices() if d["kind"] == "wifi"]},
    "network.scan": op_scan, "network.connect": op_connect, "network.disconnect": op_disconnect,
    "network.reconnect": op_reconnect, "network.forget": op_forget, "network.diagnostics": op_net_diag,
    "hardware": op_hardware, "storage": op_storage, "storage.rescan": op_storage_rescan,
    "services": op_services, "services.restart": op_restart, "logs": op_logs, "diagnostics": op_diagnostics,
}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(130)
        op = "?"
        try:
            raw = self.rfile.readline(MAX_REQ + 1)
            if len(raw) > MAX_REQ:
                raise OpError("request too large", "TOO_LARGE", status=413)
            req = json.loads(raw.decode("utf-8"))
            op, args = req.get("op"), req.get("args") or {}
            if not isinstance(op, str) or not isinstance(args, dict) or op not in OPS:
                raise OpError("unknown operation", "UNKNOWN_OP", status=404)
            resp = {"ok": True, "data": OPS[op](args)}
        except OpError as e:
            resp = {"ok": False, "error": {"code": e.code, "message": e.message, "hint": e.hint, "status": e.status}}
        except (ValueError, UnicodeDecodeError):
            resp = {"ok": False, "error": {"code": "BAD_REQUEST", "message": "malformed request", "status": 400}}
        except Exception:
            log("operation %s failed:\n%s" % (op, traceback.format_exc(limit=3)))
            resp = {"ok": False, "error": {"code": "INTERNAL", "message": "internal agent error", "status": 500}}
        try:
            self.wfile.write((json.dumps(resp) + "\n").encode("utf-8"))
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 32


def watchdog():
    """Single reconnect owner: if nothing is connected and the user did not
    disconnect on purpose, ask NetworkManager to retry (NM gives up after
    a few autoconnect attempts when an AP or DHCP server appears late)."""
    last = {}
    while True:
        time.sleep(20)
        try:
            if MANUAL["disconnected"] or not nm_running():
                continue
            if not NET_LOCK.acquire(blocking=False):
                continue
            try:
                st = network_status(fresh=True)
                if st["state"] != "INTERFACE_AVAILABLE":
                    continue
                for d in phys_devices():
                    if time.time() - last.get(d["name"], 0) < 60:
                        continue
                    if (d["kind"] == "wifi" and saved_profiles()) or (d["kind"] == "ethernet" and d["carrier"]):
                        last[d["name"]] = time.time()
                        run(["nmcli", "--wait", "30", "device", "connect", d["name"]], timeout=40)
            finally:
                NET_LOCK.release()
        except Exception:
            log("watchdog error:\n%s" % traceback.format_exc(limit=2))


def main():
    os.makedirs(vx.RUN_DIR, exist_ok=True)
    try:
        os.unlink(vx.AGENT_SOCK)
    except FileNotFoundError:
        pass
    old = os.umask(0o117)
    try:
        srv = Server(vx.AGENT_SOCK, Handler)
    finally:
        os.umask(old)
    try:
        os.chown(vx.AGENT_SOCK, 0, grp.getgrnam("venax-ctl").gr_gid)
    except (KeyError, OSError) as e:
        log("WARNING: could not set socket group: %s" % e)
    os.chmod(vx.AGENT_SOCK, 0o660)
    threading.Thread(target=watchdog, daemon=True).start()
    log("venax-agent %s listening on %s" % (vx.VERSION, vx.AGENT_SOCK))
    srv.serve_forever()


if __name__ == "__main__":
    main()
EOF_AGENT

# ------------------------------------------------------------------
step "9/14" "venax-web: unprivileged HTTP server, API and streaming proxy"
# ------------------------------------------------------------------
install_file "$ROOTFS/usr/local/sbin/venax-web" 755 <<'EOF_WEB'
#!/usr/bin/env python3
"""VenaX web server (runs as the unprivileged venax-web user).

Browser --HTTP:8080--> here --127.0.0.1:11434--> Ollama
                       '--unix socket--> venax-agent (whitelisted operations)
Streaming responses are NDJSON, re-framed line by line so that TCP/chunk
boundaries never matter; upstream failures become structured error lines."""
import http.client
import http.server
import ipaddress
import json
import os
import re
import socket
import sys
import threading
import time
import traceback
import urllib.parse

sys.path.insert(0, "/usr/local/lib/venax")
import venaxlib as vx

BIND = os.environ.get("VENAX_BIND", "0.0.0.0")
PORT = int(os.environ.get("VENAX_PORT", "8080"))
OLLAMA_HOST = os.environ.get("VENAX_OLLAMA_HOST", "127.0.0.1")
OLLAMA_PORT = int(os.environ.get("VENAX_OLLAMA_PORT", "11434"))
REGISTRY = (os.environ.get("VENAX_REGISTRY_HOST", "registry.ollama.ai"),
            int(os.environ.get("VENAX_REGISTRY_PORT", "443")))
STATIC_DIR = os.environ.get("VENAX_STATIC", "/usr/share/venax/web")
EXTRA_HOSTS = {h.strip().lower() for h in os.environ.get("VENAX_ALLOWED_HOSTS", "").split(",") if h.strip()}
MAX_BODY = 2 * 1024 * 1024
MAX_LINE = 4 * 1024 * 1024
CHAT_IDLE_TIMEOUT = 900
PULL_IDLE_TIMEOUT = 120
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
OFFLINE_RE = re.compile(r"no such host|dial tcp|i/o timeout|connection refused|lookup |network is unreachable|TLS handshake|EOF", re.I)
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8"),
}
CSP = "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'"


def log(msg):
    sys.stderr.write("[web] %s\n" % msg)
    sys.stderr.flush()


class HttpError(Exception):
    def __init__(self, status, message, code, hint=None):
        super().__init__(message)
        self.status, self.message, self.code, self.hint = status, message, code, hint


class ClientGone(Exception):
    pass


class UpstreamError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


_cache, _cache_lock = {}, threading.Lock()


def cached(key, ttl, fn):
    now = time.monotonic()
    with _cache_lock:
        e = _cache.get(key)
        if e and now - e[0] < ttl:
            return e[1]
    val = fn()
    with _cache_lock:
        _cache[key] = (time.monotonic(), val)
    return val


def agent(op, args=None, timeout=30):
    return vx.agent_call(op, args, timeout)


def valid_model(n):
    return isinstance(n, str) and bool(MODEL_RE.match(n)) and ".." not in n and "//" not in n


# ------------------------------------------------------------------ Ollama
def ollama_request(method, path, body=None, timeout=10):
    c = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT, timeout=timeout)
    try:
        data = None if body is None else json.dumps(body).encode("utf-8")
        c.request(method, path, body=data, headers={"Content-Type": "application/json"})
        r = c.getresponse()
        raw = r.read(8 * 1024 * 1024)
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            parsed = None
        return r.status, parsed, raw
    finally:
        c.close()


def _unit_state(key):
    try:
        for s in agent("services", timeout=8)["services"]:
            if s["key"] == key:
                return s["active"]
    except vx.AgentError:
        pass
    return None


def _probe_ollama():
    try:
        st, data, _ = ollama_request("GET", "/api/tags", timeout=3)
        if st == 200 and isinstance(data, dict):
            return {"state": "READY", "detail": "API answering", "models": data.get("models") or []}
        return {"state": "NOT_READY", "detail": "Ollama answered with HTTP %d" % st, "models": []}
    except (OSError, http.client.HTTPException) as e:
        unit = _unit_state("ollama")
        if unit in ("active", "activating", "reloading"):
            return {"state": "NOT_READY", "detail": "Ollama service is running but its API did not respond (%s)" % e, "models": []}
        if unit is None:
            return {"state": "FAILED", "detail": "Ollama API is not answering (%s)" % e, "models": []}
        return {"state": "FAILED", "detail": "Ollama service is %s" % unit, "models": []}


def ollama_state():
    return cached("ollama", 2, _probe_ollama)


def ollama_ps():
    try:
        st, data, _ = ollama_request("GET", "/api/ps", timeout=3)
        if st == 200 and isinstance(data, dict):
            return data.get("models") or []
    except (OSError, http.client.HTTPException):
        pass
    return None


def require_ollama():
    s = ollama_state()
    if s["state"] != "READY":
        raise HttpError(503, "Ollama is not ready: " + s["detail"], "OLLAMA_" + s["state"],
                        "Open the Services page to restart Ollama, or the Logs page to see why it failed.")
    return s


def registry_reachable():
    try:
        socket.create_connection(REGISTRY, timeout=4).close()
        return True
    except OSError:
        return False


def iter_ndjson(resp):
    """Yield dicts from an NDJSON HTTP response, independent of chunking."""
    def parse(line):
        line = line.strip()
        if not line:
            return None
        try:
            o = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise UpstreamError("UPSTREAM_MALFORMED", "Ollama sent a malformed response line")
        if not isinstance(o, dict):
            raise UpstreamError("UPSTREAM_MALFORMED", "Ollama sent an unexpected response")
        return o
    buf = b""
    while True:
        try:
            chunk = resp.read1(65536)
        except socket.timeout:
            raise UpstreamError("UPSTREAM_TIMEOUT", "Ollama stopped sending data (timed out)")
        except (OSError, http.client.HTTPException) as e:
            raise UpstreamError("UPSTREAM_ERROR", "Connection to Ollama was lost: %s" % e)
        if not chunk:
            break
        buf += chunk
        while True:
            i = buf.find(b"\n")
            if i < 0:
                break
            line, buf = buf[:i], buf[i + 1:]
            o = parse(line)
            if o is not None:
                yield o
        if len(buf) > MAX_LINE:
            raise UpstreamError("UPSTREAM_MALFORMED", "Ollama sent an oversized response line")
    o = parse(buf)
    if o is not None:
        yield o


# ------------------------------------------------------------ system info
def hw_summary():
    def f():
        h = agent("hardware", timeout=15)
        return {"cpu": h["cpu"]["model"], "threads": h["cpu"]["threads"], "ram_mb": h["memory"]["total_mb"],
                "gpus": [g["name"] for g in h["gpus"]]}
    try:
        return cached("hwsum", 60, f)
    except vx.AgentError:
        return None


def read_cpu():
    with open("/proc/stat", encoding="utf-8") as f:
        v = [int(x) for x in f.readline().split()[1:8]]
    return sum(v), v[3] + v[4]


def performance():
    t1, i1 = read_cpu()
    time.sleep(0.25)
    t2, i2 = read_cpu()
    cpu = round(100.0 * (1 - (i2 - i1) / max(1, t2 - t1)), 1)
    mem = {}
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("MemTotal", "MemAvailable"):
                mem[k] = int(v.split()[0]) // 1024
    total, avail = mem.get("MemTotal", 0), mem.get("MemAvailable", 0)
    temps = []
    for i in range(16):
        base = "/sys/class/thermal/thermal_zone%d" % i
        try:
            with open(base + "/temp", encoding="utf-8") as f:
                t = int(f.read().strip()) / 1000.0
            with open(base + "/type", encoding="utf-8") as f:
                temps.append({"name": f.read().strip(), "celsius": round(t, 1)})
        except (OSError, ValueError):
            continue

    def rd(p):
        try:
            with open(p, encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return None
    with open("/proc/uptime", encoding="utf-8") as f:
        up = float(f.read().split()[0])
    mhz = rd("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    return {"cpu_percent": cpu, "load": list(os.getloadavg()),
            "memory": {"total_mb": total, "used_mb": total - avail, "available_mb": avail,
                       "percent": round(100.0 * (total - avail) / total, 1) if total else None},
            "temperatures": temps, "cpu_mhz": int(mhz) // 1000 if mhz and mhz.isdigit() else None,
            "governor": rd("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
            "uptime_s": int(up), "loaded_models": ollama_ps() or []}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "VenaX/" + vx.VERSION
    sys_version = ""
    protocol_version = "HTTP/1.0"
    timeout = 60

    # ---------------------------------------------------------- plumbing
    def setup(self):
        super().setup()
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    def log_message(self, fmt, *args):
        log("%s %s" % (self.client_address[0], fmt % args))

    def log_request(self, code="-", size="-"):
        try:
            c = int(code)
        except (TypeError, ValueError):
            c = 0
        if c >= 400 or self.command in ("POST", "DELETE"):
            self.log_message('"%s" %s', self.requestline, code)

    def _sec_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)

    def _write(self, b):
        try:
            self.wfile.write(b)
        except OSError:
            pass

    def _emit(self, b):
        try:
            self.wfile.write(b)
            self.wfile.flush()
        except OSError as e:
            raise ClientGone() from e

    def send_json(self, obj, status=200):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self._sec_headers()
        self.end_headers()
        self._write(b)

    def send_err(self, status, message, code, hint=None, **extra):
        d = {"error": message, "code": code, "hint": hint}
        d.update(extra)
        self.send_json(d, status)

    def start_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self._sec_headers()
        self.end_headers()
        self.wfile.flush()

    def stream_error(self, code, message, hint=None):
        self._emit((json.dumps({"error": message, "code": code, "hint": hint}) + "\n").encode("utf-8"))

    def guard(self):
        host = (self.headers.get("Host") or "").strip().lower()
        h = host
        if h.startswith("["):
            h = h[1:h.find("]")] if "]" in h else h
        elif h.count(":") == 1:
            h = h.split(":")[0]
        ok = False
        try:
            ipaddress.ip_address(h)
            ok = True
        except ValueError:
            me = socket.gethostname().lower()
            ok = h in ("localhost", me, me + ".local", "venax", "venax.local") or h in EXTRA_HOSTS
        if not ok:
            self.send_err(400, "Unrecognised Host header; use the VenaX IP address", "BAD_HOST",
                          "Open http://<VenaX-IP>:%d" % PORT)
            return False
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlsplit(origin).netloc.lower() != host:
            self.send_err(403, "Cross-origin request refused", "BAD_ORIGIN")
            return False
        return True

    def read_json(self):
        if "application/json" not in (self.headers.get("Content-Type") or "").lower():
            raise HttpError(415, "Content-Type must be application/json", "BAD_CONTENT_TYPE")
        if self.headers.get("Transfer-Encoding"):
            raise HttpError(411, "Content-Length is required", "LENGTH_REQUIRED")
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise HttpError(400, "Invalid Content-Length", "BAD_REQUEST")
        if n < 0 or n > MAX_BODY:
            raise HttpError(413, "Request body too large (limit %d bytes)" % MAX_BODY, "TOO_LARGE")
        raw = self.rfile.read(n) if n else b"{}"
        if len(raw) != n and n:
            raise HttpError(400, "Request body was cut short", "BAD_REQUEST")
        try:
            obj = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise HttpError(400, "Request body is not valid JSON", "BAD_JSON")
        if not isinstance(obj, dict):
            raise HttpError(400, "Request body must be a JSON object", "BAD_JSON")
        return obj

    def dispatch(self, routes, path, arg):
        try:
            fn = routes.get(path)
            if fn is None and self.command == "DELETE" and path.startswith("/api/models/"):
                fn = Handler.h_delete_model
            if fn is None:
                self.send_err(404, "Not found", "NOT_FOUND")
            else:
                fn(self, arg)
        except ClientGone:
            pass
        except HttpError as e:
            try:
                self.send_err(e.status, e.message, e.code, e.hint)
            except Exception:
                pass
        except vx.AgentError as e:
            self.send_err(e.status if 400 <= e.status < 600 else 502, e.message, e.code, e.hint)
        except Exception:
            log("unhandled error on %s %s:\n%s" % (self.command, self.path, traceback.format_exc(limit=4)))
            try:
                self.send_err(500, "Internal error in the VenaX web service", "INTERNAL", "See the Logs page (venax-web).")
            except Exception:
                pass

    def do_GET(self):
        sp = urllib.parse.urlsplit(self.path)
        if not self.guard():
            return
        if sp.path in STATIC:
            return self.dispatch({sp.path: Handler.serve_static}, sp.path, sp.path)
        self.dispatch(self.GET, sp.path, urllib.parse.parse_qs(sp.query))

    def do_POST(self):
        if self.guard():
            self.dispatch(self.POST, urllib.parse.urlsplit(self.path).path, None)

    def do_DELETE(self):
        if self.guard():
            self.dispatch({}, urllib.parse.urlsplit(self.path).path, None)

    # ----------------------------------------------------------- handlers
    def serve_static(self, path):
        name, ctype = STATIC[path]
        try:
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                b = f.read()
        except OSError:
            raise HttpError(500, "UI file %s is missing from this image" % name, "UI_MISSING")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-cache")
        self._sec_headers()
        self.end_headers()
        self._write(b)

    def h_healthz(self, q):
        self.send_json({"status": "ok", "service": "venax-web", "version": vx.VERSION})

    def h_identity(self, q):
        urls = []
        try:
            urls = agent("network.status", timeout=8)["urls"]
        except vx.AgentError:
            pass
        host = self.headers.get("Host", "")
        if host and "http://" + host not in urls:
            urls.append("http://" + host)
        self.send_json({"name": "VenaX", "version": vx.VERSION, "hostname": socket.gethostname(),
                        "port": PORT, "urls": urls, "mdns": "http://venax.local:%d" % PORT,
                        "note": "The IP URL is authoritative; mDNS is a convenience and may not work on hotspots."})

    def h_status(self, q):
        agent_state = {"state": "READY"}
        try:
            n = agent("network.status", timeout=10)
            net = {k: n.get(k) for k in ("state", "interface", "kind", "ssid", "signal", "ipv4", "gateway", "dns",
                                         "internet", "urls", "addresses", "mdns", "hint")}
        except vx.AgentError as e:
            agent_state = {"state": "FAILED", "error": e.message}
            net = {"state": "UNKNOWN", "interface": None, "ipv4": None, "internet": False, "urls": [],
                   "hint": "Network status unavailable: " + e.message}
        ol = ollama_state()
        stor = vx.storage_info()
        warnings = []
        if agent_state["state"] != "READY":
            warnings.append("VenaX agent is not responding: network, Wi-Fi and service controls are unavailable.")
        if ol["state"] != "READY":
            warnings.append("Ollama is not ready: " + ol["detail"])
        if stor["state"] != "READY":
            warnings.append("Persistent storage is not available (%s): downloaded models are stored in RAM and will be lost at reboot." % stor["reason"])
        if net["state"] in ("NO_INTERFACE", "INTERFACE_AVAILABLE", "CONNECTING", "LOCAL_CONNECTED"):
            warnings.append(net.get("hint") or net["state"])
        ready = ol["state"] == "READY" and net["state"] in ("LOCAL_READY", "INTERNET_AVAILABLE") and agent_state["state"] == "READY"
        self.send_json({
            "venax": "ready" if ready else "degraded", "version": vx.VERSION, "hostname": socket.gethostname(),
            "network": net, "web": {"state": "READY"}, "agent": agent_state,
            "ollama": {"state": ol["state"], "detail": ol["detail"]},
            "storage": stor, "models": {"count": len(ol["models"])},
            "hardware": hw_summary(), "warnings": warnings,
        })

    def h_network(self, q):
        self.send_json(agent("network.status", {"fresh": "fresh" in q}, timeout=15))

    def h_interfaces(self, q):
        self.send_json(agent("network.interfaces", timeout=15))

    def h_scan(self, q):
        args = {"cached": "cached" in q}
        if q.get("interface"):
            args["interface"] = q["interface"][0]
        self.send_json(agent("network.scan", args, timeout=40))

    def h_net_diag(self, q):
        self.send_json(agent("network.diagnostics", timeout=40))

    def _net_post(self, op, keys, timeout):
        body = self.read_json()
        self.send_json(agent(op, {k: body[k] for k in keys if k in body}, timeout=timeout))

    def h_connect(self, q):
        self._net_post("network.connect", ("ssid", "password", "hidden", "security", "interface"), 100)

    def h_disconnect(self, q):
        self._net_post("network.disconnect", ("interface",), 30)

    def h_reconnect(self, q):
        self._net_post("network.reconnect", ("interface",), 80)

    def h_forget(self, q):
        self._net_post("network.forget", ("ssid",), 30)

    def h_models(self, q):
        s = ollama_state()
        if s["state"] != "READY":
            return self.send_err(503, "Ollama is not ready: " + s["detail"], "OLLAMA_" + s["state"],
                                 "Open the Services page to restart Ollama.", models=[], ollama=s["state"])
        models = []
        for m in s["models"]:
            d = m.get("details") or {}
            models.append({"name": m.get("name"), "size": m.get("size"), "modified_at": m.get("modified_at"),
                           "parameter_size": d.get("parameter_size"), "quantization": d.get("quantization_level")})
        self.send_json({"models": models, "ollama": "READY"})

    def h_delete_model(self, q):
        name = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path[len("/api/models/"):])
        if not valid_model(name):
            raise HttpError(400, "Invalid model name", "BAD_MODEL")
        require_ollama()
        st, data, raw = ollama_request("DELETE", "/api/delete", {"model": name, "name": name}, timeout=60)
        cached_pop("ollama")
        if st == 200:
            return self.send_json({"deleted": name})
        if st == 404:
            raise HttpError(404, "Model %s is not installed" % name, "MODEL_NOT_FOUND")
        raise HttpError(502, "Ollama could not delete the model: %s" % ((data or {}).get("error") or "HTTP %d" % st), "DELETE_FAILED")

    def _clean_messages(self, msgs):
        if not isinstance(msgs, list) or not msgs or len(msgs) > 400:
            raise HttpError(400, "messages must be a non-empty list (max 400)", "BAD_MESSAGES")
        out, total = [], 0
        for m in msgs:
            if not isinstance(m, dict) or m.get("role") not in ("system", "user", "assistant") or not isinstance(m.get("content"), str):
                raise HttpError(400, "each message needs a role (system/user/assistant) and text content", "BAD_MESSAGES")
            total += len(m["content"])
            out.append({"role": m["role"], "content": m["content"]})
        if total > 1_500_000:
            raise HttpError(413, "Conversation is too long", "TOO_LARGE")
        return out

    def _clean_options(self, o):
        if o is None:
            return None
        lim = {"temperature": (0, 2), "top_p": (0, 1), "num_predict": (-1, 8192), "num_ctx": (256, 131072)}
        if not isinstance(o, dict):
            raise HttpError(400, "options must be an object", "BAD_OPTION")
        out = {}
        for k, v in o.items():
            if k not in lim or isinstance(v, bool) or not isinstance(v, (int, float)) or not lim[k][0] <= v <= lim[k][1]:
                raise HttpError(400, "Unsupported or out-of-range option: %s" % str(k)[:30], "BAD_OPTION")
            out[k] = v
        return out

    def _relay(self, resp, pull):
        saw_end = False
        try:
            for obj in iter_ndjson(resp):
                if pull and "error" in obj and OFFLINE_RE.search(str(obj["error"])):
                    obj["code"] = "INTERNET_OFFLINE"
                    obj["hint"] = "Model downloads need Internet. Installed models still work offline."
                self._emit((json.dumps(obj) + "\n").encode("utf-8"))
                if obj.get("done") is True or "error" in obj or (pull and obj.get("status") == "success"):
                    saw_end = True
        except UpstreamError as e:
            self.stream_error(e.code, e.message, "Check the Services page; Ollama may need a restart.")
            return
        if not saw_end:
            self.stream_error("UPSTREAM_TRUNCATED", "Ollama closed the connection before the response finished",
                              "Try again; check the Logs page if it keeps happening.")

    def _stream_from_ollama(self, path, body, idle, pull):
        conn = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT, timeout=idle)
        try:
            try:
                conn.request("POST", path, body=json.dumps(body).encode("utf-8"), headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
            except (OSError, http.client.HTTPException) as e:
                raise HttpError(502, "Could not reach Ollama: %s" % e, "OLLAMA_UNREACHABLE", "Open the Services page.")
            if resp.status != 200:
                raw = resp.read(65536)
                try:
                    msg = json.loads(raw.decode("utf-8")).get("error")
                except (ValueError, AttributeError, UnicodeDecodeError):
                    msg = None
                if resp.status == 404:
                    raise HttpError(404, msg or "Model not found", "MODEL_NOT_FOUND", "Install it on the Models page.")
                raise HttpError(502, "Ollama refused the request: %s" % (msg or "HTTP %d" % resp.status), "OLLAMA_ERROR")
            self.start_stream()
            self._relay(resp, pull)
        finally:
            conn.close()

    def h_chat(self, q):
        body = self.read_json()
        model = body.get("model")
        if not valid_model(model):
            raise HttpError(400, "Invalid or missing model name", "BAD_MODEL")
        msgs = self._clean_messages(body.get("messages"))
        opts = self._clean_options(body.get("options"))
        require_ollama()
        req = {"model": model, "messages": msgs, "stream": True}
        if opts:
            req["options"] = opts
        self._stream_from_ollama("/api/chat", req, CHAT_IDLE_TIMEOUT, False)

    def h_pull(self, q):
        body = self.read_json()
        name = body.get("name", body.get("model"))
        if not valid_model(name):
            raise HttpError(400, "Invalid or missing model name", "BAD_MODEL")
        require_ollama()
        if not registry_reachable():
            raise HttpError(503, "Internet is unavailable: model downloads need to reach %s. Installed models still work offline." % REGISTRY[0],
                            "INTERNET_OFFLINE", "Connect VenaX to a network with Internet access (e.g. a hotspot with data) and try again.")
        self._stream_from_ollama("/api/pull", {"model": name, "name": name, "stream": True}, PULL_IDLE_TIMEOUT, True)
        cached_pop("ollama")

    def h_hardware(self, q):
        hw = agent("hardware", timeout=20)
        ps = ollama_ps()
        using, evidence = None, ""
        if ps is None:
            evidence = "Ollama is not reachable, so GPU use cannot be checked."
        elif not ps:
            evidence = "No model is loaded right now; start a chat and check again."
        else:
            vram = sum(m.get("size_vram", 0) for m in ps)
            using = vram > 0
            evidence = ("Loaded model uses %d MB of GPU memory." % (vram // 1048576)) if using else "Loaded model is running on the CPU (0 bytes of GPU memory in use)."
        hw["acceleration"] = {"gpu_detected": bool(hw["gpus"]), "ollama_using_gpu": using, "evidence": evidence}
        self.send_json(hw)

    def h_performance(self, q):
        self.send_json(performance())

    def h_storage(self, q):
        self.send_json(agent("storage", timeout=20))

    def h_storage_rescan(self, q):
        self.read_json()
        self.send_json(agent("storage.rescan", timeout=15))

    def h_services(self, q):
        self.send_json(agent("services", timeout=15))

    def h_restart(self, q):
        body = self.read_json()
        self.send_json(agent("services.restart", {"service": body.get("service")}, timeout=20))

    def h_diag(self, q):
        self.send_json(agent("diagnostics", timeout=100))

    def h_logs(self, q):
        self.send_json(agent("logs", {"unit": (q.get("unit") or ["ollama"])[0], "lines": (q.get("lines") or ["150"])[0]}, timeout=20))

    GET = {
        "/healthz": h_healthz, "/api/identity": h_identity, "/api/status": h_status, "/api/network": h_network,
        "/api/network/interfaces": h_interfaces, "/api/network/scan": h_scan, "/api/network/diagnostics": h_net_diag,
        "/api/models": h_models, "/api/hardware": h_hardware, "/api/performance": h_performance,
        "/api/storage": h_storage, "/api/services": h_services, "/api/diagnostics": h_diag, "/api/logs": h_logs,
    }
    POST = {
        "/api/chat": h_chat, "/api/models/pull": h_pull, "/api/network/connect": h_connect,
        "/api/network/disconnect": h_disconnect, "/api/network/reconnect": h_reconnect,
        "/api/network/forget": h_forget, "/api/services/restart": h_restart, "/api/storage/rescan": h_storage_rescan,
    }


def cached_pop(key):
    with _cache_lock:
        _cache.pop(key, None)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        et = sys.exc_info()[0]
        if et and issubclass(et, (ConnectionError, socket.timeout)):
            return
        log("connection error from %s:\n%s" % (client_address[0], traceback.format_exc(limit=3)))


def main():
    srv = Server((BIND, PORT), Handler)
    log("venax-web %s listening on %s:%d" % (vx.VERSION, BIND, PORT))
    srv.serve_forever()


if __name__ == "__main__":
    main()
EOF_WEB

install_file "$ROOTFS/usr/share/venax/web/index.html" 644 <<'EOF_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VenaX</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header><div class="brand">VenaX <small>local AI server</small></div><div id="pill" class="pill">connecting...</div></header>
<nav id="nav"></nav>
<div id="banners"></div>
<main id="main"></main>
<script src="/app.js"></script>
</body>
</html>
EOF_HTML

install_file "$ROOTFS/usr/share/venax/web/style.css" 644 <<'EOF_CSS'
:root{color-scheme:dark;--bg:#080b12;--card:#0d131e;--line:#202a3a;--fg:#e8edf7;--mut:#8f9bb0;--acc:#6d8cff;--ok:#3ecf8e;--warn:#ffb454;--bad:#ff6b6b}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,Segoe UI,sans-serif}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 20px;border-bottom:1px solid var(--line);background:#0c111b;position:sticky;top:0;z-index:5}
.brand{font-size:20px;font-weight:600}small{color:var(--mut);font-weight:400;font-size:13px}
nav{display:flex;gap:6px;flex-wrap:wrap;padding:10px 20px}
nav button.active{background:var(--acc);border-color:var(--acc);color:#fff}
main{max-width:1100px;margin:auto;padding:6px 20px 40px}
button{background:#151c29;color:var(--fg);border:1px solid #2b3548;border-radius:9px;padding:8px 13px;cursor:pointer;font:inherit}
button:hover{background:#1b2535}button:disabled{opacity:.5;cursor:default}
button.primary{background:var(--acc);border-color:var(--acc);color:#fff}button.danger{border-color:#6b2b2b;color:var(--bad)}
input,textarea,select{width:100%;background:#0a0f18;color:var(--fg);border:1px solid #2b3548;border-radius:9px;padding:10px;font:inherit}
textarea{resize:vertical}label{display:block;color:var(--mut);font-size:13px;margin:8px 0 3px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:15px;margin-bottom:12px}
.card h3{margin:0 0 8px;font-size:14px;color:var(--mut);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.big{font-size:22px;font-weight:600}.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.row>.grow{flex:1;min-width:160px}
.pill{padding:5px 12px;border-radius:999px;background:#182235;font-size:13px}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.mut{color:var(--mut)}
.pill.ok{background:#12301f}.pill.warn{background:#3a2c10}.pill.bad{background:#3a1717}
.banner{margin:6px 20px;padding:10px 14px;border-radius:10px;border:1px solid var(--line);background:#101826}
.banner.warn{border-color:#6b5420;background:#241d0c}.banner.bad{border-color:#6b2b2b;background:#241010}.banner.info{border-color:#27406b}
.msgs{min-height:45vh;max-height:60vh;overflow:auto;padding:4px 0}
.msg{padding:12px 14px;margin:8px 0;border-radius:12px;white-space:pre-wrap;line-height:1.5;word-wrap:break-word}
.msg.user{background:#15243a;margin-left:12%}.msg.ai{background:#111824;margin-right:12%}.msg.err{background:#2a1313}
table{width:100%;border-collapse:collapse}td,th{padding:7px 8px;border-bottom:1px solid var(--line);text-align:left;font-size:14px;vertical-align:top}
th{color:var(--mut);font-weight:600}
pre{white-space:pre-wrap;word-break:break-word;background:#0a0f18;border:1px solid var(--line);border-radius:10px;padding:12px;font-size:12.5px;max-height:60vh;overflow:auto}
.progress{height:8px;background:#202938;border-radius:10px;overflow:hidden;margin-top:6px}.bar{height:100%;width:0;background:var(--acc)}
.url{font-family:ui-monospace,Consolas,monospace;font-size:17px;word-break:break-all}.hidden{display:none}
EOF_CSS

install_file "$ROOTFS/usr/share/venax/web/app.js" 644 <<'EOF_JS'
'use strict';
const $ = (s, r = document) => r.querySelector(s);
function h(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'value') e.value = v;
    else e.setAttribute(k, v);
  }
  for (const c of kids.flat()) { if (c == null || c === false) continue; e.append(c.nodeType ? c : document.createTextNode(String(c))); }
  return e;
}
const fmtBytes = n => { if (n == null) return '?'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (n >= 1024 && i < 4) { n /= 1024; i++; } return n.toFixed(i ? 1 : 0) + ' ' + u[i]; };
const fmtMB = n => n == null ? '?' : n >= 1024 ? (n / 1024).toFixed(1) + ' GB' : n + ' MB';
const stClass = s => ['READY', 'ready', 'LOCAL_READY', 'INTERNET_AVAILABLE', 'active', 'PASS'].includes(s) ? 'ok' : ['FAILED', 'failed', 'NO_INTERFACE', 'NOT_AVAILABLE', 'FAIL'].includes(s) ? 'bad' : 'warn';
const NET_LABEL = { NO_INTERFACE: 'No network adapter', INTERFACE_AVAILABLE: 'Adapter present, not connected', CONNECTING: 'Connecting...', LOCAL_CONNECTED: 'Connected (web not answering yet)', LOCAL_READY: 'Local network ready', INTERNET_AVAILABLE: 'Local network + Internet', UNKNOWN: 'Unknown' };

class ApiError extends Error { constructor(m, code, hint, status) { super(m); this.code = code; this.hint = hint; this.status = status; } }
function errText(e) { return e.message + (e.hint ? '  -> ' + e.hint : ''); }
async function api(path, opts = {}) {
  const o = { headers: { 'Content-Type': 'application/json' }, signal: opts.signal };
  if (opts.json !== undefined) { o.method = opts.method || 'POST'; o.body = JSON.stringify(opts.json); } else if (opts.method) o.method = opts.method;
  let r;
  try { r = await fetch(path, o); } catch (e) {
    if (e.name === 'AbortError') throw e;
    throw new ApiError('Cannot reach VenaX (' + e.message + '). Check that this device is still on the same network.', 'NETWORK', null, 0);
  }
  if (opts.stream && r.ok) return r;
  let data = null; try { data = await r.json(); } catch (e) { /* not json */ }
  if (!r.ok) throw new ApiError((data && data.error) || ('HTTP ' + r.status), data && data.code, data && data.hint, r.status);
  return data;
}
// NDJSON reader: JSON objects may span network chunks, so buffer until newline.
async function readNDJSON(resp, onObj) {
  const reader = resp.body.getReader(), dec = new TextDecoder();
  let buf = '';
  const flush = line => { line = line.trim(); if (!line) return; let o; try { o = JSON.parse(line); } catch (e) { return; } onObj(o); };
  for (;;) {
    const { value, done } = await reader.read();
    if (value) buf += dec.decode(value, { stream: true });
    let i; while ((i = buf.indexOf('\n')) >= 0) { flush(buf.slice(0, i)); buf = buf.slice(i + 1); }
    if (done) break;
  }
  buf += dec.decode(); flush(buf);
}

const cfg = { get(k, d) { try { const v = localStorage.getItem('venax.' + k); return v == null ? d : v; } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem('venax.' + k, v); } catch (e) { /* ignore */ } } };
let STATUS = null, current = null, cleanup = null, timers = [];
const chatHistory = [];

// ------------------------------------------------------------- status/banners
async function pollStatus() {
  const pill = $('#pill'), box = $('#banners');
  try {
    STATUS = await api('/api/status');
    const s = STATUS, net = s.network;
    pill.textContent = 'VenaX: ' + s.venax.toUpperCase();
    pill.className = 'pill ' + (s.venax === 'ready' ? 'ok' : 'warn');
    box.replaceChildren();
    if (net.state === 'LOCAL_READY') box.append(h('div', { class: 'banner info' }, 'Internet: OFFLINE. Local AI: ' + (s.ollama.state === 'READY' ? 'READY' : s.ollama.state) + '. This is normal; installed models keep working. Only model downloads need Internet.'));
    for (const w of s.warnings) if (!(net.state === 'LOCAL_READY' && w === net.hint)) box.append(h('div', { class: 'banner warn' }, w));
  } catch (e) {
    STATUS = null; pill.textContent = 'VenaX: unreachable'; pill.className = 'pill bad';
    box.replaceChildren(h('div', { class: 'banner bad' }, errText(e)));
  }
  if (current && PAGES[current].onStatus) PAGES[current].onStatus();
}

// ------------------------------------------------------------------- pages
function kv(rows) { return h('table', {}, rows.map(([k, v]) => h('tr', {}, h('th', {}, k), h('td', {}, v)))); }
function card(title, ...kids) { return h('div', { class: 'card' }, h('h3', {}, title), kids); }
function every(fn, ms) { timers.push(setInterval(() => { if (!document.hidden) fn(); }, ms)); }

const PAGES = {
  dashboard: { title: 'Dashboard', render(root) {
    const grid = h('div', { class: 'cards' }), urls = h('div', { class: 'card' }), perf = h('div', { class: 'card' });
    root.append(urls, grid, perf);
    const draw = () => {
      const s = STATUS; if (!s) return;
      const n = s.network;
      urls.replaceChildren(h('h3', {}, 'Open VenaX from another device'),
        n.urls && n.urls.length ? n.urls.map((u, i) => h('div', { class: 'url' }, h('a', { href: u }, u), i ? h('small', {}, '  (other address)') : '')) : h('div', { class: 'warn' }, 'No IPv4 address yet. ' + (n.hint || '')),
        h('small', {}, 'Use the IP address. ' + (n.mdns || '') + ' is only a convenience and may not work on hotspots.'));
      const hw = s.hardware || {};
      grid.replaceChildren(
        card('VenaX', h('div', { class: 'big ' + stClass(s.venax) }, s.venax.toUpperCase()), 'Version ' + s.version),
        card('Network', h('div', { class: 'big ' + stClass(n.state) }, n.state), NET_LABEL[n.state] || '', h('br'), n.interface ? n.interface + (n.ssid ? ' / ' + n.ssid : '') + ' / ' + (n.ipv4 || '-') : '',
          h('br'), 'Internet: ', h('b', { class: n.internet ? 'ok' : 'warn' }, n.internet ? 'ONLINE' : 'OFFLINE')),
        card('Ollama', h('div', { class: 'big ' + stClass(s.ollama.state) }, s.ollama.state), s.ollama.detail, h('br'), s.models.count + ' model(s) installed'),
        card('Storage', h('div', { class: 'big ' + stClass(s.storage.state) }, s.storage.state), s.storage.persistent ? 'Persistent (VENAXDATA)' : s.storage.reason),
        card('Services', 'Web: ' + s.web.state, h('br'), 'Agent: ' + s.agent.state),
        card('Hardware', hw.cpu || '?', h('br'), (hw.threads || '?') + ' threads, ' + fmtMB(hw.ram_mb) + ' RAM', h('br'), (hw.gpus && hw.gpus.length) ? hw.gpus.join('; ') : 'No GPU detected'));
    };
    const drawPerf = async () => {
      try {
        const p = await api('/api/performance');
        perf.replaceChildren(h('h3', {}, 'Live load'), kv([['CPU', p.cpu_percent + ' %  (load ' + p.load.map(x => x.toFixed(2)).join(' / ') + ')'], ['RAM', fmtMB(p.memory.used_mb) + ' / ' + fmtMB(p.memory.total_mb) + ' (' + p.memory.percent + ' %)'],
          ['Temperature', p.temperatures.length ? p.temperatures.map(t => t.name + ' ' + t.celsius + ' C').join(', ') : 'not reported'], ['Loaded models', p.loaded_models.length ? p.loaded_models.map(m => m.name).join(', ') : 'none']]));
      } catch (e) { perf.replaceChildren(h('div', { class: 'bad' }, errText(e))); }
    };
    drawPerf(); draw(); every(drawPerf, 4000);
    PAGES.dashboard.onStatus = draw;
  } },

  chat: { title: 'Chat', render(root) {
    const sel = h('select', { class: 'grow' }), msgs = h('div', { class: 'msgs' }), box = h('textarea', { rows: '3', placeholder: 'Message your local model...  (Enter = send, Shift+Enter = newline)' });
    const sendBtn = h('button', { class: 'primary' }, 'Send'), stopBtn = h('button', { class: 'hidden' }, 'Stop'), stats = h('small', {});
    let ctl = null;
    const load = async () => {
      try {
        const d = await api('/api/models'); const prev = sel.value || cfg.get('model', '');
        sel.replaceChildren(...(d.models.length ? d.models.map(m => h('option', { value: m.name }, m.name)) : [h('option', { value: '' }, 'No models installed - open Models')]));
        if ([...sel.options].some(o => o.value === prev)) sel.value = prev;
      } catch (e) { sel.replaceChildren(h('option', { value: '' }, e.code === 'OLLAMA_FAILED' || e.code === 'OLLAMA_NOT_READY' ? 'Ollama is not ready' : errText(e))); }
    };
    const add = (cls, text) => { const d = h('div', { class: 'msg ' + cls }, text); msgs.append(d); d.scrollIntoView({ block: 'end' }); return d; };
    for (const m of chatHistory) add(m.role === 'user' ? 'user' : 'ai', m.content);
    const send = async () => {
      const text = box.value.trim(), model = sel.value;
      if (!text || !model || ctl) return;
      cfg.set('model', model); box.value = ''; add('user', text);
      const msgsOut = []; const sys = cfg.get('system', '').trim();
      if (sys) msgsOut.push({ role: 'system', content: sys });
      chatHistory.push({ role: 'user', content: text }); msgsOut.push(...chatHistory);
      const out = add('ai', ''); let full = '', last = null, failed = false;
      ctl = new AbortController(); sendBtn.disabled = true; stopBtn.classList.remove('hidden'); stats.textContent = '';
      try {
        const body = { model, messages: msgsOut }; const t = parseFloat(cfg.get('temperature', ''));
        if (!isNaN(t)) body.options = { temperature: t };
        const r = await api('/api/chat', { json: body, stream: true, signal: ctl.signal });
        await readNDJSON(r, j => {
          if (j.error) { failed = true; out.classList.add('err'); out.textContent = (full ? full + '\n\n' : '') + 'Error: ' + j.error + (j.hint ? '\n' + j.hint : ''); return; }
          if (j.message && j.message.content) { full += j.message.content; out.textContent = full; out.scrollIntoView({ block: 'end' }); }
          if (j.done) last = j;
        });
      } catch (e) {
        if (e.name === 'AbortError') { out.textContent = full + '\n[stopped]'; } else { failed = true; out.classList.add('err'); out.textContent = errText(e); }
      }
      if (full && !failed) chatHistory.push({ role: 'assistant', content: full }); else if (failed || !full) chatHistory.pop();
      if (last && last.eval_count && last.eval_duration) stats.textContent = (last.eval_count / (last.eval_duration / 1e9)).toFixed(1) + ' tokens/s';
      ctl = null; sendBtn.disabled = false; stopBtn.classList.add('hidden'); box.focus();
    };
    sendBtn.onclick = send; stopBtn.onclick = () => ctl && ctl.abort();
    box.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
    root.append(h('div', { class: 'row' }, sel, h('button', { onclick: load }, 'Refresh'), h('button', { onclick: () => { chatHistory.length = 0; msgs.replaceChildren(); } }, 'Clear')), msgs, box, h('div', { class: 'row' }, sendBtn, stopBtn, stats));
    load();
    return () => { if (ctl) ctl.abort(); };
  } },

  models: { title: 'Models', render(root) {
    const installed = h('div', { class: 'card' }), custom = h('input', { placeholder: 'e.g. llama3.2:3b' }), cat = h('div', { class: 'cards' }), note = h('div', {});
    const CATALOG = [['qwen2.5:0.5b', 'Very light', '~0.4 GB'], ['gemma2:2b', 'Light', '~1.6 GB'], ['llama3.2:3b', 'Light', '~2.0 GB'], ['phi3:mini', 'Light', '~2.2 GB'], ['mistral:7b', 'Medium', '~4.1 GB'], ['llama3.1:8b', 'Medium', '~4.7 GB'], ['gemma2:9b', 'Medium', '~5.4 GB'], ['qwen2.5:14b', 'Heavy', '~9 GB'], ['qwen2.5:32b', 'Heavy', '~20 GB'], ['llama3.1:70b', 'Very heavy', 'very large']];
    const load = async () => {
      try {
        const d = await api('/api/models');
        installed.replaceChildren(h('h3', {}, 'Installed models'), d.models.length ? h('table', {}, d.models.map(m => h('tr', {}, h('td', {}, m.name), h('td', { class: 'mut' }, fmtBytes(m.size)), h('td', { class: 'mut' }, [m.parameter_size, m.quantization].filter(Boolean).join(' ')),
          h('td', {}, h('button', { class: 'danger', onclick: async () => { if (!confirm('Delete ' + m.name + '?')) return; try { await api('/api/models/' + encodeURIComponent(m.name), { method: 'DELETE' }); } catch (e) { alert(errText(e)); } load(); } }, 'Delete'))))) : h('div', { class: 'mut' }, 'No models installed yet.'));
      } catch (e) { installed.replaceChildren(h('h3', {}, 'Installed models'), h('div', { class: 'bad' }, errText(e))); }
    };
    const install = async (name, st, bar) => {
      st.className = ''; st.textContent = 'Starting...'; bar.style.width = '0%';
      try {
        const r = await api('/api/models/pull', { json: { name }, stream: true }); let ok = false, err = null;
        await readNDJSON(r, j => {
          if (j.error) { err = j; return; }
          let t = j.status || ''; if (j.total && j.completed != null) { const p = 100 * j.completed / j.total; bar.style.width = p.toFixed(1) + '%'; t += ' ' + p.toFixed(0) + '% (' + fmtBytes(j.completed) + ' / ' + fmtBytes(j.total) + ')'; }
          st.textContent = t; if (j.status === 'success') ok = true;
        });
        if (err) { st.className = 'bad'; st.textContent = err.error + (err.hint ? ' ' + err.hint : ''); } else if (ok) { st.className = 'ok'; st.textContent = 'Installed'; bar.style.width = '100%'; load(); } else { st.className = 'bad'; st.textContent = 'Download ended unexpectedly. Try again (partial data is kept).'; }
      } catch (e) { st.className = 'bad'; st.textContent = errText(e); }
    };
    const entry = (name, tag, size) => { const st = h('small', {}), bar = h('div', { class: 'bar' }); return h('div', { class: 'card' }, h('b', {}, name), h('br'), tag ? h('small', {}, tag + ' ' + size) : '', h('div', { class: 'row' }, h('button', { onclick: () => install(name, st, bar) }, 'Install')), h('div', { class: 'progress' }, bar), st); };
    cat.append(...CATALOG.map(c => entry(...c)));
    const customRow = h('div', { class: 'row' }, h('div', { class: 'grow' }, custom), h('button', { class: 'primary', onclick: () => { const n = custom.value.trim(); if (!n) return; const st = h('small', {}), bar = h('div', { class: 'bar' }); note.replaceChildren(h('div', { class: 'card' }, h('b', {}, n), h('div', { class: 'progress' }, bar), st)); install(n, st, bar); } }, 'Install custom'));
    const warn = () => { const s = STATUS; note.dataset.k = ''; };
    root.append(installed, h('div', { class: 'card' }, h('h3', {}, 'Install a model'), h('small', {}, 'Downloads need Internet. Already installed models work fully offline.'), customRow, note), cat);
    load(); PAGES.models.onStatus = warn;
  } },

  network: { title: 'Network', render(root) {
    const cur = h('div', { class: 'card' }), list = h('div', { class: 'card' }), ifs = h('div', { class: 'card' }), diag = h('div', { class: 'card hidden' }), msg = h('div', {});
    const act = async (fn, label) => { msg.className = 'warn'; msg.textContent = label + '...'; try { const r = await fn(); msg.className = 'ok'; msg.textContent = label + ' done.' + (r && r.note ? ' ' + r.note : ''); } catch (e) { msg.className = 'bad'; msg.textContent = errText(e); } loadCur(); };
    const loadCur = async () => {
      try {
        const n = await api('/api/network'), ia = await api('/api/network/interfaces');
        cur.replaceChildren(h('h3', {}, 'Current connection'), h('div', { class: 'big ' + stClass(n.state) }, n.state), h('div', { class: 'mut' }, n.hint || ''),
          kv([['Interface', n.interface ? n.interface + ' (' + n.kind + ')' : '-'], ['SSID', n.ssid || '-'], ['Signal', n.signal != null ? n.signal + ' %' : '-'], ['IPv4', n.ipv4 ? n.ipv4 + (n.prefix ? '/' + n.prefix : '') : '-'], ['Gateway', n.gateway || '-'], ['DNS', (n.dns || []).join(', ') || '-'],
            ['Internet', n.internet ? 'ONLINE' : 'OFFLINE (local network still works)'], ['Open from clients', (n.urls || []).join('   ') || '-'], ['NetworkManager', n.networkmanager]]),
          h('div', { class: 'row' }, h('button', { onclick: () => act(() => api('/api/network/reconnect', { json: {} }), 'Reconnect') }, 'Reconnect'), h('button', { class: 'danger', onclick: () => { if (confirm('Disconnecting may cut off this browser if you reach VenaX through that interface.')) act(() => api('/api/network/disconnect', { json: {} }), 'Disconnect'); } }, 'Disconnect'), h('button', { onclick: runDiag }, 'Run network diagnostics')),
          (n.saved_wifi || []).length ? h('div', {}, h('small', {}, 'Saved Wi-Fi: '), n.saved_wifi.map(p => h('span', {}, p.ssid + ' ', h('button', { onclick: () => act(() => api('/api/network/forget', { json: { ssid: p.ssid } }), 'Forget ' + p.ssid) }, 'Forget'), ' '))) : '');
        ifs.replaceChildren(h('h3', {}, 'Interfaces'), h('table', {}, h('tr', {}, ['Name', 'Type', 'State', 'IPv4'].map(x => h('th', {}, x))), ia.interfaces.map(i => h('tr', {}, h('td', {}, i.name), h('td', {}, i.kind), h('td', {}, i.state + (i.carrier === false ? ' (no carrier)' : '')), h('td', {}, i.ipv4.map(a => a.ip).join(', ') || '-')))));
      } catch (e) { cur.replaceChildren(h('h3', {}, 'Current connection'), h('div', { class: 'bad' }, errText(e))); }
    };
    const connectForm = (net) => {
      const pw = h('input', { type: 'password', placeholder: 'Wi-Fi password', autocomplete: 'off' }), ssid = h('input', { placeholder: 'Network name (SSID)', value: net ? net.ssid : '' }), hid = h('input', { type: 'checkbox' });
      const open = net && net.security === 'open';
      const f = h('div', {}, net ? h('b', {}, net.ssid) : ssid, open ? '' : pw, net ? '' : h('label', {}, hid, ' Hidden network'),
        h('small', { class: 'warn' }, 'If you are using VenaX through its current Wi-Fi, switching networks will disconnect this browser; reopen VenaX at its new address shown on the VenaX console.'),
        h('div', { class: 'row' }, h('button', { class: 'primary', onclick: () => { const body = { ssid: net ? net.ssid : ssid.value, password: open ? '' : pw.value, hidden: hid.checked }; pw.value = ''; act(() => api('/api/network/connect', { json: body }), 'Connect to ' + body.ssid); f.remove(); } }, 'Connect'), h('button', { onclick: () => f.remove() }, 'Cancel')));
      return f;
    };
    const scan = async () => {
      list.replaceChildren(h('h3', {}, 'Wi-Fi networks'), h('div', { class: 'mut' }, 'Scanning...'));
      try {
        const d = await api('/api/network/scan');
        list.replaceChildren(h('h3', {}, 'Wi-Fi networks (' + d.interface + ')'), h('div', { class: 'row' }, h('button', { onclick: scan }, 'Scan Wi-Fi'), h('button', { onclick: () => list.append(connectForm(null)) }, 'Hidden network...')),
          h('table', {}, d.networks.map(n => { const slot = h('div', {}); return h('tr', {}, h('td', {}, n.ssid, n.in_use ? h('b', { class: 'ok' }, ' (connected)') : ''), h('td', { class: 'mut' }, n.signal + '%'), h('td', { class: 'mut' }, n.security),
            h('td', {}, n.supported ? h('button', { onclick: () => list.append(connectForm(n)) }, 'Connect') : h('small', { class: 'mut' }, 'not supported'))); })));
      } catch (e) { list.replaceChildren(h('h3', {}, 'Wi-Fi networks'), h('div', { class: 'bad' }, errText(e)), h('button', { onclick: scan }, 'Retry scan')); }
    };
    const runDiag = async () => {
      diag.classList.remove('hidden'); diag.replaceChildren(h('h3', {}, 'Network diagnostics'), 'Running...');
      try { const d = await api('/api/network/diagnostics'); diag.replaceChildren(h('h3', {}, 'Network diagnostics'), h('table', {}, d.checks.map(c => h('tr', {}, h('td', { class: stClass(c.status) }, c.status), h('td', {}, c.name), h('td', {}, c.message, c.hint && c.status !== 'PASS' ? h('div', { class: 'mut' }, c.hint) : '')))), h('pre', {}, d.journal)); } catch (e) { diag.replaceChildren(h('h3', {}, 'Network diagnostics'), h('div', { class: 'bad' }, errText(e))); }
    };
    root.append(cur, msg, list, ifs, diag); loadCur(); list.append(h('button', { onclick: scan }, 'Scan Wi-Fi')); every(loadCur, 6000);
  } },

  hardware: { title: 'Hardware', render(root) {
    const box = h('div', {}); root.append(box);
    (async () => {
      try {
        const d = await api('/api/hardware'), a = d.acceleration;
        box.replaceChildren(card('CPU', kv([['Model', d.cpu.model], ['Threads', d.cpu.threads], ['Cores', d.cpu.cores || '?'], ['Architecture', d.cpu.arch], ['Max MHz', d.cpu.max_mhz || '?'], ['Kernel', d.kernel]])),
          card('Memory', kv([['Total', fmtMB(d.memory.total_mb)], ['Available', fmtMB(d.memory.available_mb)]])),
          card('GPU', d.gpus.length ? kv(d.gpus.map(g => [g.vendor, g.name])) : 'No GPU detected on the PCI bus.', h('p', {}, h('b', {}, 'GPU detected: '), a.gpu_detected ? 'yes' : 'no', h('br'), h('b', {}, 'Ollama using GPU: '), a.ollama_using_gpu === null ? 'unknown' : a.ollama_using_gpu ? 'yes' : 'no', h('br'), h('small', {}, a.evidence))),
          card('Storage devices', d.disks.length ? kv(d.disks.map(x => [x.name, x.size + ' ' + (x.model || '') + (x.rm ? ' (removable)' : '')])) : 'none'),
          card('Network adapters', kv(d.network_adapters.map(x => [x.name, x.kind + ', driver ' + (x.driver || '?') + (x.kind === 'ethernet' ? (x.carrier ? ', cable connected' : ', no cable') : '')]))));
      } catch (e) { box.replaceChildren(h('div', { class: 'bad' }, errText(e))); }
    })();
  } },

  storage: { title: 'Storage', render(root) {
    const box = h('div', {}), msg = h('div', {});
    const load = async () => {
      try {
        const d = await api('/api/storage'), s = d.status;
        box.replaceChildren(card('Persistence', h('div', { class: 'big ' + stClass(s.state) }, s.state), s.reason, d.note ? h('p', { class: 'warn' }, d.note) : '',
          kv([['Device', s.device || '-'], ['Filesystem', s.fstype || '-'], ['Models path', s.models_path || '(ephemeral RAM)'], ['Free', s.free_kb != null ? fmtMB(Math.floor(s.free_kb / 1024)) : '-']]),
          h('button', { onclick: async () => { msg.textContent = 'Re-detecting...'; try { await api('/api/storage/rescan', { json: {} }); msg.textContent = 'Started. Ollama restarts automatically.'; } catch (e) { msg.textContent = errText(e); } setTimeout(load, 15000); } }, 'Retry detection'), msg),
          card('Space', kv(Object.entries(d.space).map(([k, v]) => [k + ' (' + v.path + ')', fmtMB(v.free_mb) + ' free of ' + fmtMB(v.total_mb)]))),
          card('Block devices', h('pre', {}, JSON.stringify(d.devices, null, 1))));
      } catch (e) { box.replaceChildren(h('div', { class: 'bad' }, errText(e))); }
    };
    root.append(box); load();
  } },

  services: { title: 'Services', render(root) {
    const box = h('div', { class: 'card' }), diag = h('div', { class: 'card hidden' });
    const load = async () => {
      try {
        const d = await api('/api/services');
        box.replaceChildren(h('h3', {}, 'Services'), h('table', {}, d.services.map(s => h('tr', {}, h('td', {}, s.unit), h('td', { class: stClass(s.active) }, s.active + (s.sub ? ' (' + s.sub + ')' : '')), h('td', { class: 'mut' }, s.restarts ? s.restarts + ' restarts' : ''),
          h('td', {}, s.restartable ? h('button', { onclick: async () => { if (s.key === 'venax-web' || s.key === 'networkmanager') { if (!confirm('Restarting ' + s.unit + ' briefly interrupts this page.')) return; } try { await api('/api/services/restart', { json: { service: s.key } }); } catch (e) { alert(errText(e)); } setTimeout(load, 2500); } }, 'Restart') : '')))),
          h('button', { onclick: runDiag }, 'Full diagnostics report'));
      } catch (e) { box.replaceChildren(h('h3', {}, 'Services'), h('div', { class: 'bad' }, errText(e))); }
    };
    const runDiag = async () => { diag.classList.remove('hidden'); diag.replaceChildren(h('h3', {}, 'Diagnostics'), 'Collecting...'); try { const d = await api('/api/diagnostics'); diag.replaceChildren(h('h3', {}, 'Diagnostics'), h('pre', {}, d.report)); } catch (e) { diag.replaceChildren(h('h3', {}, 'Diagnostics'), h('div', { class: 'bad' }, errText(e))); } };
    root.append(box, diag); load(); every(load, 5000);
  } },

  logs: { title: 'Logs', render(root) {
    const sel = h('select', {}, ['ollama', 'venax-web', 'venax-agent', 'venax-data', 'networkmanager', 'nftables', 'avahi', 'kernel'].map(u => h('option', { value: u }, u))), out = h('pre', {});
    const load = async () => { out.textContent = 'Loading...'; try { const d = await api('/api/logs?unit=' + encodeURIComponent(sel.value) + '&lines=200'); out.textContent = d.text || '(empty)'; out.scrollTop = out.scrollHeight; } catch (e) { out.textContent = errText(e); } };
    sel.onchange = load; root.append(h('div', { class: 'row' }, h('div', { class: 'grow' }, sel), h('button', { onclick: load }, 'Refresh')), out); load();
  } },

  settings: { title: 'Settings', render(root) {
    const sys = h('textarea', { rows: '4', placeholder: 'Optional system prompt added to every chat' }), temp = h('input', { placeholder: 'default (e.g. 0.7)' }), idn = h('div', {}), saved = h('small', {});
    sys.value = cfg.get('system', ''); temp.value = cfg.get('temperature', '');
    root.append(card('Chat preferences (stored in this browser only)', h('label', {}, 'System prompt'), sys, h('label', {}, 'Temperature (0-2)'), temp, h('div', { class: 'row' }, h('button', { class: 'primary', onclick: () => { cfg.set('system', sys.value); cfg.set('temperature', temp.value.trim()); saved.textContent = 'Saved.'; } }, 'Save'), saved)), card('This VenaX', idn));
    api('/api/identity').then(d => idn.replaceChildren(kv([['Version', d.version], ['Hostname', d.hostname], ['Addresses', d.urls.join('   ')], ['mDNS', d.mdns], ['Note', d.note]])), e => idn.textContent = errText(e));
  } },
};

function go(name) {
  if (!PAGES[name]) name = 'dashboard';
  if (cleanup) cleanup(); timers.forEach(clearInterval); timers = []; cleanup = null;
  current = name; const main = $('#main'); main.replaceChildren();
  document.querySelectorAll('#nav button').forEach(b => b.classList.toggle('active', b.dataset.page === name));
  cleanup = PAGES[name].render(main) || null;
  if (location.hash !== '#' + name) history.replaceState(null, '', '#' + name);
}
const nav = $('#nav');
for (const k of Object.keys(PAGES)) nav.append(h('button', { 'data-page': k, onclick: () => go(k) }, PAGES[k].title));
window.addEventListener('hashchange', () => go(location.hash.slice(1)));
pollStatus().then(() => go(location.hash.slice(1) || 'dashboard'));
setInterval(() => { if (!document.hidden) pollStatus(); }, 4000);
EOF_JS

# ------------------------------------------------------------------
step "10/14" "Console tools: wifi, venax-ctl, console, storage, diagnostics, self-test"
# ------------------------------------------------------------------
install_file "$ROOTFS/usr/local/bin/venax-ctl" 755 <<'EOF_CTL'
#!/usr/bin/env python3
"""venax-ctl <operation> [key=value ...]  -- talk to venax-agent (whitelisted ops)."""
import json
import sys

sys.path.insert(0, "/usr/local/lib/venax")
import venaxlib as vx

if len(sys.argv) < 2:
    sys.exit("usage: venax-ctl <operation> [key=value ...]   e.g. venax-ctl network.status")
args = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    if "password" in k.lower():
        sys.exit("refusing to take passwords on the command line; use the 'wifi' tool")
    try:
        args[k] = json.loads(v)
    except ValueError:
        args[k] = v
try:
    print(json.dumps(vx.agent_call(sys.argv[1], args, timeout=120), indent=2))
except vx.AgentError as e:
    sys.stderr.write("%s: %s%s\n" % (e.code, e.message, ("\n  " + e.hint) if e.hint else ""))
    sys.exit(1)
EOF_CTL

install_file "$ROOTFS/usr/local/bin/wifi" 755 <<'EOF_WIFI'
#!/usr/bin/env python3
"""VenaX Wi-Fi setup (console). Talks to venax-agent; the password only travels
over the local agent socket and never appears in a command line or log."""
import getpass
import os
import sys
import time

sys.path.insert(0, "/usr/local/lib/venax")
import venaxlib as vx

LINE = "=" * 60


def header(t):
    os.system("clear")
    print(LINE + "\n" + t.center(60) + "\n" + LINE + "\n")


def pause(msg="Press ENTER to continue..."):
    try:
        input(msg)
    except EOFError:
        pass


def call(op, args=None, timeout=40):
    return vx.agent_call(op, args or {}, timeout)


def wait_agent():
    for _ in range(40):
        try:
            call("ping", timeout=3)
            return True
        except vx.AgentError:
            time.sleep(1)
    return False


def show_error(e):
    print("\nFailed: %s" % e.message)
    if e.hint:
        print("  -> %s" % e.hint)
    print()


def connect(net, hidden=False):
    ssid = net["ssid"]
    sec = net.get("security", "auto") if net.get("security") else "auto"
    header("Wi-Fi Authentication")
    print("Network : %s\nSecurity: %s\n" % (ssid, net.get("security_raw") or ("hidden" if hidden else "?")))
    if net.get("security") in ("enterprise", "wep", "owe"):
        print("This network type (%s) is not supported by VenaX Wi-Fi setup.\nUse WPA2/WPA3, an open network, or a laptop/phone hotspot." % net["security"])
        pause()
        return False
    pw = ""
    if sec != "open":
        try:
            pw = getpass.getpass("Wi-Fi password: ")
        except (EOFError, KeyboardInterrupt):
            return False
        if not pw:
            print("Password cannot be empty for a secured network.")
            time.sleep(2)
            return False
    print("\nConnecting (up to ~60 s)...")
    try:
        r = vx.agent_call("network.connect", {"ssid": ssid, "password": pw, "hidden": hidden, "security": "auto" if hidden and not pw else sec}, 110)
    except vx.AgentError as e:
        pw = ""
        header("Connection Failed")
        show_error(e)
        pause("Press ENTER to return to the network list...")
        return False
    pw = ""
    header("Wi-Fi Connected")
    print("Network : %s\nAddress : %s\n" % (r["ssid"], r["ipv4"]))
    for u in r.get("urls", []):
        print("Open from another device:  %s" % u)
    print("\n" + r.get("note", ""))
    time.sleep(3)
    return True


def main():
    header("VenaX Wi-Fi")
    print("Waiting for the VenaX agent...")
    if not wait_agent():
        print("The VenaX agent is not running. Try: sudo systemctl status venax-agent")
        pause()
        return 1
    while True:
        header("VenaX Wi-Fi")
        print("Scanning for networks...\n")
        try:
            d = call("network.scan", {}, 40)
        except vx.AgentError as e:
            show_error(e)
            c = input("[r] retry   [q] quit : ").strip().lower()
            if c == "q":
                return 1
            continue
        nets = d["networks"]
        header("VenaX Wi-Fi  (adapter %s)" % d["interface"])
        if not nets:
            print("No Wi-Fi networks found.\n")
        for i, n in enumerate(nets, 1):
            print("  [%2d] %-34s %3d%%  %s%s" % (i, n["ssid"][:34], n["signal"], n["security_raw"], "  *" if n["in_use"] else ""))
        print("\n" + "-" * 60 + "\nEnter network number | r = rescan | h = hidden network | q = quit\n" + "-" * 60)
        try:
            c = input("Selection: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            return 1
        if c == "q":
            return 1
        if c == "r" or not c:
            continue
        if c == "h":
            ssid = input("Hidden network name (SSID): ").strip()
            if ssid and connect({"ssid": ssid, "security": "auto"}, hidden=True):
                return 0
            continue
        if c.isdigit() and 1 <= int(c) <= len(nets):
            if connect(nets[int(c) - 1]):
                return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)
EOF_WIFI

install_file "$ROOTFS/usr/local/sbin/venax-data" 755 <<'EOF_DATA'
#!/usr/bin/env bash
# Determine and RECORD persistence status, then pick Ollama's model directory.
# A status of READY means: labeled device found, mounted, writable by root AND
# by the ollama service user. Anything else is an explicit, reported ephemeral
# mode. Ollama waits for this unit (Requires/After), so it can never start
# against a guessed directory.
set -u
RUN=/run/venax
STATUS="$RUN/storage-status"
ENVF="$RUN/ollama.env"
MNT=/mnt/venax-data
EPH=/var/lib/venax-ephemeral-models
WAIT="${VENAX_DATA_WAIT:-12}"
mkdir -p "$RUN" "$MNT" "$EPH"
chown ollama:ollama "$EPH" 2>/dev/null || true

clean() { printf '%s' "$1" | tr '\n\r=' '   '; }
write_atomic() { local f="$1"; shift; printf '%s\n' "$@" > "$f.tmp" && chmod 644 "$f.tmp" && mv -f "$f.tmp" "$f"; }

ephemeral() {
    write_atomic "$STATUS" "STATUS=NOT_AVAILABLE" "REASON=$(clean "$1")" "PERSISTENT=0" "MODELS_PATH=$EPH"
    write_atomic "$ENVF" "OLLAMA_MODELS=$EPH" "VENAX_PERSISTENT=0"
    echo "[venax-data] DEGRADED MODE: persistent storage NOT available: $1" >&2
    echo "[venax-data] Ollama will use RAM-backed $EPH; models are lost at reboot." >&2
    exit 0
}

DEV="$(blkid -L VENAXDATA 2>/dev/null || true)"
for ((i = 0; i < WAIT && ${#DEV} == 0; i++)); do
    udevadm settle --timeout=2 >/dev/null 2>&1 || true
    DEV="$(blkid -L VENAXDATA 2>/dev/null || true)"
    [[ -n "$DEV" ]] || sleep 1
done
[[ -n "$DEV" ]] || ephemeral "no partition labeled VENAXDATA was detected (waited ${WAIT}s)"

FSTYPE="$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)"
if ! mountpoint -q "$MNT"; then
    OPTS="defaults,noatime"
    case "$FSTYPE" in
        vfat|exfat|ntfs|ntfs3) OPTS="$OPTS,uid=$(id -u ollama),gid=$(id -g ollama),umask=077" ;;
    esac
    if ! ERR="$(mount -o "$OPTS" "$DEV" "$MNT" 2>&1)"; then
        ephemeral "mount of $DEV failed: $ERR"
    fi
fi
mountpoint -q "$MNT" || ephemeral "mount reported success but $MNT is not a mountpoint"

PROBE="$MNT/.venax-write-test.$$"
( : > "$PROBE" ) 2>/dev/null || ephemeral "$DEV is mounted but not writable (read-only or dirty filesystem)"
rm -f "$PROBE"

mkdir -p "$MNT/ollama" "$MNT/nm-connections"
chown -R ollama:ollama "$MNT/ollama" 2>/dev/null || true
if ! runuser -u ollama -- test -w "$MNT/ollama" 2>/dev/null; then
    ephemeral "$MNT/ollama is not writable by the ollama service user (filesystem without Unix permissions? use ext4)"
fi

# Restore saved Wi-Fi profiles, then ask NetworkManager to re-read them.
if compgen -G "$MNT/nm-connections/*.nmconnection" >/dev/null; then
    install -d -m 700 /etc/NetworkManager/system-connections
    for f in "$MNT"/nm-connections/*.nmconnection; do
        install -m 600 -o root -g root "$f" /etc/NetworkManager/system-connections/ \
            || echo "[venax-data] WARNING: could not restore $(basename "$f")" >&2
    done
    for ((i = 0; i < 15; i++)); do
        [[ "$(systemctl is-active NetworkManager 2>/dev/null)" == active ]] && { nmcli connection reload >/dev/null 2>&1 || true; break; }
        sleep 1
    done
fi

FREE_KB="$(df -k --output=avail "$MNT" 2>/dev/null | tail -n1 | tr -d ' ')"
write_atomic "$STATUS" "STATUS=READY" "REASON=$(clean "mounted $DEV at $MNT")" "DEVICE=$DEV" "FSTYPE=$FSTYPE" \
    "PERSISTENT=1" "MODELS_PATH=$MNT/ollama" "FREE_KB=${FREE_KB:-0}"
write_atomic "$ENVF" "OLLAMA_MODELS=$MNT/ollama" "VENAX_PERSISTENT=1"
echo "[venax-data] READY: persistent storage on $DEV ($FSTYPE)"
EOF_DATA

install_file "$ROOTFS/usr/local/sbin/venax-performance" 755 <<'EOF_PERF'
#!/usr/bin/env bash
# Best-effort CPU tuning. Asks the governor / pstate driver for full range
# where those knobs exist. It does NOT reserve CPUs, change scheduling or
# touch firmware thermal/power limits, and never fails the boot.
set +e
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$gov" ] && echo performance > "$gov" 2>/dev/null
done
for f in /sys/devices/system/cpu/intel_pstate/max_perf_pct /sys/devices/system/cpu/amd_pstate/max_perf_pct; do
    [ -w "$f" ] && echo 100 > "$f" 2>/dev/null
done
exit 0
EOF_PERF

install_file "$ROOTFS/usr/local/bin/venax-hardware" 755 <<'EOF_HW'
#!/usr/bin/env bash
set +e
echo "VenaX hardware"; echo "=============================================="
echo; echo "CPU"; lscpu 2>/dev/null | awk -F: '/^Model name|^CPU\(s\)|^Architecture|^Thread|^Core/ {gsub(/^[ \t]+/,"",$2); print $1": "$2}'
echo; echo "RAM"; free -h
echo; echo "GPU (PCI detection only; says nothing about Ollama acceleration)"
lspci 2>/dev/null | grep -Ei 'vga|3d|display' || echo "No PCI GPU reported."
echo; echo "STORAGE"; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null
echo; echo "NETWORK"; ip -brief addr 2>/dev/null
echo; echo "OLLAMA loaded models (PROCESSOR column shows CPU/GPU use)"
curl -fsS --max-time 3 http://127.0.0.1:11434/api/ps >/dev/null 2>&1 && ollama ps || echo "Ollama not reachable."
EOF_HW

install_file "$ROOTFS/usr/local/bin/venax-status" 755 <<'EOF_STATUS'
#!/usr/bin/env bash
set +e
while true; do
    clear
    echo "VenaX live monitor"; echo "=============================================="
    uptime; top -bn1 2>/dev/null | sed -n '1,5p'; echo
    free -h; echo
    df -h / /mnt/venax-data 2>/dev/null || df -h /
    echo; echo "NETWORK"; venax-ctl network.status 2>/dev/null | jq -r '"state: \(.state)  iface: \(.interface)  ip: \(.ipv4)  internet: \(.internet)"' 2>/dev/null
    echo; echo "SERVICES"
    for u in NetworkManager venax-data venax-agent ollama venax-web nftables; do printf '  %-16s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
    echo; echo "LISTENING"; ss -tlnp 2>/dev/null | grep -E ':(8080|11434)\b|State'
    echo; echo "Ctrl+C to exit."; sleep 3
done
EOF_STATUS

install_file "$ROOTFS/usr/local/sbin/venax-diagnostics" 755 <<'EOF_DIAG'
#!/usr/bin/env bash
# Full diagnostics report. Never prints Wi-Fi secrets: connection profiles are
# listed by name only and the whole report is passed through a redaction filter.
set +u
if [[ $EUID -ne 0 ]]; then exec sudo -n "$0" "$@"; fi
sec() { printf '\n===== %s =====\n' "$1"; }
run() { "$@" 2>&1 | head -n "${LINES_MAX:-60}"; }
report() {
    echo "VenaX diagnostics  $(date -u +%FT%TZ)"
    sec "VERSION"; cat /etc/venax-release; echo "kernel: $(uname -r)"
    sec "CPU"; lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|Architecture'
    sec "RAM"; free -m
    sec "GPU"; lspci | grep -Ei 'vga|3d|display' || echo "none detected"
    sec "STORAGE / PERSISTENCE"; cat /run/venax/storage-status 2>&1; echo; cat /run/venax/ollama.env 2>&1; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
    sec "INTERFACES"; ip -br link; ip -4 -br addr
    sec "ROUTES"; ip -4 route; ip -6 route | head -n 10
    sec "NETWORKMANAGER"; nmcli general status; nmcli device status; nmcli -t -f NAME,TYPE,DEVICE connection show --active
    sec "WI-FI"; rfkill list; iw dev; LINES_MAX=40 run nmcli -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no
    sec "FIREWALL"; nft list ruleset
    sec "SERVICES"
    for u in NetworkManager venax-data venax-agent ollama venax-web nftables avahi-daemon; do printf '%-16s %s\n' "$u" "$(systemctl is-active $u)"; done
    systemctl --failed --no-pager
    sec "LISTENING PORTS"; ss -tlnup
    sec "AGENT SOCKET"; ls -l /run/venax/
    sec "HTTP CHECKS"
    echo "web /healthz  : $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8080/healthz)"
    echo "ollama /tags  : $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:11434/api/tags)"
    sec "SERVICE ERRORS (warnings and worse)"
    for u in ollama venax-web venax-agent venax-data NetworkManager; do echo "--- $u"; journalctl -u "$u" -p warning -n 15 --no-pager -o short 2>&1; done
    sec "FIRMWARE / WIFI KERNEL MESSAGES"; dmesg 2>/dev/null | grep -Ei 'firmware|iwlwifi|brcm|ath|rtl' | tail -n 25
}
report 2>&1 | sed -E 's/((psk|password|secret|passphrase)[A-Za-z0-9_-]*[ =:]+).*/\1[REDACTED]/I'
EOF_DIAG

install_file "$ROOTFS/usr/local/sbin/venax-self-test" 755 <<'EOF_SELF'
#!/usr/bin/env bash
# venax-self-test [--chat]   PASS/WARN/FAIL checks; exit 1 if any FAIL.
set +u
if [[ $EUID -ne 0 ]]; then exec sudo -n "$0" "$@"; fi
P=0; W=0; F=0
pass() { P=$((P+1)); printf '  [PASS] %s\n' "$*"; }
warn() { W=$((W+1)); printf '  [WARN] %s\n' "$*"; }
fail() { F=$((F+1)); printf '  [FAIL] %s\n' "$*"; }
echo "VenaX self-test"; echo "==============================================="

systemctl is-active --quiet NetworkManager && nmcli -t -f RUNNING general 2>/dev/null | grep -qx running \
    && pass "1  NetworkManager running" || fail "1  NetworkManager is not running"

NET="$(venax-ctl network.status 2>/dev/null)"
PHYS=""; for d in /sys/class/net/*; do [[ -e $d/device ]] && PHYS="$PHYS $(basename "$d")"; done
[[ -n "$PHYS" ]] && pass "2  network interface(s):$PHYS" || fail "2  no physical network interface"

IP="$(jq -r '.ipv4 // empty' <<<"$NET" 2>/dev/null)"
[[ -n "$IP" ]] || IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[[ -n "$IP" ]] && pass "3  IPv4 address $IP" || fail "3  no IPv4 address"

if [[ -n "$IP" ]] && ip -4 route show scope link 2>/dev/null | grep -q .; then pass "4  local (connected-subnet) route present"
else warn "4  no connected-subnet route"; fi

ss -ltn 2>/dev/null | grep -qE ':8080\b' && pass "5  web listener on :8080" || fail "5  nothing listening on :8080"

H="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8080/healthz)"
HI=""; [[ -n "$IP" ]] && HI="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$IP:8080/healthz")"
[[ "$H" == 200 ]] && pass "6  /healthz on 127.0.0.1" || fail "6  /healthz on 127.0.0.1 returned '$H'"
[[ -z "$IP" || "$HI" == 200 ]] || warn "6  /healthz via $IP returned '$HI'"

L="$(ss -ltn 2>/dev/null | awk '$4 ~ /:11434$/ {print $4}')"
if [[ "$L" == 127.0.0.1:11434 ]]; then pass "7  Ollama listens on localhost only"
elif [[ -n "$L" ]]; then warn "7  Ollama listens on $L (expected 127.0.0.1:11434)"
else fail "7  Ollama is not listening"; fi

TAGS="$(curl -fsS --max-time 4 http://127.0.0.1:11434/api/tags 2>/dev/null)"
[[ -n "$TAGS" ]] && pass "8  Ollama API answers" || fail "8  Ollama API did not answer"

SS="$(grep '^STATUS=' /run/venax/storage-status 2>/dev/null | cut -d= -f2)"
case "$SS" in READY) pass "9  persistent storage READY";; NOT_AVAILABLE) warn "9  storage NOT_AVAILABLE (ephemeral): $(grep '^REASON=' /run/venax/storage-status | cut -d= -f2-)";; *) fail "9  storage status unknown";; esac

if nft list ruleset 2>/dev/null | grep -q 'table inet venax'; then
    nft list ruleset | grep -q 'dport 11434' && warn "10 firewall exposes 11434" || pass "10 firewall loaded; 11434 not exposed"
else fail "10 VenaX firewall table not loaded"; fi

ST="$(curl -fsS --max-time 8 http://127.0.0.1:8080/api/status 2>/dev/null)"
if jq -e .venax >/dev/null 2>&1 <<<"$ST"; then
    V="$(jq -r .venax <<<"$ST")"; [[ "$V" == ready ]] && pass "11 /api/status: ready" || warn "11 /api/status: $V ($(jq -r '.warnings[0] // ""' <<<"$ST"))"
else fail "11 /api/status did not return JSON"; fi

venax-ctl ping >/dev/null 2>&1 && pass "12 venax-agent answers" || fail "12 venax-agent not reachable"

M="$(jq -r '.models[0].name // empty' <<<"$TAGS" 2>/dev/null)"
if [[ -n "$M" ]]; then
    curl -fsS --max-time 10 -d "{\"model\":\"$M\"}" http://127.0.0.1:11434/api/show >/dev/null 2>&1 \
        && pass "13 installed model readable: $M" || fail "13 cannot read model $M"
    if [[ "${1:-}" == "--chat" ]]; then
        OUT="$(curl -sN --max-time 240 -H 'Content-Type: application/json' -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}]}" http://127.0.0.1:8080/api/chat)"
        if tail -n1 <<<"$OUT" | jq -e '.done == true' >/dev/null 2>&1 && ! grep -q '"error"' <<<"$OUT"; then pass "13 chat through /api/chat completed"; else fail "13 chat through /api/chat failed: $(tail -n1 <<<"$OUT" | cut -c1-200)"; fi
    fi
else warn "13 no models installed (install one on the Models page)"; fi

echo "  Internet: $(jq -r 'if .internet then "ONLINE" else "OFFLINE (not an error)" end' <<<"$NET" 2>/dev/null)"
echo "-----------------------------------------------"
echo "RESULT: $P pass, $W warn, $F fail"
((F == 0))
EOF_SELF

install_file "$ROOTFS/usr/local/sbin/venax-console" 755 <<'EOF_CONSOLE'
#!/usr/bin/env bash
# Console: observes and displays only. Starts/restarts nothing (systemd does).
set -u
export LC_ALL=C.UTF-8
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
col() { case "$1" in READY|ready|LOCAL_READY|INTERNET_AVAILABLE|true|ONLINE) printf '%s%s%s' "$G" "$1" "$N";;
        FAILED|NO_INTERFACE|NOT_AVAILABLE|"AGENT DOWN"|DOWN) printf '%s%s%s' "$R" "$1" "$N";; *) printf '%s%s%s' "$Y" "$1" "$N";; esac; }
jqs() { [[ -n "$2" ]] && jq -r "$1" <<<"$2" 2>/dev/null; }
WIFI_OFFERED=0

draw() {
    local net st state iface kind ssid ip inet urls web ag ol ss sr nm hw
    net="$(venax-ctl network.status 2>/dev/null)"
    st="$(curl -fsS --max-time 4 http://127.0.0.1:8080/api/status 2>/dev/null)"
    state="$(jqs '.state' "$net")"; [[ -n "$state" ]] || state="AGENT DOWN"
    iface="$(jqs '.interface // "-"' "$net")"; kind="$(jqs '.kind // ""' "$net")"; ssid="$(jqs '.ssid // ""' "$net")"
    ip="$(jqs '.ipv4 // empty' "$net")"
    inet="$(jqs 'if .internet then "ONLINE" else "OFFLINE" end' "$net")"
    mapfile -t urls < <(jqs '.urls[]?' "$net")
    web="$(jqs '.web.state' "$st")"; [[ -n "$web" ]] || web="DOWN"
    ag="$(jqs '.agent.state' "$st")"; [[ -n "$ag" ]] || ag="?"
    ol="$(jqs '.ollama.state' "$st")"; [[ -n "$ol" ]] || ol="?"
    ss="$(jqs '.storage.state' "$st")"; [[ -n "$ss" ]] || ss="$(grep '^STATUS=' /run/venax/storage-status 2>/dev/null | cut -d= -f2)"
    sr="$(jqs '.storage.reason' "$st")"
    echo "============================================================"
    if [[ "$(jqs '.venax' "$st")" == ready ]]; then printf '%s                       VENA X READY%s\n' "$B$G" "$N"
    else printf '%s                     VENA X: NOT READY YET%s\n' "$B$Y" "$N"; fi
    echo "============================================================"
    printf ' Network   : %s   (%s%s)\n' "$(col "$state")" "$iface" "${ssid:+, Wi-Fi \"$ssid\"}"
    printf ' IP        : %s\n' "${ip:-none}"
    printf ' Internet  : %s' "$(col "$inet")"; [[ "$inet" == OFFLINE ]] && printf '  (local AI is unaffected)'; echo
    printf ' Web UI    : %s    Ollama: %s    Agent: %s\n' "$(col "$web")" "$(col "$ol")" "$(col "$ag")"
    printf ' Storage   : %s' "$(col "${ss:-UNKNOWN}")"; [[ "$ss" != READY ]] && printf '  %s' "${sr:-}"; echo
    printf ' Models    : %s installed\n' "$(jqs '.models.count // 0' "$st")"
    hw="$(jqs '"\(.hardware.cpu // "?"), \(.hardware.threads // "?") threads, \((.hardware.ram_mb // 0)/1024|floor) GB RAM"' "$st")"
    printf ' Hardware  : %s\n' "${hw:-?}"
    echo
    if ((${#urls[@]})); then
        printf '%s OPEN FROM CLIENT:%s\n' "$B" "$N"
        for u in "${urls[@]}"; do printf '    %s%s%s\n' "$B" "$u" "$N"; done
        echo "    (mDNS http://venax.local:8080 is a convenience only)"
    else
        echo " No address yet: $(jqs '.hint // ""' "$net")"
        echo " Press [w] to join Wi-Fi (laptop/phone hotspot or router), or plug in Ethernet."
    fi
    echo
    echo "------------------------------------------------------------"
    echo " [w] Wi-Fi   [d] diagnostics   [t] self-test   [h] hardware"
    echo " [m] monitor [s] shell         (everything else: use the browser)"
    echo "------------------------------------------------------------"
}

while true; do
    out="$(draw)"
    printf '\e[H\e[J%s\n' "$out"
    LAST_STATE="$(venax-ctl network.status 2>/dev/null | jq -r .state 2>/dev/null)"
    up="$(cut -d. -f1 /proc/uptime)"
    if ((!WIFI_OFFERED && up > 25)) && [[ "$LAST_STATE" == INTERFACE_AVAILABLE ]] \
        && venax-ctl network.interfaces 2>/dev/null | jq -e '.wifi_adapters | length > 0' >/dev/null 2>&1; then
        WIFI_OFFERED=1; /usr/local/bin/wifi; continue
    fi
    key=""
    read -r -s -n1 -t 3 key || true
    case "$key" in
        w|W) /usr/local/bin/wifi ;;
        d|D) venax-diagnostics | less -R ;;
        t|T) venax-self-test; read -r -p "Press ENTER..." _ ;;
        h|H) venax-hardware | less -R ;;
        m|M) venax-status ;;
        s|S) clear; echo "Type 'exit' to return to the VenaX status screen."; /bin/bash ;;
    esac
done
EOF_CONSOLE

# ------------------------------------------------------------------
step "11/14" "systemd units, NetworkManager profiles, firewall, discovery"
# ------------------------------------------------------------------
install_file "$ROOTFS/etc/systemd/system/venax-data.service" 644 <<'EOF'
[Unit]
Description=VenaX persistent storage detection (VENAXDATA) and Wi-Fi profile restore
After=local-fs.target systemd-udevd.service systemd-tmpfiles-setup.service
Before=ollama.service venax-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=VENAX_DATA_WAIT=12
ExecStart=/usr/local/sbin/venax-data
TimeoutStartSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/ollama.service" 644 <<'EOF'
[Unit]
Description=Ollama local inference server (VenaX, localhost only)
After=venax-data.service
Requires=venax-data.service

[Service]
Type=simple
User=ollama
Group=ollama
# Written by venax-data: persistent VENAXDATA path or the explicit ephemeral path.
# Deliberately NOT optional: no file means no start, never a silent wrong directory.
EnvironmentFile=/run/venax/ollama.env
Environment=HOME=/usr/share/ollama
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=OLLAMA_KEEP_ALIVE=10m
Environment=OLLAMA_NUM_PARALLEL=1
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_FLASH_ATTENTION=1
ExecStart=/usr/bin/ollama serve
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/venax-agent.service" 644 <<'EOF'
[Unit]
Description=VenaX agent (privileged, whitelisted operations over a local socket)
After=venax-data.service NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1 PYTHONIOENCODING=utf-8 LC_ALL=C.UTF-8
ExecStart=/usr/bin/python3 /usr/local/sbin/venax-agent
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelModules=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/venax-web.service" 644 <<'EOF'
[Unit]
Description=VenaX web UI and API (unprivileged, port 8080)
# Wants, not Requires: the UI must stay up and report FAILED states even if
# Ollama or the agent are down. No dependency on network-online: it must also
# serve a laptop on a direct cable or hotspot with no Internet.
After=venax-agent.service ollama.service
Wants=venax-agent.service ollama.service

[Service]
Type=simple
User=venax-web
Group=venax-web
SupplementaryGroups=venax-ctl
Environment=PYTHONUNBUFFERED=1 PYTHONIOENCODING=utf-8 LC_ALL=C.UTF-8
ExecStart=/usr/bin/python3 /usr/local/sbin/venax-web
Restart=always
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/venax-performance.service" 644 <<'EOF'
[Unit]
Description=VenaX best-effort CPU performance tuning
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/venax-performance

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/venax.target" 644 <<'EOF'
[Unit]
Description=VenaX appliance (storage, agent, Ollama, web UI)
Wants=venax-data.service venax-agent.service ollama.service venax-web.service
After=venax-data.service venax-agent.service ollama.service venax-web.service

[Install]
WantedBy=multi-user.target
EOF

install_file "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" 644 <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin venax --noclear %I $TERM
Type=idle
EOF

# NetworkManager: the single network authority.
install_file "$ROOTFS/etc/NetworkManager/conf.d/venax.conf" 644 <<'EOF'
[main]
plugins=keyfile
no-auto-default=*

[device]
wifi.scan-rand-mac-address=no

[connection]
# 2 = disable Wi-Fi power save (sleeping radios drop inbound client traffic)
wifi.powersave=2
wifi.cloned-mac-address=preserve
ethernet.cloned-mac-address=preserve
EOF

# Ethernet: DHCP first (router, laptop internet-sharing, ICS); if no DHCP
# server answers within 15 s fall back to IPv4 link-local (169.254.x.x),
# which makes a bare laptop<->VenaX cable work with no router at all.
NMDIR="$ROOTFS/etc/NetworkManager/system-connections"
install -d -m 700 "$NMDIR"
install_file "$NMDIR/venax-ethernet-dhcp.nmconnection" 600 <<EOF
[connection]
id=VenaX Ethernet (DHCP)
uuid=$(cat /proc/sys/kernel/random/uuid)
type=ethernet
autoconnect=true
autoconnect-priority=0
autoconnect-retries=1

[ethernet]

[ipv4]
method=auto
may-fail=false
dhcp-timeout=15

[ipv6]
method=auto
may-fail=true
EOF
install_file "$NMDIR/venax-ethernet-linklocal.nmconnection" 600 <<EOF
[connection]
id=VenaX Ethernet (link-local)
uuid=$(cat /proc/sys/kernel/random/uuid)
type=ethernet
autoconnect=true
autoconnect-priority=-10

[ethernet]

[ipv4]
method=link-local

[ipv6]
method=auto
may-fail=true
EOF

# Firewall: LAN -> 8080 only; Ollama 11434 is localhost-only (not opened).
# Protocols are written NUMERICALLY (1 = ICMP, 58 = ICMPv6) so the ruleset
# never depends on /etc/protocols name resolution.
install_file "$ROOTFS/etc/nftables.conf" 755 <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet venax {
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state invalid drop
        ct state established,related accept

        meta l4proto 1 accept
        meta l4proto 58 accept

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept

        udp dport 5353 accept
        tcp dport 8080 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

install_file "$ROOTFS/etc/avahi/services/venax.service" 644 <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">VenaX on %h</name>
  <service>
    <type>_http._tcp</type>
    <port>8080</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
EOF

install_file "$ROOTFS/home/venax/.bash_profile" 644 <<'EOF'
if [ -z "${VENAX_CONSOLE_STARTED:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    export VENAX_CONSOLE_STARTED=1
    /usr/local/sbin/venax-console
fi
EOF
install_file "$ROOTFS/home/venax/.bashrc" 644 <<'EOF'
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
PS1='\[\e[1;36m\]venax\[\e[0m\]@\[\e[1;35m\]\h\[\e[0m\]:\[\e[1;32m\]\w\[\e[0m\]\$ '
alias status='venax-status'
alias hardware='venax-hardware'
EOF
in_chroot chown -R venax:venax /home/venax

# ------------------------------------------------------------------
step "12/14" "Enabling services and trimming the image"
# ------------------------------------------------------------------
in_chroot systemctl daemon-reload
in_chroot systemctl enable getty@tty1.service nftables.service venax-data.service ollama.service \
    venax-agent.service venax-web.service venax-performance.service venax.target

# ------------------------------------------------------------------
step "13/14" "Build-time validation (failures abort the build)"
# ------------------------------------------------------------------
info "bash syntax"
for f in usr/local/sbin/venax-console usr/local/sbin/venax-data usr/local/sbin/venax-performance \
         usr/local/sbin/venax-diagnostics usr/local/sbin/venax-self-test \
         usr/local/bin/venax-hardware usr/local/bin/venax-status; do
    bash -n "$ROOTFS/$f" || fatal "shell syntax error in /$f"
    [[ -x "$ROOTFS/$f" ]] || fatal "/$f is not executable"
done
bash -n "$SELF" || fatal "build-iso.sh itself fails bash -n"

info "python compile"
for f in usr/local/lib/venax/venaxlib.py usr/local/sbin/venax-agent usr/local/sbin/venax-web \
         usr/local/bin/wifi usr/local/bin/venax-ctl; do
    in_chroot python3 -m py_compile "/$f" || fatal "python compile error in /$f"
done
find "$ROOTFS/usr/local" -name __pycache__ -type d -prune -exec rm -rf {} +

info "static UI files present"
for f in index.html app.js style.css; do [[ -s "$ROOTFS/usr/share/venax/web/$f" ]] || fatal "missing UI file $f"; done

info "nftables ruleset"
if [[ "${VENAX_SKIP_NFT_CHECK:-0}" == 1 ]]; then
    warn "nft check skipped (VENAX_SKIP_NFT_CHECK=1)"
else
    in_chroot nft -c -f /etc/nftables.conf || fatal "nftables.conf failed validation (set VENAX_SKIP_NFT_CHECK=1 only if your build host lacks nf_tables)"
fi

info "systemd units"
if [[ "${VENAX_SKIP_UNIT_VERIFY:-0}" == 1 ]]; then
    warn "unit verification skipped (VENAX_SKIP_UNIT_VERIFY=1)"
else
    for u in venax-data.service ollama.service venax-agent.service venax-web.service venax-performance.service venax.target; do
        in_chroot systemd-analyze verify "/etc/systemd/system/$u" || fatal "systemd-analyze verify failed for $u"
    done
fi

info "runtime test: web server + streaming proxy against a fake Ollama"
install_file "$ROOTFS/tmp/venax-web-test.py" 644 <<'EOF_TEST'
import http.client, http.server, json, os, socket, subprocess, sys, threading, time

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

PIECES = ["H\u00e9llo", " w\u00f6rld", " \u2014 ", "\u4f60\u597d", " \U0001F30D", "!"]
FAILS = []
def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond: FAILS.append(name)

class Fake(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def chunk(self, b):
        self.wfile.write(b"%x\r\n" % len(b) + b + b"\r\n"); self.wfile.flush()
    def jsend(self, obj, code=200):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/api/tags": self.jsend({"models": [{"name": "test:1b", "size": 5, "modified_at": "x", "details": {}}]})
        elif self.path == "/api/ps": self.jsend({"models": []})
        else: self.jsend({}, 404)
    def do_DELETE(self):
        n = int(self.headers.get("Content-Length", "0")); req = json.loads(self.rfile.read(n))
        self.jsend({}, 200 if req.get("model") == "test:1b" else 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0")); req = json.loads(self.rfile.read(n))
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        if self.path == "/api/pull":
            for c in (10, 50, 100):
                self.chunk((json.dumps({"status": "pulling abc", "total": 100, "completed": c}) + "\n").encode())
            self.chunk(b'{"status":"success"}\n'); self.wfile.write(b"0\r\n\r\n"); return
        model = req["model"]
        if model == "bad:1b":
            self.chunk(b"this is not json\n"); self.wfile.write(b"0\r\n\r\n"); return
        count = 60 if model == "slow:1b" else 1
        for _ in range(count):
            for p in PIECES:
                line = (json.dumps({"model": model, "message": {"role": "assistant", "content": p}, "done": False}, ensure_ascii=False) + "\n").encode("utf-8")
                mid = len(line) // 2 + 1          # split mid-line, often mid multi-byte character
                self.chunk(line[:mid]); time.sleep(0.005 if model != "slow:1b" else 0.03); self.chunk(line[mid:])
        if model != "trunc:1b":
            self.chunk((json.dumps({"model": model, "message": {"role": "assistant", "content": ""}, "done": True}) + "\n").encode())
        self.wfile.write(b"0\r\n\r\n")

class FakeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, *a): pass

OP, WP1, WP2 = free_port(), free_port(), free_port()
fake = FakeServer(("127.0.0.1", OP), Fake); threading.Thread(target=fake.serve_forever, daemon=True).start()
CLOSED = free_port()

def start_web(port, registry_port):
    env = dict(os.environ, VENAX_PORT=str(port), VENAX_BIND="127.0.0.1", VENAX_OLLAMA_PORT=str(OP),
               VENAX_AGENT_SOCK="/nonexistent/agent.sock", VENAX_REGISTRY_HOST="127.0.0.1",
               VENAX_REGISTRY_PORT=str(registry_port))
    p = subprocess.Popen([sys.executable, "/usr/local/sbin/venax-web"], env=env, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.3).close(); return p
        except OSError: time.sleep(0.1)
    p.kill(); raise SystemExit("web server did not start")

def req(port, method, path, body=None, ctype="application/json"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    h = {"Content-Type": ctype} if body is not None else {}
    c.request(method, path, body=json.dumps(body).encode() if isinstance(body, (dict, list)) else body, headers=h)
    r = c.getresponse(); data = r.read(); c.close(); return r.status, data

def lines(data): return [json.loads(l) for l in data.decode("utf-8").splitlines() if l.strip()]
CHAT = {"model": "test:1b", "messages": [{"role": "user", "content": "hi"}]}
EXPECT = "".join(PIECES)
web1 = start_web(WP1, OP)       # registry reachable (fake port)
web2 = start_web(WP2, CLOSED)   # registry unreachable -> "offline"
try:
    s, d = req(WP1, "GET", "/healthz"); check("healthz", s == 200 and json.loads(d)["status"] == "ok")
    s, d = req(WP1, "GET", "/"); check("index served", s == 200 and b"VenaX" in d)
    s, d = req(WP1, "GET", "/app.js"); check("app.js served", s == 200 and len(d) > 1000)
    s, d = req(WP1, "GET", "/api/status"); j = json.loads(d)
    check("status ollama READY + agent FAILED reported", s == 200 and j["ollama"]["state"] == "READY" and j["agent"]["state"] == "FAILED", j)
    s, d = req(WP1, "GET", "/api/models"); check("models list", s == 200 and json.loads(d)["models"][0]["name"] == "test:1b")
    s, d = req(WP1, "GET", "/api/network"); check("agent down -> structured 503", s == 503 and json.loads(d)["code"] == "AGENT_DOWN", d)
    s, d = req(WP1, "GET", "/api/performance"); check("performance", s == 200 and "cpu_percent" in json.loads(d))
    s, d = req(WP1, "POST", "/api/chat", CHAT)
    L = lines(d); got = "".join(o.get("message", {}).get("content", "") for o in L)
    check("chat streaming reassembles unicode across split chunks", s == 200 and got == EXPECT and L[-1].get("done") is True, (s, got))
    s, d = req(WP1, "POST", "/api/chat", dict(CHAT, model="trunc:1b")); L = lines(d)
    check("truncated upstream reported", L[-1].get("code") == "UPSTREAM_TRUNCATED", L[-1:])
    s, d = req(WP1, "POST", "/api/chat", dict(CHAT, model="bad:1b")); L = lines(d)
    check("malformed upstream reported", L[-1].get("code") == "UPSTREAM_MALFORMED", L[-1:])
    s, d = req(WP1, "POST", "/api/chat", dict(CHAT, model="x; rm -rf /")); check("bad model name rejected", s == 400)
    s, d = req(WP1, "POST", "/api/chat", {"model": "test:1b", "messages": "nope"}); check("bad messages rejected", s == 400)
    s, d = req(WP1, "POST", "/api/chat", b"{}", ctype="text/plain"); check("non-JSON content type rejected", s == 415)
    s, d = req(WP1, "GET", "/../../etc/passwd"); check("path traversal 404", s == 404)
    s, d = req(WP1, "DELETE", "/api/models/..%2F..%2Fetc"); check("bad delete name rejected", s == 400)
    s, d = req(WP1, "DELETE", "/api/models/test%3A1b"); check("delete model", s == 200 and json.loads(d)["deleted"] == "test:1b", d)
    sk = socket.create_connection(("127.0.0.1", WP1), timeout=5)
    sk.sendall(b"POST /api/chat HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 99999999\r\n\r\n")
    check("oversized body refused", b" 413 " in sk.recv(4096).split(b"\r\n")[0]); sk.close()
    sk = socket.create_connection(("127.0.0.1", WP1), timeout=5)
    sk.sendall(b"GET /healthz HTTP/1.0\r\nHost: evil.example.com\r\n\r\n")
    check("foreign Host header refused", b" 400 " in sk.recv(4096).split(b"\r\n")[0]); sk.close()
    # client disconnects mid-stream must not hurt the server or other clients
    body = json.dumps(dict(CHAT, model="slow:1b")).encode()
    sk = socket.create_connection(("127.0.0.1", WP1), timeout=5)
    sk.sendall(b"POST /api/chat HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    sk.recv(512); sk.close(); time.sleep(0.3)
    s, d = req(WP1, "GET", "/healthz"); check("server alive after client disconnect", s == 200)
    # concurrency: several simultaneous streaming chats
    results = []
    def worker():
        s2, d2 = req(WP1, "POST", "/api/chat", CHAT); L2 = lines(d2)
        results.append("".join(o.get("message", {}).get("content", "") for o in L2) == EXPECT and L2[-1].get("done") is True)
    ts = [threading.Thread(target=worker) for _ in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    check("8 concurrent chats all correct", len(results) == 8 and all(results), results)
    s, d = req(WP1, "POST", "/api/models/pull", {"name": "test:1b"}); L = lines(d)
    check("pull progress stream", s == 200 and L[-1].get("status") == "success" and any(o.get("completed") == 50 for o in L), L[-2:])
    s, d = req(WP2, "POST", "/api/models/pull", {"name": "test:1b"})
    check("pull while offline -> INTERNET_OFFLINE", s == 503 and json.loads(d)["code"] == "INTERNET_OFFLINE", d)
    s, d = req(WP2, "POST", "/api/chat", CHAT); L = lines(d)
    check("chat still works while offline", "".join(o.get("message", {}).get("content", "") for o in L) == EXPECT)
finally:
    web1.kill(); web2.kill(); fake.shutdown()
print("RESULT: %d failure(s)" % len(FAILS))
sys.exit(1 if FAILS else 0)
EOF_TEST
if [[ "${VENAX_SKIP_RUNTIME_TEST:-0}" == 1 ]]; then
    warn "runtime test skipped (VENAX_SKIP_RUNTIME_TEST=1)"
else
    in_chroot python3 /tmp/venax-web-test.py || fatal "web/streaming runtime test failed"
    ready "web server, API validation and NDJSON streaming verified"
fi
rm -f "$ROOTFS/tmp/venax-web-test.py"
find "$ROOTFS/usr/local" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ------------------------------------------------------------------
step "14/14" "Finalizing image and building the ISO"
# ------------------------------------------------------------------
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/resolv.conf"
in_chroot update-initramfs -u -k all
in_chroot dpkg-query -W -f='${Package} ${Version}\n' > "$OUTPUT_DIR/${ISO_NAME%.iso}.packages.txt"
rm -rf "$ROOTFS"/usr/share/man/* "$ROOTFS"/usr/share/info/* "$ROOTFS"/usr/share/lintian \
       "$ROOTFS"/var/cache/apt/* "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/log/* 2>/dev/null || true
find "$ROOTFS/tmp" "$ROOTFS/var/tmp" -mindepth 1 -delete 2>/dev/null || true
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

unmount_chroot || fatal "chroot mounts could not be unmounted; refusing to continue"
trap cleanup EXIT

KERNEL="$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' -type f | sort -V | tail -n1)"
INITRD="$(find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' -type f | sort -V | tail -n1)"
[[ -n "$KERNEL" ]] || fatal "kernel not found in rootfs"
[[ -n "$INITRD" ]] || fatal "initramfs not found in rootfs"
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd"

mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -comp zstd -b 256K -noappend

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0

menuentry "VenaX ${VERSION}" {
    linux /live/vmlinuz boot=live
    initrd /live/initrd
}

menuentry "VenaX ${VERSION} (safe graphics: nomodeset)" {
    linux /live/vmlinuz boot=live nomodeset
    initrd /live/initrd
}
EOF

grub-mkrescue -o "$OUTPUT_DIR/$ISO_NAME" "$ISO_DIR"
(cd "$OUTPUT_DIR" && sha256sum "$ISO_NAME" > "${ISO_NAME}.sha256" && sha256sum -c "${ISO_NAME}.sha256")
cp "$OUTPUT_DIR/${ISO_NAME}.sha256" "$OUTPUT_DIR/SHA256SUMS"

cat > "$OUTPUT_DIR/RELEASE_NOTES.txt" <<EOF
VenaX ${VERSION}  (built ${BUILD_DATE})
Base: Debian ${DEBIAN_RELEASE} (pinned suite; apt packages are NOT snapshot-pinned, so
      rebuilds on a different day can differ. Package list: ${ISO_NAME%.iso}.packages.txt)
Ollama: ${OLLAMA_VERSION} from the official release archive (cached in VenaX/ollama/)

Architecture
  browser -> venax-web :8080 (user venax-web) -> Ollama 127.0.0.1:11434
                          \-> venax-agent (root, unix socket, whitelisted ops)
  systemd: venax-data -> ollama / venax-agent -> venax-web (venax.target)

Highlights vs 1.1.x
  * No router/Internet assumption. Network states: NO_INTERFACE, INTERFACE_AVAILABLE,
    CONNECTING, LOCAL_CONNECTED, LOCAL_READY, INTERNET_AVAILABLE (separate from Internet).
  * Actual IPv4 discovered from NetworkManager/iproute2 (no subnet assumptions);
    URL http://<ip>:8080 is primary, mDNS (venax.local) is a convenience.
  * Ethernet: DHCP, then IPv4 link-local fallback for direct laptop cables.
  * Ollama bound to localhost; browser talks to /api/chat and /api/models/pull only.
  * Streaming proxy re-frames NDJSON line-by-line, reports upstream errors in-band.
  * venax-agent: no shell/exec API, whitelisted systemctl, passwords never in argv.
  * VENAXDATA: waits for the device, verifies write access for the ollama user,
    explicit READY/NOT_AVAILABLE; Ollama refuses to start without that decision.
  * Ollama archive is cached in VenaX/ollama/ and reused by every build (downloaded
    only when missing, integrity-checked before extraction).
  * Project directories are handed back to the invoking user on every exit, so a
    failed build no longer leaves root-owned files behind.
  * Fixed: console treated "connected (local only)" as disconnected; sourcing a status
    file with spaces; performance.service ordering cycle; /tmp excluded from squashfs;
    host /run bind-mounted into the build chroot; SHA256SUMS used absolute paths.
  * Fixed (2.0.0 build): firewall ruleset failed to load because a minbase Debian has no
    /etc/protocols; netbase is now installed and the ruleset uses numeric protocols.
Not included: VenaX-hosted access point mode (abstraction left open), QR code, TLS/auth.
Security note: anyone on the same network can use the web UI (private-LAN design).
EOF

fix_ownership

echo ""
echo "============================================================"
echo "                 VenaX BUILD COMPLETE"
echo "============================================================"
ready "ISO: $OUTPUT_DIR/$ISO_NAME"
cat "$OUTPUT_DIR/SHA256SUMS"
ls -lh "$OUTPUT_DIR/$ISO_NAME"
