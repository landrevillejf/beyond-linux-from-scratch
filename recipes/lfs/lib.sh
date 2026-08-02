#!/usr/bin/env bash
# recipes/lfs/lib.sh — shared helpers for LFS 13.0 LPM recipes.
#
# Recipes source this file with:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
#
# It provides:
#   LFS            - target build root (must be set in the environment)
#   LFS_TGT        - cross-compilation triplet (set by the toolchain stage)
#   LFS_SOURCES    - directory holding all upstream tarballs (default: $LFS/sources)
#   companion <file> <url>  - ensure a companion tarball exists, download if missing,
#                             echo its absolute path. Used by packages such as GCC
#                             that must unpack GMP/MPFR/MPC inside their own tree.
#   njobs          - echo the number of parallel jobs ($JOBS, else nproc).
#
# The engine (blfs/19-lpm.sh) also exports to every recipe's build():
#   PKG  - staging directory (use `make DESTDIR="$PKG" install` for tracked packages)
#   SRC  - extracted source directory (equals the cwd when build() runs)
#   JOBS - configured parallel job count

: "${LFS:?LFS must point at the target build root}"
: "${LFS_SOURCES:=$LFS/sources}"

njobs() {
    if [ -n "${JOBS:-}" ] && [ "${JOBS}" -gt 0 ] 2>/dev/null; then
        echo "$JOBS"
    else
        nproc 2>/dev/null || echo 1
    fi
}

companion() {
    local file="$1" url="$2" dest
    mkdir -p "$LFS_SOURCES"
    dest="$LFS_SOURCES/$file"
    if [ ! -f "$dest" ]; then
        echo "  -> fetching companion source $file" >&2
        curl -fL --connect-timeout 30 -o "$dest" "$url" \
            || { echo "failed to download $url" >&2; return 1; }
    fi
    echo "$dest"
}
