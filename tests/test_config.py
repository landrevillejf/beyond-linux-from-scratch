#!/usr/bin/env python3
"""
Tests for LFSConfig class
"""

import json
from pathlib import Path

from builder import LFSConfig


class TestLFSConfig:
    """Test LFSConfig class"""

    def test_init_loads_existing_config(self, mock_config_file):
        """Test loading existing configuration"""
        config = LFSConfig(mock_config_file)
        assert config.data['lfs_version'] == "13.0"
        assert config.data['architecture'] == "x86_64"

    def test_init_creates_default_config(self, temp_dir):
        """Test creating default configuration when file doesn't exist"""
        config_path = temp_dir / "nonexistent.json"
        config = LFSConfig(config_path)

        assert config.data['lfs_version'] == "13.0"
        assert config.data['blfs_version'] == "13.0"
        assert config.data['architecture'] == "x86_64"
        assert config.data['init_system']['choice'] == "sysvinit"
        assert config_path.exists()

    def test_save_configuration(self, temp_dir):
        """Test saving configuration to file"""
        config_path = temp_dir / "test_config.json"
        config = LFSConfig(config_path)
        config.set('test.key', 'test_value')
        config.save()

        with open(config_path, 'r') as f:
            saved_data = json.load(f)
        assert saved_data['test']['key'] == 'test_value'

    def test_get_nested_key(self, lfs_config):
        """Test getting nested configuration values"""
        value = lfs_config.get('init_system.choice')
        assert value == "sysvinit"

        value = lfs_config.get('nonexistent.key', 'default')
        assert value == 'default'

    def test_set_nested_key(self, lfs_config):
        """Test setting nested configuration values"""
        lfs_config.set('init_system.choice', 'systemd')
        assert lfs_config.get('init_system.choice') == 'systemd'

        lfs_config.set('new.deeply.nested.key', 'value')
        assert lfs_config.get('new.deeply.nested.key') == 'value'

    def test_default_config_structure(self, lfs_config):
        """Test default configuration has all required sections"""
        required_sections = [
            'lfs_version', 'blfs_version', 'architecture', 'target_triplet',
            'init_system', 'package_manager', 'system_updater', 'live_system',
            'java_dev', 'desktop', 'security', 'bootloader', 'filesystem',
            'kernel', 'locale', 'timezone', 'hostname', 'users', 'network',
            'build_options', 'logging'
        ]

        for section in required_sections:
            assert section in lfs_config.data

    def test_init_system_choices(self, lfs_config):
        """Test init system configuration"""
        init_system = lfs_config.get('init_system')
        assert init_system['choice'] in ['sysvinit', 'systemd', 'openrc', 'runit', 's6']
        assert init_system['service_style'] in ['lfs-classic', 'bsd-style']
        assert isinstance(init_system['parallel_startup'], bool)

    def test_build_options(self, lfs_config):
        """Test build options configuration"""
        build_opts = lfs_config.get('build_options')
        assert isinstance(build_opts['parallel_build'], bool)
        assert isinstance(build_opts['keep_build_dirs'], bool)
        assert isinstance(build_opts['strip_binaries'], bool)
        assert build_opts['download_timeout'] > 0
        assert build_opts['retry_downloads'] > 0