"""Guardrail and smoke tests for LPM (blfs/19-lpm.sh) and its
integration stages (blfs/14-create-base-packages.sh,
blfs/18-system-updater.sh).

The guardrails freeze the v2.7.0 improvements: build-time database
seeding with real versions, the GitHub-Releases-backed repository
pipeline, the new package-manager commands, and the updater
hardening. The smoke tests run the real script against a throwaway
sysroot, so no root privileges are needed.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

LPM_SCRIPT = Path('blfs/19-lpm.sh')
STAGE14 = Path('blfs/14-create-base-packages.sh')
UPDATER = Path('blfs/18-system-updater.sh')


def _content(path):
    return path.read_text()


class TestLPMCommands:
    """The v2.7.0 commands must be wired in the dispatcher and help."""

    COMMANDS = ['upgradable', 'reinstall', 'autoremove', 'why',
                'hold', 'unhold', 'holds', 'history']

    def test_dispatcher_wires_new_commands(self):
        content = _content(LPM_SCRIPT)
        for cmd in self.COMMANDS:
            assert f'{cmd})' in content, \
                f"Dispatcher missing command: {cmd}"

    def test_help_documents_new_commands(self):
        help_text = _content(LPM_SCRIPT).split('show_help()')[1]
        for cmd in ('upgradable', 'autoremove', 'hold', 'history', 'why'):
            assert cmd in help_text, f"Help missing command: {cmd}"

    def test_upgrade_skips_holds(self):
        content = _content(LPM_SCRIPT)
        upgrade = content.split('upgrade_all()')[1].split('\n}\n')[0]
        assert 'is_held' in upgrade, "upgrade_all must consult holds"
        assert 'Skipping held package' in upgrade

    def test_transactions_are_recorded(self):
        content = _content(LPM_SCRIPT)
        assert 'record_history "$HISTORY_ACTION"' in content
        assert 'record_history "remove"' in content
        assert 'history.log' in content

    def test_repos_d_loaded_at_runtime(self):
        content = _content(LPM_SCRIPT)
        assert 'load_repos_d()' in content
        load_config = content.split('load_config()')[1].split('\n}\n')[0]
        assert 'load_repos_d' in load_config, \
            "load_config must read /etc/lpm/repos.d"


class TestLPMRepositoryPipeline:
    """The repository manifest is published via GitHub releases."""

    def test_default_repo_points_at_github_releases(self):
        content = _content(LPM_SCRIPT)
        assert ('https://github.com/landrevillejf/'
                'beyond-linux-from-scratch/releases/latest/download'
                ) in content
        assert 'packages.linuxfromscratch.org' not in content, \
            "Fake repository URLs must be gone"

    def test_no_silent_sample_fallback(self):
        content = _content(LPM_SCRIPT)
        assert 'keeping the existing local database' in content
        assert 'falling back to sample data' not in content

    def test_stage14_exports_manifest(self):
        content = _content(STAGE14)
        assert 'lpm-repo' in content
        assert 'packages.list.sha256' in content
        assert '--detach-sign' in content

    def test_stage14_seeds_installed_registry(self):
        content = _content(STAGE14)
        assert 'INSTALLED_FILE="$LFS/var/lib/lpm/installed.list"' in content
        assert '$LFS/sources' in content, \
            "Versions must be resolved from the build's source tarballs"

    def test_release_workflows_publish_manifest(self):
        for workflow in ('.github/workflows/release.yml',
                         '.github/workflows/xfce-live-boot-iso.yml'):
            content = _content(Path(workflow))
            assert 'lpm-repo/packages.list*' in content, \
                f"{workflow} must upload the LPM repository manifest"


class TestSystemUpdater:
    """lfs-update must work on sysvinit and systemd alike."""

    def test_fetch_prefers_curl_with_wget_fallback(self):
        content = _content(UPDATER)
        assert 'fetch_url()' in content
        assert 'curl -fsSL' in content
        assert 'wget -qO-' in content

    def test_no_hardcoded_version_write(self):
        content = _content(UPDATER)
        assert 'echo "13.0" > "$VERSION_FILE"' not in content

    def test_status_is_init_system_agnostic(self):
        content = _content(UPDATER)
        assert 'systemctl' not in content

    def test_weekly_check_guarded_by_cron(self):
        content = _content(UPDATER)
        assert 'cron.weekly/lfs-update-check' in content
        assert '-d "$LFS/etc/cron.weekly"' in content


class TestLPMSysrootSmoke:
    """Run the real script against a throwaway sysroot (no root)."""

    @pytest.fixture()
    def sysroot(self, tmp_path):
        root = tmp_path / 'root'
        db = root / 'var/lib/lpm'
        db.mkdir(parents=True)
        (db / 'packages.list').write_text(
            'demo|1.1|Demo package||checksum\n')
        (db / 'installed.list').write_text('demo 1.0\n')
        for name in ('file_index', 'kernel_deps.list', 'holds.list',
                     'history.log'):
            (db / name).touch()
        return root

    def _lpm(self, sysroot, *args):
        if shutil.which('bash') is None:
            pytest.skip('bash not available')
        # BUILD_JOBS avoids the nproc probe (not portable to macOS hosts).
        return subprocess.run(
            ['bash', str(LPM_SCRIPT), '--sysroot', str(sysroot),
             '--no-color', *args],
            capture_output=True, text=True, timeout=60,
            env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                 'BUILD_JOBS': '1', 'HOME': '/tmp'})

    def test_version_is_270(self, sysroot):
        result = self._lpm(sysroot, 'version')
        assert result.returncode == 0, result.stderr
        assert 'LPM version 2.7.0' in result.stdout

    def test_upgradable_lists_demo(self, sysroot):
        result = self._lpm(sysroot, 'upgradable')
        assert result.returncode == 0, result.stderr
        combined = result.stdout + result.stderr
        assert 'demo' in combined
        assert '->' in combined

    def test_hold_blocks_upgrade_and_is_recorded(self, sysroot):
        assert self._lpm(sysroot, 'hold', 'demo').returncode == 0
        result = self._lpm(sysroot, 'upgrade', '--dry-run')
        assert result.returncode == 0, result.stderr
        assert 'Skipping held package' in result.stderr
        history = (sysroot / 'var/lib/lpm/history.log').read_text()
        assert '|hold|demo|' in history

    def test_why_reports_no_dependents(self, sysroot):
        result = self._lpm(sysroot, 'why', 'demo')
        assert result.returncode == 0, result.stderr
        assert 'No known dependents' in result.stdout
