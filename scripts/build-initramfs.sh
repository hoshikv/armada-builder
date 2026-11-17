#!/usr/bin/env bash
# Build a bootable initramfs for Peridot (SM8635).
#
# Usage:
#   build-initramfs.sh --modules-dir DIR --firmware-dir DIR --thermal-dir DIR \
#                      --output initrd.img [--module-mode minimal|all|none]
#
# --modules-dir points at a tree containing lib/modules/<kver>/ (the same
# layout produced by `make INSTALL_MOD_PATH=... modules_install`).

set -euo pipefail

MODULES_DIR=""
FIRMWARE_DIR=""
THERMAL_DIR=""
OUTPUT="initrd.img"
MODULE_MODE="minimal"

while [ $# -gt 0 ]; do
    case "$1" in
        --modules-dir) MODULES_DIR="$2"; shift 2 ;;
        --firmware-dir) FIRMWARE_DIR="$2"; shift 2 ;;
        --thermal-dir) THERMAL_DIR="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --module-mode) MODULE_MODE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in busybox cpio gzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found (install busybox-static, cpio, gzip)" >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,dev,run,tmp,lib,usr/bin,usr/sbin,usr/lib,thermal}

# Static busybox + applet links so the initramfs needs no shared libraries.
cp "$(command -v busybox)" "$ROOT/bin/busybox"
chmod 755 "$ROOT/bin/busybox"
APPLETS=""
if ! APPLETS="$("$ROOT/bin/busybox" --list 2>/dev/null)"; then
    # Cross-built busybox cannot run on the build host; use the common set.
    APPLETS="sh ash init mount umount cat echo ls ln mkdir mknod sleep tr uname
             modprobe insmod lsmod depmod dmesg sed grep awk cut printf test [
             switch_root poweroff reboot mdev chmod chown find xargs cp mv rm
             gzip gunzip tar sync blkid fdisk"
fi
while IFS= read -r applet; do
    [ -n "$applet" ] || continue
    ln -sf /bin/busybox "$ROOT/bin/$applet"
done <<< "$APPLETS"

# Kernel modules.
KVER=""
if [ -n "$MODULES_DIR" ] && [ -d "$MODULES_DIR/lib/modules" ]; then
    KVER="$(find "$MODULES_DIR/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)"
fi

if [ -n "$KVER" ] && [ "$MODULE_MODE" != "none" ]; then
    mkdir -p "$ROOT/lib/modules/$KVER"
    if [ "$MODULE_MODE" = "all" ]; then
        cp -a "$MODULES_DIR/lib/modules/$KVER/." "$ROOT/lib/modules/$KVER/"
    else
        MODULE_LIST="$WORK/modules.list"
        : > "$MODULE_LIST"
        for name in qcom_tsens qcom_spmi_temp_alarm msm panel_xiaomi_peridot \
                    goodix goodix_ts ath11k ath11k_pci qca hci_uart btqca; do
            modprobe -d "$MODULES_DIR" -S "$KVER" --show-depends "$name" 2>/dev/null \
                | awk '/^insmod / {print $2}' >> "$MODULE_LIST" || true
        done

        if [ -s "$MODULE_LIST" ]; then
            sort -u "$MODULE_LIST" | while IFS= read -r mod; do
                case "$mod" in
                    "$MODULES_DIR"/*) ;;
                    *) continue ;;
                esac
                rel="${mod#"$MODULES_DIR"/}"
                install -D -m 644 "$mod" "$ROOT/$rel"
            done
        fi

        # Metadata so depmod/modprobe work inside the initramfs.
        for f in modules.builtin modules.builtin.modinfo modules.order; do
            if [ -f "$MODULES_DIR/lib/modules/$KVER/$f" ]; then
                cp -a "$MODULES_DIR/lib/modules/$KVER/$f" "$ROOT/lib/modules/$KVER/"
            fi
        done
        if command -v depmod >/dev/null 2>&1; then
            depmod -b "$ROOT" "$KVER" 2>/dev/null || true
        fi
    fi
fi

# Firmware.
if [ -n "$FIRMWARE_DIR" ] && [ -d "$FIRMWARE_DIR" ]; then
    mkdir -p "$ROOT/lib/firmware"
    cp -a "$FIRMWARE_DIR"/. "$ROOT/lib/firmware/"
fi

# Thermal helpers are kept for the userspace stage; Python is not part of the
# initramfs, so init does not start them here.
if [ -n "$THERMAL_DIR" ] && [ -d "$THERMAL_DIR" ]; then
    cp -a "$THERMAL_DIR"/. "$ROOT/thermal/"
fi

cat > "$ROOT/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s /bin 2>/dev/null || true

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm /run /tmp
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

echo "=== Armada-Dodge Peridot initramfs ==="
uname -a
[ -r /proc/device-tree/model ] && { echo -n "model: "; tr -d '\0' < /proc/device-tree/model; echo; }
[ -r /proc/device-tree/compatible ] && { echo -n "compatible: "; tr '\0' ' ' < /proc/device-tree/compatible; echo; }

if command -v depmod >/dev/null 2>&1; then
    depmod -a 2>/dev/null || true
fi

for mod in qcom_tsens qcom_spmi_temp_alarm msm panel_xiaomi_peridot goodix ath11k_pci hci_uart qca; do
    modprobe "$mod" 2>/dev/null && echo "loaded: $mod"
done

echo "--- /proc/cmdline ---"
cat /proc/cmdline
echo "--- block devices ---"
ls -l /dev/block 2>/dev/null || true
ls -l /dev/mmcblk* /dev/sd* /dev/nvme* 2>/dev/null || true

if [ -x /sbin/init ]; then
    echo "starting /sbin/init"
    exec /sbin/init
fi

echo "no /sbin/init in initramfs; starting rescue shell"
exec /bin/sh -i
INIT
chmod 755 "$ROOT/init"

( cd "$ROOT" && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9 > "$OUTPUT" )

echo "initramfs: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
if [ -n "$KVER" ]; then
    echo "kernel release: $KVER, module mode: $MODULE_MODE"
fi
