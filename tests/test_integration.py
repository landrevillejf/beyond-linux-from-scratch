#!/usr/bin/env python3
"""
Integration tests for complete workflow
"""

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

from builder import LFSBuilder, ProfileManager


class TestIntegration:
    """Integration tests"""

    def test_full_profile_workflow(self, temp_dir, mock_config_file):
        """Test complete workflow with full profile"""
        output_dir = temp_dir / "lfs-full"

        builder = LFSBuilder(
            profile="full",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Check profile configuration
        assert builder.profile_config['desktop'] == 'gnome'
        assert builder.profile_config['java_dev'] is True
        assert builder.profile_config['security_hardening'] is True

        # Test environment preparation
        result = builder.prepare_environment()
        assert result is True

        # Test build stages
        stages = builder.get_build_stages()
        stage_names = [s[0] for s in stages]

        # Full profile should have all stages
        assert 'java-dev' in stage_names
        assert 'security' in stage_names
        assert 'privacy' in stage_names
        assert 'package-manager' in stage_names
        assert 'live-system' in stage_names

    def test_audio_cli_workflow(self, temp_dir, mock_config_file):
        """Test workflow with audio CLI profile"""
        output_dir = temp_dir / "lfs-audio-cli"

        builder = LFSBuilder(
            profile="audio-cli",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Check profile configuration
        assert builder.profile_config['desktop'] is None
        assert builder.profile_config['init_system'] == 'sysvinit'
        assert builder.profile_config['live_system'] is False

        # Test build stages
        stages = builder.get_build_stages()
        stage_names = [s[0] for s in stages]

        # Audio CLI should not have desktop stages
        assert 'desktop' not in stage_names
        assert 'configure-desktop' not in stage_names

    def test_audio_studio_workflow(self, temp_dir, mock_config_file):
        """Test workflow with audio studio profile"""
        output_dir = temp_dir / "lfs-audio-studio"

        builder = LFSBuilder(
            profile="audio-studio",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Check profile configuration
        assert builder.profile_config['desktop'] == 'xfce'
        assert builder.profile_config['init_system'] == 'systemd'
        assert builder.profile_config['live_system'] is True

    def test_arm64_workflow(self, temp_dir, mock_config_file):
        """Test workflow with ARM64 profile"""
        output_dir = temp_dir / "lfs-arm64"

        builder = LFSBuilder(
            profile="arm64",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Check cross-compilation settings
        assert builder.is_cross_compile() is True
        assert builder.get_target_architecture() == 'aarch64'

        # Check bootloader
        assert builder.config.get('bootloader.type') == 'uboot'

    def test_init_system_override(self, temp_dir, mock_config_file):
        """Test overriding init system via command line"""
        output_dir = temp_dir / "lfs-init-test"

        builder = LFSBuilder(
            profile="xfce",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Override init system
        builder.config.set('init_system.choice', 'sysvinit')
        assert builder.get_init_system() == 'sysvinit'

        # Check environment variable
        env = builder._get_env()
        assert env['INIT_SYSTEM'] == 'sysvinit'

    # tests/test_integration.py - corrigé
    def test_live_system_disable(self, temp_dir, mock_config_file):
        """Test disabling live system"""
        output_dir = temp_dir / "lfs-no-live"

        builder = LFSBuilder(
            profile="xfce",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        # Désactiver le live system
        builder.config.set('live_system.enabled', False)

        # Forcer la mise à jour du profile_config
        builder.profile_config['live_system'] = False

        stages = builder.get_build_stages()
        stage_names = [s[0] for s in stages]

        # Le stage live-system ne devrait PAS être présent
        assert 'live-system' not in stage_names

    def test_cross_compile_environment(self, temp_dir, mock_config_file):
        """Test cross-compilation environment variables"""
        output_dir = temp_dir / "lfs-cross"

        builder = LFSBuilder(
            profile="arm64",
            output_dir=output_dir,
            config_file=mock_config_file
        )

        env = builder._get_env()

        assert env['CROSS_COMPILE'] == '/usr/bin/aarch64-linux-gnu-'
        assert env['ARCH'] == 'aarch64'
        assert 'CROSS_PREFIX' in env
        assert env['CROSS_PREFIX'] == '/usr/bin/aarch64-linux-gnu-'
        assert 'QEMU_USER' in env
        assert 'SYSROOT' in env

    def test_all_profiles_have_required_fields(self):
        """Test that all profiles have required fields"""
        required_fields = ['description', 'size_gb', 'build_time_hours',
                           'packages', 'desktop', 'init_system', 'java_dev',
                           'package_manager', 'security_hardening',
                           'privacy_tools', 'live_system', 'system_updater']

        for profile_name in ProfileManager.list_profiles():
            profile = ProfileManager.get_profile(profile_name)
            for field in required_fields:
                assert field in profile, f"Profile {profile_name} missing {field}"

    def test_config_validation(self, temp_dir):
        """Test configuration validation"""
        from builder import LFSConfig

        config = LFSConfig(temp_dir / "test.json")

        # Test all required sections exist
        assert 'init_system' in config.data
        assert 'choice' in config.data['init_system']
        assert config.data['init_system']['choice'] in ['sysvinit', 'systemd', 'openrc', 'runit', 's6']

        # Test build options
        assert 'build_options' in config.data
        assert 'download_timeout' in config.data['build_options']
        assert 'retry_downloads' in config.data['build_options']