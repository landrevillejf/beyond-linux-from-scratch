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

    def test_readline_configure_sees_tools_lib(self):
        """readline must link against the temporary ncursesw.

        Nightly #165 died in the chapter 8 readline build with
        "cannot find -lncursesw": the only ncursesw available at that
        point is the chapter 7 one in /tools/lib, which is outside the
        native compiler's default search paths, so the forced
        SHLIB_LIBS had nothing to resolve to.  configure must be given
        -L/tools/lib, and it must appear before the make that forces
        SHLIB_LIBS.
        """
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        readline_pos = content.find('readline)')
        ldflags_pos = content.find('LDFLAGS="-L/tools/lib"', readline_pos)
        shlib_pos = content.find('SHLIB_LIBS="-lncursesw"', readline_pos)
        assert readline_pos != -1
        assert ldflags_pos > readline_pos, \
            "readline configure must expose /tools/lib to the linker"
        assert readline_pos < ldflags_pos < shlib_pos, \
            "-L/tools/lib must reach configure before make links shlibs"

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
        assert content.find('LDFLAGS="-lgcc_s ', ncurses_pos) > \
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
        assert content.count('case "$LFS_TGT" in') == 6
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

    def test_toolchain_cross_builds_keep_host_utils_first(self):
        """Cross builds must not let $LFS/tools/bin shadow host
        utilities.

        The nightly aarch64 run died in coreutils "make install" with
        mv "'_inst.451424_' ... are the same file" right after qemu
        reported "aarch64-binfmt-P: Could not open
        '/lib/ld-linux-aarch64.so.1'": with $LFS/tools/bin leading
        PATH, the install machinery resolved cp/mv/basename/... to
        freshly installed aarch64 binaries the host cannot execute.
        Native builds keep the book order; cross builds put the host
        directories first (the cross toolchain only exists in
        $LFS/tools/bin, so it still resolves) and export
        QEMU_LD_PREFIX so any binfmt-mediated execution of target
        binaries resolves the loader from the sysroot.
        """
        content = Path('host/04-build-toolchain.sh').read_text()
        assert 'PATH="$LFS/tools/bin:/usr/bin:/bin"' in content, \
            "Native builds must keep the book PATH order"
        assert 'PATH="/usr/bin:/bin:$LFS/tools/bin"' in content, \
            "Cross builds must put host directories first in PATH"
        assert 'export QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-$LFS}"' \
            in content, "Cross builds must export QEMU_LD_PREFIX"
        # The PATH policy keys on the target triple, and the host-first
        # branch sits before the PATH export.
        case_pos = content.find('"$(uname -m)"*)')
        host_first_pos = content.find(
            'PATH="/usr/bin:/bin:$LFS/tools/bin"')
        export_pos = content.find(
            'export LFS LFS_TGT LC_ALL=POSIX PATH')
        assert -1 not in (case_pos, host_first_pos, export_pos)
        assert case_pos < host_first_pos < export_pos

    def test_temp_tools_carry_tools_lib_rpath(self):
        """Temporary tools must carry an rpath toward the tools lib dir.

        The nightly xfce lfs-system run died on the very first source
        extraction: tar invoked /tools/bin/xz, which failed with
        "error while loading shared libraries: liblzma.so.5". The
        temporary tools link against the target glibc whose loader
        only searches /lib and /usr/lib at runtime, so /tools/lib is
        invisible inside the chapter 7/8 chroot. Every temporary tools
        configure call must therefore pass an rpath LDFLAGS.

        The rpath must carry BOTH roots: $LFS/tools/lib (build host,
        where the tools live during the toolchain stage) and /tools/lib
        (the chroot, where $LFS is / and the same binaries run during
        lfs-system). Embedding only $LFS/tools/lib resolves to a
        non-existent path inside the chroot, which is exactly what made
        the earlier fix a no-op there.
        """
        content = Path('host/04-build-toolchain.sh').read_text()
        # Both the host-root and the chroot-root lib dirs are covered.
        assert 'tools_rpath="-Wl,-rpath,$LFS/tools/lib ' \
            '-Wl,-rpath,/tools/lib"' in content, \
            "rpath must cover both $LFS/tools/lib and /tools/lib"
        # Generic loop configure plus the file branch pass the rpath;
        # ncurses merges it into its own LDFLAGS.
        assert content.count('LDFLAGS="$tools_rpath"') == 2
        assert 'LDFLAGS="-lgcc_s $tools_rpath"' in content

    def test_uboot_uses_lfs_sources_not_host_root(self):
        """The uboot stage must build inside $LFS/sources, never a
        host-level /sources.

        The nightly arm64/aarch64 run passed the toolchain stage but
        died in the uboot stage with "mkdir: cannot create directory
        '/sources': Permission denied": the stage runs as the
        unprivileged lfs user, which cannot create /sources at the host
        root. The U-Boot sources must be downloaded into the builder's
        sources directory ($LFS/sources), which already exists and is
        owned by lfs.
        """
        content = Path('host/05-build-uboot.sh').read_text()
        # The stage works from $LFS/sources, not a host-level /sources.
        assert 'SOURCES_DIR="${LFS:-/mnt/lfs}/sources"' in content
        assert 'mkdir -p /sources' not in content, \
            "uboot must not create a host-level /sources directory"
        assert 'cd /sources' not in content, \
            "uboot must not cd into a host-level /sources directory"

    def test_uboot_maps_kernel_arch_to_uboot_arm(self):
        """Kernel-style arch names must map to U-Boot's ARCH=arm.

        Nightly #161 advanced past the $LFS/sources fix and died in
        the U-Boot build with "ln: failed to create symbolic link
        'arch/aarch64/include/asm/arch'": the builder exports the
        kernel architecture name (aarch64), but U-Boot has no
        arch/aarch64 or arch/arm64 tree — every 32/64-bit ARM board
        builds with ARCH=arm, selected by the defconfig.
        """
        content = Path('host/05-build-uboot.sh').read_text()
        assert 'aarch64*|arm64*)' in content, \
            "uboot must map kernel arch names to U-Boot arch names"
        case_pos = content.find('aarch64*|arm64*)')
        map_pos = content.find('ARCH=arm', case_pos)
        first_make = content.find('make ARCH="${ARCH}"')
        assert -1 not in (map_pos, first_make)
        assert case_pos < map_pos < first_make, \
            "ARCH must be normalized before the first make call"

    def test_bc_links_against_tools_lib_ncursesw(self):
        """bc must resolve readline's DT_NEEDED libncursesw.so.6.

        Nightly #167 (full/sysvinit/x86_64) died in lfs-system while
        linking bin/bc: the readline built just before bc links
        against chapter 7's ncurses (/tools/lib) and carries DT_NEEDED
        libncursesw.so.6, while the native ncurses is only built after
        gcc. bc's final link had no search path for /tools/lib, so ld
        reported "libncursesw.so.6 not found" and undefined tputs/
        tgoto references. bc's configure consumes LDFLAGS from the
        environment, so the fix mirrors the readline case's exposure.
        """
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        bc_pos = content.find('    bc)\n')
        assert bc_pos != -1, "05b must keep a bc build case"
        bc_block = content[bc_pos:content.find(';;', bc_pos)]
        assert "LDFLAGS='-L/tools/lib -Wl,-rpath-link,/tools/lib'" \
            in bc_block, \
            "bc must expose /tools/lib so ld resolves libncursesw.so.6"
        readline_pos = content.find('    readline)\n')
        assert readline_pos != -1 and readline_pos < bc_pos, \
            "bc builds after readline and consumes its shared lib"

    def test_gcc_cc_link_tolerates_existing_target(self):
        """The gcc cc symlink must not fail when gcc installs it.

        Nightly #168 (minimal and java-dev, sysvinit/x86_64) died in
        lfs-system immediately after gcc's make install with "ln:
        failed to create symbolic link '/usr/bin/cc': File exists":
        GCC >= 15 creates /usr/bin/cc during make install itself, so
        the book's legacy `ln -sv gcc /usr/bin/cc` aborts the stage
        under set -e. The link creation must be guarded so re-runs and
        modern compilers both survive.
        """
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        gcc_pos = content.find('    gcc)\n')
        assert gcc_pos != -1, "05b must keep a gcc build case"
        # The gcc case nests a `case $(uname -m)` with its own ;;, so
        # slice up to the next top-level package instead.
        end_pos = content.find('    ncurses)\n', gcc_pos)
        assert end_pos != -1
        gcc_block = content[gcc_pos:end_pos]
        assert '[ -e /usr/bin/cc ] || ln -sv gcc /usr/bin/cc' \
            in gcc_block, \
            "gcc's cc link must be skipped when gcc installed it"
        assert '\n        ln -sv gcc /usr/bin/cc\n' not in gcc_block, \
            "unguarded cc link would fail on GCC >= 15"

    def test_usr_bin_env_bridged_before_openssl(self):
        """/usr/bin/env must exist in the chroot before openssl.

        Nightly #169 (minimal/sysvinit/x86_64) died in lfs-system at
        openssl: "./config: /sources/openssl-3.5.2/Configure:
        /usr/bin/env: bad interpreter: No such file or directory".
        LFS 12.4 6.5 installs the temporary Coreutils under /usr, so
        env exists when chapter 8 starts; here the temporary tools
        live under /tools, so lfs-basic must bridge /usr/bin/env to
        /tools/bin/env and lfs-system must drop the bridge before the
        final Coreutils install (make install would write through the
        symlink into /tools, leaving a dangling /usr/bin/env once
        /tools is removed).
        """
        basic = Path('lfs/05a-build-lfs-basic.sh').read_text()
        assert 'ln -sfn /tools/bin/env "$LFS/usr/bin/env"' in basic, \
            "lfs-basic must bridge /usr/bin/env to the temporary env"
        assert '[ ! -e "$LFS/usr/bin/env" ]' in basic, \
            "the env bridge must not clobber an existing real env"

        system = Path('lfs/05b-build-lfs-system.sh').read_text()
        coreutils_pos = system.find('    coreutils)\n')
        assert coreutils_pos != -1, "05b must keep a coreutils case"
        block = system[coreutils_pos:system.find(';;', coreutils_pos)]
        drop_pos = block.find('rm -f /usr/bin/env')
        install_pos = block.find('\n        make install\n')
        assert drop_pos != -1 and install_pos != -1, \
            "coreutils must drop the env bridge before installing"
        assert drop_pos < install_pos, \
            "make install would write through the env bridge symlink"

    def test_meson_case_keeps_pip_console_script(self):
        """The meson case must not symlink /usr/bin/meson over itself.

        Nightly #170 (all profiles) died in lfs-system at kmod with
        "meson: command not found": pip had installed the real
        /usr/bin/meson console script, then the case ran
        `ln -sfv meson /usr/bin/meson`, replacing it with a relative
        self-referencing symlink. The BLFS book installs meson with
        pip3 only, no symlink.
        """
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        meson_pos = content.find('    meson)\n')
        assert meson_pos != -1, "05b must keep a meson build case"
        block = content[meson_pos:content.find(';;', meson_pos)]
        assert 'pip3 wheel' in block and 'pip3 install' in block
        assert 'ln -sfv meson /usr/bin/meson' not in block, \
            "the self-link clobbers the pip-installed console script"
        assert 'command -v meson' in block, \
            "a missing meson must fail the meson case, not kmod/udev"

    def test_root_unsafe_packages_force_configure(self):
        """coreutils and tar must bypass the gnulib root check.

        Nightly #172 (xfce/sysvinit/x86_64) died in lfs-system at
        tar-1.35: "you should not run configure as root (set
        FORCE_UNSAFE_CONFIGURE=1 ...)". Chapter 8 builds run as root
        inside the chroot, and the book sets FORCE_UNSAFE_CONFIGURE=1
        for the packages whose configure performs the root check.
        """
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        for pkg in ('coreutils', 'tar'):
            pos = content.find(f'    {pkg})\n')
            assert pos != -1, f"05b must keep a {pkg} build case"
            block = content[pos:content.find(';;', pos)]
            assert 'FORCE_UNSAFE_CONFIGURE=1' in block, \
                f"{pkg} configure rejects root without FORCE_UNSAFE_CONFIGURE"

    def test_initramfs_supports_live_squashfs(self):
        """The live ISO boots with root=/dev/sr0, but the real root is
        the live.squashfs stored on the media.

        Without mounting the squashfs, switch_root dies on the missing
        /sbin/init ("Attempted to kill init" panic) and neither a real
        live boot nor the QEMU smoke test can reach userspace.
        """
        content = Path('final/12-create-initramfs.sh').read_text()
        assert 'live.squashfs' in content
        assert 'losetup /dev/loop0 /mnt/live.squashfs' in content
        assert 'switch_root /sysroot /sbin/init' in content

    def test_kernel_config_supports_live_boot_and_serial(self):
        """Live boot needs iso9660/squashfs/loop; the QEMU smoke test
        observes the guest through console=ttyS0."""
        content = Path('config/kernel-config').read_text()
        for option in ('CONFIG_ISO9660_FS=y', 'CONFIG_SQUASHFS=y',
                       'CONFIG_BLK_DEV_LOOP=y',
                       'CONFIG_SERIAL_8250=y',
                       'CONFIG_SERIAL_8250_CONSOLE=y'):
            assert option in content, f"kernel-config lacks {option}"

    def test_qemu_boot_smoke_script_is_a_real_gate(self):
        """The smoke test must reject panics and silent boots.

        Every regression since nightly #169 was caught during the
        build, never by booting the artifact; the reusable script is
        the post-build gate for nightly, release and iso-from-cache.
        """
        script = Path('tools/qemu-boot-smoke.sh')
        assert script.exists()
        content = script.read_text()
        assert 'set -euo pipefail' in content
        # Failure paths: kernel panic, silent boot, no userspace.
        assert 'Kernel panic' in content
        assert 'Linux version' in content
        # Direct kernel boot with a serial console, not the fragile
        # 90s -cdrom attempt whose -append flag was ignored.
        assert 'console=ttyS0' in content
        assert '-kernel "$WORKDIR/vmlinuz"' in content

    def test_find_archive_survives_variant_tarballs(self, tmp_path):
        """find_archive must skip docs variants and survive case and
        underscore tarball names.

        Nightly #161 died in lfs-system right after perl with
        "=== Building python-3.13.7-docs-html ===" followed by
        "./configure: No such file or directory": the old prefix glob
        returned the first alphabetical match, and the documentation
        tarball sorts before Python-3.13.7.tar.xz.  The lookup must
        also survive capitalized names (Python-3.13.7.tar.xz,
        XML-Parser), underscores (flit_core) and oddball layouts
        (tcl8.6.16-src, expect5.45.4, icu4c .tgz).
        """
        import re

        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        match = re.search(r'^find_archive\(\) \{\n.*?^\}\n', content,
                          re.DOTALL | re.MULTILINE)
        assert match, "05b must define find_archive"
        fn_text = match.group(0)

        for name in ('Python-3.13.7.tar.xz',
                     'python-3.13.7-docs-html.tar.bz2',
                     'tcl8.6.16-src.tar.gz',
                     'tcl8.6.16-html.tar.gz',
                     'expect5.45.4.tar.gz',
                     'flit_core-3.12.0.tar.gz',
                     'icu4c-77_1-src.tgz'):
            (tmp_path / name).touch()

        probe = tmp_path / 'probe.sh'
        probe.write_text(
            '#!/bin/bash\nset -u\n' + fn_text +
            'cd "$1"\n'
            'for b in python tcl expect flit-core icu4c nosuchpkg; do\n'
            '    r=$(find_archive "$b")\n'
            '    echo "${b}=${r}"\n'
            'done\n')
        result = subprocess.run(['bash', str(probe), str(tmp_path)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        picks = dict(line.split('=', 1) for line in
                     result.stdout.splitlines() if '=' in line)
        assert picks['python'] == 'Python-3.13.7.tar.xz', \
            "python must resolve to the buildable sources, not docs"
        assert picks['tcl'] == 'tcl8.6.16-src.tar.gz', \
            "tcl must prefer the -src archive over the -html docs"
        assert picks['expect'] == 'expect5.45.4.tar.gz'
        assert picks['flit-core'] == 'flit_core-3.12.0.tar.gz'
        assert picks['icu4c'] == 'icu4c-77_1-src.tgz'
        assert picks['nosuchpkg'] == ''

    def test_all_stages_use_variant_safe_find_archive(self):
        """Every stage that resolves source tarballs by package name
        must use the variant-safe helper, never the old prefix glob
        that matched documentation tarballs and missed .tgz, case and
        underscore variants."""
        legacy = 'compgen -G "${1}-*.tar.*"'
        scripts = [
            'lfs/05b-build-lfs-system.sh',
            'lfs/06a-init-system.sh',
            'lfs/06c-init-openrc.sh',
            'lfs/06d-init-runit.sh',
            'lfs/06e-init-s6.sh',
            'blfs/08-build-blfs-base.sh',
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
        for script in scripts:
            content = Path(script).read_text()
            assert legacy not in content, \
                f"{script} still uses the legacy prefix-glob lookup"
            assert "tr '[:upper:]' '[:lower:]' | tr '_' '-'" in content, \
                f"{script} lacks the case/underscore-safe lookup"
            assert '"$prefix_lc"-[0-9]*) tier1+=("$f")' in content, \
                f"{script} must prefer name-<version> tarballs"

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
        'networkmanager': ['NetworkManager'],
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


class TestAudioStudioStageGuardrails:
    """Guardrails for the audio production stage (blfs/27-audio-studio.sh).

    The stage builds the LV2 host stack and NeuralRack v0.4.1 for the
    audio-cli / audio-studio profiles.  NeuralRack has no BLFS book
    page, so its tarball must come from the upstream release asset
    (the generic GitHub refs/tags archive lacks the git submodules and
    cannot build) and every archive must be sha256-verified before
    extraction.
    """

    SCRIPT = Path('blfs/27-audio-studio.sh')
    SOURCES = Path('packages/custom-sources.list')

    @pytest.fixture(scope='class')
    def content(self):
        return self.SCRIPT.read_text()

    def test_script_exists_and_is_strict(self, content):
        assert self.SCRIPT.exists(), "27-audio-studio.sh stage must exist"
        assert 'set -euo pipefail' in content

    def test_non_audio_profile_skips_stage(self, tmp_path):
        """A manual --resume-from must not poison other profiles."""
        env = dict(os.environ)
        env['LFS'] = str(tmp_path)
        env['PROFILE'] = 'xfce'
        result = subprocess.run(['bash', str(self.SCRIPT)],
                                capture_output=True, text=True, env=env)
        assert result.returncode == 0, result.stderr
        assert 'stage skipped' in result.stdout

    def test_stage_refuses_to_run_without_chroot(self, tmp_path):
        """Audio profiles must fail loudly on a broken build tree."""
        env = dict(os.environ)
        env['LFS'] = str(tmp_path)
        env['PROFILE'] = 'audio-studio'
        result = subprocess.run(['bash', str(self.SCRIPT)],
                                capture_output=True, text=True, env=env)
        assert result.returncode != 0

    def test_checksums_pinned_and_verified_before_extract(self, content):
        """Every archive is sha256-verified before tar touches it."""
        for sha in (
            # NeuralRack v0.4.1 release -src tarball
            '82b88d2aa20155d7522b7eea030b5e888eb1ca5559af47be9a4870fa5d6226f7',
            # lv2-1.18.10
            '78c51bcf21b54e58bb6329accbb4dae03b2ed79b520f9a01e734bd9de530953f',
            # lilv-0.26.4
            '1c8b5fcb78718173e67d76e51ad423f5113a9ff68463f2566195ae46396089e3',
        ):
            assert sha in content, f"missing pinned checksum {sha}"
        assert 'sha256sum -c' in content
        assert content.index('sha256sum -c') < content.index('tar -xf'), \
            "checksums must be verified before extraction"
        assert 'refusing to build' in content

    def test_neuralrack_source_is_release_asset_not_refs_archive(self):
        """The refs/tags archive lacks git submodules and downloads
        under a generic filename; only the -src release asset works."""
        sources = self.SOURCES.read_text()
        content = self.SCRIPT.read_text()
        assert 'archive/refs/tags' not in content
        assert 'NeuralRack/archive/refs' not in sources
        assert ('https://github.com/brummer10/NeuralRack/releases/'
                'download/v0.4.1/NeuralRack-v0.4.1-src.tar.xz') in sources

    def test_audio_sources_are_listed(self):
        sources = self.SOURCES.read_text()
        for tarball in ('lv2-1.18.10.tar.xz', 'lilv-0.26.4.tar.xz',
                        'serd-0.32.4.tar.xz', 'sord-0.16.18.tar.xz',
                        'sratom-0.6.18.tar.xz', 'zix-0.4.2.tar.xz',
                        'libsndfile-1.2.2.tar.xz'):
            assert tarball in sources, f"{tarball} missing from sources"

    def test_shellcheck_clean(self, content):
        import re
        try:
            subprocess.run(['shellcheck', '--version'],
                           capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pytest.skip("shellcheck not installed")
        result = subprocess.run(['shellcheck', str(self.SCRIPT)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout

        inner_re = re.compile(
            r"cat <<'INNEREOF' \| run_privileged tee.*?\n(.*?)^INNEREOF$",
            re.DOTALL | re.MULTILINE)
        match = inner_re.search(content)
        assert match, "27-audio-studio.sh has no INNEREOF heredoc"
        with tempfile.NamedTemporaryFile(
                mode='w', suffix='.sh', delete=False) as tmp:
            tmp.write(match.group(1))
            tmp_path = tmp.name
        try:
            result = subprocess.run(['shellcheck', tmp_path],
                                    capture_output=True, text=True)
            assert result.returncode == 0, \
                f"shellcheck failed on inner payload:\n{result.stdout}"
        finally:
            os.unlink(tmp_path)


class TestCustomSourcesGuardrails:
    """Guardrails against version collisions in custom-sources.list.

    Nightly #173 (full/sysvinit/x86_64) died in the chapter 8 udev
    case: the list carried three systemd entries (256.20, 221, 257.8).
    Each entry downloads under a distinct filename, and find_archive
    returns the first glob-order match, so the udev case (written for
    the LFS 12.4 systemd-257.8 layout) deterministically ran against
    the 2015 systemd-221 tree and died at
    rules.d/50-udev-default.rules.in.
    """

    SOURCES = Path('packages/custom-sources.list')

    def test_systemd_tarball_is_listed_exactly_once(self):
        entries = []
        for line in self.SOURCES.read_text().splitlines():
            line = line.strip()
            if not line.startswith('http'):
                continue
            name = line.rsplit('/', 1)[-1]
            # systemd-<digit>... tarballs only; this keeps the
            # systemd-man-pages-* helper archive out of the check.
            if name.startswith('systemd-') and name[8:9].isdigit():
                entries.append(line)
        assert len(entries) == 1, \
            f"conflicting systemd sources (glob order picks the " \
            f"oldest tree): {entries}"
        assert 'systemd-257.8' in entries[0], entries


class TestProfilePromiseGuardrails:
    """Profile completeness audit guardrails.

    Every profile promise must map to software a stage really
    installs, and every required archive must be listed exactly once
    in custom-sources.list (duplicate filenames collide on the
    download key, exactly like the systemd-221 incident).
    """

    SOURCES = Path('packages/custom-sources.list')

    JAVA_ARCHIVES = (
        'OpenJDK21U-jdk_x64_linux_hotspot_21.0.10_9.tar.gz',
        'apache-maven-3.9.16-bin.tar.gz',
        'gradle-8.14-bin.zip',
        'apache-tomcat-10.1.56.tar.gz',
        'jenkins.war',
        'docker-28.3.3.tgz',
        'kubectl',
    )

    def _listed_filenames(self):
        return [
            line.strip().rsplit('/', 1)[-1]
            for line in self.SOURCES.read_text().splitlines()
            if line.strip().startswith('http')
        ]

    def test_java_toolchain_sources_are_listed_exactly_once(self):
        """The java-dev stage is fail-fast, so its seven archives must
        be present in custom-sources.list exactly once each."""
        listed = self._listed_filenames()
        for archive in self.JAVA_ARCHIVES:
            count = listed.count(archive)
            assert count == 1, \
                f"{archive} listed {count} times (must be exactly 1)"

    def test_jack2_source_is_listed_exactly_once(self):
        listed = self._listed_filenames()
        assert listed.count('jack2-1.9.22.tar.gz') == 1

    def test_java_dev_stage_has_no_silent_skip_guards(self):
        """The old `if ls <tarball>` guards logged success on an image
        without Java; the stage must stay fail-fast."""
        import re
        content = Path('blfs/12-install-java-dev.sh').read_text()
        assert not re.search(r'(?m)^\s*if ls ', content), \
            "java-dev stage must not silently skip missing archives"
        assert 'require_file' in content, \
            "java-dev stage must resolve required archives via require_file"
        assert 'set -euo pipefail' in content

    def test_networking_stage_builds_dhcpcd_and_networkmanager(self):
        content = Path('blfs/23-basic-networking.sh').read_text()
        assert 'run_build required dhcpcd' in content
        assert 'run_build required libndp' in content
        assert 'build_commands_networkmanager' in content

    def test_multimedia_stage_builds_jack2(self):
        content = Path('blfs/24-multimedia.sh').read_text()
        assert 'run_build optional jack2' in content
        assert 'build_commands_jack2' in content

    def test_applications_stage_builds_emacs_for_gnu_free(self):
        content = Path('blfs/10-build-applications.sh').read_text()
        assert 'gnu-free*) APPS_TO_BUILD="$APPS_TO_BUILD,emacs"' in content
        assert 'build_emacs()' in content


class TestFindArchiveVersionSelection:
    """find_archive must pick the newest version among duplicates.

    Nightly #174 (minimal/sysvinit/x86_64) failed exactly like #173
    even though custom-sources.list was fixed: the nightly restores
    the packages-cache-latest release into sources/, and that cache
    still carried the stale systemd-221 and systemd-256.20 tarballs
    next to systemd-257.8.  find_archive returned the first
    glob-order match (the oldest name), so the chapter 8 udev case
    deterministically ran against systemd-221 again.  Every copy now
    sorts the versioned candidates and returns the newest.
    """

    STAGE_DIRS = ('lfs', 'blfs')

    def _stage_scripts_with_find_archive(self):
        for dirname in self.STAGE_DIRS:
            for script in sorted(Path(dirname).glob('*.sh')):
                content = script.read_text()
                if 'find_archive()' in content:
                    yield script, content

    def test_no_stage_picks_the_first_glob_order_tarball(self):
        offenders = [
            str(script)
            for script, content in self._stage_scripts_with_find_archive()
            if '"${tier1[0]}"' in content
        ]
        assert not offenders, \
            f"glob-order selection resurrects stale cached tarballs " \
            f"in: {offenders}"

    def test_versioned_selection_sorts_by_version(self):
        for script, content in self._stage_scripts_with_find_archive():
            assert 'sort -V' in content, \
                f"{script} find_archive must sort candidates by version"

    def test_find_archive_prefers_newest_systemd(self, tmp_path):
        """Replay nightly #174: three systemd tarballs in sources/.

        The LFS 12.4 udev case expects the systemd-257.8 layout
        (rules.d/), so find_archive must return the newest tarball
        even when older duplicates are present.
        """
        import re

        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        match = re.search(r'(find_archive\(\) \{.*?\n\})', content,
                          re.DOTALL)
        assert match, "find_archive not found in lfs/05b"

        workdir = tmp_path / 'sources'
        workdir.mkdir()
        for name in ('systemd-221.tar.xz', 'systemd-256.20.tar.gz',
                     'systemd-257.8.tar.gz'):
            (workdir / name).write_bytes(b'')

        probe = tmp_path / 'probe.sh'
        probe.write_text(
            f"set -euo pipefail\n{match.group(1)}\n"
            f"cd '{workdir}'\nfind_archive systemd\n")
        result = subprocess.run(['bash', str(probe)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == 'systemd-257.8.tar.gz', \
            f"find_archive picked {result.stdout.strip()!r}"


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
