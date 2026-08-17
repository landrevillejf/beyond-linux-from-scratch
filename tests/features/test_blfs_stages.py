"""BDD test runner for blfs_stages.feature – covers new BLFS stages,
desktop dispatcher, and init system dispatching."""

import json
import sys
from pathlib import Path

from pytest_bdd import given, scenarios, then, when, parsers

import builder


scenarios('blfs_stages.feature')


# ── Shared fixtures ────────────────────────────────────────────────────────

@given('a configuration file "config/build.conf" with default settings', target_fixture='build_context')
def build_context(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / 'config').mkdir(exist_ok=True)
    (tmp_path / 'packages').mkdir(exist_ok=True)
    (tmp_path / 'output').mkdir(exist_ok=True)

    config_file = tmp_path / 'config' / 'build.conf'
    config_file.write_text(json.dumps({
        "repositories": [],
        "live_system": {"enabled": True},
        "init_system": {"choice": "sysvinit"},
        "kernel": {"type": "linux"},
        "bootloader": {"type": "grub"},
    }))

    return {
        "root": tmp_path,
        "config": config_file,
        "output": tmp_path / 'output',
        "argv": ['builder.py'],
        "succeeded": False,
    }


@given('a temporary output directory')
def temporary_output_directory(build_context):
    build_context["output"].mkdir(exist_ok=True)


# ── When steps ────────────────────────────────────────────────────────────

def _run_main_with_mocks(monkeypatch, build_context):
    output_dir = build_context["output"]
    argv = list(build_context["argv"])
    profile = "xfce"

    if '--profile' in argv:
        profile = argv[argv.index('--profile') + 1]

    log_messages = []

    def fake_prepare(self):
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / 'sources').mkdir(exist_ok=True)
        (output_dir / 'logs').mkdir(exist_ok=True)
        (output_dir / 'image').mkdir(exist_ok=True)
        (output_dir / 'build_info.json').write_text(json.dumps({
            "profile": profile,
            "init_system": self.get_init_system(),
        }))
        return True

    def fake_build(self, **_kwargs):
        (output_dir / 'lfs-installer.iso').write_text('fake iso')
        build_context["stages"] = self.get_build_stages()
        build_context["env"] = self._get_env()
        return True

    class FakeLogger:
        def info(self, message):
            log_messages.append(str(message))

        def warning(self, message):
            log_messages.append(str(message))

        def error(self, message):
            log_messages.append(str(message))

        def setLevel(self, _level):
            return None

    monkeypatch.setattr(builder.LFSBuilder, 'setup_logging', lambda self: FakeLogger())
    monkeypatch.setattr(builder.LFSBuilder, 'check_prerequisites', lambda self: True)
    monkeypatch.setattr(builder.LFSBuilder, 'prepare_environment', fake_prepare)
    monkeypatch.setattr(builder.LFSBuilder, 'download_sources', lambda self: True)
    monkeypatch.setattr(builder.LFSBuilder, 'build', fake_build)

    monkeypatch.setattr(sys, 'argv', argv)
    builder.main()
    build_context["succeeded"] = True
    build_context["log_messages"] = log_messages


@when(parsers.parse('I run the builder with profile "{profile}" and init "{init_system}"'))
def run_builder_with_init(monkeypatch, build_context, profile, init_system):
    build_context["argv"].extend([
        '--profile', profile,
        '--init', init_system,
        '--output', str(build_context["output"]),
        '--config', str(build_context["config"]),
    ])
    _run_main_with_mocks(monkeypatch, build_context)


@when(parsers.parse('I run the builder with profile "{profile}"'))
def run_builder_profile_only(monkeypatch, build_context, profile):
    build_context["argv"].extend([
        '--profile', profile,
        '--output', str(build_context["output"]),
        '--config', str(build_context["config"]),
    ])
    _run_main_with_mocks(monkeypatch, build_context)


# ── Then steps ─────────────────────────────────────────────────────────────

@then('the build should succeed')
def build_should_succeed(build_context):
    assert build_context["succeeded"] is True


@then(parsers.parse('the build stages should include "{stage_name}"'))
def stages_should_include(build_context, stage_name):
    stages = build_context.get("stages", [])
    stage_ids = [s[0] for s in stages]
    assert stage_name in stage_ids, (
        f"Stage '{stage_name}' not found in build stages: {stage_ids}"
    )


@then(parsers.parse('the build stages should not include "{stage_name}"'))
def stages_should_not_include(build_context, stage_name):
    stages = build_context.get("stages", [])
    stage_ids = [s[0] for s in stages]
    assert stage_name not in stage_ids, (
        f"Stage '{stage_name}' should not be in build stages: {stage_ids}"
    )


@then(parsers.parse('the environment variable "{var_name}" should be "{expected_value}"'))
def env_var_should_be(build_context, var_name, expected_value):
    env = build_context.get("env", {})
    assert var_name in env, f"Environment variable {var_name} not found in env"
    assert env[var_name] == expected_value, (
        f"Expected {var_name}={expected_value}, got {env[var_name]}"
    )
