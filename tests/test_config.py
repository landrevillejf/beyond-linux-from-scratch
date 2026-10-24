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
            'java_dev', 'desktop', 'graphics', 'security', 'bootloader', 'filesystem',
            'kernel', 'locale', 'timezone', 'hostname', 'users', 'network',
            'build_options', 'logging', 'installer', 'sources'
        ]

        for section in required_sections:
            assert section in lfs_config.data

    def test_system_updater_enabled_agrees_across_config_sources(self, temp_dir):
        """Every checked-in preset must match the code default.

        config/build.conf and config/default.json carried
        `system_updater.enabled: false` while config/build.conf.json,
        LFSConfig's built-in default and the test fixture all said true.
        Nothing reads the key today - builder.py overwrites it from the
        profile and no stage script consumes LFS_CONFIG_SYSTEM_UPDATER_*
        - which is exactly why the disagreement survived unnoticed and
        why it is worth pinning down.
        """
        generated = LFSConfig(temp_dir / "fresh.conf")
        assert generated.data['system_updater']['enabled'] is True

        for name in ('config/build.conf', 'config/build.conf.json',
                     'config/default.json'):
            data = json.loads(Path(name).read_text())
            assert data['system_updater']['enabled'] is True, \
                f"{name} disagrees with the code default on system_updater"

    def test_installer_type_agrees_across_config_sources(self, temp_dir):
        """Every checked-in preset must default the installer to 'none'.

        installer.type is resolved from the profile's graphical_installer
        flag and exported as LFS_CONFIG_INSTALLER_TYPE, which is the only
        thing blfs/29-build-calamares.sh reads to decide whether to spend
        hours compiling Qt6, KF6, kpmcore and Calamares.  A preset that
        disagreed with the code default would schedule that chain for
        whoever happened to pass --config with it.
        """
        generated = LFSConfig(temp_dir / "fresh.conf")
        assert generated.data['installer']['type'] == 'none'

        for name in ('config/build.conf', 'config/build.conf.json',
                     'config/default.json'):
            data = json.loads(Path(name).read_text())
            assert data['installer']['type'] == 'none', \
                f"{name} disagrees with the code default on installer.type"

    def test_graphics_mesa_defaults_agree_across_config_sources(self, temp_dir):
        """Every checked-in preset must match the code default for Mesa.

        graphics.mesa_gallium_drivers and graphics.mesa_llvm drive the Mesa
        build in blfs/08b-build-xorg.sh.  lfs-x11-contract.md 3.3 wants a DRI3
        hardware GL path, but the offline CI chroot cannot build the
        LLVM/libclc/rustc stack that iris/radeonsi need, so the default stays
        software (softpipe, llvm disabled) and hardware drivers are opt-in via
        these keys.  A preset that disagreed would silently change what every
        --config build compiles.
        """
        generated = LFSConfig(temp_dir / "fresh.conf")
        assert generated.data['graphics']['mesa_gallium_drivers'] == 'softpipe'
        assert generated.data['graphics']['mesa_llvm'] == 'disabled'

        for name in ('config/build.conf', 'config/build.conf.json',
                     'config/default.json'):
            data = json.loads(Path(name).read_text())
            assert data['graphics']['mesa_gallium_drivers'] == 'softpipe', \
                f"{name} disagrees with the code default on mesa_gallium_drivers"
            assert data['graphics']['mesa_llvm'] == 'disabled', \
                f"{name} disagrees with the code default on mesa_llvm"

    def test_sources_profile_scoped_agrees_across_config_sources(self, temp_dir):
        """Every checked-in preset must default sources.profile_scoped to true.

        sources.profile_scoped flattens to LFS_CONFIG_SOURCES_PROFILE_SCOPED
        and gates whether _update_sources_list() scopes downloads to the active
        profile's build stages.  A preset that disagreed with the code default
        would silently restore the download-everything behaviour that overflowed
        the Ubuntu 26 runner's /tmp tmpfs (Nightly #39, Errno 28) for whoever
        happened to pass --config with it.
        """
        generated = LFSConfig(temp_dir / "fresh.conf")
        assert generated.data['sources']['profile_scoped'] is True

        for name in ('config/build.conf', 'config/build.conf.json',
                     'config/default.json'):
            data = json.loads(Path(name).read_text())
            assert data['sources']['profile_scoped'] is True, \
                f"{name} disagrees with the code default on sources.profile_scoped"

    def test_security_hardening_defaults_agree_across_config_sources(self, temp_dir):
        """The hardening-program security knobs must match across every source.

        Phase 0 of the hardening program added nested
        security.{selinux, kernel_hardening, fips, boot_integrity, usbguard,
        supply_chain, compliance, baseline_all_profiles} keys.  They flatten to
        LFS_CONFIG_SECURITY_* and drive later phases (kernel config, SELinux
        enforce, FIPS-mode crypto, supply-chain verification, compliance gate).
        They must default identically in get_default_config() and in each
        checked-in preset, or a --config build would silently pick a different
        security posture than the code default.  kernel_hardening used to be a
        bare bool and is now a container of knobs, so its shape is pinned here
        too.
        """
        expected = {
            'selinux': {'mode': 'enforcing', 'type': 'targeted'},
            'kernel_hardening': {
                'enabled': True, 'lockdown': 'integrity',
                'module_sig_force': True, 'ima': True,
                'hardened_usercopy': True, 'init_on_alloc_free': True
            },
            'fips': {'enabled': False},
            'boot_integrity': {'secure_boot': False, 'measured_boot': False},
            'usbguard': {'enabled': False},
            'supply_chain': {
                'verify_signatures': True, 'provenance': False,
                'require_lockfile': False
            },
            'compliance': {'profiles': [], 'fail_on_gap': False},
            'baseline_all_profiles': False
        }

        generated = LFSConfig(temp_dir / "fresh.conf")
        sources = [('get_default_config()', generated.data)]
        for name in ('config/build.conf', 'config/build.conf.json',
                     'config/default.json'):
            sources.append((name, json.loads(Path(name).read_text())))

        for source_name, data in sources:
            security = data['security']
            for key, value in expected.items():
                assert security[key] == value, \
                    f"{source_name} disagrees with the code default on security.{key}"

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