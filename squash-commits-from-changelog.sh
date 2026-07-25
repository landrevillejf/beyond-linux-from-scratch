#!/usr/bin/env bash
# squash-commits-from-changelog.sh
# Squash all commits since a given base into one commit,
# using the latest version entry from CHANGELOG.md as the commit message.

set -euo pipefail

BASE_COMMIT="${1:-}"   # optional: SHA, tag, or "root" for the initial commit
FORCE_PUSH="${2:-no}"  # "yes" to force-push the result

# ---- 1. Find the base commit ----
if [ -z "$BASE_COMMIT" ]; then
    # Default: use the very first commit of the repo
    BASE_COMMIT=$(git rev-list --max-parents=0 HEAD)
    echo "No base commit specified, using root commit: $BASE_COMMIT"
fi

# ---- 2. Extract the latest version message from CHANGELOG.md ----
if [ ! -f CHANGELOG.md ]; then
    echo "ERROR: CHANGELOG.md not found in current directory"
    exit 1
fi

# Assuming the latest version is the first `## [x.y.z]` block after the header
VERSION_LINE=$(grep -m1 '^## \[[0-9]' CHANGELOG.md || true)
if [ -z "$VERSION_LINE" ]; then
    echo "ERROR: Could not find a version header in CHANGELOG.md"
    exit 1
fi

VERSION=$(echo "$VERSION_LINE" | sed 's/^## \[//;s/\].*//')
DATE_PART=$(echo "$VERSION_LINE" | sed 's/.*\] – //' || echo "")
echo "Using version: $VERSION ($DATE_PART)"

# Extract the content of this version block (until the next `## [` line)
# We use awk to capture lines between our header and the next header.
MESSAGE=$(awk -v ver="$VERSION_LINE" '
    $0 == ver {found=1; next}
    /^## \[/ {if (found) exit}
    found {print}
' CHANGELOG.md)

if [ -z "$MESSAGE" ]; then
    echo "ERROR: No content found for version $VERSION"
    exit 1
fi

# Clean up the message: trim leading/trailing whitespace, remove empty first lines
MESSAGE=$(echo "$MESSAGE" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Build final commit message
COMMIT_MSG="Release v${VERSION} ($DATE_PART)

$MESSAGE"

echo "----- Commit message preview -----"
echo "$COMMIT_MSG"
echo "----------------------------------"

# ---- 3. Squash all commits from BASE_COMMIT (exclusive) to HEAD ----
# We'll reset soft to BASE_COMMIT, keeping all changes staged, then commit.
echo "Resetting soft to $BASE_COMMIT ..."
git reset --soft "$BASE_COMMIT"

echo "Creating new commit with consolidated message..."
git commit -m "$COMMIT_MSG"

# ---- 4. Optional force-push ----
if [ "$FORCE_PUSH" = "yes" ]; then
    CURRENT_BRANCH=$(git branch --show-current)
    echo "Force-pushing to origin/$CURRENT_BRANCH..."
    git push --force-with-lease origin "$CURRENT_BRANCH"
else
    echo "Squash complete. To push, run:"
    echo "  git push --force-with-lease origin $(git branch --show-current)"
fi