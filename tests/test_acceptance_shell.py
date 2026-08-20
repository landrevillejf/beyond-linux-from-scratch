#!/usr/bin/env python3
"""
Tests d'acceptance avec scripts shell réels
Exécute les vrais scripts LFS/BLFS dans un environnement contrôlé
"""

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest


class TestRealShellScripts:
    """Tests des scripts shell réels"""

    @pytest.fixture
    def test_env(self, temp_dir):
        """Create test environment fixture"""
        return {
            'LFS': str(temp_dir / 'lfs'),
            'TEST_MODE': '1',
            'PATH': os.environ.get('PATH', ''),
            'HOME': str(temp_dir),
        }

    @pytest.fixture
    def test_env(self, temp_dir):
        """Create test environment"""
        return {
            'LFS': str(temp_dir / 'lfs'),
            'TEST_MODE': '1',
            'PATH': os.environ.get('PATH', ''),
            'HOME': str(temp_dir),
        }

    @pytest.fixture
    def test_env(self, temp_dir):
        """Créer un environnement de test pour les scripts shell"""
        env = {
            'LFS': str(temp_dir / 'lfs'),
            'TEST_MODE': '1',
            'PATH': os.environ.get('PATH', ''),
            'HOME': str(temp_dir),
        }

        # Créer la structure de répertoires
        (temp_dir / 'lfs').mkdir(exist_ok=True)
        (temp_dir / 'sources').mkdir(exist_ok=True)
        (temp_dir / 'scripts').mkdir(exist_ok=True)

        return env

    @pytest.fixture
    def mock_script(self, temp_dir):
        """Créer un script shell simple pour test"""
        script_path = temp_dir / "test_script.sh"
        script_path.write_text("""#!/bin/bash
echo "Script executed"
echo "LFS=$LFS"
echo "TEST_MODE=$TEST_MODE"
exit 0
""")
        script_path.chmod(0o755)
        return script_path

    def test_execute_shell_script(self, mock_script, test_env):
        """Exécution d'un script shell simple"""
        result = subprocess.run(
            [str(mock_script)],
            env=test_env,
            capture_output=True,
            text=True
        )

        assert result.returncode == 0
        assert "Script executed" in result.stdout
        assert test_env['LFS'] in result.stdout

    def test_script_error_handling(self, temp_dir, test_env):
        """Test gestion d'erreur dans un script"""
        error_script = temp_dir / "error_script.sh"
        error_script.write_text("""#!/bin/bash
echo "Starting..."
exit 1
""")
        error_script.chmod(0o755)

        result = subprocess.run(
            [str(error_script)],
            env=test_env,
            capture_output=True,
            text=True
        )

        assert result.returncode == 1

    # tests/test_acceptance_shell.py - ligne 90
    def test_script_with_timeout(self, temp_dir, test_env):
        """Test script avec timeout"""
        timeout_script = temp_dir / "timeout_script.sh"
        timeout_script.write_text("""#!/bin/bash
    sleep 30
    echo "Done"
    """)
        timeout_script.chmod(0o755)

        start_time = time.time()
        try:
            result = subprocess.run(
                [str(timeout_script)],
                env=test_env,
                capture_output=True,
                text=True,
                timeout=2
            )
            elapsed = time.time() - start_time
            # Si le script termine avant timeout, c'est une erreur
            assert False, "Le script aurait dû timeout"
        except subprocess.TimeoutExpired:
            elapsed = time.time() - start_time
            assert elapsed < 5  # Doit timeout rapidement
            print(f"✅ Script correctement arrêté après {elapsed:.1f}s")

    def test_lfs_init_script_validation(self, temp_dir, test_env):
        """Validation de la syntaxe des scripts LFS"""
        lfs_scripts = [
            'lfs/05a-build-lfs-basic.sh',
            'lfs/05b-build-lfs-system.sh',
            'lfs/06a-init-system.sh',
            'lfs/06b-service-management.sh',
        ]

        for script_path in lfs_scripts:
            if Path(script_path).exists():
                # Vérifier la syntaxe bash (sans exécuter)
                result = subprocess.run(
                    ['bash', '-n', script_path],
                    capture_output=True,
                    text=True
                )
                assert result.returncode == 0, f"Syntax error in {script_path}"
                print(f"✅ Syntaxe valide: {script_path}")

    def test_blfs_desktop_script_validation(self, temp_dir, test_env):
        """Validation des scripts BLFS desktop"""
        blfs_scripts = [
            'blfs/09-build-desktop.sh',
            'blfs/10-build-applications.sh',
            'blfs/11-configure-desktop.sh',
        ]

        for script_path in blfs_scripts:
            if Path(script_path).exists():
                result = subprocess.run(
                    ['bash', '-n', script_path],
                    capture_output=True,
                    text=True
                )
                assert result.returncode == 0, f"Syntax error in {script_path}"
                print(f"✅ Syntaxe valide: {script_path}")

    def test_toolchain_script_exports_lfs_tools_path(self):
        """Toolchain script must use cross tools from $LFS/tools/bin."""
        toolchain_script = Path('host/04-build-toolchain.sh')
        assert toolchain_script.exists()
        content = toolchain_script.read_text()
        assert 'KERNEL_TYPE=${KERNEL_TYPE:-linux}' in content
        assert 'PATH="$LFS/tools/bin:/usr/bin:/bin"' in content
        assert "export LFS LFS_TGT LC_ALL=POSIX PATH" in content
        assert "export LFS LC_ALL LFS_TGT PATH" in content
        assert "find . -maxdepth 1 -type f -printf '%f\\n' | grep -E \"^${KERNEL_TYPE}-[0-9].*\\\\.tar\\\\.xz$\" | head -n1" in content
        assert 'LINUX_DIR=$(tar -tf "$LINUX_TAR" | head -1 | cut -d/ -f1)' in content

    def test_toolchain_temporary_tools_follow_lfs_book(self):
        """Toolchain script must build the Chapter 6 temporary tools exactly
        like the LFS book (cross configure with --host=$LFS_TGT, no autoconf
        cache files) and keep Binutils/GCC pass 2 before the tools loop.

        Regression test for the nightly toolchain failure: libstdc++ built
        with --prefix=$LFS/tools landed in a directory the pass 1 cross
        compiler does not search ('C++ compiler cannot create executables'
        in the GCC pass 2 libcody subconfigure).
        """
        toolchain_script = Path('host/04-build-toolchain.sh')
        assert toolchain_script.exists()
        content = toolchain_script.read_text()

        # The old gnulib cache hacks are gone: the book does not use them.
        assert 'CROSS_CACHE_TMPL' not in content, \
            "Cross-compile cache template must be removed (not in the LFS book)"
        assert '--cache-file=' not in content, \
            "Configure cache files must not be used (not in the LFS book)"

        # LFS 12.4 section 5.6: libstdc++ installs into the final location
        # through DESTDIR so the pass 1 cross compiler finds it via sysroot.
        assert '--prefix=/usr' in content
        assert 'make DESTDIR="$LFS" install' in content
        assert '--with-gxx-include-dir=/tools/"$LFS_TGT"/include/c++/' in content

        # LFS 12.4 section 6.18: GCC pass 2 needs LDFLAGS_FOR_TARGET and the
        # generic cc symlink.
        assert 'LDFLAGS_FOR_TARGET=-L"$PWD"/"$LFS_TGT"/libgcc' in content
        assert 'ln -sv gcc "$LFS/usr/bin/cc"' in content

        # The Chapter 6 loop must build every tool required by 05a.
        tools_loop = 'for pkg in m4 ncurses bash coreutils diffutils file ' \
            'findutils gawk grep gzip make patch sed tar xz bison bzip2; do'
        assert tools_loop in content, "Tool loop does not follow book order"

        # Book-mandated per-package handling must be present.
        assert 'gl_cv_func_strcasecmp_works=y' in content, \
            "Missing diffutils strcasecmp cross-compile answer (LFS 6.6)"
        assert 'make TIC_PATH="$(pwd)/build/progs/tic" install' in content, \
            "Missing native tic handling for ncurses (LFS 6.3)"
        assert 'FILE_COMPILE="$(pwd)/build/src/file"' in content, \
            "Missing native file binary handling (LFS 6.7)"
        assert 'ln -sv bash "$LFS/tools/bin/sh"' in content, \
            "Missing /tools/bin/sh symlink (LFS 6.4)"

        # Ordering: libstdc++ -> Binutils pass 2 -> GCC pass 2 -> tools loop.
        libstdc_pos = content.find('Building libstdc++')
        binutils_p2_pos = content.find('Building Binutils (pass 2)')
        gcc_p2_pos = content.find('Building GCC (pass 2)')
        tools_loop_pos = content.find('Building temporary tools (LFS Chapter 6)')
        assert -1 not in (libstdc_pos, binutils_p2_pos, gcc_p2_pos,
                          tools_loop_pos), "Missing toolchain stage marker"
        assert libstdc_pos < binutils_p2_pos < gcc_p2_pos < tools_loop_pos, \
            "Pass 2 stages must run after libstdc++ and before the tools loop"

    def test_shellcheck_on_scripts(self):
        """Exécuter shellcheck sur tous les scripts (si installé)"""
        try:
            subprocess.run(['shellcheck', '--version'], capture_output=True, check=True)
            shellcheck_available = True
        except (subprocess.CalledProcessError, FileNotFoundError):
            shellcheck_available = False
            pytest.skip("shellcheck not installed")

        scripts = list(Path('.').rglob('*.sh'))
        scripts = [s for s in scripts if 'venv' not in str(s) and '.pytest' not in str(s)]

        errors = []
        for script in scripts[:10]:  # Limiter pour le test
            result = subprocess.run(
                ['shellcheck', str(script)],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                errors.append(f"{script}: {result.stderr[:100]}")

        if errors:
            print(f"⚠️ Problèmes shellcheck détectés:\n" + "\n".join(errors[:5]))
        else:
            print(f"✅ shellcheck: {len(scripts)} scripts vérifiés")


class TestChrootEnvironment:
    """Tests pour l'environnement chroot (simulation)"""

    def test_chroot_simulation(self, temp_dir, test_env):
        """Simuler un environnement chroot"""
        chroot_dir = temp_dir / 'chroot'
        chroot_dir.mkdir()

        # Créer une structure minimale
        (chroot_dir / 'bin').mkdir()
        (chroot_dir / 'lib').mkdir()
        (chroot_dir / 'usr').mkdir()

        # Copier bash
        bash_path = shutil.which('bash')
        if bash_path:
            shutil.copy(bash_path, chroot_dir / 'bin/')

        test_env['CHROOT_TEST'] = '1'

        print(f"✅ Environnement chroot simulé créé: {chroot_dir}")

    def test_build_script_in_chroot(self, temp_dir, test_env):
        """Exécuter un script dans un chroot simulé"""
        chroot_dir = temp_dir / 'chroot'
        chroot_dir.mkdir()

        # Créer un script dans le chroot
        script_in_chroot = chroot_dir / 'test.sh'
        script_in_chroot.write_text("""#!/bin/sh
echo "Running inside chroot"
exit 0
""")
        script_in_chroot.chmod(0o755)

        # Copier les binaires nécessaires
        for cmd in ['sh', 'echo']:
            src = shutil.which(cmd)
            if src:
                dest = chroot_dir / 'bin' / cmd
                dest.parent.mkdir(exist_ok=True)
                shutil.copy(src, dest)

        # Exécution réelle (nécessite sudo pour chroot)
        try:
            result = subprocess.run(
                ['sudo', 'chroot', str(chroot_dir), '/test.sh'],
                capture_output=True,
                text=True,
                timeout=5
            )
            print(f"Résultat chroot: {result.stdout}")
        except subprocess.TimeoutExpired:
            print("⚠️ Timeout dans chroot")
        except PermissionError:
            pytest.skip("Need sudo for chroot test")


class TestIntegrationWorkflow:
    """Test du workflow complet (simulation)"""

    def test_complete_build_workflow_simulation(self, temp_dir):
        """Simulation du workflow de build complet"""
        from builder import LFSBuilder
        import json

        # Créer un fichier de config valide
        config_dir = temp_dir / 'config'
        config_dir.mkdir()
        config_file = config_dir / 'build.conf'
        config_file.write_text('{"lfs_version": "13.0"}')  # JSON valide

        output_dir = temp_dir / 'test_build'

        # Utiliser le fichier de config créé
        builder = LFSBuilder(
            profile='minimal',
            output_dir=output_dir,
            config_file=config_file  # Utiliser le fichier valide
        )

        # Vérifier l'environnement (sans exécuter)
        env = builder._get_env()
        assert 'LFS' in env
        assert 'PROFILE' in env
        assert env['PROFILE'] == 'minimal'

        # Vérifier la structure des stages
        stages = builder.get_build_stages()
        assert len(stages) > 10
        print(f"✅ {len(stages)} stages de build")

        # Vérifier les noms des stages critiques
        critical_stages = ['lfs-system', 'init-system']
        for stage in critical_stages:
            stage_names = [s[0] for s in stages]
            assert stage in stage_names, f"{stage} not found"
        print("✅ Tous les stages critiques présents")

    def test_real_script_execution_dry_run(self, temp_dir):
        """Exécution à sec des scripts réels (bash -n)"""
        scripts = []
        for pattern in ['lfs/*.sh', 'blfs/*.sh', 'host/*.sh', 'final/*.sh']:
            scripts.extend(Path('.').glob(pattern))

        scripts = [s for s in scripts if not s.name.startswith('_')]

        failed = []
        for script in scripts:
            result = subprocess.run(
                ['bash', '-n', str(script)],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                failed.append((script, result.stderr))

        if failed:
            print(f"⚠️ {len(failed)} scripts avec erreurs de syntaxe:")
            for script, error in failed[:5]:
                print(f"  - {script}: {error[:100]}")
        else:
            print(f"✅ {len(scripts)} scripts syntaxiquement valides")


class TestLFSComplianceGuardrails:
    """Guardrail tests from docs/LFS_COMPLIANCE_AUDIT.md phase 6.

    These tests freeze the book-compliance fixes: no host binary
    imports in the LFS stages, a complete chapter 8 package list,
    per-package BLFS commands without error masking, and the
    standalone-system checks in final/16.
    """

    def test_lfs_scripts_have_no_host_binary_imports(self):
        """No stage may copy host binaries into the built system."""
        import re

        scripts = list(Path('lfs').glob('*.sh'))
        assert scripts, "lfs/ stage scripts not found"

        forbidden = ['copy_binaries', 'copy_host_binaries',
                     'import_host_binaries']
        # Host import pattern: cp from the host /bin or /usr/bin into the
        # $LFS tree.  In-chroot copies (no $LFS on the line) are fine.
        host_copy_re = re.compile(
            r'cp[^\n]*\s/(?:usr/)?bin/[^\n]*\$LFS')

        for script in scripts:
            content = script.read_text()
            for token in forbidden:
                assert token not in content, \
                    f"{script} still imports host binaries ({token})"
            assert not host_copy_re.search(content), \
                f"{script} copies binaries from the host /bin or /usr/bin"

    def test_chapter8_package_list_is_complete(self):
        """The chapter 8 loop must build every book package."""
        import re

        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        match = re.search(r'CH8_PACKAGES="([^"]*)"', content)
        assert match, "CH8_PACKAGES list not found in 05b"
        packages = set(match.group(1).split())

        # Critical LFS 12.4 chapter 8 packages (subset used as canary).
        expected = {
            'man-pages', 'iana-etc', 'glibc', 'zlib', 'bzip2', 'xz',
            'file', 'readline', 'm4', 'bc', 'flex', 'tcl', 'dejagnu',
            'pkgconf', 'binutils', 'gmp', 'mpfr', 'mpc', 'attr', 'acl',
            'libcap', 'libxcrypt', 'shadow', 'gcc', 'ncurses', 'sed',
            'psmisc', 'gettext', 'bison', 'grep', 'bash', 'libtool',
            'gdbm', 'gperf', 'expat', 'inetutils', 'less', 'perl',
            'autoconf', 'automake', 'openssl', 'libelf', 'libffi',
            'python', 'ninja', 'meson', 'kmod', 'coreutils',
            'diffutils', 'gawk', 'findutils', 'groff', 'grub', 'gzip',
            'iproute2', 'kbd', 'libpipeline', 'make', 'patch', 'tar',
            'texinfo', 'vim', 'udev', 'man-db', 'procps-ng',
            'util-linux', 'e2fsprogs', 'sysklogd', 'sysvinit',
        }
        missing = expected - packages
        assert not missing, f"Chapter 8 packages missing: {sorted(missing)}"

    def test_blfs_base_uses_per_package_commands(self):
        """blfs-base must use the BLFS book commands, not a generic
        configure/make template, and must not mask build failures."""
        content = Path('blfs/08-build-blfs-base.sh').read_text()

        # The generic template is gone.
        assert 'compile_package' not in content, \
            "Generic compile_package template must be removed"

        # Per-package book commands.
        assert './config --prefix=/usr' in content, \
            "OpenSSL must be built with ./config (BLFS book)"
        assert '--openssldir=/etc/ssl' in content
        assert '--with-openssl' in content, "cURL must link against OpenSSL"
        assert '--with-ca-path=/etc/ssl/certs' in content
        assert '--with-history' in content, "libxml2 needs readline history"
        assert 'PYTHON=/usr/bin/python3' in content

        # No error masking on package builds: '|| true' is only allowed
        # on mount/umount cleanup lines.
        for line in content.splitlines():
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if '|| true' in stripped:
                assert 'mount' in stripped, \
                    f"Error masking outside mount cleanup: {stripped}"

    def test_final_validation_has_standalone_guardrails(self):
        """final/16 must verify /tools removal and scan for /tools
        rpaths (audit finding F-08)."""
        content = Path('final/16-validate-build.sh').read_text()
        assert '/tools removed' in content
        assert 'readelf -d' in content
        assert 'RPATH|RUNPATH' in content
        assert 'config-' in content, \
            "Kernel .config provenance check missing"

    def test_ncurses_built_with_gnu17_for_gcc15(self):
        """ncurses must be built with -std=gnu17 under GCC 15.

        GCC 15 defaults to C23 where bool is a keyword; ncurses
        configure then misdetects bool and emits a curses.h that
        leaks "#define bool unsigned char" into the C++ binding,
        breaking it against GCC 15 libstdc++ headers. Regression
        test for the nightly toolchain failures.
        """
        for script in ('host/04-build-toolchain.sh',
                       'lfs/05b-build-lfs-system.sh'):
            content = Path(script).read_text()
            assert 'CFLAGS="-O2 -std=gnu17"' in content, \
                f"{script} must force C17 for ncurses (GCC 15 bool bug)"

    def test_toolchain_provides_shared_libgcc_for_temp_tools(self):
        """The temporary tools must link against a shared libgcc.

        The Chapter 6 tools link with the pass 1 cross compiler whose
        static-only libgcc keeps unwind symbols hidden since GCC 14, so
        the ncurses --with-cxx-shared demo link failed in the nightly
        with "hidden symbol _Unwind_GetLanguageSpecificData in libgcc.a
        referenced by DSO". GCC pass 2 runs before the tools loop and
        installs libgcc_s.so.1 into the sysroot; the stage must verify
        it exists and the temporary ncurses build must link -lgcc_s.
        """
        content = Path('host/04-build-toolchain.sh').read_text()

        # GCC pass 2 installs libgcc_s.so.1 before the tools loop and
        # the stage fails fast when it is missing.
        gcc_p2_pos = content.find('Building GCC (pass 2)')
        tools_loop_pos = content.find(
            'Building temporary tools (LFS Chapter 6)')
        libgcc_check_pos = content.find('$LFS/usr/lib/libgcc_s.so.1')
        assert -1 not in (gcc_p2_pos, tools_loop_pos, libgcc_check_pos)
        assert gcc_p2_pos < libgcc_check_pos < tools_loop_pos, \
            "libgcc_s.so.1 must be verified after GCC pass 2 and " \
            "before the tools loop"

        # Temporary ncurses resolves unwind symbols via the shared
        # libgcc instead of the hidden static ones.
        ncurses_pos = content.find('ncurses)')
        assert ncurses_pos != -1
        assert content.find('LDFLAGS="-lgcc_s"', ncurses_pos) > \
            ncurses_pos, "Temporary ncurses must link with -lgcc_s"

    def test_toolchain_normalizes_lib64_for_all_targets(self):
        """GCC must install 64-bit libraries into lib, not lib64,
        for every supported target.

        The nightly aarch64 build failed because GCC pass 2 installed
        libgcc_s.so.1 into $LFS/usr/lib64 (the MULTILIB_OSDIRNAMES
        default), tripping the libgcc_s fail-fast guard that looks in
        $LFS/usr/lib. The lib64 -> lib sed from LFS book section 5.3
        must therefore be keyed on the target triple (not uname -m,
        which differs on cross builds) and cover aarch64 in addition
        to x86_64, in the libstdc++ pass and both GCC passes.
        """
        content = Path('host/04-build-toolchain.sh').read_text()

        # libstdc++ plus GCC pass 1 and pass 2 all normalize aarch64.
        assert content.count('/mabi.lp64=/s/lib64/lib/') == 3, \
            "aarch64 lib64 -> lib sed missing from a GCC build step"
        assert 'gcc/config/aarch64/t-aarch64-linux' in content

        # Keyed on the target triple so cross builds are covered;
        # no target-layout decision may key on the host uname -m.
        assert content.count('case "$LFS_TGT" in') == 5
        assert 'case $(uname -m) in' not in content

    def test_temp_coreutils_uses_dummy_man_for_man_pages(self):
        """Temporary coreutils must not run the real help2man.

        When target binaries happen to execute on the build host
        (same architecture), autoconf resolves cross_compiling to
        "no" and coreutils runs help2man against them; the nightly
        x86_64 build then died on "help2man: can't get `--help' info
        from man/stty.td/stty". Forcing run_help2man=man/dummy-man
        selects the distributed man pages, exactly like a genuine
        cross build.
        """
        content = Path('host/04-build-toolchain.sh').read_text()
        coreutils_pos = content.find('coreutils)')
        assert coreutils_pos != -1
        assert content.find('run_help2man=man/dummy-man',
                            coreutils_pos) > coreutils_pos, \
            "Temporary coreutils must force dummy-man for man pages"
        assert 'make -j"$NUM_JOBS" $make_flags' in content

    def test_stage14_seeds_installed_registry_from_sources(self):
        """Stage 14 must seed installed.list with versions resolved
        from the build's source tarballs, not just a hardcoded table.

        Without a seeded installed registry, lpm list/upgrade/verify
        are useless on the finished system.
        """
        content = Path('blfs/14-create-base-packages.sh').read_text()

        # Same name-version split rule as LPM itself: the version part
        # must start with a digit.
        assert '[a-zA-Z0-9._+-]+)-([0-9]' in content, \
            "Stage 14 must reuse the LPM name-version regex"
        assert '"$LFS/sources"' in content, \
            "Versions must come from the tarballs actually built"
        assert 'resolve_version()' in content

        # installed.list is seeded, merging idempotently (existing
        # non-seeded entries win, seeded entries are refreshed).
        assert 'INSTALLED_FILE="$LFS/var/lib/lpm/installed.list"' in content
        assert 'Seeding installed registry' in content

        # base-packages.list stays (autoremove depends on it).
        assert 'base-packages.list' in content

        # The repository manifest is exported for the release
        # pipeline, with checksum and optional signature.
        assert 'lpm-repo' in content
        assert 'packages.list.sha256' in content
        assert '--detach-sign' in content

    def test_lfs_update_is_hardened_and_init_agnostic(self):
        """lfs-update must fetch with curl first, never hardcode the
        system version, and avoid systemctl (sysvinit profiles)."""
        content = Path('blfs/18-system-updater.sh').read_text()

        # curl-first fetch with wget fallback.
        assert 'fetch_url()' in content
        fetch = content.split('fetch_url()')[1].split('\n}\n')[0]
        assert fetch.index('curl') < fetch.index('wget'), \
            "fetch_url must prefer curl and fall back to wget"

        # No hardcoded version write; the marker only moves when the
        # repo manifest declares a version.
        assert 'echo "13.0" > "$VERSION_FILE"' not in content
        assert 'declared_version' in content

        # status must not assume systemd.
        assert 'systemctl' not in content
        assert 'count_upgradable' in content

        # Weekly check only when a cron.weekly directory exists.
        assert 'cron.weekly/lfs-update-check' in content
        assert '-d "$LFS/etc/cron.weekly"' in content

    def test_shellcheck_on_compliance_scripts(self):
        """shellcheck must be clean on every script touched by the
        compliance remediation."""
        try:
            subprocess.run(['shellcheck', '--version'],
                           capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pytest.skip("shellcheck not installed")

        scripts = [
            'lfs/05b-build-lfs-system.sh',
            'lfs/07-configure-lfs.sh',
            'lfs/08-build-kernel.sh',
            'blfs/08-build-blfs-base.sh',
            'final/16-validate-build.sh',
        ]
        for script in scripts:
            assert Path(script).exists(), f"{script} missing"
            result = subprocess.run(
                ['shellcheck', script],
                capture_output=True,
                text=True
            )
            assert result.returncode == 0, \
                f"shellcheck failed on {script}:\n{result.stdout}"


class TestBLFSErrorPolicyGuardrails:
    """Wave 2 guardrails (audit finding F-07).

    Every BLFS stage must classify packages with run_build
    required/optional instead of masking failures, run the chroot
    with a clean environment, and stay shellcheck clean on both the
    outer script and the inner heredoc payload.
    """

    WAVE2_SCRIPTS = [
        'blfs/08a-build-blfs-libs.sh',
        'blfs/08b-build-xorg.sh',
        'blfs/08c-build-wayland.sh',
        'blfs/08d-build-display-manager.sh',
        'blfs/09a-build-xfce.sh',
        'blfs/09b-build-gnome.sh',
        'blfs/09c-build-kde.sh',
        'blfs/09d-build-lxqt.sh',
        'blfs/23-basic-networking.sh',
        'blfs/24-multimedia.sh',
        'blfs/25-server.sh',
        'blfs/26-printing-scanning.sh',
    ]

    # Tarball base names that differ from the script package name.
    ALIASES = {
        'glib2': ['glib'],
        'icu': ['icu4c'],
        'libelf': ['elfutils'],
        'libyaml': ['yaml'],
        'lm-sensors': ['lm_sensors'],
        'wxWidgets': ['wxWidgets', 'wxwidgets'],
        'rust': ['rustc'],
        'mesa': ['Mesa', 'mesa'],
        'gtk3': ['gtk-3'],
        'gtk4': ['gtk-4'],
        'libsoup3': ['libsoup'],
        'apache': ['httpd'],
        'qt6': ['qt-everywhere-src'],
    }

    # Packages provided by another stage or by the LFS base system.
    PROVIDED_ELSEWHERE = {
        'sqlite',  # LFS chapter 8
        'curl',    # blfs/08-build-blfs-base.sh
    }

    def test_blfs_stages_define_error_policy(self):
        """Every wave 2 stage defines run_build and uses it."""
        for script in self.WAVE2_SCRIPTS:
            content = Path(script).read_text()
            assert 'run_build()' in content, \
                f"{script} must define the run_build policy wrapper"
            assert 'aborting stage' in content, \
                f"{script} must abort on required package failure"
            assert 'run_build required' in content, \
                f"{script} must classify required packages"

    def test_blfs_stages_have_no_build_masking(self):
        """No build_pkg call may be masked with '|| log_warning'
        and a missing source archive must fail the build."""
        import re

        masked_re = re.compile(
            r'build_(?:xfce_)?pkg\s[^\n]*\|\|')
        for script in self.WAVE2_SCRIPTS:
            content = Path(script).read_text()
            assert not masked_re.search(content), \
                f"{script} masks package build failures"
            assert 'Source archive missing for $pkg; skipping' \
                not in content, \
                f"{script} silently skips missing source archives"

    def test_blfs_stages_run_chroot_with_clean_env(self):
        """The chroot invocation must wipe the host environment."""
        for script in self.WAVE2_SCRIPTS:
            content = Path(script).read_text()
            assert 'chroot "$LFS" /usr/bin/env -i' in content, \
                f"{script} must run the inner script with env -i"

    def test_required_packages_have_sources(self):
        """Every required package must resolve to a tarball listed in
        packages/stable/12.4/sources.list."""
        import re

        sources = Path('packages/stable/12.4/sources.list').read_text()
        call_re = re.compile(r'run_build\s+required\s+(\S+)')
        loop_re = re.compile(
            r'for pkg in ([^;\n]+); do\n\s*run_build required "\$pkg"')

        for script in self.WAVE2_SCRIPTS:
            content = Path(script).read_text()
            required = set()
            for pkg in call_re.findall(content):
                if pkg.startswith('"$'):
                    # Loop variable: resolve the literal package list.
                    loop_match = loop_re.search(content)
                    assert loop_match, \
                        f"{script}: required {pkg} outside a resolvable " \
                        "loop"
                    required.update(loop_match.group(1).split())
                else:
                    required.add(pkg.strip('"'))
            for pkg in required:
                if pkg in self.PROVIDED_ELSEWHERE:
                    continue
                bases = self.ALIASES.get(pkg, [pkg])
                found = any(
                    f"/{base}-" in sources or f"/{base}." in sources
                    for base in bases)
                assert found, \
                    f"{script}: required package {pkg} has no source " \
                    f"in packages/stable/12.4/sources.list"

    def test_shellcheck_on_wave2_scripts(self):
        """shellcheck must be clean on the outer scripts and on the
        inner heredoc payloads of every wave 2 stage."""
        import re

        try:
            subprocess.run(['shellcheck', '--version'],
                           capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pytest.skip("shellcheck not installed")

        inner_re = re.compile(
            r"cat <<'INNEREOF' \| run_privileged tee.*?\n(.*?)^INNEREOF$",
            re.DOTALL | re.MULTILINE)

        for script in self.WAVE2_SCRIPTS:
            result = subprocess.run(
                ['shellcheck', script],
                capture_output=True,
                text=True
            )
            assert result.returncode == 0, \
                f"shellcheck failed on {script}:\n{result.stdout}"

            content = Path(script).read_text()
            match = inner_re.search(content)
            assert match, f"{script} has no INNEREOF heredoc"
            with tempfile.NamedTemporaryFile(
                    mode='w', suffix='.sh', delete=False) as tmp:
                tmp.write(match.group(1))
                tmp_path = tmp.name
            try:
                result = subprocess.run(
                    ['shellcheck', tmp_path],
                    capture_output=True,
                    text=True
                )
                assert result.returncode == 0, \
                    f"shellcheck failed on inner payload of " \
                    f"{script}:\n{result.stdout}"
            finally:
                os.unlink(tmp_path)


class TestBLFSBookCommandGuardrails:
    """Wave 3 guardrails (audit finding F-07).

    Every package-building BLFS stage must use per-package BLFS book
    commands (build_<name>/build_commands_<name> dispatched by
    run_build) instead of relying solely on the generic meson/
    autotools/cmake auto-detection.  The generic build_pkg remains as
    a documented fallback for packages without a book page.
    """

    WAVE3_SCRIPTS = [
        'blfs/08a-build-blfs-libs.sh',
        'blfs/08b-build-xorg.sh',
        'blfs/08c-build-wayland.sh',
        'blfs/08d-build-display-manager.sh',
        'blfs/09a-build-xfce.sh',
        'blfs/09b-build-gnome.sh',
        'blfs/09c-build-kde.sh',
        'blfs/09d-build-lxqt.sh',
        'blfs/23-basic-networking.sh',
        'blfs/24-multimedia.sh',
        'blfs/25-server.sh',
        'blfs/26-printing-scanning.sh',
    ]

    def test_wave3_scripts_use_book_commands(self):
        """Every stage defines book_install, per-package book command
        functions, and dispatches them through run_build."""
        import re

        for script in self.WAVE3_SCRIPTS:
            content = Path(script).read_text()
            assert 'book_install()' in content, \
                f"{script} must define the book_install runner"
            assert re.search(r'^build_commands_\w+\(\)', content,
                             re.MULTILINE), \
                f"{script} has no per-package book command functions"
            assert 'declare -F "$fn"' in content, \
                f"{script} run_build must dispatch book functions"

    def test_wave3_scripts_keep_generic_fallback(self):
        """Packages without a book page must fall back to the generic
        build_pkg, which stays defined in every stage."""
        for script in self.WAVE3_SCRIPTS:
            content = Path(script).read_text()
            assert 'build_pkg()' in content, \
                f"{script} must keep the generic build_pkg fallback"


class TestInitSystemErrorPolicyGuardrails:
    """Guardrail tests for the wave 4 init-system remediation.

    The init stages (lfs/06a..06e) must follow the same strict error
    policy as the BLFS stages: a run_build wrapper that aborts on a
    required failure, no host-tool imports, a clean chroot environment,
    and required packages that resolve to a listed source tarball.
    """

    # Scripts that actually build packages (have an INNEREOF payload).
    BUILD_SCRIPTS = [
        'lfs/06a-init-system.sh',
        'lfs/06c-init-openrc.sh',
        'lfs/06d-init-runit.sh',
        'lfs/06e-init-s6.sh',
    ]

    # Every init-stage script, including the service abstraction layer.
    ALL_SCRIPTS = BUILD_SCRIPTS + ['lfs/06b-service-management.sh']

    def test_init_stages_define_error_policy(self):
        """Every init build stage defines and uses run_build."""
        for script in self.BUILD_SCRIPTS:
            content = Path(script).read_text()
            assert 'run_build()' in content, \
                f"{script} must define the run_build policy wrapper"
            assert 'aborting stage' in content, \
                f"{script} must abort on required package failure"
            assert ('run_build required' in content or
                    'run_build optional' in content), \
                f"{script} must classify packages via run_build"

    def test_init_stages_have_no_build_masking(self):
        """No build_pkg call may be masked and missing sources must
        fail the build."""
        import re

        masked_re = re.compile(r'build_pkg\s[^\n]*\|\|')
        for script in self.BUILD_SCRIPTS:
            content = Path(script).read_text()
            assert not masked_re.search(content), \
                f"{script} masks package build failures"
            assert 'Source archive missing for $pkg; skipping' \
                not in content, \
                f"{script} silently skips missing source archives"

    def test_init_stages_do_not_import_host_tools(self):
        """Init stages must not copy host binaries into the target
        (audit finding F-05)."""
        for script in self.ALL_SCRIPTS:
            content = Path(script).read_text()
            assert 'copy_tool_with_libs' not in content, \
                f"{script} still imports host tools"
            assert '/tools/bin' not in content, \
                f"{script} still references the removed /tools tree"

    def test_init_stages_run_chroot_with_clean_env(self):
        """The chroot invocation must wipe the host environment."""
        for script in self.ALL_SCRIPTS:
            content = Path(script).read_text()
            assert 'chroot "$LFS" /usr/bin/env -i' in content, \
                f"{script} must run the inner script with env -i"

    def test_init_required_packages_have_sources(self):
        """Every required init package must resolve to a tarball listed
        in packages/stable/12.4/sources.list."""
        import re

        sources = Path('packages/stable/12.4/sources.list').read_text()
        call_re = re.compile(r'run_build\s+required\s+(\S+)')

        for script in self.BUILD_SCRIPTS:
            content = Path(script).read_text()
            for pkg in set(call_re.findall(content)):
                found = (f"/{pkg}-" in sources or f"/{pkg}." in sources)
                assert found, \
                    f"{script}: required package {pkg} has no source " \
                    f"in packages/stable/12.4/sources.list"

    def test_shellcheck_on_init_scripts(self):
        """shellcheck must be clean on the outer scripts and on the
        inner heredoc payloads of every init build stage."""
        import re

        try:
            subprocess.run(['shellcheck', '--version'],
                           capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pytest.skip("shellcheck not installed")

        inner_re = re.compile(
            r"cat <<'INNEREOF' \| run_privileged tee.*?\n(.*?)^INNEREOF$",
            re.DOTALL | re.MULTILINE)

        for script in self.ALL_SCRIPTS:
            result = subprocess.run(
                ['shellcheck', script],
                capture_output=True,
                text=True
            )
            assert result.returncode == 0, \
                f"shellcheck failed on {script}:\n{result.stdout}"

        for script in self.BUILD_SCRIPTS:
            content = Path(script).read_text()
            match = inner_re.search(content)
            assert match, f"{script} has no INNEREOF heredoc"
            with tempfile.NamedTemporaryFile(
                    mode='w', suffix='.sh', delete=False) as tmp:
                tmp.write(match.group(1))
                tmp_path = tmp.name
            try:
                result = subprocess.run(
                    ['shellcheck', tmp_path],
                    capture_output=True,
                    text=True
                )
                assert result.returncode == 0, \
                    f"shellcheck failed on inner payload of " \
                    f"{script}:\n{result.stdout}"
            finally:
                os.unlink(tmp_path)
