import json
import logging
import os
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest
from builder import LFSBuilder, main


@pytest.fixture
def builder():
    output_dir = Path(tempfile.mkdtemp())
    config_file = Path("config/build.conf")
    config_file.parent.mkdir(parents=True, exist_ok=True)
    if not config_file.exists():
        with open(config_file, 'w') as f:
            json.dump({
                "lfs_version": "13.0",
                "blfs_version": "13.0",
                "architecture": "x86_64"
            }, f)
    b = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
    return b


@pytest.fixture
def executor(builder):
    return builder.executor


@pytest.fixture
def downloader(builder):
    sources_dir = builder.downloader.sources_dir
    sources_dir.mkdir(parents=True, exist_ok=True)
    return builder.downloader


@pytest.fixture
def stages():
    return [
        ('host-check', 'host/01-check-host.sh'),
        ('host-prepare', 'host/02-prepare-host.sh')
    ]


class TestCheckPrerequisites:

    # --- Helper pour les mocks de base Linux (toutes commandes présentes, espace disque OK, pas Docker) ---
    @staticmethod
    def _base_linux_patches(builder):
        return [
            patch.object(builder, 'detect_host_distro', return_value='fedora'),
            patch.object(builder, 'ensure_lfs_user', return_value=True),
            patch('shutil.which', return_value=True),
            patch('shutil.disk_usage', return_value=MagicMock(free=100*1024**3)),
            patch('os.path.exists', return_value=False),   # pas docker
        ]

    def _context_for(self, patches):
        import contextlib
        stack = contextlib.ExitStack()
        for p in patches:
            stack.enter_context(p)
        return stack

    # --- Détection de la distribution (via mock de detect_host_distro) ---
    @pytest.mark.parametrize("distro", ['fedora', 'debian', 'arch', 'unknown'])
    def test_host_distro_logging(self, builder, distro):
        builder.system = 'Linux'
        builder.logger = MagicMock()
        patches = self._base_linux_patches(builder)
        patches.append(patch.object(builder, 'detect_host_distro', return_value=distro))
        with self._context_for(patches):
            builder.check_prerequisites()
            builder.logger.info.assert_any_call(f"Detected host distribution: {distro}")

    # --- Utilisateur lfs manquant ---
    def test_lfs_user_missing(self, builder):
        builder.system = 'Linux'
        builder.logger = MagicMock()
        patches = self._base_linux_patches(builder)
        patches.append(patch.object(builder, 'ensure_lfs_user', return_value=False))
        with self._context_for(patches):
            assert builder.check_prerequisites() is False

    # --- Utilisateur lfs OK ---
    def test_lfs_user_ok(self, builder):
        builder.system = 'Linux'
        patches = self._base_linux_patches(builder)
        patches.append(patch.object(builder, 'ensure_lfs_user', return_value=True))
        with self._context_for(patches):
            assert builder.check_prerequisites() is True

    # --- Cross-compilation + messages par distribution ---
    @pytest.mark.parametrize("distro, expected_msg", [
        ('fedora', "Install with: sudo dnf install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"),
        ('debian', "Install with: sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"),
        ('arch', "Install with: sudo pacman -S aarch64-linux-gnu-gcc"),
        ('unknown', "Please install the cross-compiler for aarch64 manually."),
    ])
    def test_cross_compile_missing_compiler_with_distro(self, builder, distro, expected_msg):
        builder.system = 'Linux'
        builder.logger = MagicMock()
        patches = self._base_linux_patches(builder)
        patches.append(patch.object(builder, 'detect_host_distro', return_value=distro))
        patches.append(patch.object(builder, 'is_cross_compile', return_value=True))
        patches.append(patch.object(builder, 'get_target_architecture', return_value='aarch64'))
        patches.append(patch('shutil.which', return_value=None))  # cross-compiler absent
        with self._context_for(patches):
            builder.check_prerequisites()
            builder.logger.warning.assert_called_with("Cross-compiler not found: aarch64-linux-gnu-gcc")
            builder.logger.info.assert_any_call(expected_msg)

    # --- Commandes manquantes avec aide par distribution ---
    @pytest.mark.parametrize("distro, missing_cmd, expected_help", [
        ('fedora', 'gcc', "Install missing packages: sudo dnf install build-essential bison flex gawk texinfo wget xorriso parted"),
        ('debian', 'make', "Install missing packages: sudo apt install build-essential bison flex gawk texinfo wget xorriso parted"),
        ('arch', 'bison', "Install missing packages: sudo pacman -S base-devel bison flex gawk texinfo wget xorriso parted"),
        ('unknown', 'wget', "Please install the required build tools manually."),
    ])
    def test_missing_commands_distro_help(self, builder, distro, missing_cmd, expected_help):
        builder.system = 'Linux'
        builder.logger = MagicMock()

        def which_side(cmd):
            return cmd != missing_cmd

        patches = self._base_linux_patches(builder)
        patches.append(patch.object(builder, 'detect_host_distro', return_value=distro))
        patches.append(patch('shutil.which', side_effect=which_side))
        with self._context_for(patches):
            result = builder.check_prerequisites()
            assert result is False
            builder.logger.error.assert_called_with(f"Missing commands: {missing_cmd}")
            builder.logger.info.assert_any_call(expected_help)

    # --- OS non supporté ---
    def test_unsupported_os(self, builder):
        builder.system = 'Unknown'
        assert builder.check_prerequisites() is False

    # --- Windows ---
    def test_windows_os(self, builder):
        builder.system = 'Windows'
        with patch('shutil.which', return_value=True), \
                patch('shutil.disk_usage', return_value=MagicMock(free=100*1024**3)):
            assert builder.check_prerequisites() is True

    # --- macOS non Docker ---
    def test_macos_non_docker(self, builder):
        builder.system = 'Darwin'
        with patch('os.path.exists', return_value=False), \
                patch('shutil.which', return_value=True), \
                patch('shutil.disk_usage', return_value=MagicMock(free=100*1024**3)):
            assert builder.check_prerequisites() is True

    # --- Espace disque faible ---
    def test_low_disk_space(self, builder, caplog):
        builder.system = 'Linux'
        patches = self._base_linux_patches(builder)
        patches.append(patch('shutil.disk_usage', return_value=MagicMock(free=10*1024**3)))
        with self._context_for(patches):
            with caplog.at_level(logging.WARNING):
                result = builder.check_prerequisites()
            assert result is True
            assert "Low disk space" in caplog.text

    # --- Autres tests (inchangés) ---
    def test_build_resume_from(self, builder):
        with patch.object(builder.executor, 'resume_from', return_value=True) as mock_resume:
            builder.build(resume_from='host-check')
            mock_resume.assert_called_once_with('host-check', builder.get_build_stages())

    def test_build_stage_failure(self, builder):
        with patch.object(builder.executor, 'run_script', return_value=False):
            with patch.object(builder, 'get_build_stages', return_value=[('stage1', 'script.sh')]):
                assert builder.build() is False

    def test_find_script_not_found(self, executor):
        assert executor.find_script('nonexistent.sh') is None

    def test_resume_from_valid_stage(self, executor, stages):
        with patch.object(executor, 'run_script', return_value=True) as mock_run:
            executor.resume_from('host-check', stages)
            mock_run.assert_called()

    def test_download_sources_file_not_found(self, builder):
        with patch('pathlib.Path.exists', return_value=False):
            assert builder.download_sources() is False

    def test_create_writable_media_no_iso(self, builder):
        with patch('pathlib.Path.exists', return_value=False):
            assert builder.create_writable_media() is False

    def test_download_all_retries_fail(self, downloader):
        with patch('urllib.request.urlretrieve', side_effect=Exception('Network error')):
            result = downloader.download('http://example.com/file', 'file')
            assert result is False

    def test_run_script_exception(self, executor):
        with patch('subprocess.run', side_effect=ValueError('Something went wrong')):
            with patch('pathlib.Path.exists', return_value=True):
                with patch('pathlib.Path.chmod'):
                    result = executor.run_script('script.sh', 'stage')
                    assert result is False

    def test_main_help(self, capsys):
        with pytest.raises(SystemExit) as exc:
            with patch('sys.argv', ['builder.py', '--help']):
                main()
        assert exc.value.code == 0

    def test_download_retry_success_after_failure(self, downloader):
        def fake_retrieve(url, dest, *args, **kwargs):
            if not hasattr(fake_retrieve, 'attempt'):
                fake_retrieve.attempt = 0
            fake_retrieve.attempt += 1
            if fake_retrieve.attempt == 1:
                raise Exception('Network error')
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('dummy')
            return (str(dest), None)
        with patch('urllib.request.urlretrieve', side_effect=fake_retrieve):
            result = downloader.download('http://example.com/file', 'file')
            assert result is True

    def test_find_script_with_scripts_prefix(self, executor, tmp_path):
        original_cwd = os.getcwd()
        os.chdir(tmp_path)
        try:
            scripts_dir = tmp_path / 'scripts'
            scripts_dir.mkdir()
            (scripts_dir / 'test.sh').touch()
            result = executor.find_script('test.sh')
            assert result == Path('scripts/test.sh')
        finally:
            os.chdir(original_cwd)


# --- Tests unitaires des méthodes detect_host_distro et ensure_lfs_user ---

class TestDetectHostDistro:
    @pytest.mark.parametrize("content,expected", [
        ("ID=fedora\n", "fedora"),
        ("ID=debian\n", "debian"),
        ("ID=ubuntu\n", "debian"),
        ("ID=arch\n", "arch"),
        ("ID=opensuse\n", "unknown"),
        ("", "unknown"),
    ])
    def test_detect_host_distro(self, builder, content, expected):
        with patch.object(Path, 'exists', return_value=True), \
                patch.object(Path, 'read_text', return_value=content):
            assert builder.detect_host_distro() == expected

    def test_os_release_not_found(self, builder):
        with patch.object(Path, 'exists', return_value=False):
            assert builder.detect_host_distro() == "unknown"

    def test_detect_host_distro_with_override(self, builder):
        builder.config.set('host.distro_override', 'fedora')
        with patch.object(Path, 'exists', return_value=False):
            assert builder.detect_host_distro() == "fedora"


class TestEnsureLFSUser:
    def test_user_exists_bashrc_ok(self, builder):
        with patch('pwd.getpwnam', return_value=True), \
                patch.object(Path, 'exists', return_value=True):
            assert builder.ensure_lfs_user() is True

    def test_user_exists_no_bashrc_root_creates(self, builder):
        builder.logger = MagicMock()
        with patch('pwd.getpwnam', return_value=True), \
                patch.object(Path, 'exists', return_value=False), \
                patch('os.geteuid', return_value=0), \
                patch.object(Path, 'touch'), \
                patch('shutil.chown') as mock_chown:
            assert builder.ensure_lfs_user() is True
            mock_chown.assert_called_once()

    def test_user_exists_no_bashrc_non_root_returns_false(self, builder):
        builder.logger = MagicMock()
        with patch('pwd.getpwnam', return_value=True), \
                patch.object(Path, 'exists', return_value=False), \
                patch('os.geteuid', return_value=1000):
            assert builder.ensure_lfs_user() is False
            builder.logger.error.assert_called_once()

    def test_user_missing_root_creates(self, builder):
        builder.logger = MagicMock()
        with patch('pwd.getpwnam', side_effect=KeyError), \
                patch('os.geteuid', return_value=0), \
                patch('subprocess.run') as mock_run, \
                patch.object(Path, 'touch'), \
                patch('shutil.chown'):
            assert builder.ensure_lfs_user() is True
            mock_run.assert_called_once_with(['useradd', '-m', '-s', '/bin/bash', 'lfs'], check=True)

    def test_user_missing_non_root_returns_false(self, builder):
        builder.logger = MagicMock()
        with patch('pwd.getpwnam', side_effect=KeyError), \
                patch('os.geteuid', return_value=1000):
            assert builder.ensure_lfs_user() is False
            builder.logger.error.assert_called_once()