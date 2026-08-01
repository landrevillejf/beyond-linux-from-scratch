import json
import sys
from pathlib import Path

from pytest_bdd import given, scenarios, then, when

import builder


scenarios('build.feature')


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
        "bootloader": {"type": "grub"}
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


@given('I override the live system to disabled')
def override_live_system(build_context):
    build_context["argv"].append('--no-live')


def _run_main_with_mocks(monkeypatch, build_context):
    output_dir = build_context["output"]
    profile = "xfce"
    argv = list(build_context["argv"])
    log_messages = []

    if '--profile' in argv:
        profile = argv[argv.index('--profile') + 1]

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


@when('I run the builder with profile "minimal" and init "sysvinit"')
def run_builder_profile_init(monkeypatch, build_context):
    build_context["argv"].extend([
        '--profile', 'minimal',
        '--init', 'sysvinit',
        '--output', str(build_context["output"]),
        '--config', str(build_context["config"]),
    ])
    _run_main_with_mocks(monkeypatch, build_context)


@when('I run the builder with profile "server"')
def run_builder_profile_server(monkeypatch, build_context):
    build_context["argv"].extend([
        '--profile', 'server',
        '--output', str(build_context["output"]),
        '--config', str(build_context["config"]),
    ])
    _run_main_with_mocks(monkeypatch, build_context)


@then('the build should succeed')
def build_should_succeed(build_context):
    assert build_context["succeeded"] is True


@then('an ISO file named "lfs-installer.iso" should be created')
def iso_named_should_exist(build_context):
    assert (build_context["output"] / 'lfs-installer.iso').exists()


@then('the ISO file should exist')
def iso_should_exist(build_context):
    assert (build_context["output"] / 'lfs-installer.iso').exists()


@then('the build info file should contain the profile "minimal"')
def build_info_should_contain_profile(build_context):
    build_info = json.loads((build_context["output"] / 'build_info.json').read_text())
    assert build_info["profile"] == "minimal"


@then('the logs should show "Live system disabled"')
def logs_should_show_live_disabled(build_context):
    assert any("Live system disabled" in msg for msg in build_context.get("log_messages", []))
