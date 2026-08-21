"""Guardrail and smoke tests for LPM (blfs/19-lpm.sh) and its
integration stages (blfs/14-create-base-packages.sh,
blfs/18-system-updater.sh).

The guardrails freeze the v2.7.0 improvements: build-time database
seeding with real versions, the GitHub-Releases-backed repository
pipeline, the new package-manager commands, and the updater
hardening. The smoke tests run the real script against a throwaway
sysroot, so no root privileges are needed.
"""

import io
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

LPM_SCRIPT = Path('blfs/19-lpm.sh')
STAGE14 = Path('blfs/14-create-base-packages.sh')
UPDATER = Path('blfs/18-system-updater.sh')
LPM_CONF = Path('config/lpm.conf')
LFS_SYSTEM = Path('lfs/05b-build-lfs-system.sh')


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


class TestLPMConfigContract:
    """config/lpm.conf is sourced by lpm; stale keys break the DB.

    The historical config set LPM_DB to a FILE path (db.json) while the
    engine treats LPM_DB as a directory, which relocated every database
    into /var/lib/lpm/db.json/ and hid the build-time seeded registry.
    """

    def test_lpm_db_is_a_directory(self):
        content = _content(LPM_CONF)
        assert 'db.json' not in content, \
            "LPM_DB must be a directory, not a file path"
        assert 'LPM_DB=/var/lib/lpm' in content

    def test_config_only_ships_consumed_keys(self):
        content = _content(LPM_CONF)
        for dead_key in ('REPO_MIRRORS', 'DEFAULT_REPO', 'GPG_VERIFY',
                         'DOWNLOAD_RETRIES', 'MAX_DEPTH', 'USE_COLORS',
                         'REQUIRE_ROOT', 'USE_SANDBOX'):
            assert dead_key not in content, \
                f"Dead config key still shipped: {dead_key}"
        # JOBS= is dead (BUILD_JOBS= is the consumed one): match only
        # at the start of a line so BUILD_JOBS stays legal.
        assert '\nJOBS=' not in content, "Dead config key: JOBS"
        assert 'REPO_REMOTE_URLS=()' in content

    def test_stage14_config_matches_engine(self):
        content = _content(STAGE14)
        # USE_COLOR runs as a shell command: it must be true/false,
        # never 1 (which silently disables colors).
        assert 'USE_COLOR=true' in content
        assert 'JOBS=0' not in content, "JOBS is not consumed by lpm"


class TestLPMBinaryRepo:
    """The base set is published as real binary packages.

    05b captures per-package file lists during the build; stage 14
    turns them into {name}-{version}.tar.xz archives whose sha256
    lands in the repository manifest, and the stable release
    pipelines upload the tarballs next to packages.list.
    """

    def test_05b_captures_package_manifests(self):
        content = _content(LFS_SYSTEM)
        assert 'LPM_MANIFEST_DIR=/var/lib/lpm/manifests' in content
        assert 'snapshot_tree()' in content
        assert '"$LPM_MANIFEST_DIR/$pkg.list"' in content
        # The diff must run before diffutils exists: awk, not comm.
        loop = content.split('for pkg in $CH8_PACKAGES')[1]
        assert 'comm ' not in loop.split('done')[0]

    def test_stage14_builds_binary_packages(self):
        content = _content(STAGE14)
        assert 'package_from_manifest()' in content
        assert 'MANIFEST_DIR="$LFS/var/lib/lpm/manifests"' in content
        # lpm install layout: {name}-{version}/files/ prefix.
        assert '--transform "s|^|$name-$version/files/|"' in content
        # Real checksums come from the tarball itself.
        assert 'checksum=$(sha256_stdin < "$tarball")' in content

    def test_stable_workflows_upload_binary_packages(self):
        for workflow in ('.github/workflows/release.yml',
                         '.github/workflows/xfce-live-boot-iso.yml'):
            content = _content(Path(workflow))
            assert 'lpm-repo/*.tar.xz' in content, \
                f"{workflow} must upload the base binary packages"

    def test_nightly_stays_metadata_only(self):
        content = _content(Path('.github/workflows/nightly.yml'))
        assert 'lpm-repo/*.tar.xz' not in content, \
            "matrix jobs would collide on identical asset names"

    def test_stage14_creates_real_package(self, tmp_path):
        """End-to-end: manifest -> tarball -> sha256 in the DB."""
        if shutil.which('bash') is None:
            pytest.skip('bash not available')
        # package_from_manifest needs GNU tar (--transform,
        # --verbatim-files-from); real builds run on Linux runners.
        tar_version = subprocess.run(['tar', '--version'],
                                     capture_output=True, text=True)
        if 'GNU tar' not in tar_version.stdout:
            pytest.skip('GNU tar required (bsdtar lacks --transform)')
        root = tmp_path / 'fake-root'
        (root / 'usr/bin').mkdir(parents=True)
        (root / 'usr/lib').mkdir(parents=True)
        (root / 'usr/bin/demo').write_text('#!/bin/sh\necho demo\n')
        (root / 'usr/lib/libdemo.so').write_text('fake-lib')
        (root / 'usr/lib/broken').symlink_to('libdemo.so')
        # Stage 14 only packages entries of the curated BASE_PACKAGES
        # set, so the fake manifest must ride on a real member (glibc).
        (root / 'var/lib/lpm/manifests').mkdir(parents=True)
        (root / 'var/lib/lpm/manifests/glibc.list').write_text(
            '/usr/bin/demo\n'
            '/usr/lib/libdemo.so\n'
            '/usr/lib/broken\n'
            '/usr/lib/gone-after-strip\n')
        # Version hint resolved the same way as a real build.
        (root / 'sources').mkdir()
        (root / 'sources/glibc-2.42.tar.xz').touch()

        bin_dir = tmp_path / 'bin'
        bin_dir.mkdir()
        # Identity sudo shim: the smoke test already owns the tree.
        shim = bin_dir / 'sudo'
        shim.write_text('#!/bin/sh\nexec "$@"\n')
        shim.chmod(0o755)

        env = {'PATH': f'{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin',
               'LFS': str(root), 'HOME': '/tmp'}
        result = subprocess.run(['bash', str(STAGE14)],
                                capture_output=True, text=True,
                                timeout=300, env=env)
        assert result.returncode == 0, result.stderr

        repo = tmp_path / 'lpm-repo'
        tarball = repo / 'glibc-2.42.tar.xz'
        assert tarball.exists(), 'binary package must be created'
        assert tarball.stat().st_size > 0

        db = (repo / 'packages.list').read_text()
        entry = next(l for l in db.splitlines() if l.startswith('glibc|'))
        checksum = entry.split('|')[4]
        assert len(checksum) == 64 and checksum != 'sha256-dummy', \
            'manifest must carry the real tarball sha256'


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
                         '.github/workflows/xfce-live-boot-iso.yml',
                         '.github/workflows/nightly.yml'):
            content = _content(Path(workflow))
            assert 'lpm-repo/packages.list*' in content, \
                f"{workflow} must upload the LPM repository manifest"

    def test_nightly_release_is_a_prerelease(self):
        # GitHub's "latest" pointer skips prereleases, so nightly
        # releases must not shadow the stable repo manifest fetched
        # by lpm update-db via releases/latest/download.
        content = _content(Path('.github/workflows/nightly.yml'))
        create_release = content.split('create-release:')[1]
        assert 'prerelease: true' in create_release

    def test_nightly_release_has_dated_tag(self):
        # Without an explicit tag, softprops would tag the release with
        # the branch name and every nightly would overwrite the same
        # release. Each nightly must get its own dated tag and title.
        content = _content(Path('.github/workflows/nightly.yml'))
        create_release = content.split('create-release:')[1]
        assert 'tag_name: nightly-' in create_release
        assert 'name: Nightly Build' in create_release
        assert 'make_latest: false' in create_release

    def test_nightly_build_uses_dated_iso_naming(self):
        # The workflow verifies/uploads a date-suffixed ISO name, so the
        # build itself must run with --nightly (dated ISO naming) or the
        # verify step would reference a file that never exists.
        content = _content(Path('.github/workflows/nightly.yml'))
        build_section = content.split('create-release:')[0]
        assert '--nightly' in build_section


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

    def _make_package(self, sysroot, name, version):
        """Build a minimal installable archive in the local repo."""
        pkg_dir = sysroot / 'usr/share/lpm/packages'
        pkg_dir.mkdir(parents=True, exist_ok=True)
        archive = pkg_dir / f'{name}-{version}.tar.xz'
        data = b'#!/bin/sh\necho hello\n'
        info = tarfile.TarInfo(f'{name}-{version}/files/usr/bin/hello')
        info.size = len(data)
        info.mode = 0o755
        with tarfile.open(archive, 'w:xz') as tf:
            tf.addfile(info, io.BytesIO(data))
        return archive

    def test_placeholder_checksum_is_not_compared(self, sysroot):
        """base-<hash> and sha256-dummy entries are placeholders: they
        must skip verification, never fail it (stage 14 seeds them)."""
        db = sysroot / 'var/lib/lpm/packages.list'
        db.write_text(db.read_text() +
                      'basepkg|1.0|Base package||base-abcdef1234567890\n')
        self._make_package(sysroot, 'basepkg', '1.0')
        result = self._lpm(sysroot, 'install', 'basepkg')
        assert result.returncode == 0, result.stderr
        assert 'Checksum mismatch' not in result.stderr
        assert (sysroot / 'usr/bin/hello').exists()

    def test_real_checksum_mismatch_still_rejected(self, sysroot):
        """A real 64-hex sha256 that does not match must still die."""
        db = sysroot / 'var/lib/lpm/packages.list'
        db.write_text(db.read_text() +
                      'badpkg|1.0|Bad package||' + '0' * 64 + '\n')
        self._make_package(sysroot, 'badpkg', '1.0')
        result = self._lpm(sysroot, 'install', 'badpkg')
        assert result.returncode != 0
        assert 'Checksum mismatch' in result.stderr
