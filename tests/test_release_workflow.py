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
