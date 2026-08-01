from pathlib import Path


def test_release_workflow_restores_lfs_ownership_after_cache_copy():
    workflow = Path(".github/workflows/release.yml").read_text()
    copy_command = "sudo cp -v /tmp/lfs-sources/* /tmp/lfs-build/build-release/sources/ 2>/dev/null || true"
    chown_command = "sudo chown -R lfs:lfs /tmp/lfs-build/build-release"

    assert copy_command in workflow
    assert chown_command in workflow
    assert workflow.index(copy_command) < workflow.index(chown_command)
