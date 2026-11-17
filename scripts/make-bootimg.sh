#!/usr/bin/env bash
# Build a flashless `fastboot boot` image (Android boot header v2) for Peridot.
#
# Usage:
#   make-bootimg.sh --kernel Image --initrd initrd.img --dtb peridot.dtb \
#                   --output peridot-boot.img [--cmdline "..."]
#
# Header v2 keeps kernel + ramdisk + dtb in one image, which is what ABL needs
# when booting a temporary image that was never written to a slot.

set -euo pipefail

KERNEL=""
INITRD=""
DTB=""
OUTPUT="peridot-boot.img"
CMDLINE="console=ttyMSM0,115200n8 earlycon loglevel=7 ignore_loglevel"

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) KERNEL="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        --dtb) DTB="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --cmdline) CMDLINE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,9p' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for f in "$KERNEL" "$INITRD" "$DTB"; do
    [ -f "$f" ] || { echo "error: missing input: $f" >&2; exit 1; }
done
if ! command -v mkbootimg >/dev/null 2>&1; then
    echo "error: mkbootimg not found (install mkbootimg)" >&2
    exit 1
fi

mkbootimg \
    --kernel "$KERNEL" \
    --ramdisk "$INITRD" \
    --dtb "$DTB" \
    --header_version 2 \
    --pagesize 4096 \
    --base 0x00000000 \
    --cmdline "$CMDLINE" \
    --output "$OUTPUT"

echo "boot image: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
