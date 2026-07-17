import pytest
from pytest_bdd import given, when, then, parsers
import subprocess
import json
from pathlib import Path
from builder import main as builder_main

# Shared state (can use a fixture)
@pytest.fixture
def context():
    return {}

@given('a configuration file "config/build.conf" with default settings')
def config_file(tmp_path, context):
    config_path = tmp_path / "config" / "build.conf"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text('{}')  # minimal config
    context["config"] = str(config_path)
    context["output"] = str(tmp_path / "build-output")
    return config_path

@given('a temporary output directory')
def output_dir(tmp_path, context):
    context["output"] = str(tmp_path / "build-output")
    return context["output"]

@given(parsers.parse('I override the live system to {state}'))
def override_live(state, context):
    context["no_live"] = state.lower() == "disabled"

@when(parsers.parse('I run the builder with profile "{profile}" and init "{init_system}"'))
def run_builder(profile, init_system, context, capsys, monkeypatch):
    args = [
        "builder.py",
        "--profile", profile,
        "--init", init_system,
        "--output", context["output"],
        "--config", context["config"],
        "--no-live" if context.get("no_live") else ""
    ]
    # Remove empty args
    args = [a for a in args if a]

    monkeypatch.setattr("sys.argv", args)
    try:
        builder_main()
        context["exit_code"] = 0
    except SystemExit as e:
        context["exit_code"] = e.code
    # Capture output if needed
    context["out"], context["err"] = capsys.readouterr()
    # Also capture logs if needed

@when(parsers.parse('I run the builder with profile "{profile}"'))
def run_builder_default_init(profile, context, monkeypatch):
    # Default init is systemd for xfce, but we can let it use the profile's default
    # This step can call the same logic with init not specified
    args = [
        "builder.py",
        "--profile", profile,
        "--output", context["output"],
        "--config", context["config"],
        "--no-live" if context.get("no_live") else ""
    ]
    args = [a for a in args if a]
    monkeypatch.setattr("sys.argv", args)
    try:
        builder_main()
        context["exit_code"] = 0
    except SystemExit as e:
        context["exit_code"] = e.code

@then("the build should succeed")
def build_succeeded(context):
    assert context["exit_code"] == 0

@then(parsers.parse('an ISO file named "{filename}" should be created'))
def iso_exists(filename, context):
    iso_path = Path(context["output"]) / filename
    assert iso_path.exists(), f"ISO {iso_path} not found"

@then(parsers.parse('the build info file should contain the profile "{profile}"'))
def build_info_contains_profile(profile, context):
    info_path = Path(context["output"]) / "build_info.json"
    assert info_path.exists()
    data = json.loads(info_path.read_text())
    assert data["profile"] == profile

@then(parsers.parse('the logs should show "{text}"'))
def logs_contain_text(text, context):
    log_path = Path(context["output"]) / "logs" / "build.log"
    assert log_path.exists()
    content = log_path.read_text()
    assert text in content