#!/usr/bin/env bash
# Build the FAT32 RAM media image for Peridot without mounting it (mtools).
#
# Usage:
#   make-media.sh --image Image --initrd initrd.img --dtb peridot.dtb \
#                 --modules-dir DIR --firmware-dir DIR --thermal-dir DIR \
#                 --output peridot-media.img [--size-mb 2048]
#
# Optional userspace trees are picked up from --armada-root, --arch-root and
# --steam-extra when they exist and are non-empty.

set -euo pipefail

IMAGE=""
INITRD=""
DTB=""
MODULES_DIR=""
FIRMWARE_DIR=""
THERMAL_DIR=""
ARMADA_ROOT=""
ARCH_ROOT=""
STEAM_EXTRA=""
OUTPUT="peridot-media.img"
SIZE_MB=2048

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        --dtb) DTB="$2"; shift 2 ;;
        --modules-dir) MODULES_DIR="$2"; shift 2 ;;
        --firmware-dir) FIRMWARE_DIR="$2"; shift 2 ;;
        --thermal-dir) THERMAL_DIR="$2"; shift 2 ;;
        --armada-root) ARMADA_ROOT="$2"; shift 2 ;;
        --arch-root) ARCH_ROOT="$2"; shift 2 ;;
        --steam-extra) STEAM_EXTRA="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --size-mb) SIZE_MB="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in mkfs.vfat mcopy mmd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found (install dosfstools mtools)" >&2
        exit 1
    fi
done
for f in "$IMAGE" "$INITRD" "$DTB"; do
    [ -f "$f" ] || { echo "error: missing input: $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"/{boot,modules,firmware,thermal,armada,arch,steam}

cp "$IMAGE" "$STAGE/boot/Image"
cp "$INITRD" "$STAGE/boot/initrd.img"
cp "$DTB" "$STAGE/boot/peridot.dtb"

if [ -n "$MODULES_DIR" ] && [ -d "$MODULES_DIR/lib/modules" ]; then
    cp -a "$MODULES_DIR/lib/modules" "$STAGE/modules/"
fi
if [ -n "$FIRMWARE_DIR" ] && [ -d "$FIRMWARE_DIR" ]; then
    cp -a "$FIRMWARE_DIR"/. "$STAGE/firmware/"
fi
if [ -n "$THERMAL_DIR" ] && [ -d "$THERMAL_DIR" ]; then
    cp -a "$THERMAL_DIR"/. "$STAGE/thermal/"
fi
for pair in "$ARMADA_ROOT:armada" "$ARCH_ROOT:arch" "$STEAM_EXTRA:steam"; do
    src="${pair%:*}"
    dst="${pair##*:}"
    if [ -n "$src" ] && [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
        cp -a "$src"/. "$STAGE/$dst/"
    fi
done

cat > "$STAGE/boot/boot.conf" <<EOF
# Peridot Armada Boot Configuration
KERNEL=Image
INITRD=initrd.img
DTB=peridot.dtb
BOOTARGS=console=ttyMSM0,115200n8 earlycon loglevel=7 ignore_loglevel
EOF

dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=none
mkfs.vfat -F 32 -n PERIDOT "$OUTPUT" >/dev/null
for item in "$STAGE"/*; do
    mcopy -s -i "$OUTPUT" "$item" ::/
done

echo "media: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
mdir -i "$OUTPUT" ::/ | head -20
