#!/usr/bin/env bash
#
# recipes/lfs/build-all.sh — drive an entire LFS 13.0 build through LPM recipes.
#
# It walks build-order.txt and invokes `lpm build` for each recipe in sequence.
# Cross-toolchain (Chapter 5) and temporary-tools (Chapters 6-7) recipes install
# directly into $LFS and are built with --no-install (LPM only runs their build()
# and records an empty package). Final-system (Chapter 8) recipes stage into $PKG
# and become real, tracked LPM packages installed into the LPM root.
#
# Usage:
#   LFS=/mnt/lfs LFS_TGT=x86_64-lfs-linux-gnu \
#     recipes/lfs/build-all.sh [options] [-- <extra args forwarded to lpm>]
#
# Options:
#   --phase <toolchain|temp-tools|system|all>  Only build the given phase (default: all)
#   --start <recipe>       Resume from the given recipe path (as listed in build-order.txt)
#   --list                 Print the resolved build order and exit
#   --dry-run              Print the lpm commands without executing them
#   -h, --help             Show this help
#
# Environment:
#   LFS        (required)  Target build root
#   LFS_TGT    (required for toolchain/temp phases) Cross triplet
#   LPM        (optional)  lpm executable to use (default: lpm)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER_FILE="$HERE/build-order.txt"
LPM="${LPM:-lpm}"

phase="all"
start=""
dry_run=false
list_only=false
extra=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)   phase="$2"; shift 2 ;;
        --start)   start="$2"; shift 2 ;;
        --list)    list_only=true; shift ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)        shift; extra=("$@"); break ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

: "${LFS:?LFS must point at the target build root}"
[ -f "$ORDER_FILE" ] || { echo "Missing $ORDER_FILE" >&2; exit 1; }

phase_of() {
    case "$1" in
        toolchain/*)  echo toolchain ;;
        temp-tools/*) echo temp-tools ;;
        system/*)     echo system ;;
        *)            echo unknown ;;
    esac
}

mapfile -t recipes < <(grep -vE '^[[:space:]]*(#|$)' "$ORDER_FILE")

started=false
[ -z "$start" ] && started=true

for rel in "${recipes[@]}"; do
    p="$(phase_of "$rel")"
    if [ "$phase" != "all" ] && [ "$phase" != "$p" ]; then
        continue
    fi
    if ! $started; then
        [ "$rel" = "$start" ] && started=true || continue
    fi

    recipe="$HERE/$rel"
    [ -f "$recipe" ] || { echo "Recipe not found: $recipe" >&2; exit 1; }

    args=(build)
    if [ "$p" = "toolchain" ] || [ "$p" = "temp-tools" ]; then
        args+=(--no-install)
    fi
    args+=("$recipe")

    if $list_only; then
        printf '%-12s %s\n' "$p" "$rel"
        continue
    fi

    echo "==> [$p] $rel"
    if $dry_run; then
        echo "    $LPM ${extra[*]:-} ${args[*]}"
    else
        "$LPM" "${extra[@]}" "${args[@]}"
    fi
done

$list_only || echo "All requested recipes processed."
