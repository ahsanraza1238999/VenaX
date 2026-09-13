#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------------
# Root privilege handling
# ------------------------------------------------------------------
# This build needs root for debootstrap, mount, chroot, and writing
# into the generated (root-owned) rootfs. Instead of requiring the
# caller to remember `sudo ./build-iso.sh` every time -- and instead
# of leaving things half-root/half-user-owned if they alternate
# between `sudo ./build-iso.sh` and `./build-iso.sh` across runs
# (which is exactly what produces "mkdir: Permission denied" on a
# later plain run) -- the script re-execs itself under sudo exactly
# once, up front, regardless of how it was invoked.
if [[ "${EUID}" -ne 0 ]]; then
    echo "Root privileges are required (debootstrap/mount/chroot). Re-running with sudo..."
    exec sudo -E -- "$0" "$@"
fi

# The human who actually asked for this build, even though the script
# is now root. Used at the very end to hand ownership of the build
# output back to them, so they aren't left with root-owned files in
# their own home directory.
ORIG_USER="${SUDO_USER:-root}"

# ============================================================
# VenaX Final ISO Builder
# ============================================================
# USB boot -> auto login -> network setup -> VenaX URL.
# The browser handles chat, model installation and monitoring.
# The console is the admin/fallback interface, not the primary one.
#
# ------------------------------------------------------------
# v1.1.0 — Production refactor
# ------------------------------------------------------------
# This release re-architects the BOOT ORCHESTRATION. Previous versions
# used ~/.bash_profile -> venax-startup as the thing that actually
# started/restarted Ollama, the web UI and the firewall. That worked,
# but it meant the "real" boot sequence only existed inside an
# interactive login shell, with hand-rolled retry loops standing in
# for systemd dependency management. That produced hidden races
# (services being "restarted" before their dependencies were verified,
# a console script pretending to be an init system) and meant nothing
# started until someone (or autologin) reached a bash prompt.
#
# What changed:
#   - systemd now owns the entire critical path:
#         local-fs.target -> venax-data.service -> ollama.service -> venax-web.service
#     aggregated under venax.target. These are enabled units that start
#     on boot regardless of whether anyone is logged in at a console.
#   - venax-startup was replaced by venax-console. venax-console no
#     longer starts or restarts any service. It only: (a) checks
#     whether a usable network connection exists and launches the
#     interactive Wi-Fi tool if not, and (b) polls already-running
#     systemd units / health endpoints to render the status banner.
#     .bash_profile now launches an admin/status view, not the
#     orchestrator.
#   - Wi-Fi credentials are no longer passed as a `nmcli ... password`
#     command-line argument (visible in `ps`). A NetworkManager keyfile
#     is written to a 600-permission temp file and installed directly
#     into /etc/NetworkManager/system-connections, then the temp file
#     is shredded.
#   - VENAXDATA mount failure is no longer swallowed with `|| true`.
#     venax-data.service now determines and records a real
#     READY / NOT_AVAILABLE status (device missing, mount failed, or
#     mounted-but-not-writable are all distinguished), and Ollama's
#     model path is switched to an explicitly-ephemeral location when
#     persistent storage isn't available, instead of silently writing
#     into whatever happened to be at /mnt/venax-data.
#   - The web UI runs as an unprivileged `venax-web` system account
#     instead of root, and every subprocess call uses an argument list
#     instead of `shell=True`.
#   - Ollama installation now pins OLLAMA_VERSION instead of always
#     installing whatever the upstream installer resolves "today".
#   - Debian release pinned to bookworm instead of the floating
#     `stable` alias, for build reproducibility.
#   - Forced OLLAMA_VULKAN=1 removed; Ollama's own hardware detection
#     decides acceleration, so CPU-only and non-Vulkan GPUs are not
#     broken.
#   - Frontend NDJSON parsing now buffers across network chunks
#     instead of assuming a `decoder.decode(chunk).split('\n')` chunk
#     boundary lines up with a JSON object boundary.
#   - Chat now uses /api/chat with real message history instead of a
#     single-shot /api/generate call dressed up as a chat UI.
#   - Unnecessary `tcp dport 5353` firewall allowance removed (mDNS
#     only needs UDP/5353).
#
# ------------------------------------------------------------
# v1.1.1 — Build-script fix (ISO never produced)
# ------------------------------------------------------------
#   - Fixed a bug where the final ISO was never produced: cleanup()
#     was being called directly in step [14/14] to unmount the chroot
#     bind mounts before doing host-side ISO assembly, but cleanup()
#     itself always ends in `exit "$rc"` (so the EXIT trap can rely on
#     it). Calling it directly therefore terminated the script right
#     after unmounting, before mksquashfs/grub-mkrescue/sha256sum ever
#     ran. Unmounting is now a separate `unmount_chroot` function;
#     `cleanup()` (used only by the EXIT trap) calls it and then exits.
#
# ------------------------------------------------------------
# v1.1.2 — Build-script fix (permission denied on re-run)
# ------------------------------------------------------------
#   - Fixed "mkdir: Permission denied" on rootfs/iso/build when the
#     script was run without `sudo` after a previous `sudo`-run had
#     left those directories root-owned. The script now self-elevates
#     to root on its own at startup (`exec sudo -E -- "$0" "$@"`), so
#     every run is consistently root from the first command to the
#     last, regardless of whether the caller typed `sudo` or not. At
#     the very end, ownership of the build output is handed back to
#     the invoking (non-root) user so they aren't left with root-owned
#     files in their own home directory.
# ============================================================

VERSION="1.1.0"
ARCH="amd64"
DEBIAN_RELEASE="bookworm"          # pinned, not the floating "stable" alias
DEBIAN_MIRROR="https://deb.debian.org/debian"
SECURITY_MIRROR="https://security.debian.org/debian-security"

# Pin the Ollama release actually installed into the image. The
# upstream install.sh honors OLLAMA_VERSION when set, which is the
# most reproducible option the officially supported installer exposes
# today. If a future installer drops support for this, that will show
# up as a build failure here rather than a silent version drift.
OLLAMA_VERSION="0.5.4"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$PROJECT_DIR/rootfs"
ISO_DIR="$PROJECT_DIR/iso"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
ISO_NAME="VenaX-${VERSION}-x86_64.iso"

# Unmounts the chroot bind mounts. Safe to call more than once, and
# does NOT exit the script -- callers decide what happens next.
unmount_chroot() {
    set +e
    echo ""
    echo "[CLEANUP] Removing temporary mounts..."
    for m in \
        "$ROOTFS/run" \
        "$ROOTFS/dev/pts" \
        "$ROOTFS/dev" \
        "$ROOTFS/proc" \
        "$ROOTFS/sys"
    do
        mountpoint -q "$m" 2>/dev/null || continue
        # Try a normal unmount first. Only fall back to lazy/forced
        # unmount if that genuinely fails -- masking a stuck mount
        # with -lf unconditionally hides real build-environment
        # problems (busy chroot processes, leaked file descriptors).
        if ! umount "$m" 2>/dev/null; then
            echo "[CLEANUP] Normal unmount of $m failed, retrying with lazy unmount..."
            umount -lf "$m" 2>/dev/null || echo "[CLEANUP] WARNING: could not unmount $m"
        fi
    done
    set -e
}

# Used ONLY by the EXIT trap (e.g. on early/unexpected failure).
# Do not call this directly mid-script -- it exits the process.
cleanup() {
    local rc=$?
    unmount_chroot
    exit "$rc"
}
trap cleanup EXIT

require_host_tools() {
    local missing=()
    for cmd in sudo debootstrap grub-mkrescue mksquashfs xorriso rsync python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        echo "Missing host build tools: ${missing[*]}"
        echo "Install them with:"
        echo "  apt update"
        echo "  apt install -y debootstrap grub-pc-bin grub-efi-amd64-bin grub-mkrescue xorriso squashfs-tools rsync python3"
        exit 1
    fi
}

echo "============================================================"
echo "                 Building VenaX ${VERSION}"
echo "============================================================"
echo ""
require_host_tools

echo "[1/14] Cleaning previous build..."
rm -rf "$ROOTFS" "$ISO_DIR" "$BUILD_DIR"
mkdir -p "$ROOTFS" "$ISO_DIR/live" "$ISO_DIR/boot/grub" "$BUILD_DIR" "$OUTPUT_DIR"

echo "[2/14] Creating minimal Debian (${DEBIAN_RELEASE}) root filesystem..."
debootstrap \
    --arch="$ARCH" \
    --variant=minbase \
    "$DEBIAN_RELEASE" \
    "$ROOTFS" \
    "$DEBIAN_MIRROR"

echo "[3/14] Base configuration..."

tee "$ROOTFS/etc/hostname" >/dev/null <<'EOF'
venax
EOF

tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 venax
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# Pinned release name (not "stable") + HTTPS mirrors, per the
# reproducibility/security requirements: floating suite names make the
# exact package set depend on the day the ISO happens to be built, and
# plain HTTP mirrors are weaker in transit (apt signature verification
# still protects package integrity either way -- this is defense in
# depth, not a replacement for it).
tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb ${SECURITY_MIRROR} ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

tee "$ROOTFS/etc/motd" >/dev/null <<EOF
============================================================
                         VenaX ${VERSION}
                 Local AI Server OS
============================================================
EOF

echo "[4/14] Preparing build environment..."
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"

echo "[5/14] Installing required packages..."

chroot "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    sudo \
    bash \
    coreutils \
    procps \
    iproute2 \
    iputils-ping \
    isc-dhcp-client \
    network-manager \
    wpasupplicant \
    iw \
    rfkill \
    pciutils \
    usbutils \
    lshw \
    ethtool \
    util-linux \
    e2fsprogs \
    dosfstools \
    ntfs-3g \
    curl \
    ca-certificates \
    wget \
    rsync \
    python3 \
    python3-minimal \
    jq \
    avahi-daemon \
    libnss-mdns \
    nftables \
    openssh-client \
    less \
    nano \
    kbd \
    console-setup \
    console-setup-linux \
    fonts-terminus-otb \
    zstd \
    xz-utils \
    pci.ids \
    usb.ids \
    firmware-linux-free \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-atheros \
    firmware-brcm80211 \
    firmware-misc-nonfree

apt-get clean
rm -rf /var/lib/apt/lists/*
'
# NOTE: libvulkan1/mesa-vulkan-drivers/vulkan-tools were dropped from
# the base image. They were previously installed alongside a forced
# OLLAMA_VULKAN=1, which is being removed (see Ollama section below).
# Ollama's own runtime already ships/loads the acceleration backends it
# needs; force-installing a Vulkan userspace stack for every appliance
# regardless of the actual GPU present is exactly the kind of
# unnecessary weight this refactor is supposed to remove. If a future
# maintainer wants managed GPU acceleration, add the specific driver
# package for the specific hardware class instead of a blanket install.

echo "[6/14] Creating VenaX users..."

chroot "$ROOTFS" /bin/bash -c '
set -e

# Interactive/admin console user. This account is only reachable from
# the physical console (autologin on tty1) -- it is not network-facing
# -- so NOPASSWD sudo here is an appliance-console tradeoff, not a
# network attack surface.
id venax >/dev/null 2>&1 || useradd -m -s /bin/bash venax
echo "venax:venax" | chpasswd

mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/venax <<EOF
venax ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/venax

# Dedicated, unprivileged system account for the network-facing web
# service. No login shell, no home directory content beyond its own
# working dir, no sudo rights at all.
id venax-web >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin venax-web

cat > /etc/default/console-setup <<EOF
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="Terminus"
FONTSIZE="16x32"
EOF

cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

systemctl enable NetworkManager
systemctl enable NetworkManager-wait-online.service
systemctl enable avahi-daemon
systemctl enable nftables
'

echo "[7/14] Installing performance and hardware layer..."

tee "$ROOTFS/etc/systemd/system/venax-performance.service" >/dev/null <<'EOF'
[Unit]
Description=VenaX practical performance tuning (best-effort, non-fatal)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/venax-performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

tee "$ROOTFS/usr/local/sbin/venax-performance" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Best-effort practical performance tuning. This intentionally never
# fails the unit (Type=oneshot succeeds regardless) because not every
# control exists on every CPU/firmware, and a laptop with none of
# these knobs available is not a boot failure.
#
# This does NOT bypass thermal/power firmware limits: it only asks the
# governor/pstate driver, where present, to make full turbo range
# available. The kernel/firmware retain final say over actual clocks
# and thermals.
set +e

for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$gov" ] || continue
    echo performance > "$gov" 2>/dev/null || true
done

for f in \
    /sys/devices/system/cpu/intel_pstate/max_perf_pct \
    /sys/devices/system/cpu/amd_pstate/max_perf_pct
do
    [ -w "$f" ] || continue
    echo 100 > "$f" 2>/dev/null || true
done

exit 0
EOF
chmod 755 "$ROOTFS/usr/local/sbin/venax-performance"
chroot "$ROOTFS" systemctl enable venax-performance.service

tee "$ROOTFS/usr/local/bin/venax-hardware" >/dev/null <<'EOF'
#!/usr/bin/env bash
set +e

echo "============================================================"
echo "                    VenaX Hardware"
echo "============================================================"
echo ""

echo "CPU"
echo "------------------------------------------------------------"
lscpu 2>/dev/null | awk -F: '
    /^Model name/ {gsub(/^[ \t]+/,"",$2); print "Model: "$2}
    /^CPU\(s\)/ {gsub(/^[ \t]+/,"",$2); print "Logical CPUs: "$2}
    /^Architecture/ {gsub(/^[ \t]+/,"",$2); print "Architecture: "$2}
'
echo ""

echo "RAM"
echo "------------------------------------------------------------"
free -h
echo ""

echo "GPU (detected on PCI bus -- does not imply Ollama acceleration)"
echo "------------------------------------------------------------"
lspci 2>/dev/null | grep -Ei 'vga|3d|display' || echo "No PCI GPU reported."
echo ""

echo "STORAGE"
echo "------------------------------------------------------------"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || true
echo ""

echo "NETWORK"
echo "------------------------------------------------------------"
ip -brief addr 2>/dev/null || true
echo ""

echo "OLLAMA (actually-loaded runner reflects real acceleration in use)"
echo "------------------------------------------------------------"
ollama ps 2>/dev/null || echo "Ollama not reachable."
EOF
chmod 755 "$ROOTFS/usr/local/bin/venax-hardware"

tee "$ROOTFS/usr/local/bin/venax-status" >/dev/null <<'EOF'
#!/usr/bin/env bash
set +e

while true; do
    clear
    echo "============================================================"
    echo "                         VenaX"
    echo "                  SYSTEM PERFORMANCE"
    echo "============================================================"
    echo ""

    echo "CPU / LOAD"
    echo "------------------------------------------------------------"
    uptime 2>/dev/null || true
    top -bn1 2>/dev/null | sed -n '1,5p'
    echo ""

    echo "RAM"
    echo "------------------------------------------------------------"
    free -h
    echo ""

    echo "STORAGE"
    echo "------------------------------------------------------------"
    df -h / /mnt/venax-data 2>/dev/null || df -h /
    echo ""

    echo "GPU / ACCELERATION"
    echo "------------------------------------------------------------"
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
          --format=csv,noheader 2>/dev/null || true
    fi
    ollama ps 2>/dev/null || true
    echo ""

    echo "NETWORK"
    echo "------------------------------------------------------------"
    ip -brief addr 2>/dev/null || true
    echo ""
    echo "SERVICES"
    echo "------------------------------------------------------------"
    for u in NetworkManager venax-data ollama venax-web nftables; do
        printf '  %-16s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
    done
    echo ""
    echo "LISTENING PORTS"
    echo "------------------------------------------------------------"
    ss -tlnp 2>/dev/null | grep -E ':(8080|11434)\b|State' || true
    echo ""

    echo "Press Ctrl+C to exit."
    sleep 3
done
EOF
chmod 755 "$ROOTFS/usr/local/bin/venax-status"

echo "[8/14] Creating robust CLI Wi-Fi setup..."

tee "$ROOTFS/usr/local/bin/wifi" >/dev/null <<'WIFIEOF'
#!/usr/bin/env bash
set -u

LOG=/tmp/venax-wifi-nmcli.log

wait_nm() {
    sudo -n systemctl start NetworkManager >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        if sudo -n nmcli -t -f RUNNING general 2>/dev/null | grep -qx 'running'; then return 0; fi
        sleep 1
    done
    return 1
}

wifi_device() {
    sudo -n nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
}

get_ip() {
    sudo -n nmcli -g IP4.ADDRESS device show "$1" 2>/dev/null | sed -n '1p' | cut -d/ -f1
}

wait_connected() {
    local dev="$1"
    for _ in $(seq 1 45); do
        local state ip
        state="$(sudo -n nmcli -g GENERAL.STATE device show "$dev" 2>/dev/null | head -n1 || true)"
        ip="$(get_ip "$dev")"
        if [[ "$state" == 100* ]] && [[ -n "$ip" ]] && ip route 2>/dev/null | grep -q '^default '; then return 0; fi
        sleep 1
    done
    return 1
}

scan_networks() {
    sudo -n nmcli -t --escape yes -f SSID,SECURITY,SIGNAL device wifi list ifname "$DEV" 2>/dev/null |
    python3 -c '
import sys

def split(line):
    out=[]; cur=[]; esc=False
    for c in line.rstrip("\n"):
        if esc:
            cur.append("\\"+c); esc=False
        elif c=="\\": esc=True
        elif c==":": out.append("".join(cur)); cur=[]
        else: cur.append(c)
    if esc: cur.append("\\")
    out.append("".join(cur)); return out

def dec(s):
    out=[]; i=0
    while i<len(s):
        if s[i]=="\\" and i+1<len(s):
            c=s[i+1]
            if c=="x" and i+3<len(s):
                try: out.append(chr(int(s[i+2:i+4],16))); i+=4; continue
                except ValueError: pass
            if c in ("\\",":"): out.append(c); i+=2; continue
        out.append(s[i]); i+=1
    return "".join(out)

seen=set()
for line in sys.stdin:
    f=split(line)
    if len(f)<3: continue
    ssid,sec,sig=map(dec,f[:3])
    if not ssid or ssid in seen: continue
    seen.add(ssid)
    print(ssid+"\t"+sec+"\t"+sig)
'
}

dump_diagnostics() {
    # Deliberately omits credentials -- only interface/connection state.
    {
        echo "--- date ---"; date
        echo "--- rfkill list ---"; sudo -n rfkill list 2>&1
        echo "--- nmcli device status ---"; sudo -n nmcli device status 2>&1
        echo "--- nmcli general status ---"; sudo -n nmcli general status 2>&1
    } >> "$LOG" 2>&1
}

persist_profiles() {
    sudo -n mkdir -p /mnt/venax-data/nm-connections 2>/dev/null
    if mountpoint -q /mnt/venax-data 2>/dev/null; then
        if sudo -n cp -a /etc/NetworkManager/system-connections/. /mnt/venax-data/nm-connections/ 2>/dev/null; then
            sudo -n chmod 600 /mnt/venax-data/nm-connections/* 2>/dev/null || true
        else
            echo "WARNING: could not persist Wi-Fi profile to VENAXDATA (storage not writable?)."
        fi
    else
        echo "NOTE: persistent storage is not mounted -- this Wi-Fi profile will not"
        echo "survive a reboot unless VENAXDATA becomes available."
    fi
}

# Write a NetworkManager keyfile connection profile directly, instead
# of passing the password as a `nmcli ... password <pw>` argument.
# Command-line arguments are visible to any other local user via
# `ps`/`/proc/<pid>/cmdline`, so this avoids that exposure entirely.
# The password touches disk only in a 0600 temp file for the instant
# it takes to install it, and is never echoed or logged.
connect_secured() {
    local ssid="$1" password="$2" dev="$3"
    local tmp
    tmp="$(mktemp /tmp/venax-wifi.XXXXXX.nmconnection)"
    chmod 600 "$tmp"

    # Escape characters that are special in NetworkManager's keyfile
    # (INI-like) format so an SSID/password containing them can't break
    # the file structure.
    local esc_ssid="${ssid//\\/\\\\}"
    esc_ssid="${esc_ssid//\"/\\\"}"

    {
        printf '[connection]\n'
        printf 'id=%s\n' "$ssid"
        printf 'type=wifi\n'
        printf 'autoconnect=true\n'
        printf '\n[wifi]\n'
        printf 'mode=infrastructure\n'
        printf 'ssid=%s\n' "$esc_ssid"
        printf '\n[wifi-security]\n'
        printf 'key-mgmt=wpa-psk\n'
        printf 'psk=%s\n' "$password"
        printf '\n[ipv4]\nmethod=auto\n'
        printf '\n[ipv6]\nmethod=auto\n'
    } > "$tmp"

    local dest="/etc/NetworkManager/system-connections/${ssid}.nmconnection"
    local rc=0
    if sudo -n install -m 600 -o root -g root "$tmp" "$dest"; then
        sudo -n nmcli connection reload >/dev/null 2>&1
        sudo -n nmcli --wait 45 connection up id "$ssid" ifname "$dev" >>"$LOG" 2>&1
        rc=$?
    else
        rc=1
    fi

    shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
    return $rc
}

connect_open() {
    local ssid="$1" dev="$2"
    sudo -n nmcli --wait 45 device wifi connect "$ssid" ifname "$dev" >>"$LOG" 2>&1
}

if ! wait_nm; then
    clear
    echo '============================================================'
    echo '                       VenaX Wi-Fi'
    echo '============================================================'
    echo
    echo 'NetworkManager did not become ready.'
    dump_diagnostics
    echo "Diagnostics written to $LOG"
    echo
    read -r -p 'Press ENTER to retry...' _
    exit 1
fi

sudo -n rfkill unblock all >/dev/null 2>&1 || true
sudo -n nmcli radio wifi on >/dev/null 2>&1 || true

DEV="$(wifi_device)"
if [[ -z "$DEV" ]]; then
    clear
    echo '============================================================'
    echo '                       VenaX Wi-Fi'
    echo '============================================================'
    echo
    echo 'No Wi-Fi adapter detected.'
    echo
    sudo -n nmcli device status 2>/dev/null || true
    echo
    echo 'If your adapter is a USB dongle, this image may be missing its'
    echo 'firmware. Check: lsusb  /  lspci  /  dmesg | grep -i firmware'
    echo
    read -r -p 'Press ENTER to return...' _
    exit 1
fi

sudo -n nmcli device set "$DEV" managed yes >/dev/null 2>&1 || true
sudo -n ip link set "$DEV" up >/dev/null 2>&1 || true

# A server appliance must stay reachable even when idle. Wi-Fi
# power-save lets the radio sleep between beacons, which delays or
# drops unsolicited inbound connections from a client on the LAN.
sudo -n iw dev "$DEV" set power_save off >/dev/null 2>&1 || true

while true; do
    clear
    echo '============================================================'
    echo '                       VenaX Wi-Fi'
    echo '============================================================'
    echo
    echo "Adapter: $DEV"
    echo
    echo 'Scanning for networks...'
    echo

    sudo -n nmcli device wifi rescan ifname "$DEV" >/dev/null 2>&1 || true
    NETWORKS=()
    for _ in $(seq 1 8); do
        mapfile -t NETWORKS < <(scan_networks)
        ((${#NETWORKS[@]} > 0)) && break
        sleep 1
    done

    if ((${#NETWORKS[@]} == 0)); then
        echo 'No Wi-Fi networks found.'
        echo
        echo '[r] Rescan'
        echo '[q] Quit'
        echo
        read -r -p 'Selection: ' choice
        case "$choice" in r|R) continue;; q|Q) exit 1;; esac
        continue
    fi

    clear
    echo '============================================================'
    echo '                       VenaX Wi-Fi'
    echo '============================================================'
    echo
    echo 'Available networks:'
    echo
    for i in "${!NETWORKS[@]}"; do
        IFS=$'\t' read -r ssid security signal <<< "${NETWORKS[$i]}"
        printf '  [%2d] %-34s %3s%%  %s\n' "$((i+1))" "$ssid" "$signal" "$security"
    done
    echo
    echo '------------------------------------------------------------'
    echo 'Enter network number'
    echo 'r = rescan    q = quit'
    echo '------------------------------------------------------------'
    echo
    read -r -p 'Selection: ' choice

    case "$choice" in q|Q) exit 1;; r|R) continue;; esac
    [[ "$choice" =~ ^[0-9]+$ ]] || continue
    index=$((choice-1))
    ((index >= 0 && index < ${#NETWORKS[@]})) || continue
    IFS=$'\t' read -r SSID SECURITY SIGNAL <<< "${NETWORKS[$index]}"

    clear
    echo '============================================================'
    echo '                    Wi-Fi Authentication'
    echo '============================================================'
    echo
    echo "Network : $SSID"
    echo "Signal  : ${SIGNAL}%"
    echo "Security: ${SECURITY:-Open}"
    echo

    # Enterprise (802.1X) Wi-Fi is not supported by this simple
    # keyfile flow -- say so rather than silently failing.
    if [[ "$SECURITY" == *802.1X* ]]; then
        echo 'This network uses enterprise (802.1X) authentication, which is'
        echo 'not supported by the VenaX Wi-Fi setup tool.'
        echo
        read -r -p 'Press ENTER to return to the network list...' _
        continue
    fi

    while IFS=: read -r uuid name; do
        [[ -n "$uuid" && "$name" == "$SSID" ]] || continue
        sudo -n nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || true
    done < <(sudo -n nmcli -t --escape no -f UUID,NAME connection show 2>/dev/null || true)
    sudo -n rm -f "/etc/NetworkManager/system-connections/${SSID}.nmconnection" 2>/dev/null || true

    PASSWORD=''
    if [[ -n "$SECURITY" && "$SECURITY" != "--" ]]; then
        printf 'Wi-Fi password: '
        IFS= read -r -s PASSWORD
        printf '\n\n'
        if [[ -z "$PASSWORD" ]]; then
            echo 'Password cannot be empty for a secured network.'
            sleep 2
            continue
        fi
    else
        echo 'This network is open; no password is required.'
        echo
    fi

    echo 'Connecting...'
    echo
    : > "$LOG"
    if [[ -n "$PASSWORD" ]]; then
        connect_secured "$SSID" "$PASSWORD" "$DEV"
        RC=$?
    else
        connect_open "$SSID" "$DEV"
        RC=$?
    fi
    PASSWORD=''
    unset PASSWORD

    if ((RC == 0)) && wait_connected "$DEV"; then
        sudo -n nmcli connection modify "$SSID" connection.autoconnect yes >/dev/null 2>&1 || true
        sudo -n nmcli connection modify "$SSID" 802-11-wireless.cloned-mac-address preserve >/dev/null 2>&1 || true
        sudo -n iw dev "$DEV" set power_save off >/dev/null 2>&1 || true
        persist_profiles
        IP="$(get_ip "$DEV")"
        clear
        echo '============================================================'
        echo '                    Wi-Fi Connected'
        echo '============================================================'
        echo
        echo "Network : $SSID"
        echo "Address : $IP"
        echo
        exit 0
    fi

    dump_diagnostics
    clear
    echo '============================================================'
    echo '                    Connection Failed'
    echo '============================================================'
    echo
    echo "Network: $SSID"
    echo
    echo 'NetworkManager output:'
    sed -n '1,15p' "$LOG" 2>/dev/null || true
    echo
    echo "Full diagnostics: $LOG"
    echo 'Check the password, signal, router security and Wi-Fi firmware.'
    echo
    read -r -p 'Press ENTER to return to the network list...' _
done
WIFIEOF
chmod 755 "$ROOTFS/usr/local/bin/wifi"

echo "[9/14] Persistent storage (VENAXDATA) handling..."

mkdir -p "$ROOTFS/mnt/venax-data" "$ROOTFS/run/venax" "$ROOTFS/var/lib/venax-ephemeral-models"

tee "$ROOTFS/usr/local/sbin/venax-data" >/dev/null <<'DATAEOF'
#!/usr/bin/env bash
# Determine and RECORD the real persistence status. Earlier versions
# used `mount ... || true`, which meant a failed mount was
# indistinguishable from a successful one everywhere downstream --
# Ollama could end up writing "persistent" models into whatever was
# left at /mnt/venax-data (possibly just an empty directory on the
# live rootfs), and the user would only discover this after a reboot
# wiped their downloads.
set -u

STATUS_DIR=/run/venax
STATUS_FILE="$STATUS_DIR/storage-status"
ENV_FILE="$STATUS_DIR/ollama.env"
EPHEMERAL_MODELS=/var/lib/venax-ephemeral-models

mkdir -p "$STATUS_DIR"
mkdir -p /mnt/venax-data
mkdir -p "$EPHEMERAL_MODELS"

write_status() {
    # $1 = READY|NOT_AVAILABLE, $2 = human-readable reason
    printf 'STATUS=%s\nREASON=%s\n' "$1" "$2" > "$STATUS_FILE"
}

fail_to_ephemeral() {
    write_status "NOT_AVAILABLE" "$1"
    printf 'OLLAMA_MODELS=%s\nVENAX_PERSISTENT=0\n' "$EPHEMERAL_MODELS" > "$ENV_FILE"
    echo "[venax-data] Persistent storage NOT available: $1" >&2
    echo "[venax-data] Model downloads will NOT survive a reboot." >&2
}

DATA_DEV="$(blkid -L VENAXDATA 2>/dev/null || true)"

if [[ -z "$DATA_DEV" ]]; then
    fail_to_ephemeral "no partition labeled VENAXDATA was found"
    exit 0
fi

if ! mountpoint -q /mnt/venax-data; then
    if ! MOUNT_ERR="$(mount "$DATA_DEV" /mnt/venax-data 2>&1)"; then
        fail_to_ephemeral "mount of $DATA_DEV failed: ${MOUNT_ERR//$'\n'/ }"
        exit 0
    fi
fi

if ! mountpoint -q /mnt/venax-data; then
    fail_to_ephemeral "mount reported success but /mnt/venax-data is not a mountpoint"
    exit 0
fi

# A mounted filesystem is not necessarily writable (e.g. dirty NTFS,
# read-only remount after an error). Prove writability rather than
# assuming it.
PROBE="/mnt/venax-data/.venax-write-test.$$"
if ! ( : > "$PROBE" ) 2>/dev/null; then
    fail_to_ephemeral "$DATA_DEV is mounted but not writable"
    exit 0
fi
rm -f "$PROBE"

mkdir -p /mnt/venax-data/ollama
chmod 755 /mnt/venax-data/ollama
# Ollama runs as its own service user; make sure that user can write
# into the persistent model directory regardless of the underlying
# filesystem's default ownership.
chown -R ollama:ollama /mnt/venax-data/ollama 2>/dev/null || true

mkdir -p /mnt/venax-data/nm-connections
if [ -n "$(ls -A /mnt/venax-data/nm-connections 2>/dev/null)" ]; then
    if cp -a /mnt/venax-data/nm-connections/. /etc/NetworkManager/system-connections/ 2>/tmp/venax-nm-restore.err; then
        chown -R root:root /etc/NetworkManager/system-connections 2>/dev/null || true
        chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
    else
        echo "[venax-data] WARNING: failed to restore saved Wi-Fi profiles: $(cat /tmp/venax-nm-restore.err)" >&2
    fi
fi

FREE_KB="$(df -k --output=avail /mnt/venax-data 2>/dev/null | tail -n1 | tr -d ' ')"
write_status "READY" "mounted at /mnt/venax-data, ${FREE_KB:-unknown} KB free"
printf 'OLLAMA_MODELS=%s\nVENAX_PERSISTENT=1\n' "/mnt/venax-data/ollama" > "$ENV_FILE"
DATAEOF
chmod 755 "$ROOTFS/usr/local/sbin/venax-data"

tee "$ROOTFS/etc/systemd/system/venax-data.service" >/dev/null <<'EOF'
[Unit]
Description=VenaX persistent model storage and network profile restore
# Must run, and record a real status, before Ollama decides where its
# model directory lives.
Before=ollama.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/venax-data
RemainAfterExit=yes
# A failure here should not be silently invisible, but it also should
# not prevent the rest of the appliance from starting -- an ephemeral
# fallback is a valid, clearly-communicated degraded mode, not a boot
# blocker.
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[10/14] Installing Ollama (pinned version)..."

chroot "$ROOTFS" /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
export OLLAMA_VERSION='${OLLAMA_VERSION}'
curl -fsSL https://ollama.com/install.sh | sh
"

mkdir -p "$ROOTFS/etc/systemd/system/ollama.service.d"

tee "$ROOTFS/etc/systemd/system/ollama.service.d/venax.conf" >/dev/null <<'EOF'
[Unit]
# venax-data.service always finishes (RemainAfterExit=yes) and always
# writes /run/venax/ollama.env, whether persistent storage turned out
# to be available or not -- so Ollama can depend on it unconditionally.
After=venax-data.service
Requires=venax-data.service
Wants=network-online.target
After=network-online.target

[Service]
# OLLAMA_MODELS is supplied dynamically by venax-data.service, pointing
# at either the persistent VENAXDATA path or an explicitly-ephemeral
# path -- never a silent guess.
EnvironmentFile=/run/venax/ollama.env
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
# No forced acceleration backend here (see build-script comments) --
# Ollama's own hardware probing chooses CPU / Vulkan / CUDA / ROCm as
# appropriate for the machine it is actually running on.
LimitNOFILE=1048576
LimitNPROC=1048576
EOF

echo "[11/14] Creating VenaX client web UI (non-root)..."

tee "$ROOTFS/usr/local/bin/venax-web.py" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
"""VenaX web UI / API proxy.

Runs as the unprivileged `venax-web` system account (see the
venax-web.service unit). It never runs a subprocess through a shell
and never forwards untrusted browser input into a command line.
"""
import http.server
import ipaddress
import json
import os
import re
import socket
import subprocess
import urllib.error
import urllib.request

HOST = "0.0.0.0"
PORT = 8080
OLLAMA = "http://127.0.0.1:11434"
MAX_BODY = 1 * 1024 * 1024  # 1 MiB is generous for chat/pull request bodies
MODEL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:\-/]{0,127}$")
STORAGE_STATUS_FILE = "/run/venax/storage-status"

HTML = r'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VenaX Local AI</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#080b12;color:#e8edf7;font-family:system-ui,-apple-system,Segoe UI,sans-serif}
header{padding:18px 22px;border-bottom:1px solid #202838;background:#0c111b;position:sticky;top:0;z-index:5}
h1{margin:0;font-size:20px}small{color:#8f9bb0}
main{max-width:1100px;margin:auto;padding:18px}
.tabs{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
button,.tab{background:#151c29;color:#e8edf7;border:1px solid #2b3548;border-radius:9px;padding:10px 13px;cursor:pointer}
button:hover{background:#1b2535}
.panel{display:none}.panel.active{display:block}
.chat{min-height:60vh;display:flex;flex-direction:column}
.messages{flex:1;overflow:auto;padding:8px 0}
.msg{padding:13px 15px;margin:8px 0;border-radius:12px;white-space:pre-wrap;line-height:1.5}
.user{background:#15243a;margin-left:10%}.ai{background:#111824;margin-right:10%}
textarea,select{width:100%;background:#0d131e;color:#fff;border:1px solid #2b3548;border-radius:9px;padding:11px}
.row{display:grid;grid-template-columns:1fr auto;gap:8px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px}
.card{background:#0d131e;border:1px solid #202a3a;border-radius:12px;padding:15px}
.progress{height:8px;background:#202938;border-radius:10px;overflow:hidden;margin-top:8px}
.bar{height:100%;width:0;background:#6d8cff}
pre{white-space:pre-wrap}.badge{display:inline-block;padding:3px 7px;border-radius:999px;background:#182235;color:#a9bbff;font-size:12px}
.warn{color:#ffb454}
</style>
</head>
<body>
<header><h1>VenaX <small>local AI server</small></h1></header>
<main>
<div class="tabs">
<button onclick="tab('chat')">Chat</button>
<button onclick="tab('models')">Models</button>
<button onclick="tab('system')">System</button>
<button onclick="tab('connect')">Connect</button>
</div>

<section id="chat" class="panel active">
<div class="chat">
<div class="row"><select id="model"></select><button onclick="refreshModels()">Refresh</button></div>
<div id="messages" class="messages"></div>
<div class="row">
<textarea id="prompt" rows="3" placeholder="Message your local model..."></textarea>
<button onclick="send()">Send</button>
</div>
</div>
</section>

<section id="models" class="panel">
<h2>Models</h2>
<p id="modelwarn" class="warn"></p>
<div id="modelcards" class="cards"></div>
</section>

<section id="system" class="panel">
<h2>System</h2>
<div id="stats" class="card">Loading...</div>
</section>

<section id="connect" class="panel">
<h2>Connect</h2>
<div class="card">
<p><b>VenaX web:</b> <span id="weburl"></span></p>
<p><b>Ollama API:</b> <span id="apiurl"></span></p>
<p><b>mDNS (convenience):</b> http://venax.local:8080 -- not guaranteed on every network/device.</p>
<p><small>Anyone who can reach this device's address on the LAN can use these
endpoints. Ollama's local API has no built-in authentication. Do not rely on
this on an untrusted or public Wi-Fi network.</small></p>
</div>
</section>
</main>

<script>
const CATALOG=[
["qwen2.5:0.5b","Very light","~0.4 GB"],
["gemma2:2b","Light","~1.6 GB"],
["llama3.2:3b","Light","~2.0 GB"],
["phi3:mini","Light","~2.2 GB"],
["mistral:7b","Medium","~4.1 GB"],
["llama3.1:8b","Medium","~4.7 GB"],
["gemma2:9b","Medium","~5.4 GB"],
["qwen2.5:14b","Heavy","~9 GB"],
["qwen2.5:32b","Heavy","~20 GB"],
["mixtral:8x7b","Very heavy","large"],
["llama3.1:70b","Very heavy","very large"]
];

let history=[]; // {role, content} -- kept in the browser only

function tab(id){
document.querySelectorAll('.panel').forEach(x=>x.classList.remove('active'));
document.getElementById(id).classList.add('active');
if(id==='system')stats(); if(id==='models')renderCatalog();
}
async function api(path,opts){
const r=await fetch(path,opts); if(!r.ok)throw new Error(await r.text()); return r;
}
async function refreshModels(){
try{
const data=await(await api('/api/models')).json();
const s=document.getElementById('model'); s.innerHTML='';
for(const m of data.models||[]){const o=document.createElement('option');o.value=m.name;o.textContent=m.name;s.appendChild(o);}
if(!s.options.length){const o=document.createElement('option');o.textContent='Install a model first';s.appendChild(o);}
}catch(e){console.error(e)}
}
function add(role,text){
const d=document.createElement('div');d.className='msg '+role;d.textContent=text;
document.getElementById('messages').appendChild(d);d.scrollIntoView({behavior:'smooth'});return d;
}

// Reads a fetch() streaming body as NDJSON, correctly buffering across
// chunk boundaries -- a JSON object can be split across two network
// reads, so `decoder.decode(chunk).split('\n')` on its own silently
// corrupts/drops output whenever that happens to occur mid-object.
async function readNDJSON(response, onObject){
  const reader=response.body.getReader();
  const dec=new TextDecoder();
  let buf='';
  while(true){
    const {value,done}=await reader.read();
    if(value) buf+=dec.decode(value,{stream:true});
    let nl;
    while((nl=buf.indexOf('\n'))>=0){
      const line=buf.slice(0,nl); buf=buf.slice(nl+1);
      if(line.trim()){
        try{ onObject(JSON.parse(line)); }catch(e){ /* skip malformed line */ }
      }
    }
    if(done) break;
  }
  buf+=dec.decode(); // flush any trailing multi-byte sequence
  const rest=buf.trim();
  if(rest){ try{ onObject(JSON.parse(rest)); }catch(e){} }
}

async function send(){
const box=document.getElementById('prompt'),text=box.value.trim(),model=document.getElementById('model').value;
if(!text||!model||model==='Install a model first')return;
box.value='';add('user',text);
history.push({role:'user',content:text});
const out=add('ai','');
try{
const r=await api('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({model,messages:history})});
let full='';
await readNDJSON(r,(j)=>{
  if(j.message&&j.message.content){ full+=j.message.content; out.textContent=full; out.scrollIntoView({behavior:'smooth'}); }
});
history.push({role:'assistant',content:full});
}catch(e){out.textContent='Error: '+e.message}
}
function renderCatalog(){
const root=document.getElementById('modelcards');root.innerHTML='';
for(const [name,size,approx] of CATALOG){
const c=document.createElement('div');c.className='card';
const safe=btoa(name).replace(/=/g,'');
c.innerHTML='<b>'+name+'</b><br><span class="badge">'+size+'</span><br><small>'+approx+'</small><br><br>'+
'<button onclick="installModel('+JSON.stringify(name)+')">Install</button>'+
'<div class="progress"><div class="bar" id="bar-'+safe+'"></div></div><small id="status-'+safe+'"></small>';
root.appendChild(c);
}
}
async function installModel(name){
const safe=btoa(name).replace(/=/g,'');
const st=document.getElementById('status-'+safe),bar=document.getElementById('bar-'+safe);
st.textContent='Downloading...';
try{
const r=await api('/api/pull',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name})});
await readNDJSON(r,(j)=>{
  if(j.status)st.textContent=j.status;
  if(j.completed&&j.total)bar.style.width=(100*j.completed/j.total)+'%';
});
st.textContent='Installed';bar.style.width='100%';refreshModels();
}catch(e){st.textContent='Error: '+e.message}
}
async function stats(){
try{
const j=await(await api('/api/system')).json();
document.getElementById('stats').innerHTML='<pre>'+escapeHtml(JSON.stringify(j,null,2))+'</pre>';
const warn=document.getElementById('modelwarn');
if(j.persistent_storage!=='READY'){
  warn.textContent='Persistent storage is NOT available ('+(j.storage_reason||'unknown reason')+'). Downloaded models will NOT survive a reboot.';
}else{
  warn.textContent='';
}
}catch(e){document.getElementById('stats').textContent=e.message}
}
function escapeHtml(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
document.getElementById('weburl').textContent=location.origin;
document.getElementById('apiurl').textContent=location.protocol+'//'+location.hostname+':11434';
refreshModels();renderCatalog();stats();
</script>
</body>
</html>'''


def jb(obj):
    return json.dumps(obj).encode()


def ollama_open(path, payload=None, timeout=3600):
    data = None if payload is None else jb(payload)
    req = urllib.request.Request(
        OLLAMA + path, data=data,
        headers={"Content-Type": "application/json"} if data else {})
    return urllib.request.urlopen(req, timeout=timeout)


def run(argv):
    """Run a fixed argument list -- never a shell string. Callers must
    not pass any browser-controlled value into argv."""
    try:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=10
        ).stdout.strip()
    except Exception:
        return ""


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def cpu_model():
    out = run(["lscpu"])
    for line in out.splitlines():
        if line.startswith("Model name:"):
            return line.split(":", 1)[1].strip()
    return ""


def storage_status():
    status, reason = "UNKNOWN", ""
    try:
        with open(STORAGE_STATUS_FILE) as f:
            for line in f:
                if line.startswith("STATUS="):
                    status = line.strip().split("=", 1)[1]
                elif line.startswith("REASON="):
                    reason = line.strip().split("=", 1)[1]
    except OSError:
        pass
    return status, reason


def internet_reachable():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(("1.1.1.1", 53))
        return True
    except OSError:
        return False
    finally:
        s.close()


def info():
    storage, reason = storage_status()
    return {
        "hostname": socket.gethostname(),
        "lan_ip": local_ip(),
        "internet": "Connected" if internet_reachable() else "Unavailable",
        "cpu": cpu_model(),
        "logical_cpus": run(["nproc"]),
        "memory": run(["free", "-h"]),
        "storage": run(["df", "-h", "/", "/mnt/venax-data"]),
        "gpu": run(["bash", "-c", "lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true"]) if False else run(["lspci"]),
        "ollama_version": run(["ollama", "--version"]),
        "ollama_running": run(["ollama", "ps"]),
        "uptime": run(["uptime", "-p"]),
        "persistent_storage": storage,
        "storage_reason": reason,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "VenaX/1.1"

    def log_message(self, fmt, *args):
        print("[WEB]", fmt % args, flush=True)

    def send_json(self, obj, status=200):
        b = jb(obj)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(b)

    def stream_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

    def do_GET(self):
        try:
            if self.path == "/" or self.path.startswith("/?"):
                b = HTML.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                return
            if self.path == "/healthz":
                self.send_json({"web": "ok"})
                return
            if self.path == "/api/models":
                with ollama_open("/api/tags", timeout=10) as r:
                    self.send_json(json.loads(r.read()))
                return
            if self.path == "/api/system":
                self.send_json(info())
                return
            self.send_error(404)
        except urllib.error.URLError as e:
            self.send_json({"error": f"Ollama unreachable: {e}"}, 502)
        except Exception as e:
            self.send_json({"error": str(e)}, 500)

    def _read_json_body(self):
        length = self.headers.get("Content-Length")
        if length is None:
            raise ValueError("missing Content-Length")
        n = int(length)
        if n <= 0:
            return {}
        if n > MAX_BODY:
            raise ValueError("request body too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        try:
            payload = self._read_json_body()

            if self.path == "/api/chat":
                model = payload.get("model")
                messages = payload.get("messages")
                if not isinstance(model, str) or not MODEL_NAME_RE.match(model):
                    self.send_json({"error": "invalid or missing model name"}, 400)
                    return
                if not isinstance(messages, list) or not messages:
                    self.send_json({"error": "missing message history"}, 400)
                    return
                self.stream_headers()
                with ollama_open("/api/chat", {"model": model, "messages": messages, "stream": True}) as r:
                    while True:
                        line = r.readline()
                        if not line:
                            break
                        self.wfile.write(line)
                        self.wfile.flush()
                return

            if self.path == "/api/pull":
                name = payload.get("name")
                if not isinstance(name, str) or not MODEL_NAME_RE.match(name):
                    self.send_json({"error": "invalid or missing model name"}, 400)
                    return
                self.stream_headers()
                with ollama_open("/api/pull", {"name": name, "stream": True}) as r:
                    while True:
                        line = r.readline()
                        if not line:
                            break
                        self.wfile.write(line)
                        self.wfile.flush()
                return

            self.send_error(404)
        except (ValueError, json.JSONDecodeError) as e:
            self.send_json({"error": str(e)}, 400)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client disconnected mid-stream; nothing to report
        except urllib.error.URLError as e:
            try:
                self.send_json({"error": f"Ollama unreachable: {e}"}, 502)
            except Exception:
                pass
        except Exception as e:
            try:
                self.send_json({"error": str(e)}, 500)
            except Exception:
                pass


if __name__ == "__main__":
    print(f"VenaX web UI listening on {HOST}:{PORT}", flush=True)
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    server.serve_forever()
PYEOF
chmod 755 "$ROOTFS/usr/local/bin/venax-web.py"

tee "$ROOTFS/etc/systemd/system/venax-web.service" >/dev/null <<'EOF'
[Unit]
Description=VenaX client web interface
# Wants, not Requires: diagnostics (system/connect pages, healthz)
# should stay reachable even if Ollama itself failed to start, so the
# user isn't left with nothing at all to look at.
After=ollama.service network-online.target
Wants=ollama.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/venax-web.py
Restart=always
RestartSec=2
User=venax-web
Group=venax-web
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/mnt/venax-data /run/venax
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[12/14] Configuring firewall, systemd targets and console..."

mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
tee "$ROOTFS/etc/NetworkManager/conf.d/venax.conf" >/dev/null <<'EOF'
[main]
plugins=keyfile

[device]
wifi.scan-rand-mac-address=no

[connection]
autoconnect-retries=3
wifi.cloned-mac-address=preserve
# 2 = disable Wi-Fi power-save. A sleeping radio is a common cause of a
# server that answers itself (loopback) but is slow or unreachable to
# other devices on the LAN.
wifi.powersave=2
EOF

# mDNS only needs UDP/5353 (multicast DNS-SD). The previous ruleset
# also opened TCP/5353, which avahi does not use here -- removed.
tee "$ROOTFS/etc/nftables.conf" >/dev/null <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet venax {
    chain input {
        type filter hook input priority 0;
        policy drop;

        iif "lo" accept
        ct state established,related accept

        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        udp dport 5353 accept

        tcp dport 8080 accept
        tcp dport 11434 accept
    }

    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}
EOF

# venax.target aggregates the actual appliance services under one
# name systemd can order multi-user.target boot against. This is the
# thing that now genuinely orchestrates the "critical path" described
# in the design doc -- it is not something a login shell has to poke.
tee "$ROOTFS/etc/systemd/system/venax.target" >/dev/null <<'EOF'
[Unit]
Description=VenaX appliance (network, storage, Ollama, web UI)
Wants=venax-data.service ollama.service venax-web.service
After=venax-data.service ollama.service venax-web.service

[Install]
WantedBy=multi-user.target
EOF

# venax-console is the admin/status view shown on the auto-login
# console. Unlike the old venax-startup, it does not start or restart
# any service -- systemd has already done that independently of
# whether anyone is logged in at the console. Its only two jobs are:
#   1. Interactively launch Wi-Fi setup if no usable connection exists.
#   2. Poll already-running units/health endpoints and render status.
tee "$ROOTFS/usr/local/sbin/venax-console" >/dev/null <<'CONSOLEEOF'
#!/usr/bin/env bash
set -u

clear
echo '============================================================'
echo '                         VenaX'
echo '                    Local AI Server'
echo '============================================================'
echo

connected() {
    sudo -n nmcli -t -f STATE general status 2>/dev/null | grep -qx 'connected'
}

if ! connected; then
    echo 'No active network connection detected.'
    echo 'If Ethernet is plugged in, it should connect automatically --'
    echo 'this prompt means neither Ethernet nor a saved Wi-Fi profile'
    echo 'produced a working connection yet.'
    echo
    until connected; do
        /usr/local/bin/wifi
        connected && break
        clear
        echo 'Wi-Fi setup was not completed.'
        echo
        echo '[ENTER] try again    [s] drop to a shell'
        read -r -p 'Selection: ' choice
        if [[ "$choice" == "s" || "$choice" == "S" ]]; then
            exec /bin/bash
        fi
    done
fi

WIFI_DEV="$(sudo -n nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
IP=""
if [[ -n "$WIFI_DEV" ]]; then
    IP="$(sudo -n nmcli -g IP4.ADDRESS device show "$WIFI_DEV" 2>/dev/null | head -n1 | cut -d/ -f1)"
fi
if [[ -z "$IP" ]]; then
    IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
[[ -z "$IP" ]] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo 'Waiting for VenaX services (already started by systemd)...'
echo

WEB_READY=0
for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then WEB_READY=1; break; fi
    sleep 1
done

OLLAMA_READY=0
for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then OLLAMA_READY=1; break; fi
    sleep 1
done

STORAGE_STATUS="UNKNOWN"
STORAGE_REASON=""
if [[ -r /run/venax/storage-status ]]; then
    # shellcheck disable=SC1091
    source /run/venax/storage-status
    STORAGE_STATUS="${STATUS:-UNKNOWN}"
    STORAGE_REASON="${REASON:-}"
fi

INTERNET="Unavailable"
timeout 2 bash -c 'echo >/dev/tcp/1.1.1.1/53' >/dev/null 2>&1 && INTERNET="Connected"

clear
echo '============================================================'
if ((WEB_READY && OLLAMA_READY)) && [[ -n "$IP" ]]; then
    echo '                     VENA X READY'
elif ((WEB_READY)); then
    echo '              VENA X RUNNING (OLLAMA NOT READY)'
else
    echo '              VENA X WEB UI NOT READY'
fi
echo '============================================================'
echo
echo 'Network'
printf '  Interface   : %s\n' "${WIFI_DEV:-(non-wifi / ethernet)}"
printf '  LAN         : %s\n' "$(connected && echo Connected || echo 'Not connected')"
printf '  IP          : %s\n' "${IP:-unknown}"
printf '  Internet    : %s\n' "$INTERNET"
echo
echo 'Storage'
printf '  Persistent  : %s\n' "$STORAGE_STATUS"
[[ -n "$STORAGE_REASON" ]] && printf '  Detail      : %s\n' "$STORAGE_REASON"
echo
echo 'AI Server'
printf '  Ollama      : %s\n' "$(systemctl is-active ollama 2>/dev/null)"
echo
echo 'Web UI'
printf '  Status      : %s\n' "$(systemctl is-active venax-web 2>/dev/null)"
if ((WEB_READY)) && [[ -n "$IP" ]]; then
    printf '  URL         : http://%s:8080\n' "$IP"
    printf '  mDNS        : http://venax.local:8080\n'
fi
if ((OLLAMA_READY)) && [[ -n "$IP" ]]; then
    printf '  Ollama API  : http://%s:11434\n' "$IP"
fi
echo
if ! ((WEB_READY)); then
    echo 'Web UI diagnostics:'
    echo '------------------------------------------------------------'
    systemctl status venax-web.service --no-pager -l 2>&1 | sed -n '1,10p'
    echo
fi
if ! ((OLLAMA_READY)); then
    echo 'Ollama diagnostics:'
    echo '------------------------------------------------------------'
    systemctl status ollama.service --no-pager -l 2>&1 | sed -n '1,10p'
    echo
fi
echo 'TERMINAL COMMANDS'
echo '------------------------------------------------------------'
echo '  venax-status      live CPU/RAM/storage/GPU monitor'
echo '  venax-hardware    hardware information'
echo '  wifi              Wi-Fi manager'
echo '  ollama            Ollama CLI'
echo '============================================================'
echo
exec /bin/bash
CONSOLEEOF
chmod 755 "$ROOTFS/usr/local/sbin/venax-console"

mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
tee "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin venax --noclear %I $TERM
Type=idle
EOF

# .bash_profile now launches an admin STATUS VIEW, not the boot
# orchestrator. Core services are already independently started by
# systemd (venax.target / multi-user.target) whether or not this
# shell ever runs.
tee "$ROOTFS/home/venax/.bash_profile" >/dev/null <<'EOF'
if [ -z "${VENAX_CONSOLE_STARTED:-}" ]; then
    export VENAX_CONSOLE_STARTED=1
    /usr/local/sbin/venax-console
fi
EOF

tee "$ROOTFS/home/venax/.bashrc" >/dev/null <<'EOF'
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
PS1='\[\e[1;36m\]venax\[\e[0m\]@\[\e[1;35m\]\h\[\e[0m\]:\[\e[1;32m\]\w\[\e[0m\]\$ '
alias status='venax-status'
alias hardware='venax-hardware'
EOF

chroot "$ROOTFS" /bin/bash -c '
chown -R venax:venax /home/venax
chmod 644 /home/venax/.bash_profile /home/venax/.bashrc
systemctl daemon-reload
systemctl enable getty@tty1.service
systemctl enable nftables.service
systemctl enable venax-data.service
systemctl enable ollama.service
systemctl enable venax-web.service
systemctl enable venax.target
'

echo "[13/14] Build-time validation..."

echo "  - bash syntax..."
for f in \
    "$ROOTFS/usr/local/bin/wifi" \
    "$ROOTFS/usr/local/bin/venax-status" \
    "$ROOTFS/usr/local/bin/venax-hardware" \
    "$ROOTFS/usr/local/sbin/venax-console" \
    "$ROOTFS/usr/local/sbin/venax-data" \
    "$ROOTFS/usr/local/sbin/venax-performance"; do
    bash -n "$f" || { echo "ERROR: shell syntax validation failed: $f"; exit 1; }
    chmod 755 "$f"
    [[ -x "$f" ]] || { echo "ERROR: not executable after chmod: $f"; exit 1; }
done
bash -n "$PROJECT_DIR/build-iso.sh" || { echo "ERROR: build-iso.sh itself fails bash -n"; exit 1; }

echo "  - Python syntax..."
python3 -m py_compile "$ROOTFS/usr/local/bin/venax-web.py" || { echo "ERROR: venax-web.py failed to compile"; exit 1; }
rm -rf "$ROOTFS/usr/local/bin/__pycache__"

echo "  - nftables syntax..."
if command -v nft >/dev/null 2>&1; then
    nft -c -f "$ROOTFS/etc/nftables.conf" || { echo "ERROR: nftables.conf failed validation"; exit 1; }
else
    echo "    nft not present on build host -- skipping (will still be enforced at boot by nftables.service)."
fi

echo "  - systemd unit verification..."
if command -v systemd-analyze >/dev/null 2>&1; then
    for unit in venax-data.service venax-web.service venax.target; do
        systemd-analyze verify --root="$ROOTFS" "$unit" 2>&1 | sed "s/^/    [$unit] /" || true
    done
else
    echo "    systemd-analyze not present on build host -- skipping."
fi

echo "[14/14] Building final ISO..."

chroot "$ROOTFS" update-initramfs -u -k all

# Unmount the chroot bind mounts now (host-side tools below need the
# real host /proc, /sys, /dev -- not the bind-mounted chroot copies),
# but do NOT call cleanup() here: cleanup() always ends in `exit`,
# which previously killed the script before mksquashfs/grub-mkrescue
# ever ran. unmount_chroot() only unmounts; it returns control here.
unmount_chroot
trap - EXIT

KERNEL="$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' -type f | sort -V | tail -n1)"
INITRD="$(find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' -type f | sort -V | tail -n1)"

[[ -n "$KERNEL" ]] || { echo "ERROR: kernel not found."; exit 1; }
[[ -n "$INITRD" ]] || { echo "ERROR: initrd not found."; exit 1; }

cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd"

mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" \
    -comp zstd -noappend \
    -e var/cache/apt var/lib/apt/lists var/log tmp var/tmp

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0

menuentry "VenaX ${VERSION}" {
    linux /live/vmlinuz boot=live
    initrd /live/initrd
}
EOF

grub-mkrescue -o "$OUTPUT_DIR/$ISO_NAME" "$ISO_DIR"
sha256sum "$OUTPUT_DIR/$ISO_NAME" > "$OUTPUT_DIR/SHA256SUMS"

cat > "$OUTPUT_DIR/RELEASE_NOTES.txt" <<EOF
VenaX ${VERSION}
================
See boot screen for usage. See the CHANGELOG comments at the top of
build-iso.sh for what changed in this production refactor.
EOF

# Hand the deliverables (and the top-level project dir entry) back to
# the person who ran this, since the whole build ran as root. Leaving
# $ROOTFS root-owned is fine/expected -- it gets wiped and rebuilt as
# root on every run anyway.
if [[ "$ORIG_USER" != "root" ]] && id -u "$ORIG_USER" >/dev/null 2>&1; then
    chown -R "$ORIG_USER":"$ORIG_USER" "$OUTPUT_DIR" "$ISO_DIR" "$BUILD_DIR" 2>/dev/null || true
    chown "$ORIG_USER":"$ORIG_USER" "$PROJECT_DIR" 2>/dev/null || true
fi

echo ""
echo "============================================================"
echo "                 VenaX BUILD COMPLETE"
echo "============================================================"
echo ""
echo "ISO: $OUTPUT_DIR/$ISO_NAME"
echo ""
echo "SHA256:"
cat "$OUTPUT_DIR/SHA256SUMS"
echo ""
ls -lh "$OUTPUT_DIR/$ISO_NAME" "$OUTPUT_DIR/SHA256SUMS" "$OUTPUT_DIR/RELEASE_NOTES.txt"
echo ""
