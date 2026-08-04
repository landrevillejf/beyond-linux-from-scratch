#!/usr/bin/env bash
# make-release.sh – Prepare a release of the LFS/BLFS Builder project
# Usage: ./make-release.sh [--no-tag] [--no-tar] [--skip-tests] [--skip-clean] [--bump X.Y.Z]

set -e

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------- Detect OS for sed compatibility ----------
if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INLINE="sed -i ''"
else
    SED_INLINE="sed -i"
fi

# ---------- Functions ----------
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --no-tag       Do not create the Git tag (only the tarball)
  --no-tar       Do not create the tarball (only the tag)
  --skip-tests   Skip running tests before release
  --skip-clean   Skip cleaning build artifacts before release
  --bump VERSION   Update the version in VERSION file to VERSION (e.g. --bump 0.52.8)
                   before creating the release.
  --help         Show this help

Description:
  This script prepares a project release:
    - Optionally bumps the version in VERSION file
    - Checks that the Git repository is clean (or offers to commit changes)
    - Extracts the version from VERSION file
    - Optionally runs tests (if tools/run-tests.sh exists)
    - Optionally cleans build artifacts (if tools/clean-build.sh exists)
    - Creates a tarball of the source code
    - Creates a Git tag (optional)
    - Displays instructions for pushing and publishing

The version is read from VERSION file (single line with X.Y.Z format).
EOF
    exit 0
}

bump_version() {
    local new_version="$1"
    if [ -z "$new_version" ]; then
        echo -e "${RED}Error: specify new version (e.g., 0.52.8)${NC}" >&2
        exit 1
    fi
    # Update VERSION file
    echo "$new_version" > VERSION
    echo -e "${GREEN}Version set to $new_version in VERSION file${NC}"
    # Update version shown in documentation
    if [ -f docs/index.md ]; then
        sed -i.bak "s/\*\*Version:\*\* .*/\*\*Version:\*\* $new_version  /" docs/index.md && rm -f docs/index.md.bak
        echo -e "${GREEN}Version updated in docs/index.md${NC}"
    fi
}

# ---------- Parse arguments ----------
CREATE_TAG=true
CREATE_TAR=true
RUN_TESTS=true
RUN_CLEAN=true
BUMP_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-tag)      CREATE_TAG=false ;;
        --no-tar)      CREATE_TAR=false ;;
        --skip-tests)  RUN_TESTS=false ;;
        --skip-clean)  RUN_CLEAN=false ;;
        --bump)        BUMP_VERSION="$2"; shift ;;
        --help)        show_help ;;
        *)             echo -e "${RED}Unknown option: $1${NC}"; show_help ;;
    esac
    shift
done

# ---------- Checks ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: this directory is not a Git repository.${NC}"
    exit 1
fi

# ---------- Bump version if requested ----------
if [ -n "$BUMP_VERSION" ]; then
    echo -e "${BLUE}Bumping version to ${BUMP_VERSION}...${NC}"
    bump_version "$BUMP_VERSION"
    if ! git diff --quiet VERSION docs/index.md; then
        echo -e "${YELLOW}VERSION file has been modified. Committing the version bump...${NC}"
        git add VERSION docs/index.md
        git commit -m "Bump version to ${BUMP_VERSION}"
        echo -e "${GREEN}Version bump committed.${NC}"
    fi
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${YELLOW}Warning: there are uncommitted changes.${NC}"
    read -p "Do you want to commit them now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Committing...${NC}"
        git add -A
        git commit -m "WIP before release"
    else
        echo -e "${RED}Aborting: changes must be committed.${NC}"
        exit 1
    fi
fi

# ---------- Run tests ----------
if [ "$RUN_TESTS" = true ] && [ -f "./tools/run-tests.sh" ]; then
    echo -e "${BLUE}Running tests...${NC}"
    if ! bash ./tools/run-tests.sh; then
        echo -e "${RED}Tests failed. Aborting release.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Tests passed.${NC}"
elif [ "$RUN_TESTS" = true ]; then
    echo -e "${YELLOW}No tests script found (tools/run-tests.sh). Skipping.${NC}"
fi

# ---------- Clean build artifacts ----------
if [ "$RUN_CLEAN" = true ] && [ -f "./tools/clean-build.sh" ]; then
    echo -e "${BLUE}Cleaning build artifacts...${NC}"
    bash ./tools/clean-build.sh
    echo -e "${GREEN}Cleanup done.${NC}"
elif [ "$RUN_CLEAN" = true ]; then
    echo -e "${YELLOW}No clean script found (tools/clean-build.sh). Skipping.${NC}"
fi

# ---------- Extract version from VERSION file ----------
VERSION_FILE="VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}Error: $VERSION_FILE not found.${NC}"
    exit 1
fi

VERSION=$(cat "$VERSION_FILE")
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: VERSION file is empty.${NC}"
    exit 1
fi

SPLIT_CREATED=false

echo -e "${GREEN}Detected version: ${VERSION}${NC}"

# ---------- Check if tag already exists ----------
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo -e "${YELLOW}Tag v$VERSION already exists.${NC}"
    read -p "Do you want to delete it and recreate it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git tag -d "v$VERSION"
        echo -e "${GREEN}Tag deleted.${NC}"
    else
        echo -e "${RED}Aborting.${NC}"
        exit 1
    fi
fi

# ---------- Summary and confirmation ----------
echo -e "${BLUE}Preparing release v${VERSION}${NC}"
echo "  - Create tag ?     : $([ "$CREATE_TAG" = true ] && echo "YES" || echo "NO")"
echo "  - Create tarball ? : $([ "$CREATE_TAR" = true ] && echo "YES" || echo "NO")"
echo

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborting.${NC}"
    exit 1
fi

# ---------- Create tarball ----------
if [ "$CREATE_TAR" = true ]; then
    TAR_NAME="lfs-builder-${VERSION}.tar.gz"
    EXCLUDE=(
        --exclude='.git'
        --exclude="$TAR_NAME"
        --exclude="./$TAR_NAME"
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.pytest_cache'
        --exclude='.coverage'
        --exclude='htmlcov'
        --exclude='coverage.xml'
        --exclude='*.egg-info'
        --exclude='.venv'
        --exclude='venv'
        --exclude='env'
        --exclude='lfs-build'
        --exclude='*.iso'
        --exclude='*.img'
        --exclude='*.qcow2'
        --exclude='.DS_Store'
    )
    echo -e "${BLUE}Creating tarball $TAR_NAME...${NC}"
    tar -czf "$TAR_NAME" "${EXCLUDE[@]}" .
    echo -e "${GREEN}Tarball created: $TAR_NAME${NC}"
fi

# ---------- Split tarball if it exceeds 2GB (GitHub's file size limit) ----------
if [ "$CREATE_TAR" = true ]; then
    TAR_SIZE=$(stat -f%z "$TAR_NAME" 2>/dev/null || stat -c%s "$TAR_NAME" 2>/dev/null)
    SIZE_LIMIT=$((2 * 1024 * 1024 * 1024))  # 2GB in bytes
    
    if [ "$TAR_SIZE" -gt "$SIZE_LIMIT" ]; then
        echo -e "${YELLOW}Tarball exceeds 2GB GitHub limit ($((TAR_SIZE / 1024 / 1024 / 1024))GB). Splitting...${NC}"
        split -b 1G "$TAR_NAME" "$TAR_NAME.part"
        echo -e "${GREEN}Split into parts:${NC}"
        ls -lh "$TAR_NAME".part*
        # Remove the original if split was successful
        rm "$TAR_NAME"
        echo -e "${GREEN}Original tarball removed. Use .part* files for release.${NC}"
        SPLIT_CREATED=true
    fi
fi

# ---------- Create tag ----------
if [ "$CREATE_TAG" = true ]; then
    echo -e "${BLUE}Creating tag v$VERSION...${NC}"
    git tag -a "v$VERSION" -m "Release v$VERSION"
    echo -e "${GREEN}Tag created.${NC}"
fi

# ---------- Instructions ----------
echo
echo -e "${GREEN}=== Release v$VERSION prepared successfully! ===${NC}"
echo
echo "Next steps:"
if [ "$CREATE_TAG" = true ]; then
    echo "  1. Push the tag:"
    echo "     git push origin v$VERSION"
fi
if [ "$CREATE_TAR" = true ]; then
    if [ "$SPLIT_CREATED" = true ]; then
        echo "  2. Publish the split tarballs:"
        echo "     gh release create v$VERSION lfs-builder-${VERSION}.tar.gz.part* --title \"LFS Builder v$VERSION\" --notes \"Release notes...\""
        echo
        echo "     To reconstruct the archive:"
        echo "     cat lfs-builder-${VERSION}.tar.gz.part* > lfs-builder-${VERSION}.tar.gz"
    else
        echo "  2. Publish the tarball:"
        echo "     gh release create v$VERSION lfs-builder-${VERSION}.tar.gz --title \"LFS Builder v$VERSION\" --notes \"Release notes...\""
    fi
    echo "  3. (Optional) Verify the tarball content:"
    if [ "$SPLIT_CREATED" = true ]; then
        echo "     cat lfs-builder-${VERSION}.tar.gz.part* | tar -tzf - | head -20"
    else
        echo "     tar -tzf lfs-builder-${VERSION}.tar.gz | head -20"
    fi
fi
echo
echo -e "${BLUE}Happy releasing!${NC}"