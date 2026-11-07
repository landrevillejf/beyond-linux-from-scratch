#!/usr/bin/env python3
"""
Tests for LFSConfig class
"""

import json
import re
from pathlib import Path

from builder import LFSBuilder, LFSConfig


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


class TestTrackedConfigIsNotAWriteTarget:
    """No test may hand the tracked config/build.conf to a config object.

    Measured, not assumed: `LFSConfig.set()' calls `save()' -- `open(w)' --
    on every mutation, and `load()' writes defaults when the file is missing,
    so a single such test rewrites the working tree on every suite run.  Two
    pollutions were reproduced here: `host.distro_override' flipped from
    "auto" to "fedora" (md5 before/after `pytest tests/'), and the arm64 pair
    `architecture: aarch64' + `cross_compile: true' that three kernel tests
    used to write -- the same pair that today sits in the tracked file.
    Reading it stays legal; instantiating on it is not.
    """

    WRITE_PATTERNS = (
        re.compile(r"config_file\s*=\s*['\"]config/build\.conf"),
        re.compile(r"config_file\s*=\s*Path\(\s*['\"]config/build\.conf"),
        re.compile(r"\bconfig\s*=\s*['\"]config/build\.conf"),
        re.compile(r"args\.config\s*=\s*['\"]config/build\.conf"),
    )

    def _offenders(self):
        tests_dir = Path(__file__).parent
        offenders = []
        for path in sorted(tests_dir.glob('*.py')):
            lines = path.read_text().splitlines()
            for number, line in enumerate(lines):
                if not any(p.search(line) for p in self.WRITE_PATTERNS):
                    continue
                window = '\n'.join(lines[max(0, number - 14):number])
                # A mock assertion only names the default the product must
                # pass; it builds no config object.  The window must show the
                # assertion and must not show a real instantiation.
                if ('assert_called_once_with(' in window
                        and 'LFSBuilder(' not in window):
                    continue
                offenders.append(f'{path.name}:{number + 1}: {line.strip()}')
        return offenders

    def test_no_test_instantiates_on_the_tracked_config(self):
        offenders = self._offenders()
        assert offenders == [], (
            'these tests point a real config object at the tracked file, '
            'which LFSConfig.set() then saves: ' + ' | '.join(offenders))


class TestTrackedConfigTargetsTheNativeArchitecture:
    """The presets must not re-target a build that never asked for a cross.

    Measured on this repository, before any of it was changed:
    `config/build.conf' carried `architecture: aarch64',
    `cross_compile: true', `target_triplet: aarch64-lfs-linux-gnu' and
    `bootloader.type: uboot', while its three sibling presets
    (`config/build.conf.json', `config/default.json', `config.yml') and
    `get_default_config()' all carried x86_64/false/grub.  Those four keys
    are the ones `main()' rewrites only inside its `if args.arch:' block,
    and argparse gives `--arch' no default, so every invocation without it
    inherited them.  `_apply_profile_settings()' sets them for a cross
    profile and never resets them otherwise, so a plain
    `builder.py --profile xfce' resolved to an arm64 cross-build, scheduled
    `host/00-setup-qemu.sh' (gated on `is_cross_compile()') and
    `host/05-build-uboot.sh' (gated on `bootloader.type'), and named its
    artifact lfs-<ver>-xfce-aarch64-<init>.iso.
    How the four values entered the file is not established, but the
    mechanism that puts them there is now reproduced: constructing a builder
    for a cross profile rewrote a copy of the corrected preset back to
    aarch64/true/uboot, because every profile and CLI override went through
    `LFSConfig.set()', which saved.  The same fingerprint can come from a
    hand edit, so only the mechanism is claimed here, not the August event.
    """

    PRESETS = ('config/build.conf', 'config/build.conf.json',
               'config/default.json')

    def _builder(self, tmp_path, profile):
        """A builder over a copy, so the assertion cannot write the tree."""
        cfg = tmp_path / f'{profile}.conf'
        cfg.write_text(Path('config/build.conf').read_text())
        out = tmp_path / f'out-{profile}'
        out.mkdir(exist_ok=True)
        return LFSBuilder(profile=profile, output_dir=out, config_file=cfg)

    def test_target_block_agrees_across_config_sources(self, temp_dir):
        generated = LFSConfig(temp_dir / 'fresh.conf')
        assert generated.data['architecture'] == 'x86_64'
        assert generated.data['cross_compile'] is False
        assert generated.data['bootloader']['type'] == 'grub'

        for name in self.PRESETS:
            data = json.loads(Path(name).read_text())
            assert data['architecture'] == 'x86_64', \
                f"{name} disagrees with the code default on architecture"
            assert data['cross_compile'] is False, \
                f"{name} disagrees with the code default on cross_compile"
            assert data['bootloader']['type'] == 'grub', \
                f"{name} disagrees with the code default on bootloader.type"

    def test_set_does_not_write_the_file_it_was_given(self, tmp_path):
        """The pin for the mechanism, not just for this preset's symptoms.

        One `set()' on an existing file must leave the bytes alone: without
        this, any `--profile arm64' or `--arch aarch64' run puts the arm64
        block back into whatever config it was handed -- and `--config'
        defaults to the tracked file, so the tree would change under a
        maintainer who only wanted to build once.
        """
        cfg = tmp_path / 'build.conf'
        original = Path('config/build.conf').read_text()
        cfg.write_text(original)
        config = LFSConfig(cfg)
        config.set('architecture', 'aarch64')
        config.set('cross_compile', True)
        assert config.get('architecture') == 'aarch64', \
            'the override must still apply in memory'
        assert cfg.read_text() == original, \
            'set() wrote the resolved values back to the file'

    def test_a_profile_that_does_not_ask_for_cross_stays_native(self, tmp_path):
        """The property the invariant lives on: a native profile builds native.

        Scheduling qemu-setup and the uboot stage for an x86_64 profile costs
        hours and produces an image no x86_64 consumer can boot, so this is
        asserted on the resolved stage list, not only on the raw JSON.
        """
        builder = self._builder(tmp_path, 'xfce')
        assert builder.is_cross_compile() is False
        assert builder.get_target_architecture() == 'x86_64'
        scripts = {script for _name, script in builder.get_build_stages()}
        assert 'host/00-setup-qemu.sh' not in scripts
        assert 'host/05-build-uboot.sh' not in scripts
        assert '-xfce-x86_64-' in builder.get_iso_name(), \
            'the artifact name must carry the architecture it was built for'

    def test_a_cross_profile_still_resolves_arm64(self, tmp_path):
        """The fix must not cost the ARM profiles their cross path.

        `arm64' sets cross_compile in ProfileManager, so the profile itself
        still drives architecture, triplet and the uboot bootloader however
        the preset reads; dropping that would have traded one broken profile
        for three.
        """
        builder = self._builder(tmp_path, 'arm64')
        assert builder.is_cross_compile() is True
        assert builder.get_target_architecture() == 'aarch64'
        scripts = {script for _name, script in builder.get_build_stages()}
        assert 'host/00-setup-qemu.sh' in scripts
        assert 'host/05-build-uboot.sh' in scripts
