"""Profile management for LFS Builder"""

import copy
from typing import Dict, List, Optional


class ProfileManager:
    """Manage build profiles with flexible desktop, init system, and audio options"""

    # Available choices for configuration
    AVAILABLE_DESKTOPS = ['none', 'xfce', 'gnome', 'kde', 'lxqt', 'phosh']
    AVAILABLE_INIT_SYSTEMS = ['sysvinit', 'systemd', 'openrc', 'runit', 's6']
    AVAILABLE_AUDIO = ['none', 'cli', 'studio']

    PROFILES = {
        'minimal': {
            'description': 'Minimal command-line only system',
            'size_gb': 1,
            'build_time_hours': 2,
            'packages': ['base', 'network', 'ssh'],
            'desktop': 'none',
            'init_system': 'sysvinit',
            'audio': 'none',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': False,
            'desktop_options': ['none'],
            'init_options': ['sysvinit', 'systemd', 'openrc'],
            'audio_options': ['none']
        },
        'gnu-free': {
            'description': '100% Free Software System (FSF compliant)',
            'size_gb': 3,
            'build_time_hours': 4,
            'packages': ['gnu-core', 'gnu-network', 'gnu-dev', 'gnu-utils'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': False,
            'system_updater': True,
            'gnu_free': True,
            'kernel': 'linux-libre'
        },
        'gnu-free-full': {
            'description': 'Full GNU System with all GNU packages',
            'size_gb': 10,
            'build_time_hours': 8,
            'packages': ['gnu-all', 'gnu-emacs', 'gnu-octave', 'icecat'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True,
            'gnu_free': True,
            'kernel': 'linux-libre'
        },
        'xfce': {
            'description': 'XFCE desktop environment',
            'size_gb': 4,
            'build_time_hours': 4,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'apps'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'gnome': {
            'description': 'GNOME desktop environment',
            'size_gb': 8,
            'build_time_hours': 8,
            'packages': ['base', 'network', 'ssh', 'xorg', 'gnome', 'apps'],
            'desktop': 'gnome',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'java-dev': {
            'description': 'Java development environment with XFCE',
            'size_gb': 10,
            'build_time_hours': 6,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'apps', 'java', 'maven', 'gradle', 'tomcat', 'jenkins', 'docker'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': True,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'secure': {
            'description': 'Security-hardened system with privacy tools',
            'size_gb': 6,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'ssh', 'xorg', 'xfce', 'security', 'privacy'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True
        },
        'full': {
            'description': 'Complete system with everything',
            'size_gb': 20,
            'build_time_hours': 12,
            'packages': ['all'],
            'desktop': 'gnome',
            'init_system': 'systemd',
            'java_dev': True,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': True,
            'live_system': True,
            'system_updater': True
        },
        'arm64': {
            'description': 'ARM64 server (Raspberry Pi, Orange Pi)',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'uboot'
        },
        'audio-cli': {
            'description': 'CLI-only audio production system',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'audio-core', 'audio-midi'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        },
        'pinebook': {
            'description': 'Pinebook / Pinebook Pro ARM64 laptop',
            'size_gb': 4,
            'build_time_hours': 4,
            'packages': ['base', 'network', 'xorg', 'xfce', 'pinebook'],
            'desktop': 'xfce',
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'uboot'
        },
        'audio-studio': {
            'description': 'Full audio production studio with XFCE',
            'size_gb': 8,
            'build_time_hours': 6,
            'packages': ['base', 'network', 'xorg', 'xfce', 'audio-core', 'audio-daw', 'audio-plugins', 'audio-midi'],
            'desktop': 'xfce',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'kde': {
            'description': 'KDE Plasma full-featured desktop environment',
            'size_gb': 10,
            'build_time_hours': 12,
            'packages': ['base', 'network', 'ssh', 'xorg', 'kde', 'apps', 'multimedia'],
            'desktop': 'kde',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'lxqt': {
            'description': 'LXQt extremely lightweight Qt desktop environment',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh', 'xorg', 'lxqt', 'apps'],
            'desktop': 'lxqt',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': True,
            'system_updater': True
        },
        'server': {
            'description': 'Production-optimized server configuration',
            'size_gb': 2,
            'build_time_hours': 3,
            'packages': ['base', 'network', 'ssh', 'server-tools'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        },
        'brax3': {
            'description': 'Brax3 Linux smartphone (Qualcomm Snapdragon)',
            'size_gb': 4,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'xorg', 'phosh', 'brax3'],
            'desktop': 'phosh',
            'init_system': 'systemd',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': True,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True,
            'cross_compile': True,
            'architecture': 'aarch64',
            'bootloader': 'aboot'
        },
        'custom': {
            'description': 'User-defined custom profile template',
            'size_gb': 5,
            'build_time_hours': 5,
            'packages': ['base', 'network', 'ssh'],
            'desktop': None,
            'init_system': 'sysvinit',
            'java_dev': False,
            'package_manager': True,
            'security_hardening': False,
            'privacy_tools': False,
            'live_system': False,
            'system_updater': True
        }
    }

    @classmethod
    def get_profile(cls, name: str) -> Dict:
        """Get profile configuration (returns a deep copy to prevent mutation)"""
        if name not in cls.PROFILES:
            raise ValueError(f"Unknown profile: {name}. Available: {list(cls.PROFILES.keys())}")
        return copy.deepcopy(cls.PROFILES[name])

    @classmethod
    def list_profiles(cls) -> List[str]:
        """List all available profiles"""
        return list(cls.PROFILES.keys())

    @classmethod
    def get_profile_info(cls, name: str,
                         init_system: Optional[str] = None,
                         desktop: Optional[str] = None,
                         live_system: Optional[bool] = None,
                         security_hardening: Optional[bool] = None,
                         privacy_tools: Optional[bool] = None) -> str:
        profile = cls.get_profile(name)
        effective_init = init_system if init_system is not None else profile.get('init_system', 'sysvinit')
        effective_desktop = desktop if desktop is not None else profile.get('desktop')
        effective_live = live_system if live_system is not None else profile.get('live_system', False)
        effective_security = security_hardening if security_hardening is not None else profile.get('security_hardening', False)
        effective_privacy = privacy_tools if privacy_tools is not None else profile.get('privacy_tools', False)

        return f"""
    ╔══════════════════════════════════════════════════════════════════╗
    ║ Profile: {name.upper()}
    ╠══════════════════════════════════════════════════════════════════╣
    ║ Description:   {profile['description']}
    ║ Size:          ~{profile['size_gb']} GB
    ║ Build time:    ~{profile['build_time_hours']} hours
    ║ Desktop:       {effective_desktop or 'None (CLI only)'}
    ║ Init System:   {effective_init}
    ║ Architecture:  {profile.get('architecture', 'x86_64')}
    ║ Bootloader:    {profile.get('bootloader', 'grub')}
    ║ Java Dev:      {'yes' if profile['java_dev'] else 'no'}
    ║ Package Mgr:   {'yes' if profile['package_manager'] else 'no'}
    ║ Security:      {'yes' if effective_security else 'no'}
    ║ Privacy:       {'yes' if effective_privacy else 'no'}
    ║ Live System:   {'yes' if effective_live else 'no'}
    ║ Auto Updates:  {'yes' if profile.get('system_updater', False) else 'no'}
    ╚══════════════════════════════════════════════════════════════════╝
    """
