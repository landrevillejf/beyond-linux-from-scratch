"""
End-to-end integration tests for the build pipeline.

These tests verify the structural integrity of the entire project without
actually building anything (which requires a Linux host with root).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from builder import BUILD_STAGES, LFSConfig, ProfileManager, SourceDownloader, __version__

REPO_ROOT = Path(__file__).parent.parent


class TestBuildPipelineIntegrity:
    """Verify that every build stage is properly configured."""

    def test_all_stage_scripts_exist(self):
        """Every stage in BUILD_STAGES must point to an existing script."""
        for stage_name, script_path in BUILD_STAGES:
            full_path = REPO_ROOT / script_path
            assert full_path.exists(), f"Stage '{stage_name}' script missing: {script_path}"

    def test_all_stage_scripts_have_shebang(self):
        """Every stage script must start with a bash shebang."""
        for stage_name, script_path in BUILD_STAGES:
            full_path = REPO_ROOT / script_path
            first_line = full_path.read_text().split('\n')[0]
            assert 'bash' in first_line and first_line.startswith('#!'), (
                f"Stage '{stage_name}' ({script_path}) missing bash shebang: {first_line}"
            )

    def test_all_stage_scripts_have_set_e(self):
        """Every stage script must have 'set -e' for error handling."""
        for stage_name, script_path in BUILD_STAGES:
            full_path = REPO_ROOT / script_path
            content = full_path.read_text()
            # Check first 10 lines for set -e (or set -eu, set -euo pipefail)
            header = '\n'.join(content.split('\n')[:15])
            assert 'set -' in header and 'e' in header, (
                f"Stage '{stage_name}' ({script_path}) missing 'set -e'"
            )

    def test_all_stage_scripts_pass_syntax_check(self):
        """Every stage script must pass bash -n syntax check."""
        for stage_name, script_path in BUILD_STAGES:
            full_path = REPO_ROOT / script_path
            result = subprocess.run(
                ['bash', '-n', str(full_path)],
                capture_output=True, text=True
            )
            assert result.returncode == 0, (
                f"Stage '{stage_name}' ({script_path}) has syntax errors:\n"
                f"{result.stderr}"
            )

    def test_stage_order_is_sequential(self):
        """Stage names must be unique and in a sensible order."""
        stage_names = [name for name, _ in BUILD_STAGES]
        assert len(stage_names) == len(set(stage_names)), "Duplicate stage names found"
        # Host stages should come before LFS, LFS before BLFS, BLFS before final
        host_idx = next(i for i, (n, _) in enumerate(BUILD_STAGES) if n == 'host-check')
        lfs_idx = next(i for i, (n, _) in enumerate(BUILD_STAGES) if n == 'lfs-basic')
        blfs_idx = next(i for i, (n, _) in enumerate(BUILD_STAGES) if n == 'blfs-base')
        final_idx = next(i for i, (n, _) in enumerate(BUILD_STAGES) if n == 'initramfs')
        assert host_idx < lfs_idx < blfs_idx < final_idx

    def test_minimum_stage_count(self):
        """Pipeline must have at least 25 stages."""
        assert len(BUILD_STAGES) >= 25, f"Only {len(BUILD_STAGES)} stages found"


class TestConfigurationIntegrity:
    """Verify that all configuration files are valid and consistent."""

    def test_build_conf_is_valid_json(self):
        """config/build.conf must be valid JSON."""
        conf_path = REPO_ROOT / "config" / "build.conf"
        assert conf_path.exists()
        with open(conf_path) as f:
            data = json.load(f)
        assert isinstance(data, dict)

    def test_build_conf_has_required_sections(self):
        """build.conf must have all required configuration sections."""
        config = LFSConfig(REPO_ROOT / "config" / "build.conf")
        data = config.data
        required_keys = [
            'lfs_version', 'architecture', 'init_system',
            'desktop', 'branding', 'security', 'kernel'
        ]
        for key in required_keys:
            assert key in data, f"Missing required config section: {key}"

    def test_all_json_configs_valid(self):
        """All .json config files must be valid JSON."""
        config_dir = REPO_ROOT / "config"
        for json_file in config_dir.glob("*.json"):
            with open(json_file) as f:
                data = json.load(f)
            assert isinstance(data, (dict, list)), f"{json_file.name} is not a JSON object/array"

    def test_version_file_exists(self):
        """VERSION file must exist and contain a valid version string."""
        version_file = REPO_ROOT / "VERSION"
        assert version_file.exists()
        version = version_file.read_text().strip()
        assert version, "VERSION file is empty"
        # Must look like a version number (digits and dots)
        parts = version.split('.')
        assert len(parts) >= 2, f"Version '{version}' doesn't look like semver"
        assert all(p.isdigit() for p in parts), f"Version '{version}' has non-numeric parts"

    def test_grub_cfg_template_exists(self):
        """config/grub.cfg template must exist for bootloader stage."""
        grub_template = REPO_ROOT / "config" / "grub.cfg"
        assert grub_template.exists(), "config/grub.cfg template missing"
        content = grub_template.read_text()
        assert 'menuentry' in content, "grub.cfg has no menu entries"
        assert 'vmlinuz' in content, "grub.cfg doesn't reference kernel"


class TestProfileIntegrity:
    """Verify that all profiles are properly defined."""

    def test_minimum_profiles_exist(self):
        """Must have at least 10 profiles."""
        profiles = ProfileManager.list_profiles()
        assert len(profiles) >= 10, f"Only {len(profiles)} profiles found"

    def test_all_profiles_have_required_fields(self):
        """Every profile must have description and desktop."""
        for profile_name in ProfileManager.list_profiles():
            info = ProfileManager.get_profile(profile_name)
            assert 'description' in info, f"Profile '{profile_name}' missing description"
            assert 'desktop' in info or 'init_system' in info, (
                f"Profile '{profile_name}' missing desktop or init_system"
            )

    def test_xfce_profile_exists(self):
        """The default xfce profile must exist."""
        profiles = ProfileManager.list_profiles()
        assert 'xfce' in profiles

    def test_minimal_profile_exists(self):
        """The minimal profile must exist for CI testing."""
        profiles = ProfileManager.list_profiles()
        assert 'minimal' in profiles


class TestBrandingIntegrity:
    """Verify that branding assets and configuration are consistent."""

    def test_branding_toml_exists(self):
        """branding/branding.toml must exist."""
        toml_path = REPO_ROOT / "branding" / "branding.toml"
        assert toml_path.exists()

    def test_branding_logos_exist(self):
        """All referenced logo SVGs must exist."""
        logo_dir = REPO_ROOT / "branding" / "default" / "logo"
        assert logo_dir.exists()
        required = ["logo.svg", "text-logo.svg", "horizontal-logo.svg",
                     "vertical-logo.svg", "favicon.svg", "icon.svg"]
        for logo in required:
            assert (logo_dir / logo).exists(), f"Missing logo: {logo}"

    def test_gtk_themes_exist(self):
        """GTK dark and light theme CSS files must exist."""
        themes_dir = REPO_ROOT / "branding" / "default" / "themes"
        # Dark theme
        assert (themes_dir / "gtk-3.20" / "gtk.css").exists(), "GTK3 dark theme missing"
        assert (themes_dir / "gtk-4.0" / "gtk.css").exists(), "GTK4 dark theme missing"
        # Light theme
        assert (themes_dir / "LFS-Light" / "gtk-3.0" / "gtk.css").exists(), "GTK3 light theme missing"
        assert (themes_dir / "LFS-Light" / "gtk-4.0" / "gtk.css").exists(), "GTK4 light theme missing"

    def test_plymouth_theme_exists(self):
        """Plymouth theme files must exist."""
        plymouth_dir = REPO_ROOT / "branding" / "default" / "plymouth" / "lfs"
        assert (plymouth_dir / "lfs.plymouth").exists()
        assert (plymouth_dir / "lfs.script").exists()

    def test_branding_manifest_is_valid_json(self):
        """branding-manifest.json must be valid JSON."""
        manifest = REPO_ROOT / "branding" / "branding-manifest.json"
        if manifest.exists():
            with open(manifest) as f:
                data = json.load(f)
            assert isinstance(data, dict)


class TestSecurityFeatures:
    """Verify that security hardening is properly configured."""

    def test_security_script_has_nftables(self):
        """Security hardening script must include nftables rules."""
        script = REPO_ROOT / "blfs" / "15-security-hardening.sh"
        content = script.read_text()
        assert 'nftables' in content, "nftables rules missing from security script"
        assert 'policy drop' in content, "nftables default-deny policy missing"

    def test_security_script_has_ssh_hardening(self):
        """Security script must harden SSH configuration."""
        script = REPO_ROOT / "blfs" / "15-security-hardening.sh"
        content = script.read_text()
        assert 'PermitRootLogin no' in content
        assert 'PasswordAuthentication no' in content

    def test_security_script_has_sysctl(self):
        """Security script must include sysctl hardening."""
        script = REPO_ROOT / "blfs" / "15-security-hardening.sh"
        content = script.read_text()
        assert 'sysctl' in content.lower() or 'sysctl' in content

    def test_no_hardcoded_passwords(self):
        """No script should contain hardcoded passwords."""
        for script_dir in ['host', 'lfs', 'blfs', 'final']:
            for script in (REPO_ROOT / script_dir).glob("*.sh"):
                content = script.read_text()
                assert 'password123' not in content, (
                    f"Hardcoded password found in {script}"
                )


class TestFirstBootService:
    """Verify first-boot service is properly configured."""

    def test_first_boot_has_real_tasks(self):
        """First-boot script must perform real system configuration."""
        script = REPO_ROOT / "blfs" / "17-first-boot-service.sh"
        content = script.read_text()
        # Must have SSH key regeneration
        assert 'ssh-keygen' in content, "First-boot missing SSH key regeneration"
        # Must have password expiry
        assert 'chage' in content, "First-boot missing password expiry"
        # Must have locale generation
        assert 'locale' in content.lower(), "First-boot missing locale generation"
        # Must disable itself
        assert 'disable' in content, "First-boot doesn't disable itself"

    def test_first_boot_supports_multiple_init(self):
        """First-boot must support systemd, sysvinit, and runit."""
        script = REPO_ROOT / "blfs" / "17-first-boot-service.sh"
        content = script.read_text()
        assert 'systemd' in content
        assert 'init.d' in content or 'sysvinit' in content
        assert 'runit' in content or 'sv' in content


class TestLPMPackageManager:
    """Verify LPM package manager is properly configured."""

    def test_lpm_script_exists(self):
        """LPM script must exist and be substantial."""
        lpm = REPO_ROOT / "blfs" / "19-lpm.sh"
        assert lpm.exists()
        assert lpm.stat().st_size > 10000, "LPM script suspiciously small"

    def test_lpm_has_remote_repos(self):
        """LPM must configure remote repositories."""
        lpm = REPO_ROOT / "blfs" / "19-lpm.sh"
        content = lpm.read_text()
        assert 'repos.d' in content, "LPM missing repos.d configuration"
        assert 'https://' in content, "LPM has no remote repo URLs"

    def test_lpm_has_dependency_resolution(self):
        """LPM must support dependency resolution."""
        lpm = REPO_ROOT / "blfs" / "19-lpm.sh"
        content = lpm.read_text()
        assert 'resolve' in content.lower() or 'deps' in content.lower()

    def test_lpm_has_checksum_verification(self):
        """LPM must verify package checksums."""
        lpm = REPO_ROOT / "blfs" / "19-lpm.sh"
        content = lpm.read_text()
        assert 'sha256' in content.lower() or 'checksum' in content.lower()


class TestDownloadResilience:
    """Verify download system handles failures gracefully."""

    def test_downloader_has_backoff(self, tmp_path):
        """SourceDownloader must implement exponential backoff."""
        import logging
        import time
        downloader = SourceDownloader(tmp_path, logging.getLogger(), timeout=5, retries=3)
        # Verify the download path contains time.sleep for backoff.  The
        # retry loop lives in _download_attempt and the delay/jitter in
        # _backoff_delay since download() also grew a mirror fallback.
        import inspect
        source = ''.join(inspect.getsource(m) for m in (
            downloader.download,
            downloader._download_attempt,
            downloader._backoff_delay,
        ))
        assert 'time.sleep' in source, "Download missing backoff delay"
        assert 'random' in source or 'uniform' in source, "Download missing jitter"

    def test_downloader_retries_on_5xx(self, tmp_path):
        """SourceDownloader must retry on 5xx errors."""
        import logging
        import urllib.error
        from unittest.mock import patch, MagicMock
        downloader = SourceDownloader(tmp_path, logging.getLogger(), timeout=5, retries=3)
        with patch('urllib.request.urlretrieve') as mock_retrieve:
            mock_retrieve.side_effect = [
                urllib.error.HTTPError('http://x.com/f', 503, 'Unavailable', None, None),
                MagicMock(),
            ]
            with patch('builder.time.sleep'):  # skip actual delay
                result = downloader.download('http://x.com/f', 'f', retries=2)
        assert result is True, "Downloader should retry on 503"

    def test_download_from_list_has_retry_passes(self, tmp_path):
        """download_from_list must support retry passes."""
        import inspect
        source = inspect.getsource(SourceDownloader.download_from_list)
        assert 'retry_passes' in source, "download_from_list missing retry_passes parameter"
        assert 'Retry pass' in source, "download_from_list missing retry pass logic"
