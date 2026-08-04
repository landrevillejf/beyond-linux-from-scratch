# How to Release the LFS Builder

## Overview

A release consists of:
1. **Versioning the source code** – Creating a Git tag and tarball via `make-release.sh`
2. **Publishing artifacts** – Uploading the tarball to GitHub Releases
3. **Triggering CI/CD builds** – Running workflows to build cache and ISO (optional, manual or scheduled)

---

## Quick Start

```bash
# 1. Bump version if needed
./make-release.sh --bump 0.52.36

# 2. Push tag to remote
git push origin v0.52.36

# 3. Create and upload release (script will auto-split if >2GB)
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz* \
  --title "LFS Builder v0.52.36" \
  --notes "Release notes here..."

# 4. (Optional) Trigger build workflows in GitHub Actions
# Go to: https://github.com/landrevillejf/beyond-linux-from-scratch/actions
```

---

## Step-by-Step Guide

### Step 1: Update Version (Optional)

If you want to bump the version automatically, run:

```bash
./make-release.sh --bump 0.52.36
```

This updates the `VERSION` file and documentation, then commits the change.

**If you prefer manual version updates**, edit `VERSION`:

```bash
echo "0.52.36" > VERSION
git add VERSION
git commit -m "Bump version to 0.52.36"
```

### Step 2: Run `make-release.sh`

```bash
./make-release.sh
```

**What this does:**
- ✅ Runs tests (unless `--skip-tests`)
- ✅ Cleans build artifacts (unless `--skip-clean`)
- ✅ Creates a tarball: `lfs-builder-0.52.36.tar.gz`
- ✅ **Automatically splits if tarball > 2GB** (GitHub's limit) → creates `.partaa`, `.partab`, etc.
- ✅ Creates a Git tag: `v0.52.36`

**Useful flags:**
```bash
./make-release.sh --skip-tests --skip-clean      # Fast: skip tests and cleanup
./make-release.sh --no-tag                        # Create tarball only (no tag)
./make-release.sh --no-tar                        # Create tag only (no tarball)
```

### Step 3: Push the Tag

```bash
git push origin v0.52.36
```

### Step 4: Create GitHub Release

The script shows you the exact command to run. If the tarball was split (>2GB), it will be:

```bash
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz.part* \
  --title "LFS Builder v0.52.36" \
  --notes "
## Release v0.52.36

### Changes
- Feature 1
- Bug fix 2

### Installation
To reconstruct from split archives:
\`\`\`bash
cat lfs-builder-0.52.36.tar.gz.part* > lfs-builder-0.52.36.tar.gz
tar -xzf lfs-builder-0.52.36.tar.gz
\`\`\`
"
```

**Otherwise (if tarball < 2GB):**

```bash
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz \
  --title "LFS Builder v0.52.36" \
  --notes "Release notes..."
```

---

## Automatic Tarball Splitting

### What Happens?

If your tarball exceeds 2GB (GitHub's file size limit):

1. `make-release.sh` automatically splits it into 1GB chunks
2. Creates files: `lfs-builder-0.52.36.tar.gz.partaa`, `partab`, `partac`, etc.
3. Deletes the original tarball
4. Shows you the exact `gh release create` command to upload all parts

### How to Reconstruct

Users can reassemble split archives:

```bash
# Download all .part* files, then:
cat lfs-builder-0.52.36.tar.gz.part* > lfs-builder-0.52.36.tar.gz
tar -xzf lfs-builder-0.52.36.tar.gz
```

**Always include reconstruction instructions in release notes!**

---

## GitHub Actions Workflows

### Available Workflows

| Workflow | Trigger | Produces |
|----------|---------|----------|
| `XFCE SYSVINIT x86_64 Build Live ISO` | Manual / Schedule | Full build from scratch → rootfs cache + live ISO |
| `XFCE SYSTEMD x86_64 Build Live ISO` | Manual / Schedule | Full build from scratch → rootfs cache + live ISO |
| `Build ISO from Cache` | Manual | Uses existing cache → rebuilds ISO only (faster) |
| `Nightly` | Schedule (daily) | Tests all profiles (minimal builds) |

### Triggering a Build (Optional)

After pushing your release tag:

1. Go to **Actions** tab on GitHub
2. Select the desired workflow (e.g., `XFCE SYSVINIT x86_64 Build Live ISO`)
3. Click **Run workflow**
4. Choose branch or tag (usually `main` or your tag)
5. Click **Run**

The workflow will:
- Build cache and ISO
- Publish to a **separate GitHub Release** (typically tagged `vX.Y.Z-live`)

---

## Pre-Release Checklist

Before running `make-release.sh`:

- [ ] All tests pass locally: `pytest tests/`
- [ ] CHANGELOG.md is updated
- [ ] README.md is current (if docs changed)
- [ ] No uncommitted changes (or commit them first)
- [ ] Version in `VERSION` file is correct (or use `--bump`)

---

## Troubleshooting

### "Tag already exists"

If `make-release.sh` says the tag exists, you can:

1. **Option A:** Let the script delete and recreate it (interactive prompt)
2. **Option B:** Delete manually and retry
   ```bash
   git tag -d v0.52.36
   ./make-release.sh --no-tag  # re-run with --no-tag
   ```

### "Tarball upload fails"

If `gh release create` fails:

- Ensure you're logged in: `gh auth status`
- Check file permissions: `ls -lh lfs-builder-*`
- For split archives, ensure **all** `.part*` files exist: `ls lfs-builder-0.52.36.tar.gz.part*`

### "Tests fail during release"

Skip tests and run them manually:

```bash
pytest tests/
./make-release.sh --skip-tests
```

---

## Examples

### Example 1: Simple release (no version bump)

```bash
./make-release.sh --skip-clean  # Create tarball and tag
git push origin v0.52.36
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz* \
  --title "LFS Builder v0.52.36" \
  --notes "Minor fixes and improvements."
```

### Example 2: Full release with version bump

```bash
./make-release.sh --bump 0.52.36          # Updates VERSION, commits, tags
git push origin v0.52.36
# (script shows the exact gh command to run)
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz* \
  --title "LFS Builder v0.52.36" \
  --notes "See CHANGELOG.md for details."
```

### Example 3: Release with split tarball

```bash
./make-release.sh --skip-tests
# Script auto-splits if > 2GB and shows:
gh release create v0.52.36 lfs-builder-0.52.36.tar.gz.part* \
  --title "LFS Builder v0.52.36" \
  --notes "This release is split into parts. To reconstruct:
cat lfs-builder-0.52.36.tar.gz.part* > lfs-builder-0.52.36.tar.gz"
```

---

## Environment Variables

To customize the release process, you can set:

- `SKIP_TESTS=1` – Skip test execution
- `SKIP_CLEAN=1` – Skip cleanup of artifacts

---

## References

- **Version file:** `VERSION`
- **Release script:** `make-release.sh`
- **Workflows:** `.github/workflows/release*.yml`
- **Changelog:** `CHANGELOG.md`
- **README:** `README.md`

---

## Questions?

For more details on how the build system works, see:
- `ADVANCED.md` – Internal architecture
- `README.md` – Command-line reference
- `SECURITY.md` – Security policy