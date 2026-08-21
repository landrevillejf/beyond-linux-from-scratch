#!/usr/bin/env python3
"""
Tests for sign_iso() and generate_sbom() to achieve 100% coverage
Covers lines: 1921-1946, 1950-2026, 2360, 2364-2365
"""

import pytest
import json
import hashlib
import logging
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).parent.parent))
from builder import LFSBuilder, main


class TestSignISO:
    """Test LFSBuilder.sign_iso() method – lines 1921-1946"""

    def _make_builder(self, tmp_path):
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")
        return LFSBuilder("minimal", tmp_path, config_file)

    def test_sign_iso_no_iso_file(self, tmp_path):
        """sign_iso returns False when ISO doesn't exist (line 1922-1924)"""
        builder = self._make_builder(tmp_path)
        result = builder.sign_iso()
        assert result is False

    def test_sign_iso_gpg_not_found(self, tmp_path):
        """sign_iso returns True (non-fatal) when GPG is missing (line 1926-1928)"""
        builder = self._make_builder(tmp_path)
        # Create the ISO file with the dynamic name
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_bytes(b'fake iso content')

        with patch('shutil.which', return_value=None):
            result = builder.sign_iso()
            assert result is True

    def test_sign_iso_success(self, tmp_path):
        """sign_iso succeeds and creates .sig file (lines 1930-1943)"""
        builder = self._make_builder(tmp_path)
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_bytes(b'fake iso content')

        with patch('shutil.which', return_value='/usr/bin/gpg'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                result = builder.sign_iso()
                assert result is True
                mock_run.assert_called_once()
                cmd = mock_run.call_args[0][0]
                assert 'gpg' in cmd
                assert '--detach-sign' in cmd

    def test_sign_iso_success_with_gpg_key(self, tmp_path):
        """sign_iso passes --local-user when gpg_key is provided (lines 1935-1936)"""
        builder = self._make_builder(tmp_path)
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_bytes(b'fake iso content')

        with patch('shutil.which', return_value='/usr/bin/gpg'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                result = builder.sign_iso(gpg_key='ABCD1234')
                assert result is True
                cmd = mock_run.call_args[0][0]
                assert '--local-user' in cmd
                assert 'ABCD1234' in cmd

    def test_sign_iso_gpg_failure(self, tmp_path):
        """sign_iso returns False when GPG signing fails (lines 1944-1946)"""
        import subprocess
        builder = self._make_builder(tmp_path)
        iso_file = tmp_path / builder.get_iso_name()
        iso_file.write_bytes(b'fake iso content')

        with patch('shutil.which', return_value='/usr/bin/gpg'):
            with patch('subprocess.run', side_effect=subprocess.CalledProcessError(
                1, 'gpg', stderr=b'key not found'
            )):
                result = builder.sign_iso()
                assert result is False


class TestGenerateSBOM:
    """Test LFSBuilder.generate_sbom() method – lines 1950-2026"""

    def _make_builder(self, tmp_path):
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")
        return LFSBuilder("minimal", tmp_path, config_file)

    def test_generate_sbom_no_build_info_no_packages(self, tmp_path):
        """SBOM with no build_info.json and no installed packages (lines 1950-2026)"""
        builder = self._make_builder(tmp_path)

        result = builder.generate_sbom()
        assert result is True

        sbom_file = tmp_path / 'sbom.spdx.json'
        assert sbom_file.exists()
        sbom = json.loads(sbom_file.read_text())
        assert sbom['spdxVersion'] == 'SPDX-2.3'
        assert sbom['dataLicense'] == 'CC0-1.0'
        assert sbom['SPDXID'] == 'SPDXRef-DOCUMENT'
        assert 'Way-Beyond-LFS-minimal' in sbom['name']
        assert sbom['packages'] == []

    def test_generate_sbom_with_build_info(self, tmp_path):
        """SBOM includes externalDocumentRefs when build_info.json exists (lines 1958-1960, 2014-2020)"""
        builder = self._make_builder(tmp_path)

        # Create build_info.json
        build_info = {
            "build_date": "2026-01-15T10:00:00",
            "profile": "minimal",
            "version": "0.52.4"
        }
        (tmp_path / 'build_info.json').write_text(json.dumps(build_info))

        result = builder.generate_sbom()
        assert result is True

        sbom = json.loads((tmp_path / 'sbom.spdx.json').read_text())
        assert 'externalDocumentRefs' in sbom
        assert len(sbom['externalDocumentRefs']) == 1
        ref = sbom['externalDocumentRefs'][0]
        assert ref['externalDocumentId'] == 'DocumentRef-build-info'
        assert 'checksum' in ref
        assert ref['checksum']['algorithm'] == 'SHA256'

    def test_generate_sbom_with_installed_packages(self, tmp_path):
        """SBOM includes packages from LPM installed.list (lines 1963-1970, 1990-2010)"""
        builder = self._make_builder(tmp_path)

        # Create installed packages list
        lpm_dir = tmp_path / 'image' / 'var' / 'lib' / 'lpm'
        lpm_dir.mkdir(parents=True)
        (lpm_dir / 'installed.list').write_text(
            "bash 5.2\ncoreutils 9.4\nglibc 2.39\n"
        )

        result = builder.generate_sbom()
        assert result is True

        sbom = json.loads((tmp_path / 'sbom.spdx.json').read_text())
        assert len(sbom['packages']) == 3
        pkg_names = [p['name'] for p in sbom['packages']]
        assert 'bash' in pkg_names
        assert 'coreutils' in pkg_names
        assert 'glibc' in pkg_names

        # Check SPDXID format
        for pkg in sbom['packages']:
            assert pkg['SPDXID'].startswith('SPDXRef-Package-')
            assert pkg['downloadLocation'] == 'NOASSERTION'
            assert pkg['filesAnalyzed'] is False

        # Check relationships
        assert len(sbom['relationships']) == 3
        for rel in sbom['relationships']:
            assert rel['spdxElementId'] == 'SPDXRef-DOCUMENT'
            assert rel['relationshipType'] == 'DESCRIBES'

    def test_generate_sbom_with_special_chars_in_package_name(self, tmp_path):
        """SBOM sanitizes special chars in package SPDXID (line 1992)"""
        builder = self._make_builder(tmp_path)

        lpm_dir = tmp_path / 'image' / 'var' / 'lib' / 'lpm'
        lpm_dir.mkdir(parents=True)
        (lpm_dir / 'installed.list').write_text("libstdc++6 14.0\n")

        result = builder.generate_sbom()
        assert result is True

        sbom = json.loads((tmp_path / 'sbom.spdx.json').read_text())
        # Special chars should be replaced with hyphens
        spdx_id = sbom['packages'][0]['SPDXID']
        assert '+' not in spdx_id

    def test_generate_sbom_with_build_info_and_packages(self, tmp_path):
        """SBOM with both build_info and packages – full coverage (all lines)"""
        builder = self._make_builder(tmp_path)

        # Create build_info.json
        build_info = {"build_date": "2026-08-17", "profile": "xfce"}
        (tmp_path / 'build_info.json').write_text(json.dumps(build_info))

        # Create installed packages
        lpm_dir = tmp_path / 'image' / 'var' / 'lib' / 'lpm'
        lpm_dir.mkdir(parents=True)
        (lpm_dir / 'installed.list').write_text("bash 5.2\n")

        result = builder.generate_sbom()
        assert result is True

        sbom = json.loads((tmp_path / 'sbom.spdx.json').read_text())
        assert 'externalDocumentRefs' in sbom
        assert len(sbom['packages']) == 1
        assert len(sbom['relationships']) == 1


class TestMainSBOMAndSignISO:
    """Test main() calls to generate_sbom() and sign_iso() – lines 2360, 2364-2365"""

    def test_main_with_sbom_flag(self, tmp_path):
        """main() calls generate_sbom when --sbom is passed (line 2360)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        test_args = [
            'builder.py',
            '--profile', 'minimal',
            '--output', str(tmp_path),
            '--config', str(config_file),
            '--sbom',
        ]

        with patch('sys.argv', test_args):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            with patch.object(LFSBuilder, 'generate_sbom', return_value=True) as mock_sbom:
                                with patch.object(LFSBuilder, 'create_writable_media', return_value=True):
                                    main()
                                    mock_sbom.assert_called_once()

    def test_main_with_sign_iso_flag_no_key(self, tmp_path):
        """main() calls sign_iso(None) when --sign-iso is passed without key (lines 2364-2365)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        test_args = [
            'builder.py',
            '--profile', 'minimal',
            '--output', str(tmp_path),
            '--config', str(config_file),
            '--sign-iso',
        ]

        with patch('sys.argv', test_args):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            with patch.object(LFSBuilder, 'sign_iso', return_value=True) as mock_sign:
                                with patch.object(LFSBuilder, 'create_writable_media', return_value=True):
                                    main()
                                    mock_sign.assert_called_once_with(None)

    def test_main_with_sign_iso_flag_with_key(self, tmp_path):
        """main() calls sign_iso('KEYID') when --sign-iso KEYID is passed (lines 2364-2365)"""
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")

        test_args = [
            'builder.py',
            '--profile', 'minimal',
            '--output', str(tmp_path),
            '--config', str(config_file),
            '--sign-iso', 'ABCD1234',
        ]

        with patch('sys.argv', test_args):
            with patch.object(LFSBuilder, 'check_prerequisites', return_value=True):
                with patch.object(LFSBuilder, 'prepare_environment', return_value=True):
                    with patch.object(LFSBuilder, 'download_sources', return_value=True):
                        with patch.object(LFSBuilder, 'build', return_value=True):
                            with patch.object(LFSBuilder, 'sign_iso', return_value=True) as mock_sign:
                                with patch.object(LFSBuilder, 'create_writable_media', return_value=True):
                                    main()
                                    mock_sign.assert_called_once_with('ABCD1234')


class TestISONameGeneration:
    """Test get_iso_name() method for versioned ISO naming"""

    def _make_builder(self, tmp_path, profile='minimal', milestone=None,
                      nightly=False):
        config_file = tmp_path / "test.conf"
        config_file.write_text("{}")
        return LFSBuilder(profile, tmp_path, config_file, milestone=milestone,
                          nightly=nightly)

    def test_get_iso_name_default(self, tmp_path):
        """ISO name includes version, profile, arch, init"""
        builder = self._make_builder(tmp_path)
        name = builder.get_iso_name()
        assert name.startswith('lfs-')
        assert 'minimal' in name
        assert 'x86_64' in name
        assert 'sysvinit' in name
        assert name.endswith('.iso')

    def test_get_iso_name_with_milestone(self, tmp_path):
        """ISO name includes milestone tag when set (line 1237)"""
        builder = self._make_builder(tmp_path, milestone='rc1')
        name = builder.get_iso_name()
        assert 'rc1' in name
        # Format: lfs-VERSION-minimal-x86_64-sysvinit-rc1.iso
        parts = name.replace('.iso', '').split('-')
        assert parts[-1] == 'rc1'

    def test_get_iso_name_with_date(self, tmp_path):
        """ISO name includes date when dated=True (line 1240)"""
        builder = self._make_builder(tmp_path)
        name = builder.get_iso_name(dated=True)
        today = datetime.now().strftime("%Y%m%d")
        assert today in name

    def test_get_iso_name_with_milestone_and_date(self, tmp_path):
        """ISO name includes both milestone and date"""
        builder = self._make_builder(tmp_path, milestone='beta1')
        name = builder.get_iso_name(dated=True)
        today = datetime.now().strftime("%Y%m%d")
        assert 'beta1' in name
        assert today in name

    def test_get_iso_name_nightly_defaults_to_dated(self, tmp_path):
        """nightly=True makes the default ISO name include today's date"""
        builder = self._make_builder(tmp_path, nightly=True)
        name = builder.get_iso_name()
        today = datetime.now().strftime("%Y%m%d")
        assert name.endswith(f"-{today}.iso")

    def test_get_iso_name_nightly_with_milestone(self, tmp_path):
        """nightly + milestone keeps the date as the last component"""
        builder = self._make_builder(tmp_path, milestone='rc1', nightly=True)
        name = builder.get_iso_name()
        today = datetime.now().strftime("%Y%m%d")
        parts = name.replace('.iso', '').split('-')
        assert parts[-1] == today
        assert 'rc1' in parts

    def test_get_iso_name_not_nightly_defaults_to_undated(self, tmp_path):
        """Without nightly, the default ISO name carries no date"""
        builder = self._make_builder(tmp_path)
        name = builder.get_iso_name()
        today = datetime.now().strftime("%Y%m%d")
        assert today not in name

    def test_build_creates_compat_symlink(self, tmp_path):
        """build() creates backward-compatible lfs-installer.iso symlink (line 1948)"""
        builder = self._make_builder(tmp_path)
        iso_name = builder.get_iso_name()
        iso_path = tmp_path / iso_name
        iso_path.write_bytes(b"X" * 1024)

        with patch.object(builder.executor, 'run_script', return_value=True):
            result = builder.build()
            assert result is True

        compat = tmp_path / 'lfs-installer.iso'
        assert compat.exists()
        assert compat.is_symlink()

    def test_build_symlink_creation_failure_nonfatal(self, tmp_path):
        """build() handles OSError when symlink creation fails (line 1949)"""
        builder = self._make_builder(tmp_path)
        iso_name = builder.get_iso_name()
        iso_path = tmp_path / iso_name
        iso_path.write_bytes(b"X" * 1024)

        with patch.object(builder.executor, 'run_script', return_value=True):
            with patch('pathlib.Path.symlink_to', side_effect=OSError("readonly fs")):
                result = builder.build()
                assert result is True  # Non-fatal

    def test_create_writable_media_fallback_to_compat(self, tmp_path):
        """create_writable_media falls back to compat symlink (lines 2081-2082)"""
        builder = self._make_builder(tmp_path)
        # Create only the compat symlink, not the versioned ISO
        compat = tmp_path / 'lfs-installer.iso'
        compat.write_bytes(b"fake iso")

        with patch('builder.USBWriter.write_iso', return_value=True) as mock_write:
            result = builder.create_writable_media('/dev/sdb')
            assert result is True
            mock_write.assert_called_once()
            # Should have used the compat path
            call_args = mock_write.call_args
            assert 'lfs-installer.iso' in str(call_args)
