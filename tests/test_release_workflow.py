from pathlib import Path


def test_release_workflow_restores_lfs_ownership_after_cache_copy():
    workflow = Path(".github/workflows/release.yml").read_text()
    copy_command = "sudo cp -v /tmp/lfs-sources/* /tmp/lfs-build/build-release/sources/ 2>/dev/null || true"
    chown_command = "sudo chown -R lfs:lfs /tmp/lfs-build/build-release"

    assert copy_command in workflow
    assert chown_command in workflow
    assert workflow.index(copy_command) < workflow.index(chown_command)


def test_release_workflow_ensures_lfs_owns_build_dir_before_builder_runs():
    """Verify a full-tree chown is run immediately before builder.py.

    The root cause of the v0.52.14 release-job failure was a PermissionError
    when ``sudo -u lfs python3 builder.py`` tried to create its log directory
    inside ``/tmp/lfs-build/build-release/``.  Directories created by earlier
    steps with ``sudo mkdir`` are root-owned; the per-step ``chown`` scoped to
    ``build-release/`` is not sufficient when the cache is absent or a future
    step leaves root-owned content elsewhere in the tree.

    This test asserts that a defensive ``sudo chown -R lfs:lfs /tmp/lfs-build``
    (covering the whole build tree) is present in the workflow AND is ordered
    AFTER the test step but BEFORE the builder invocation.
    """
    workflow = Path(".github/workflows/release.yml").read_text()

    run_tests_cmd = "python3 -m pytest tests/"
    full_chown_cmd = "sudo chown -R lfs:lfs /tmp/lfs-build"
    build_cmd = "sudo -u lfs python3 builder.py"

    assert run_tests_cmd in workflow, "Run-tests step not found in release workflow"
    assert full_chown_cmd in workflow, (
        "Missing 'sudo chown -R lfs:lfs /tmp/lfs-build' step in release workflow"
    )
    assert build_cmd in workflow, "builder.py invocation not found in release workflow"

    # The *last* occurrence of the full-tree chown must appear after the test
    # runner step and before the builder.py invocation, ensuring lfs owns the
    # entire /tmp/lfs-build tree at the moment builder.py starts.
    last_chown_pos = workflow.rfind(full_chown_cmd)
    tests_pos = workflow.index(run_tests_cmd)
    build_pos = workflow.index(build_cmd)

    assert tests_pos < last_chown_pos, (
        "Full-tree chown must appear after the test step to guard against any "
        "root-owned content created during test collection or coverage reporting"
    )
    assert last_chown_pos < build_pos, (
        "Full-tree chown must appear before the builder.py invocation so that "
        "the lfs user can create its log directory without a PermissionError"
    )


class TestReleasePipelineHardening:
    """Guardrails for signing, compat pointers and 2 GB asset splitting."""

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def test_nightly_signing_step_is_secret_guarded(self):
        workflow = self._read("nightly.yml")
        assert "HAVE_GPG_KEY: ${{ secrets.GPG_PRIVATE_KEY != '' }}" in workflow
        assert "if: env.HAVE_GPG_KEY == 'true'" in workflow
        assert "gpg --batch --import" in workflow
        assert "--detach-sign --armor" in workflow

    def test_nightly_publishes_compat_iso_pointer(self):
        workflow = self._read("nightly.yml")
        assert "lfs-installer.iso.pointer" in workflow
        build_section = workflow.split("create-release:")[0]
        assert "iso_name=$ISO" in build_section
        assert "sha256=$SHA" in build_section

    def test_nightly_exports_split_rootfs_for_selected_profiles(self):
        workflow = self._read("nightly.yml")
        # Rootfs is only useful (and heavy) for the reference desktop and
        # the ARM target; other profiles must not pay the asset cost.
        assert "if: matrix.profile == 'xfce' || matrix.profile == 'arm64'" \
            in workflow
        assert "split -b 1900m" in workflow
        assert "rootfs-*.tar.zst.part-*" in workflow

    def test_nightly_prunes_old_releases(self):
        workflow = self._read("nightly.yml")
        create_release = workflow.split("create-release:")[1]
        assert "30 days ago" in create_release
        assert "gh release delete" in create_release

    def test_rootfs_cache_release_uses_split_parts(self):
        workflow = self._read("build-rootfs-cache.yml")
        # A single rootfs archive breaks the day it exceeds the 2 GB
        # release-asset cap; the cache must stream into split parts.
        assert "split -b 1900m" in workflow
        assert "rootfs-cache-*.tar.zst.part-*" in workflow

    def test_iso_from_cache_reassembles_all_parts(self):
        workflow = self._read("build-iso-from-cache.yml")
        # The consumer must fetch every part of the rootfs-cache-latest
        # release, not just the first asset it finds.
        assert "releases/tags/rootfs-cache-latest" in workflow
        assert "head -n1" not in workflow
        assert "part_urls<<EOF" in workflow

    def test_release_workflow_publishes_compat_iso_pointer(self):
        workflow = Path(".github/workflows/release.yml").read_text()
        # The pointer must reach both the Actions artifact and the GitHub
        # release so releases/latest/download/lfs-installer.iso.pointer
        # stays a stable machine-readable alias.
        assert workflow.count("lfs-installer.iso.pointer") >= 3
        assert "download_url=https://github.com/${{ github.repository }}" \
            "/releases/download/${GITHUB_REF_NAME}/$ISO" in workflow
