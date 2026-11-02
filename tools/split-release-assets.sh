#!/bin/bash
# tools/split-release-assets.sh
# Split release payloads that exceed GitHub's per-asset size cap, so a large
# live ISO stays publishable.
#
# GitHub's Release API refuses any asset whose size is not strictly
# "less than 2147483648" bytes.  lg3d Nightly #69 died exactly there:
#
#   Validation Failed: {"resource":"ReleaseAsset","code":"custom","field":
#   "size","message":"size must be less than 2147483648"}
#
# the 2 856 MB lg3d live ISO was rejected while every small asset of the same
# release uploaded fine, so the nightly published a release with no bootable
# image at all.  Recompression is not an answer: a live ISO carries an
# xz-compressed squashfs that already sits at its entropy floor, so zstd on top
# of it buys a few percent, not the 30% the cap demands.  The caches work
# around the cap by streaming through `split -b 1900m` (cache-packages.yml,
# build-base-cache.yml, build-rootfs-cache.yml); this applies the same
# convention to whatever else crosses the line.
#
# For every oversized file F the tool leaves behind, in F's own directory:
#
#   F.part-00 .. F.part-NN   the byte-exact pieces, concatenated in order
#   F.parts                  manifest: whole-file size/sha256 + assemble line
#   F.parts.sha256           sha256sum lines for the individual parts
#
# and F itself is removed, so the uploader never sees a >2 GiB asset again.
# The per-part names keep the original extension (`.iso.part-00`), which is
# what lets a consumer grab every piece of one ISO with a single glob.
#
# Reassembly is published as an EXPLICIT part list rather than a glob, because
# a dated tag can be re-dispatched (workflow_dispatch twice the same day) and
# the previous generation may have had MORE parts than this one: softprops
# overwrites same-named assets but never removes one, so a stale tail would sit
# on the release and `cat F.part-*` would splice it onto the ISO.  With --tag
# the tool deletes those superseded parts before the new ones are uploaded.
#
# Usage:
#   split-release-assets.sh [options] <dir>...
#
# Only the top level of <dir> is scanned by default: release.yml and
# build-iso-from-cache.yml point this tool at build-release/, and $LFS *is*
# build-release/, so a recursive scan would reach into the installed system and
# cut a data file that is not a release payload at all.  Pass --recursive for
# the create-release download tree, where one subdirectory per matrix leg is
# exactly the layout being published.
#
# Options:
#   --max-bytes N     split files larger than N (default 2147483647, one byte
#                     under the API cap; the default needs no tuning)
#   --part-size SIZE  piece size passed to split(1) (default 1900m, the size
#                     the cache releases already use)
#   --recursive       also scan <dir>/*/, for the create-release tree
#   --tag TAG         release tag to purge superseded parts from (optional;
#                     needs gh + GITHUB_TOKEN, skipped with a warning when
#                     either is missing, because purging must never block a
#                     release)
#   --repo REPO       repository for --tag (default $GITHUB_REPOSITORY)
#   --dry-run         report what would be split, change nothing
#   -h, --help        show this help
#
# Environment:
#   GITHUB_TOKEN         API token for the --tag purge
#   GITHUB_REPOSITORY    owner/repo for the --tag purge
#   GITHUB_STEP_SUMMARY  optional; the manifests are appended to it
#   SUDO_UID/SUDO_GID    when run through sudo, the outputs are handed back to
#                        the caller, because the uploader that consumes them
#                        runs unprivileged (see hand_back_to_caller)
set -euo pipefail

# The cap the API enforces; a file of exactly this size is already rejected, so
# MAX_BYTES is one byte less and anything bigger than MAX_BYTES gets split.
ASSET_CAP_BYTES=2147483648
MAX_BYTES=$((ASSET_CAP_BYTES - 1))
PART_SIZE="1900m"
RELEASE_TAG=""
REPO="${GITHUB_REPOSITORY:-}"
DRY_RUN=0
SCAN=(-maxdepth 1)
DIRS=()

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }

usage() {
    cat <<'EOF'
usage: split-release-assets.sh [options] <dir>...

  --max-bytes N     split files larger than N (default 2147483647)
  --part-size SIZE  piece size for split(1) (default 1900m)
  --recursive       also scan <dir>/*/ (default: <dir> only)
  --tag TAG         purge superseded parts from this release tag
  --repo REPO       owner/repo for --tag (default $GITHUB_REPOSITORY)
  --dry-run         report only
EOF
}

# GNU split suffixes are binary (m = 1048576), which is what the 1900m parts in
# the cache workflows already assume.
to_bytes() {
    local size="$1" mult=1
    case "$size" in
    *k | *K)
        mult=1024
        size="${size%[kK]}"
        ;;
    *m | *M)
        mult=$((1024 * 1024))
        size="${size%[mM]}"
        ;;
    *g | *G)
        mult=$((1048576 * 1024))
        size="${size%[gG]}"
        ;;
    esac
    echo $((size * mult))
}

# A caller whose payload tree belongs to the build user either hands that
# directory over first (what the workflow steps do) or runs this through sudo;
# either way the step that uploads the result runs unprivileged.  Hand
# everything back, or the upload dies on a file it cannot read.
hand_back_to_caller() {
    local path
    [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ] || return 0
    for path in "$@"; do
        [ -e "$path" ] || continue
        chmod 0644 "$path" || true
        chown "${SUDO_UID}:${SUDO_GID}" "$path" || true
    done
}

note_summary() {
    # Best effort: only exists on a GitHub runner.
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
    [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ] &&
        chown "${SUDO_UID}:${SUDO_GID}" "$GITHUB_STEP_SUMMARY" || true
}

# Rewrite every *.pointer that advertises the file just split, so the tiny
# pointer asset never 404s: its download_url now resolves the manifest, which
# in turn carries the assemble line.
repair_pointers() {
    local dir="$1" base="$2" manifest="$3" parts="$4"
    local pointer url tmp mode
    while IFS= read -r pointer; do
        [ -f "$pointer" ] || continue
        grep -q "^iso_name=${base}\$" "$pointer" || continue
        url=$(sed -n 's/^download_url=//p' "$pointer" | head -n1)
        # mktemp hands back 0600 and mv keeps it, which would turn a world
        # readable pointer into one the uploader cannot read.
        mode=$(stat -c %a "$pointer")
        tmp=$(mktemp "${pointer}.XXXXXX")
        grep -v '^download_url=' "$pointer" >"$tmp" || true
        {
            if [ -n "$url" ]; then
                echo "download_url=${url%/*}/${manifest}"
            fi
            echo "parts_manifest=${manifest}"
            echo "parts=${parts}"
            echo "assemble=cat ${parts} > ${base}"
        } >>"$tmp"
        mv "$tmp" "$pointer"
        chmod "$mode" "$pointer"
        hand_back_to_caller "$pointer"
        log_info "repaired pointer ${pointer##*/} -> ${manifest}"
        note_summary "- pointer \`${pointer##*/}\` now resolves \`${manifest}\`"
    done < <(find "$dir" -maxdepth 1 -name '*.pointer' -type f)
}

split_file() {
    local file="$1" dir base size sha need suffix_len count parts manifest shafile
    local prefixed=() part
    dir=$(dirname "$file")
    base=$(basename "$file")
    size=$(stat -c %s "$file")

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "would split $file ($size bytes) into parts of $PART_SIZE"
        return 0
    fi

    need=$(((size + PART_BYTES - 1) / PART_BYTES))
    # -d -a 2 covers 99 pieces, 183 GiB at the default part size; widen the
    # numeric suffix only if some payload ever needs more.
    suffix_len=2
    if [ "$need" -gt 99 ]; then
        suffix_len=${#need}
    fi

    log_info "splitting $file ($size bytes) into $need parts of $PART_SIZE"
    sha=$(sha256sum "$file" | awk '{print $1}')
    split -b "$PART_SIZE" -d -a "$suffix_len" "$file" "$file.part-"
    rm -f "$file"

    # Names relative to the directory, so the assemble line works once a
    # consumer has cd'd into wherever it downloaded the parts.
    parts=$(cd "$dir" && ls -v "${base}.part-"* | tr '\n' ' ')
    parts=${parts% }
    count=$(wc -w <<<"$parts")
    manifest="${base}.parts"
    shafile="${base}.parts.sha256"

    {
        echo "# ${base} exceeds GitHub's per-release-asset cap of ${ASSET_CAP_BYTES} bytes,"
        echo "# so it is published as the parts below.  Reassemble, then verify:"
        echo "#"
        echo "#   cat ${parts} > ${base}"
        echo "#   sha256sum ${base}   # must equal the sha256= line below"
        echo "# ${base}.parts.sha256 holds the checksum of each individual part."
        echo "# Do not glob *.part*: that also matches this manifest."
        echo "file=${base}"
        echo "size=${size}"
        echo "sha256=${sha}"
        echo "part_size=${PART_SIZE}"
        echo "part_count=${count}"
        echo "parts=${parts}"
        echo "assemble=cat ${parts} > ${base}"
    } >"$dir/$manifest"
    # shellcheck disable=SC2086
    (cd "$dir" && sha256sum $parts) >"$dir/$shafile"
    # `parts` are deliberately directory-relative (that is what the assemble
    # line needs), so they must be re-based before touching them here.
    for part in $parts; do # shellcheck disable=SC2086
        prefixed+=("$dir/$part")
    done
    hand_back_to_caller "$dir/$manifest" "$dir/$shafile" "${prefixed[@]}"

    log_info "wrote ${dir}/${manifest} (${count} parts) and ${dir}/${shafile}"
    note_summary "- **${base}** (${size} bytes) published as ${count} parts:"
    note_summary "  \`cat ${parts} > ${base}\`, then \`sha256sum ${base}\`"
    note_summary "  must equal \`${sha}\`"
    repair_pointers "$dir" "$base" "$manifest" "$parts"
}

# Delete the parts this release carries for an ISO we are about to publish but
# that this generation no longer produces.  Scoped to the ISO names present
# locally, so no other payload on the tag is ever touched.
purge_superseded() {
    local dir="$1" stems asset local_parts
    [ -n "$RELEASE_TAG" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 ||
        [ -z "${GITHUB_TOKEN:-}" ] || [ -z "$REPO" ]; then
        log_warn "--tag given but gh/jq/token/repo missing: keeping stale parts"
        return 0
    fi
    # Compare by basename: create-release downloads one artifact directory per
    # matrix leg, so the parts of different legs never share a directory.
    stems=$(find "$dir" "${SCAN[@]}" -type f -name '*.part-*' -printf '%f\n' 2>/dev/null |
        sed -E 's/\.part-[0-9]+$//' | sort -u)
    [ -n "$stems" ] || return 0
    local_parts=$(find "$dir" "${SCAN[@]}" -type f -name '*.part-*' \
        -printf '%f\n' 2>/dev/null | sort -u)
    if ! gh release view "$RELEASE_TAG" --repo "$REPO" --json assets \
        >"$ASSET_JSON" 2>/dev/null; then
        log_warn "release $RELEASE_TAG is not published yet: nothing to purge"
        return 0
    fi
    while IFS= read -r stem; do
        while IFS= read -r asset; do
            [ -n "$asset" ] || continue
            grep -qxF "$asset" <<<"$local_parts" && continue
            log_info "deleting superseded asset $asset"
            gh release delete-asset "$RELEASE_TAG" "$asset" --repo "$REPO" --yes ||
                log_warn "could not delete $asset"
        done < <(jq -r '.assets[].name' "$ASSET_JSON" |
            grep -E "^${stem//./\\.}\.part-[0-9]+$" || true)
    done <<<"$stems"
}

while [ $# -gt 0 ]; do
    case "$1" in
    --max-bytes)
        MAX_BYTES="$2"
        shift 2
        ;;
    --part-size)
        PART_SIZE="$2"
        shift 2
        ;;
    --tag)
        RELEASE_TAG="$2"
        shift 2
        ;;
    --repo)
        REPO="$2"
        shift 2
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    --recursive)
        SCAN=()
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    -*)
        log_fail "unknown option: $1"
        usage >&2
        exit 2
        ;;
    *)
        DIRS+=("$1")
        shift
        ;;
    esac
done

if [ ${#DIRS[@]} -eq 0 ]; then
    log_fail "no directory given"
    usage >&2
    exit 2
fi

PART_BYTES=$(to_bytes "$PART_SIZE")
if [ "$PART_BYTES" -gt "$MAX_BYTES" ]; then
    log_fail "--part-size $PART_SIZE is not under the $MAX_BYTES byte asset cap"
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ASSET_JSON="$WORK/release-assets.json"

found=0
for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        log_fail "not a directory: $dir"
        exit 2
    fi
    # Depth follows SCAN: create-release downloads one subdirectory per
    # matrix leg (artifacts/release-artifacts-<profile>-<init>-<arch>/) and
    # needs --recursive, while the jobs that point at build-release/ must stay
    # at the top level or they would cut files of the installed system.
    while IFS= read -r file; do
        found=$((found + 1))
        split_file "$file"
    done < <(
        find "$dir" "${SCAN[@]}" -type f ! -name '*.part-*' ! -name '*.parts' \
            ! -name '*.parts.sha256' ! -name '*.pointer' -size +"$MAX_BYTES"c | sort
    )
    purge_superseded "$dir"
done

if [ "$found" -eq 0 ]; then
    log_info "no asset exceeds $MAX_BYTES bytes; nothing to split"
else
    log_info "split $found asset(s) to stay under the $MAX_BYTES byte cap"
fi
