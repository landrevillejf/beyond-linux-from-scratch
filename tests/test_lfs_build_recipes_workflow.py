from pathlib import Path


def test_lfs_build_recipes_workflow_grants_repo_access_before_builder_runs():
    workflow = Path(".github/workflows/lfs-build-recipes.yml").read_text()

    checkout_step = "uses: actions/checkout@v4"
    chmod_home_cmd = "sudo chmod o+x /home/runner"
    chmod_repo_cmd = "sudo chmod -R o+r /home/runner/work"
    build_cmd = "sudo -u lfs python3 builder.py"

    assert checkout_step in workflow, "Checkout step not found in LFS recipes workflow"
    assert chmod_home_cmd in workflow, "Missing /home/runner permission fix for lfs user"
    assert chmod_repo_cmd in workflow, "Missing repository read permission fix for lfs user"
    assert build_cmd in workflow, "builder.py invocation not found in LFS recipes workflow"

    chmod_pos = workflow.index(chmod_home_cmd)
    chmod_repo_pos = workflow.index(chmod_repo_cmd)
    build_pos = workflow.index(build_cmd)

    assert chmod_pos < chmod_repo_pos < build_pos, (
        "Permission fixes must run before builder.py so the lfs user can read the checked-out repository"
    )
