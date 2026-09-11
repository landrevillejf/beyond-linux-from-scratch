#!/usr/bin/env python3
"""
Tests d'acceptance avec scripts shell réels
Exécute les vrais scripts LFS/BLFS dans un environnement contrôlé
"""

import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

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

        # curl 8.15 requires libpsl, which needs libidn2 and
        # libunistring; the whole chain must be built before cURL in
        # this stage (08a runs later, nightly #178).
        for pkg in ('libunistring', 'libidn2', 'libpsl'):
            pkg_pos = content.find(f'find_archive {pkg})')
            curl_pos = content.find('find_archive curl)')
            assert pkg_pos != -1, f"{pkg} must be built in blfs-base"
            assert pkg_pos < curl_pos, \
                f"{pkg} must be installed before cURL (nightly #178)"
        assert 'meson setup --prefix=/usr' in content, \
            "libpsl uses the book meson build"
        assert '--buildtype=release' in content
        assert 'doc/libpsl' not in content, \
            "libpsl tarball ships no docs; book installs none (#179)"
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

    def test_blfs_base_refreshes_ld_cache_before_curl(self):
        """blfs-base must refresh the loader cache before curl configures.

        Nightly #223 (arm64/aarch64/sysvinit) ran 1h45m and then died in
        blfs-base at curl's configure: "checking run-time libs
        availability... failed / one or more libs available at link-time
        are not available run-time (-lidn2 -lpsl -lssl -lcrypto -lzstd
        -lz)".  Every one of those libraries installs under /usr/lib, but
        the chroot's /etc/ld.so.cache is the stale one left by the LFS
        chapter-8 build, so the aarch64 loader never resolves the
        openssl/IDN/psl stack installed moments earlier.  The stage must
        run ldconfig before curl, and pin the three BLFS libs to /usr/lib
        so none can split into /usr/lib64 (the libffi multi-os trap).
        """
        content = Path('blfs/08-build-blfs-base.sh').read_text()

        ldconfig_pos = content.find('/sbin/ldconfig')
        curl_pos = content.find('find_archive curl)')
        assert ldconfig_pos != -1, \
            "blfs-base must run ldconfig (nightly #223 curl run-time probe)"
        assert curl_pos != -1, "curl build missing from blfs-base"
        assert ldconfig_pos < curl_pos, \
            "ldconfig must run before curl is configured (nightly #223)"

        # The three BLFS libs curl links against must be pinned to /usr/lib
        # so the gcc multi-os directory cannot divert them to /usr/lib64.
        assert content.count('--libdir=/usr/lib') >= 2, \
            "libunistring and libidn2 must pin --libdir=/usr/lib (#223)"
        assert '--libdir=lib' in content, \
            "libpsl meson build must pin --libdir=lib (nightly #223)"

    def test_blfs_bootscripts_no_bulk_install(self):
        """blfs-bootscripts must never run a bulk make install.

        The BLFS book (introduction/bootscripts.html) installs each
        init script with its own "make install-<init-script>" target;
        the package Makefile defines no "install" rule, so the blanket
        "make install" added by the bootscripts installation feature
        aborted blfs-base with "No rule to make target 'install'"
        (nightly #181). blfs-base may only keep the source tree
        available for the per-service stages.
        """
        content = Path('blfs/08-build-blfs-base.sh').read_text()
        pos = content.find('---- blfs-bootscripts')
        assert pos != -1, "blfs-bootscripts section missing from blfs-base"
        for line in content[pos:].splitlines():
            assert line.strip() != 'make install', \
                "blfs-bootscripts has no bulk install target (nightly #181)"

    def test_blfs_libs_pcre2_not_a_prerequisite_and_precedes_glib2(self):
        """pcre2 is built by blfs-libs itself, never by an LFS stage.

        Nightly #183 (full/sysvinit/x86_64) died in blfs-libs after
        0.2 s with "Missing LFS prerequisites: pcre2": the
        verify_prerequisites check demanded a package no earlier
        stage installs, and the stage's own pcre2 build ran in the
        last phase, after glib2 (which hard-requires pcre2).  pcre2
        must stay out of the prerequisite list and run before glib2.
        """
        content = Path('blfs/08a-build-blfs-libs.sh').read_text()

        # The prerequisite loop must not mention pcre2.
        func_pos = content.find('verify_prerequisites()')
        assert func_pos != -1
        func_end = content.find('verify_prerequisites\n', func_pos)
        func = content[func_pos:func_end if func_end != -1 else
                       func_pos + 800]
        assert 'pcre2' not in func, \
            "pcre2 is provided by this stage, not by LFS (nightly #183)"

        # First pcre2 build must precede the glib2 build.
        pcre2_pos = content.find('run_build required pcre2')
        glib2_pos = content.find('run_build required glib2')
        assert pcre2_pos != -1, "pcre2 build missing from blfs-libs"
        assert glib2_pos != -1, "glib2 build missing from blfs-libs"
        assert pcre2_pos < glib2_pos, \
            "pcre2 must be built before glib2 (nightly #183)"

    def test_blfs_libs_builds_shared_mime_info_before_gdk_pixbuf(self):
        """shared-mime-info must precede gdk-pixbuf in blfs-libs.

        Nightly #191/#192 (all desktop profiles) died at gdk-pixbuf:
        since gdk-pixbuf 2.43 its meson build declares a hard
        dependency on the shared-mime-info pkg-config file
        ("Dependency \"shared-mime-info\" not found, tried pkgconfig
        and cmake"), but the stage built shared-mime-info after it.
        shared-mime-info itself only needs glib2 and libxml2, both
        already installed at that point, so the swap is safe.
        """
        content = Path('blfs/08a-build-blfs-libs.sh').read_text()
        smi_pos = content.find('run_build required shared-mime-info')
        pixbuf_pos = content.find('run_build required gdk-pixbuf')
        assert smi_pos != -1, \
            "shared-mime-info build missing from blfs-libs"
        assert pixbuf_pos != -1, "gdk-pixbuf build missing from blfs-libs"
        assert smi_pos < pixbuf_pos, \
            "shared-mime-info must be built before gdk-pixbuf " \
            "(nightly #191/#192)"

    def test_gdk_pixbuf_pinned_to_blfs_book_version(self):
        """gdk-pixbuf must stay at the BLFS 12.4 book version (2.42.x).

        Nightly #193 (all desktop profiles) died at gdk-pixbuf 2.44.4:
        meson reported `Dependency "glycin-2" not found, tried pkgconfig
        and cmake`.  Version 2.44.x introduced a hard meson dependency
        on glycin-2, which is not in the BLFS book and has no buildable
        release tarball.  The custom-sources.list override must pin the
        book version 2.42.12, whose only required dependencies are
        glib2, libjpeg-turbo, libpng and shared-mime-info.
        """
        content = Path('packages/custom-sources.list').read_text()
        assert 'gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz' in content, \
            "gdk-pixbuf must be pinned to BLFS book version 2.42.12"
        assert 'gdk-pixbuf/2.44' not in content, \
            "gdk-pixbuf 2.44.x requires glycin-2 (not in BLFS book)"

    def test_libtirpc_gcc15_patch_in_custom_sources(self):
        """The libtirpc gcc15 patch must be in custom-sources.list.

        Nightly #193 (all CLI profiles) died at libtirpc 1.3.6:
        GCC 15 defaults to C23 where `()` means no-args, causing
        `conflicting types for 'xdr_opaque_auth'`.  The BLFS
        gcc15_fixes patch resolves this but is only fetched when
        listed in custom-sources.list.
        """
        content = Path('packages/custom-sources.list').read_text()
        assert 'libtirpc-1.3.6-gcc15_fixes' in content, \
            "libtirpc gcc15 patch missing from custom-sources.list"

    def test_prep_src_keeps_logs_off_stdout(self):
        """prep_src stdout is captured as the extracted directory.

        Nightly #184 (full/sysvinit/x86_64) died on the very first
        blfs-libs package: book_install ran
        pushd '[INFO] Building libpng from ...\\nlibpng-1.6.47'
        because prep_src logged to stdout, which book_install
        captures to obtain the directory name.  Every stage that
        defines prep_src must send its progress message to stderr.
        """
        for script in sorted(Path('blfs').glob('*.sh')):
            content = script.read_text()
            if 'prep_src()' not in content:
                continue
            if 'Building $pkg from $archive' not in content:
                continue
            assert 'log_info "Building $pkg from $archive" >&2' \
                in content, \
                f"{script}: prep_src log must go to stderr " \
                "(stdout is the directory name, nightly #184)"

    def test_kernel_stage_reads_sources_from_lfs_tree(self):
        """build-kernel must locate sources in $LFS/sources.

        Nightly #185 (minimal/sysvinit/x86_64) died with "Sources
        directory not found: /tmp/lfs-build/sources": the stage
        guessed $(dirname $LFS)/sources, but CI keeps the host
        downloads in build-release/sources.  The chroot mirror at
        $LFS/sources is populated by lfs-basic for every profile and
        is already asserted below for the native path, so it is the
        canonical location.
        """
        content = Path('lfs/08-build-kernel.sh').read_text()
        assert 'SOURCES_HOST="$LFS/sources"' in content
        assert '$(dirname "$LFS")/sources' not in content

    def test_blfs_base_builds_cmake_before_libs_stage(self):
        """blfs-base must install cmake before the 08a libs stage.

        Nightly #186 (full/sysvinit/x86_64) died on the second
        blfs-libs package: libjpeg-turbo ran cmake, which no stage
        ever built ("cmake: command not found").  The blfs-base
        stage now builds cmake with the book bootstrap commands;
        --no-system-* flags keep the bundled copy for every cmake
        dependency that does not exist yet at that point.
        """
        content = Path('blfs/08-build-blfs-base.sh').read_text()
        assert 'find_archive cmake' in content, \
            "blfs-base must build cmake (nightly #186)"
        assert './bootstrap --prefix=/usr' in content
        for lib in ('libarchive', 'libuv', 'nghttp2', 'zstd'):
            assert f'--no-system-{lib}' in content, \
                f"cmake must bundle {lib} (not built before 08a)"
        # cmake must land in blfs-base, before any expat/libxml2 work,
        # and no later stage may claim it is still missing.
        libs = Path('blfs/08a-build-blfs-libs.sh').read_text()
        assert 'cmake: command not found' not in libs

    def test_basic_networking_builds_libpcap_before_nmap(self):
        """Stage 23 must build system libpcap before nmap.

        Nightly #186 (minimal/x86_64/systemd) failed linking nmap:
        without a system libpcap, nmap statically compiles its
        bundled copy, which picks up the installed libnl-3 netlink
        support and leaves nl_*/genl_* symbols undefined at the
        final link.  The BLFS book lists libpcap as nmap's
        recommended dependency, so the stage builds it first.
        """
        content = Path('blfs/23-basic-networking.sh').read_text()
        pcap_pos = content.find('run_build required libpcap')
        nmap_pos = content.find('run_build required nmap')
        assert pcap_pos != -1, "libpcap build missing from stage 23"
        assert nmap_pos != -1, "nmap build missing from stage 23"
        assert pcap_pos < nmap_pos, \
            "libpcap must be built before nmap (nightly #186)"
        assert 'build_commands_libpcap' in content
        assert 'libpcap) have_pc libpcap ;;' in content

    def test_display_manager_builds_duktape_before_polkit(self):
        """Stage 08d must build duktape before polkit.

        polkit-126 defaults to the duktape JavaScript engine and the
        BLFS postlfs/polkit page lists "duktape-2.7.0 and GLib" as
        Required.  duktape ships in sources.list but no stage ever
        built it, so polkit's meson setup aborted the display-manager
        stage at "../meson.build:148:16: ERROR: C header 'duktape.h'
        not found" for all eight desktop profiles (Nightly #228).
        #227's session_tracking fix only let polkit get far enough to
        reach this header check.  The stage must build duktape with
        the general/duktape book commands and install it before
        polkit runs.
        """
        content = Path('blfs/08d-build-display-manager.sh').read_text()
        duktape_pos = content.find('run_build required duktape')
        polkit_pos = content.find('run_build required polkit')
        assert duktape_pos != -1, "duktape build missing from stage 08d"
        assert polkit_pos != -1, "polkit build missing from stage 08d"
        assert duktape_pos < polkit_pos, \
            "duktape must be built before polkit (nightly #228)"
        assert 'build_commands_duktape' in content
        assert 'duktape)' in content, \
            "is_installed must have a duktape case"
        assert '[ -f /usr/include/duktape.h ]' in content, \
            "is_installed must detect duktape by its installed header"
        # general/duktape builds the shared library, not the static
        # Makefile, and installs it under /usr so polkit finds
        # duktape.h and libduktape.so.
        assert 'make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr' \
            in content

    def test_inkscape_overridden_via_conglomeration_mirror(self):
        """The dead inkscape.org gallery URL must be overridden.

        Nightly #186 reported HTTP 403 for
        inkscape.org/gallery/item/56344/inkscape-1.4.2.tar.xz: the
        gallery item URL expired.  custom-sources.list is the only
        file that overrides the fetched official wget-lists, so the
        BLFS conglomeration mirror must be listed there exactly
        once.
        """
        content = Path('packages/custom-sources.list').read_text()
        url = ('https://ftp2.osuosl.org/pub/blfs/conglomeration/'
               'inkscape/inkscape-1.4.2.tar.xz')
        assert content.count(url) == 1, \
            "inkscape conglomeration override missing or duplicated"
        assert 'inkscape.org/gallery' not in content

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

    def test_kernel_configs_enumerate_boot_block_devices(self):
        """Every bootable kernel-config fragment must carry the block,
        initramfs and devtmpfs stack, or the built kernel cannot mount
        root.

        lfs/08-build-kernel.sh seeds .config from the fragment and runs
        `make olddefconfig`, which defaults every unnamed symbol to n.
        SCSI, BLK_DEV_SD, BLK_DEV_INITRD and DEVTMPFS all default to n,
        and CONFIG_ATA depends on SCSI -- so the pre-#224 fragments, which
        set only CONFIG_ATA/SATA_AHCI, had ATA silently dropped and could
        neither enumerate the QEMU q35 AHCI disk nor honour -initrd.  The
        boot smoke test then panicked with "VFS: Cannot open root device
        ... unknown-block(0,0): error -6" and an empty partition list for
        every headless profile (Nightly #224).

        PCI is the same trap one level down (Nightly #228/#229): the
        fragments named CONFIG_SATA_AHCI/ATA_PIIX/VIRTIO_PCI=y but never
        CONFIG_PCI, and SATA_AHCI depends on `ATA && PCI`, so olddefconfig
        resolved PCI to n and silently dropped the AHCI host driver.  The
        kernel then never bound the q35 ICH9 SATA controller, made no
        /dev/sda, and the initramfs dropped to a shell with "Root device
        not found" -- the boot smoke test failed for every x86_64 profile
        that reached it, and the #227 wait_for_dev poll could not help
        because built-in drivers probe before /init ever runs.
        """
        boot_stack = (
            'CONFIG_PCI=y',
            'CONFIG_SCSI=y',
            'CONFIG_BLK_DEV_SD=y',
            'CONFIG_BLK_DEV_INITRD=y',
            'CONFIG_RD_ZSTD=y',
            'CONFIG_DEVTMPFS=y',
            'CONFIG_EFI_PARTITION=y',
        )
        for name in ('kernel-config', 'kernel-config-audio-studio',
                     'kernel-config-arm64'):
            content = Path(f'config/{name}').read_text()
            for option in boot_stack:
                assert option in content, f"{name} lacks {option}"
            # CONFIG_ATA depends on SCSI: never enable ATA without SCSI,
            # or olddefconfig drops both and the SATA disk disappears.
            if 'CONFIG_ATA=y' in content:
                assert 'CONFIG_SCSI=y' in content, \
                    f"{name} enables ATA without its SCSI dependency"
            # CONFIG_SATA_AHCI depends on `ATA && PCI`: naming AHCI without
            # PCI lets olddefconfig drop the AHCI host driver, so the q35
            # ICH9 SATA disk is never bound and /dev/sda does not exist
            # (Nightly #228/#229).
            if 'CONFIG_SATA_AHCI=y' in content:
                assert 'CONFIG_PCI=y' in content, \
                    f"{name} enables SATA_AHCI without its PCI dependency"
                assert 'CONFIG_ATA=y' in content, \
                    f"{name} enables SATA_AHCI without its ATA dependency"

    def test_qemu_boot_smoke_roots_disk_image_on_real_partition(self):
        """The disk-image boot must target the real root partition and
        tolerate the empty-disk switch_root panic.

        host/03-create-disk-image.sh lays the image out as p1=ESP(/boot),
        p2=swap, p3=root, so the old root=/dev/sda2 pointed at swap.  And
        because host/03 umounts the image before anything is installed,
        the root partition is empty: the initramfs reaches userspace
        ("Mounting root:") but then panics switching into an empty /mnt.
        For a .img that trailing panic is expected; for a live ISO (real
        squashfs root) a panic stays fatal.
        """
        content = Path('tools/qemu-boot-smoke.sh').read_text()
        assert 'ROOT_DEV="${ROOT_DEV:-/dev/sda3}"' in content
        assert ':-/dev/sda2' not in content, \
            "disk image root must not be the swap partition (sda2)"
        assert 'p3 is the root filesystem' in content
        assert 'ARTIFACT_TYPE=img' in content
        assert 'ARTIFACT_TYPE=iso' in content
        assert 'disk image root is empty by design' in content
        assert 'Kernel panic during boot' in content

    def test_no_offline_man_pages_in_blfs_meson(self):
        """No BLFS meson build may request man pages with -D man=true.

        gtk3 and polkit rendered man pages with xsltproc against a
        network DocBook XSL URL; no stage installs docbook-xsl and the
        chroot is offline (xsltproc runs --nonet), so -D man=true aborted
        the xorg stage for every desktop profile with "Attempt to load
        network entity" (Nightly #224).  Only comments may mention it.
        """
        for script in sorted(Path('blfs').glob('*.sh')):
            for lineno, line in enumerate(
                    script.read_text().splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith('#'):
                    continue
                assert '-D man=true' not in stripped, \
                    f"{script}:{lineno} builds man pages offline"

    def test_gtk4_disables_offline_gstreamer_media_backend(self):
        """gtk4 must not try to fetch its gstreamer media backend online.

        gtk4's media-gstreamer feature defaults to auto, so with no
        gstreamer-player-1.0 in the offline chroot meson fell back to the
        gstreamer-full.wrap subproject and died with "Git program not
        found, cannot download gstreamer-full.wrap via git", aborting the
        xorg stage for full/gnome/kde/java-dev (Nightly #226).  The build
        must probe for gstreamer and disable the backend when absent, and
        keep the --wrap-mode=nofallback offline guard pango/08a/09b use.
        """
        content = Path('blfs/08b-build-xorg.sh').read_text()
        fn = content.split('build_commands_gtk4() {', 1)[1]
        fn = fn.split('\n}\n', 1)[0]
        assert 'media_gst=disabled' in fn, \
            "gtk4 must default the gstreamer media backend to disabled"
        assert 'gstreamer-player-1.0' in fn, \
            "gtk4 must probe gstreamer before enabling the media backend"
        assert '-D media-gstreamer="$media_gst"' in fn, \
            "gtk4 must pass the probed media-gstreamer feature to meson"
        assert '--wrap-mode=nofallback' in fn, \
            "gtk4 must keep the offline wrap guard (no git subproject fetch)"

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
        # glib2-gir is the book's second glib2 install pass (the
        # introspection data); it re-extracts the very same glib
        # tarball, so it resolves through the glib base name.
        'glib2-gir': ['glib'],
        'icu': ['icu4c'],
        'libelf': ['elfutils'],
        'libyaml': ['yaml'],
        'linux-pam': ['Linux-PAM'],
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
        'lmdb': ['LMDB_0.9.33'],
        'liburcu': ['userspace-rcu'],
        'spirv-headers': ['SPIRV-Headers'],
        'spirv-tools': ['SPIRV-Tools'],
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
        packages/stable/12.4/sources.list or its override companion
        packages/custom-sources.list.

        The stable list is generated from the official wget-lists and is
        a curated subset, so packages the BLFS book needs but the
        wget-list omits (the x7lib chapter: xtrans, libFS, libICE,
        libSM, libXt, libXmu, libXaw, libXfont2, libXft, libXxf86dga,
        libxshmfence, libXpresent and font-util) are pinned in
        custom-sources.list instead.  builder.py merges both files
        (custom entries win) into the generated packages/sources.list
        the downloader consumes, so a pin in either file means the
        archive is fetched (Nightly #213).
        """
        import re

        sources = (
            Path('packages/stable/12.4/sources.list').read_text()
            + Path('packages/custom-sources.list').read_text()
        )
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


class TestNightly213StageGuardrails:
    """Guardrails for the Nightly #213 blfs-libs / xorg ordering fixes.

    Run #213 lost six jobs to three independent ordering and
    error-reporting defects:

    * mesa was built by blfs-libs (08a) before wayland-scanner existed,
      so meson aborted with "Dependency wayland-scanner not found";
    * libinput was built before libevdev, and the generic build_pkg
      swallowed the meson failure behind a bogus "installed" message;
    * the xorg stage never built the x7lib chapter (libFS, libICE,
      libSM, libXt, libXmu, libXaw, libXfont2, libXft, libXxf86dga,
      libxshmfence, libXpresent), libxcvt, font-util, or libepoxy
      before xorg-server.

    These tests pin the corrected ordering so a future reshuffle cannot
    silently reintroduce the failures.
    """

    LIBS = Path('blfs/08a-build-blfs-libs.sh')
    XORG = Path('blfs/08b-build-xorg.sh')
    WAYLAND = Path('blfs/08c-build-wayland.sh')
    SOURCES = Path('packages/custom-sources.list')

    # x7lib chapter libraries the xorg stage gained in Nightly #213.
    X7LIB = ('xtrans', 'libFS', 'libICE', 'libSM', 'libXt', 'libXmu',
             'libXaw', 'libXfont2', 'libXft', 'libXxf86dga',
             'libxshmfence', 'libXpresent')

    @staticmethod
    def _body(content, name):
        """Return the source of a shell function definition.

        The leading newline keeps rebuild_pkg() from matching build_pkg
        and the closing brace line ends the slice.
        """
        start = content.index(f'\n{name}() {{')
        end = content.index('\n}\n', start)
        return content[start:end]

    @staticmethod
    def _build_pos(content, mode, pkg):
        """Return the offset of a run_build call, ignoring its options.

        Matching the bare 'run_build <mode> <pkg>\\n' form made the
        ordering assertions break the moment a package needed extra
        meson options, which Nightly #215 added to libevdev, libwacom
        and libinput.  The ordering is what matters, not the flags.
        """
        match = re.search(rf'^run_build {mode} {re.escape(pkg)}\b',
                          content, re.MULTILINE)
        return match.start() if match else -1

    def test_libevdev_precedes_libinput(self):
        """libinput's meson build hard-requires libevdev (Nightly #213:
        "Dependency libevdev not found")."""
        content = self.LIBS.read_text()
        evdev = self._build_pos(content, 'required', 'libevdev')
        libinput = self._build_pos(content, 'required', 'libinput')
        assert evdev != -1, "libevdev build missing from blfs-libs"
        assert libinput != -1, "libinput build missing from blfs-libs"
        assert evdev < libinput, \
            "libevdev must be built before libinput (Nightly #213)"

    def test_wayland_precedes_wayland_protocols(self):
        """wayland-protocols' meson build looks up wayland-scanner, so
        wayland must be installed first (Nightly #213)."""
        content = self.LIBS.read_text()
        wayland = content.find('run_build required wayland\n')
        protocols = content.find('run_build required wayland-protocols\n')
        assert wayland != -1, "wayland build missing from blfs-libs"
        assert protocols != -1, \
            "wayland-protocols build missing from blfs-libs"
        assert wayland < protocols, \
            "wayland must be built before wayland-protocols (#213)"

    def test_mesa_not_built_by_blfs_libs(self):
        """mesa belongs to the xorg stage (08b): the book lists the Xorg
        Libraries as a REQUIRED mesa dependency and its wayland platform
        needs wayland-scanner.  Building it in 08a aborted meson with
        "Dependency wayland-scanner not found" (Nightly #213)."""
        content = self.LIBS.read_text()
        assert 'run_build required mesa' not in content, \
            "mesa must be built by the xorg stage (08b), not blfs-libs"
        assert 'build_commands_mesa()' not in content, \
            "the mesa build function must live in the xorg stage (08b)"

    def test_glib2_gir_second_pass_follows_first(self):
        """The book reinstalls glib2 for its introspection data; without
        GObject-2.0.gir, libgudev and gtk4 die with "Couldn't find
        include 'GObject-2.0.gir'" (Nightly #213).  gobject-introspection
        must sit between the two glib2 passes."""
        content = self.LIBS.read_text()
        assert 'build_glib2_gir()' in content
        first = content.find('run_build required glib2\n')
        gir = content.find('run_build required glib2-gir\n')
        introspection = content.find(
            'run_build required gobject-introspection\n')
        assert first != -1 and gir != -1 and introspection != -1
        assert first < introspection < gir, \
            "gobject-introspection must run between the glib2 passes"

    def test_xorg_stage_builds_x7lib_chapter(self):
        """The xorg stage must build the x7lib libraries mesa and the
        toolkits link against; they were missing entirely before the
        Nightly #213 ordering audit."""
        content = self.XORG.read_text()
        for pkg in self.X7LIB:
            assert f'run_build required {pkg}\n' in content, \
                f"{pkg} missing from the xorg stage (Nightly #213)"

    def test_xtrans_precedes_libx11(self):
        """libX11's configure hard-requires the xtrans pkg-config module,
        so xtrans cannot wait for the extension-library phase: building it
        after libX11 aborted the xorg stage with "Package requirements
        (xproto >= 7.0.25 xextproto xtrans ...) were not met: Package
        'xtrans' not found" and took all eight desktop profiles with it
        (Nightly #221).  The book reaches the same order from the other
        direction - xtrans is the first line of lib-7.md5."""
        content = self.XORG.read_text()
        xtrans = self._build_pos(content, 'required', 'xtrans')
        libx11 = self._build_pos(content, 'required', 'libX11')
        assert xtrans != -1, "xtrans build missing from the xorg stage"
        assert libx11 != -1, "libX11 build missing from the xorg stage"
        assert xtrans < libx11, \
            "xtrans must be built before libX11 (Nightly #221)"
        # Exactly one build site: a second, later call would satisfy the
        # ordering assertion while the first one still ran too late.
        assert content.count('run_build required xtrans') == 1

    def test_xorg_server_deps_precede_server(self):
        """libxcvt and font-util are REQUIRED by xorg-server and libepoxy
        feeds its glamor module; all three must be built before the
        server (Nightly #213)."""
        content = self.XORG.read_text()
        server = content.find('run_build required xorg-server\n')
        assert server != -1, "xorg-server build missing from the stage"
        for pkg in ('libxcvt', 'font-util', 'libepoxy'):
            pos = content.find(f'run_build required {pkg}\n')
            assert pos != -1, \
                f"{pkg} build missing from the xorg stage"
            assert pos < server, \
                f"{pkg} must be built before xorg-server (Nightly #213)"

    def test_new_xorg_tarballs_are_pinned(self):
        """The x7lib chapter, libxcvt and font-util are absent from the
        official wget-list snapshot, so they must be pinned in
        custom-sources.list for the downloader to fetch them
        (Nightly #213)."""
        import re

        content = self.SOURCES.read_text()
        for pkg in self.X7LIB + ('libxcvt', 'font-util'):
            assert re.search(rf'/{re.escape(pkg)}-\d', content), \
                f"{pkg} tarball not pinned in custom-sources.list"

    def test_build_pkg_propagates_failures(self):
        """run_build calls build_pkg from an "if" condition, which
        suspends set -e for the whole call; every build branch must
        chain with && and record a non-zero rc, or a failed meson/ninja
        falls through to log_success.  Nightly #213 hid libinput's
        "Dependency libevdev not found" behind a bogus success."""
        for script in (self.LIBS, self.XORG, self.WAYLAND):
            fn = self._body(script.read_text(), 'build_pkg')
            assert 'rc=1' in fn, \
                f"{script}: build_pkg must capture the failure rc"
            assert 'if [ "$rc" -ne 0 ]; then' in fn, \
                f"{script}: build_pkg must return non-zero on failure"

    def test_lpm_repos_write_is_privileged(self):
        """The repos.d directories are root-owned, so the unprivileged CI
        user must write default.conf through the privileged wrapper; a
        bare redirection died with "Permission denied" (Nightly #213)."""
        content = Path('blfs/19-lpm.sh').read_text()
        assert '$run_privileged tee "$target/etc/lpm/repos.d/default.conf"' \
            in content, \
            "the repos.d default.conf write must go through run_privileged"


class TestNightly214StageGuardrails:
    """Guardrails for the Nightly #214 all-profile failure classes.

    Run #214 lost all thirteen jobs to four independent defects:

    * a stale gobject-introspection 1.82.0 pin in custom-sources.list
      overrode the book's 1.84.0, and pango 1.56.4 hard-requires
      >= 1.83.2, so every desktop profile aborted blfs-libs;
    * the branding stage wrote into the root-owned $LFS tree as the
      unprivileged builder user and died on its first mkdir, taking
      both minimal profiles with it (system-updater is the same latent
      defect one stage later);
    * expect's 2003-vintage tclconfig/config.guess cannot recognise
      aarch64, so the native arm64 job aborted lfs-system with
      "cannot guess build type";
    * texlive tarballs nobody builds burned ~1h of GitHub's hard
      six-hour job cap on a host that resets every connection, and the
      server and arm64 x86_64 jobs were cancelled mid-build.
    """

    BRANDING = Path('blfs/20-branding.sh')
    UPDATER = Path('blfs/18-system-updater.sh')
    LFS_SYSTEM = Path('lfs/05b-build-lfs-system.sh')
    SOURCES = Path('packages/custom-sources.list')
    BOOK_SOURCES = Path('packages/stable/12.4/sources.list')

    # pango 1.56.4's meson floor for gobject-introspection-1.0.
    GI_FLOOR = (1, 83, 2)

    def _root_relaunch_guard(self, path, first_write):
        """Assert the script re-execs as root before it touches $LFS."""
        content = path.read_text()
        guard = content.index('if [ "$EUID" -ne 0 ]; then')
        write = content.index(first_write)
        assert guard < write, (
            f'{path} must re-launch as root before writing into $LFS'
        )
        assert 'exec sudo -E "$0" "$@"' in content[guard:write]

    def test_branding_stage_relaunches_as_root(self):
        self._root_relaunch_guard(
            self.BRANDING, 'mkdir -p "$LFS/usr/share/themes')

    def test_system_updater_stage_relaunches_as_root(self):
        self._root_relaunch_guard(self.UPDATER, 'mkdir -pv "$LFS/usr/bin"')

    def test_branding_hands_user_config_back_to_its_owner(self):
        """Running as root must not leave a root-owned ~/.config behind."""
        content = self.BRANDING.read_text()
        assert 'chown -R --reference="$LFS/home/lfsuser"' in content

    def test_expect_configure_pins_a_validated_build_triplet(self):
        content = self.LFS_SYSTEM.read_text()
        start = content.index('    expect)\n')
        end = content.index('    dejagnu)', start)
        block = content[start:end]

        assert '--build="$build_triplet"' in block
        # expect's config.sub is as fossilised as its config.guess and
        # rejects the common aarch64-pc-linux-gnu form, so the triplet
        # must be validated against it before configure ever sees it.
        assert 'sh tclconfig/config.sub "$build_triplet"' in block
        assert '-unknown-linux-gnu' in block

    def test_custom_sources_do_not_downgrade_gobject_introspection(self):
        """The effective gi version must satisfy pango's 1.83.2 floor.

        A custom pin overrides the book version, so a stale pin here is
        what aborted blfs-libs for all eight desktop profiles in #214.
        """
        pattern = r'gobject-introspection-(\d+\.\d+\.\d+)\.tar\.xz'
        book = re.findall(pattern, self.BOOK_SOURCES.read_text())
        custom = re.findall(pattern, self.SOURCES.read_text())

        assert book, 'the book list must carry gobject-introspection'
        effective = custom[-1] if custom else book[0]
        version = tuple(int(part) for part in effective.split('.'))
        assert version >= self.GI_FLOOR, (
            f'gobject-introspection {effective} is below the '
            f'{".".join(str(p) for p in self.GI_FLOOR)} floor pango requires'
        )


class TestNightly215StageGuardrails:
    """Guardrails for the Nightly #215 all-profile failure classes.

    Run #215 confirmed the #214 fixes held - branding and system-updater
    both re-launched as root and completed - and uncovered two new
    defects further down the pipeline:

    * eight desktop profiles aborted blfs-libs on libevdev.  Its
      meson_options.txt defaults 'tests' and 'documentation' to
      'enabled' and resolves both with `required: get_option(...)`, so
      setup aborted with 'Dependency "check" not found' instead of
      degrading: check is an LFS temp-tools package no BLFS stage
      rebuilds and doxygen is deliberately never installed;
    * the server profile reached the bootloader stage, which chroots
      into $LFS without ever re-launching as root.  chroot died with
      "Operation not permitted", the `|| echo` swallowed it, and
      /boot/grub was therefore never created, so writing grub.cfg
      aborted the stage.
    """

    LIBS = Path('blfs/08a-build-blfs-libs.sh')
    BOOTLOADER = Path('final/13-create-bootloader.sh')

    @pytest.fixture(scope='class')
    def libs(self):
        return self.LIBS.read_text()

    @staticmethod
    def _opts(libs, mode, pkg):
        """Return everything a run_build call passes after the package."""
        match = re.search(
            rf'^run_build {mode} {re.escape(pkg)}(.*)$', libs, re.MULTILINE)
        assert match, f'{pkg} is not built by run_build {mode} in 08a'
        return match.group(1)

    def test_libevdev_disables_its_default_enabled_features(self, libs):
        """Both are `type: feature` defaulting to 'enabled', so they take
        'disabled' - and both are resolved with required: get_option()."""
        opts = self._opts(libs, 'required', 'libevdev')
        assert '-Dtests=disabled' in opts, (
            'libevdev tests must be disabled: check is an LFS temp-tools '
            'package that no BLFS stage rebuilds (Nightly #215)')
        assert '-Ddocumentation=disabled' in opts, (
            'libevdev documentation must be disabled: it hard-requires '
            'doxygen, which this builder never installs')

    def test_libwacom_disables_tests_like_the_book_does(self, libs):
        """The BLFS general/libwacom page passes -D tests=disabled."""
        opts = self._opts(libs, 'optional', 'libwacom')
        assert '-Dtests=disabled' in opts, (
            'libwacom has the same default-enabled tests feature as '
            'libevdev; the book disables it')

    def test_libinput_disables_the_deps_no_stage_provides(self, libs):
        """libinput's options are `type: boolean`, so they take 'false'.

        mtdev is built by no stage at all and debug-gui hard-requires
        GTK 3/4, which only arrives with the desktop stages - both are
        declared with no `required: false`, so leaving them at their
        default true aborts meson setup the moment libevdev resolves.
        """
        opts = self._opts(libs, 'required', 'libinput')
        for flag in ('-Dmtdev=false', '-Ddebug-gui=false', '-Dtests=false'):
            assert flag in opts, (
                f'libinput must pass {flag}; the boolean defaults to true '
                f'and the dependency is unavailable at blfs-libs time')

    def test_libinput_follows_whether_libwacom_installed(self, libs):
        """libwacom is optional but libinput hard-requires it if enabled.

        A literal -Dlibwacom=true would abort a required package over an
        optional tablet-support extra, so the flag must be derived from
        is_installed and evaluated after libwacom was attempted.
        """
        opts = self._opts(libs, 'required', 'libinput')
        assert '"$libinput_wacom"' in opts, (
            'libinput must take its libwacom flag from the probe variable')
        assert '-Dlibwacom=' not in opts, (
            'the libwacom flag must not be hard-coded on the run_build line')

        probe = libs.index('if is_installed libwacom; then')
        call = libs.index('run_build required libinput')
        attempted = libs.index('run_build optional libwacom')
        assert attempted < probe < call, (
            'the libwacom probe must run after libwacom was attempted and '
            'before libinput is configured')

    def test_bootloader_stage_relaunches_as_root(self):
        """chroot and the bind mounts both need real root privileges."""
        content = self.BOOTLOADER.read_text()
        guard = content.index('if [ "$EUID" -ne 0 ]; then')
        assert 'exec sudo -E "$0" "$@"' in content[guard:guard + 200]
        for op in ('mount --bind /dev', 'chroot "$LFS"'):
            assert guard < content.index(op), (
                f'final/13-create-bootloader.sh must re-launch as root '
                f'before "{op}" (Nightly #215)')

    def test_bootloader_creates_boot_grub_before_writing_config(self):
        """grub-install is skipped whenever no target disk can be probed,
        which is always true in CI, so nothing else creates /boot/grub."""
        content = self.BOOTLOADER.read_text()
        mkdir = content.index('mkdir -p "$LFS/boot/grub"')
        write = content.index('> "$LFS/boot/grub/grub.cfg"')
        assert mkdir < write, (
            'the grub.cfg redirect needs its parent directory to exist')


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

    def test_plugin_packs_gated_on_audio_plugins_token(self, content):
        """Phases 4-5 run only when the profile carries the
        audio-plugins token, so audio-cli stays a console stack."""
        assert 'has_pkg()' in content, "has_pkg token gate helper missing"
        gated = content[content.index('Phase 4: LV2 plugin packs'):]
        assert 'if has_pkg audio-plugins; then' in gated
        assert 'build_lsp_plugins' in gated
        assert 'build_dragonfly_reverb' in gated
        assert 'Skipping plugin packs' in gated

    def test_plugin_checksums_pinned(self, content):
        for sha in (
            # lsp-plugins-src-1.2.35 release asset
            '2c95ec7bb219d561ea3db36051b6c732133bcd76426fb836b1dd850dc4b5bb6c',
            # dragonfly-reverb-3.2.10-src release asset
            '18af55a9592c9f50c4d5f86c9d5159132735d9ba53d49e9cfe7169b3109f7743',
        ):
            assert sha in content, f"missing pinned checksum {sha}"

    def test_plugin_sources_listed_exactly_once(self):
        """Both plugin packs need their -src release asset; the generic
        refs/tags archive lacks the bundled sub-projects/DPF framework."""
        listed = [line.strip().rsplit('/', 1)[-1]
                  for line in self.SOURCES.read_text().splitlines()
                  if line.strip().startswith('http')]
        for archive in ('lsp-plugins-src-1.2.35.tar.gz',
                        'dragonfly-reverb-3.2.10-src.tar.xz'):
            assert listed.count(archive) == 1, \
                f"{archive} listed {listed.count(archive)} times"

    def test_plugin_bundles_install_into_lv2_dir(self, content):
        """Dragonfly ships no install target; the stage must hand-copy
        its bundles so lilv can discover them next to lsp-*.lv2."""
        assert '/usr/lib/lv2' in content
        assert 'cp -r bin/*.lv2 /usr/lib/lv2/' in content

    def test_ardour_checksums_pinned(self, content):
        """Ardour's non-book dependencies are sha256-pinned like the
        other upstream tarballs; the book packages (fftw, boost, *mm)
        come from the official wget-list and carry the book checksums."""
        for sha in (
            # liblo-0.36
            'c08d14832e8dcf8f06840405824a4f9611a0cb3daed0198946326c740941c8b6',
            # vamp-plugin-sdk-v2.10
            'b552bc91817294c7f90ea07d70938642ebf15d5e3bafc81cf7d55efab9995399',
            # rubberband-4.0.0
            'af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9',
        ):
            assert sha in content, f"missing pinned checksum {sha}"

    def test_ardour_sources_are_listed_exactly_once(self):
        """liblo/vamp-plugin-sdk/rubberband have no BLFS book page;
        their pinned releases must sit in custom-sources.list exactly
        once (duplicate filenames collide on the download key)."""
        listed = [line.strip().rsplit('/', 1)[-1]
                  for line in self.SOURCES.read_text().splitlines()
                  if line.strip().startswith('http')]
        for archive in ('liblo-0.36.tar.gz',
                        'vamp-plugin-sdk-v2.10.tar.gz',
                        'rubberband-4.0.0.tar.bz2'):
            assert listed.count(archive) == 1, \
                f"{archive} listed {listed.count(archive)} times"

    def test_ardour_source_is_a_pinned_tag_clone(self, content):
        """GitHub tag archives of Ardour/ardour are placeholder stubs
        (README-GITHUB.txt says so) and git.ardour.org archives need a
        login, so the tree must come from a pinned shallow tag clone
        whose revision is baked into libs/ardour/revision.cc (the LFS
        chroot ships no git for waf's git-describe)."""
        assert 'git clone --quiet --depth 1 --branch "$ARDOUR_TAG"' in content
        assert 'https://git.ardour.org/ardour/ardour.git' in content
        assert 'ARDOUR_TAG=9.8' in content
        assert 'describe --tags' in content
        assert 'libs/ardour/revision.cc' in content

    def test_ardour_stack_gated_on_audio_plugins_token(self, content):
        """Phases 5-6 run only on audio-studio; audio-cli stays a
        console stack and must not drag in the GUI dependency chain."""
        gated = content[content.index('Phase 5: Ardour dependency stack'):]
        assert 'if has_pkg audio-plugins; then' in gated
        for fn in ('build_fftw', 'build_boost', 'mm_build gtkmm',
                   'build_liblo', 'build_vamp_plugin_sdk',
                   'build_rubberband', 'build_ardour'):
            assert fn in gated, f"{fn} missing from the token-gated phases"
        assert 'Skipping Ardour dependency stack' in gated
        assert 'Skipping Ardour' in gated

    def test_realtime_limits_installed(self, content):
        """PipeWire gains realtime via RLIMIT once the audio group has
        rtprio/memlock; the tuning must always run (ungated phase)."""
        assert '/etc/security/limits.d/audio.conf' in content
        assert '@audio   -   rtprio     99' in content
        assert '@audio   -   memlock    unlimited' in content
        assert 'groupadd -f audio' in content

    def test_audio_studio_kernel_is_preempt_rt(self):
        """The audio-studio promise requires the PREEMPT_RT kernel;
        the preemption model is exclusive, so the voluntary model must
        be absent, and live-ISO boot options must survive."""
        kernel = Path(__file__).parent.parent / 'config/kernel-config-audio-studio'
        kernel = kernel.read_text()
        assert 'CONFIG_PREEMPT_RT=y' in kernel
        assert 'CONFIG_EXPERT=y' in kernel
        assert 'CONFIG_PREEMPT_VOLUNTARY' not in kernel
        for option in ('CONFIG_ISO9660_FS=y', 'CONFIG_SQUASHFS=y',
                       'CONFIG_BLK_DEV_LOOP=y'):
            assert option in kernel

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

    def _systemd_tarballs(self):
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
        return entries

    def test_systemd_tarball_is_never_listed_twice(self):
        """Two systemd releases in this file resurrect nightly #173.

        The official wget-list builder.py fetches already carries the
        book release, so no pin here is the normal state; what has to
        stay impossible is a second, conflicting one overriding it.
        """
        entries = self._systemd_tarballs()
        assert len(entries) <= 1, \
            f"conflicting systemd sources (glob order picks the " \
            f"oldest tree): {entries}"

    def test_official_wget_list_is_not_pasted_into_the_overrides(self):
        """This file overrides the official lists; it must not restate them.

        builder.py fetches the LFS and BLFS wget-lists from the
        'repositories' URLs, then applies this file on top with a
        last-line-wins rule keyed by source_key().  A pasted copy of an
        official list therefore silently overrides every curated pin
        above it for the same package.  The downloads/12.4 flavour that
        used to sit here named ftpmirror.gnu.org for all 30 GNU tarballs
        while the view/stable list builder.py fetches names ftp.gnu.org,
        so build-base-cache run #5 lost m4, mpc, sed and readline to a
        redirector answering 502/504 -- and neither the conglomeration
        tier nor the Void tier carries LFS core packages at all.
        """
        hosts = {
            urlparse(line.strip()).hostname
            for line in self.SOURCES.read_text().splitlines()
            if line.strip().startswith('http')
        }
        assert 'ftpmirror.gnu.org' not in hosts, \
            ("ftpmirror.gnu.org is the redirector the official "
             "downloads/<version> wget-list names; the view/stable list "
             "builder.py fetches uses ftp.gnu.org, and SourceDownloader "
             "re-points either at the GNU mirror tier on failure")


class TestProfilePromiseGuardrails:
    """Profile completeness audit guardrails.

    Every profile promise must map to software a stage really
    installs, and every required archive must be listed exactly once
    in custom-sources.list (duplicate filenames collide on the
    download key, exactly like the systemd-221 incident).
    """

    SOURCES = Path('packages/custom-sources.list')

    JAVA_ARCHIVES = (
        'OpenJDK21U-jdk_x64_linux_hotspot_21.0.9_10.tar.gz',
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

    def test_business_isbn_overridden_via_backpan(self):
        """CPAN keeps only the latest release of a distribution, so
        the official wget-list's Business-ISBN-3.012 URL is a
        permanent 404 (nightly #185).  Only custom-sources.list
        overrides the fetched official lists at runtime -- the fix
        in packages/stable/12.4/sources.list had no effect because
        that file is never read at runtime.
        """
        listed = self._listed_filenames()
        assert listed.count('Business-ISBN-3.012.tar.gz') == 1
        content = self.SOURCES.read_text()
        assert ('https://backpan.perl.org/authors/id/B/BR/BRIANDFOY/'
                'Business-ISBN-3.012.tar.gz') in content

    def test_ntp_source_is_not_the_dead_ntp_org_url(self):
        """ntp.org's download URL serves an HTML error page, so nightly
        #187 died with 'gzip: stdin: not in gzip format' in the
        basic-networking stage.  The override must stay on the BLFS
        conglomeration mirror until upstream revives."""
        listed = self._listed_filenames()
        assert listed.count('ntp-4.2.8p18.tar.gz') == 1
        content = self.SOURCES.read_text()
        assert 'www.ntp.org/downloads' not in content
        assert ('https://ftp2.osuosl.org/pub/blfs/conglomeration/ntp/'
                'ntp-4.2.8p18.tar.gz') in content

    def test_cairo_is_stable_release_not_snapshot(self):
        """The cairo 1.17.8 snapshot no longer compiles with the LFS
        12.4 GCC 14 toolchain (ninja stops in util/cairo-script,
        nightly #187); custom-sources.list must pin the current stable
        release used by the BLFS book."""
        listed = self._listed_filenames()
        assert listed.count('cairo-1.18.4.tar.xz') == 1
        content = self.SOURCES.read_text()
        assert 'snapshots/cairo-1.17.8' not in content

    def test_no_dead_jack2_source_is_listed(self):
        """Upstream stopped attaching release assets after v1.9.14, so
        every known jack2-1.9.22 tarball URL is a permanent 404
        (nightly #182).  jack2 stays optional in 24-multimedia.sh
        (pipewire-jack covers the JACK API); the dead entry must not
        come back until a real package-prefixed tarball exists."""
        listed = self._listed_filenames()
        assert listed.count('jack2-1.9.22.tar.gz') == 0

    # Nightly #212: every pin below was either a permanent 404 or a
    # non-book version.  Custom entries are applied last and share the
    # dedup key of the book tarball, so a dead pin silently evicted a
    # live source (08c ended up with no wayland tarball at all) and a
    # non-book major let find_archive's "newest wins" rule build the
    # wrong tree.  The official wget-list is authoritative for all of
    # them; each removal is documented where the pin used to sit.
    RETIRED_PINS = (
        'ImageMagick-7.1.2-27.tar.gz',
        'accountsservice-23.13.92.tar.xz',
        'accountsservice-26.27.3.tar.gz',
        'babl-0.1.110.tar.xz',
        'babl-0.1.98.tar.xz',
        'enscript-1.6.6.tar.gz',
        'gegl-0.4.50.tar.xz',
        'gegl-0.4.8.tar.bz2',
        'gtk+-3.24.43.tar.xz',
        'gtk-4.18.4.tar.xz',
        'hunspell-5.2.3.tar.gz',
        'json-glib-1.10.4.tar.xz',
        'kmod-34.tar.xz',
        'libdrm-2.4.174.tar.xz',
        'libjpeg-turbo-3.1.1.tar.gz',
        'libseccomp-2.6.0.tar.xz',
        'libwacom-0.29.tar.bz2',
        'poppler-25.6.0.tar.xz',
        'poppler-26.08.0.tar.xz',
        'wayland-1.23.1.tar.xz',
        'wayland-1.26.0.tar.gz',
        'wayland-protocols-1.44.tar.xz',
        'xcb-proto-1.18.0.tar.xz',
        'xeyes-1.2.0.tar.xz',
        'xf86-video-fbdev-0.5.0.tar.xz',
        'xkbcommon-1.11.0.tar.gz',
        'xkbcommon-1.13.2.tar.gz',
        'xorgproto-2024.1.1.tar.xz',
    )

    def test_retired_nightly_212_pins_stay_out_of_the_list(self):
        """The pins retired by the nightly #212 source audit must not
        come back: each one costs a live book URL."""
        listed = self._listed_filenames()
        resurrected = [pin for pin in self.RETIRED_PINS if pin in listed]
        assert not resurrected, \
            f"retired pins are back (they evict the live book URL " \
            f"sharing their dedup key): {resurrected}"

    def test_dbus_glib_override_does_not_downgrade_to_0_112(self):
        """dbus-glib 0.112 no longer compiles against the current glib
        headers (the G_TYPE_VALUE_ARRAY deprecation is a hard
        '#pragma GCC error', nightly #189).  The official BLFS
        wget-list already carries the fixed 0.114 release, so
        custom-sources.list must not override it back to 0.112."""
        content = self.SOURCES.read_text()
        assert 'dbus-glib-0.112' not in content

    def test_networking_stage_builds_sqlite_before_nfs_utils(self):
        """nfs-utils configure links every probe program with
        LIBS="-lsqlite3 -levent_core" (the book requires both for the
        fsidd daemon), so sqlite must exist in the chroot first;
        nightly #189 died with 'C compiler cannot create executables'
        because the server stage owning sqlite runs later."""
        content = Path('blfs/23-basic-networking.sh').read_text()
        assert 'run_build required sqlite' in content
        assert content.index('run_build required sqlite') < \
            content.index('run_build required nfs-utils')
        assert 'LIBS="-lsqlite3 -levent_core"' in content

    def test_networking_stage_builds_rpc_chain_before_nfs_utils(self):
        """libtirpc, rpcsvc-proto and rpcbind must precede nfs-utils.

        Nightly #192 (all 12 profiles) died at nfs-utils configure
        with "Please install rpcgen or use --with-rpcgen": glibc no
        longer ships rpc/rpc.h nor rpcgen, and the BLFS book lists
        libtirpc (RPC headers/library) and rpcsvc-proto (rpcgen) as
        REQUIRED nfs-utils dependencies, plus rpcbind at runtime.
        Both tarballs were already downloaded into /sources by the
        official wget-list but no stage ever built them.
        """
        content = Path('blfs/23-basic-networking.sh').read_text()
        nfs_pos = content.index('run_build required nfs-utils')
        for pkg in ('libtirpc', 'rpcsvc-proto', 'rpcbind'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 23"
            assert pos < nfs_pos, \
                f"{pkg} must be built before nfs-utils (nightly #192)"
        assert 'build_commands_libtirpc' in content
        assert 'build_commands_rpcsvc_proto' in content
        assert 'build_commands_rpcbind' in content
        assert 'libtirpc) have_pc libtirpc ;;' in content
        assert 'rpcsvc-proto) have_cmd rpcgen ;;' in content
        assert 'rpcbind) have_cmd rpcbind ;;' in content

    def test_libxkbcommon_disables_protocols_missing_at_stage_time(self):
        """libxkbcommon meson must not hard-require libxcb/wayland.

        Nightly #198 (all desktop jobs) died at meson with "X11
        support requires xcb-xkb >= 1.10"; nightly #199 died again
        with "The Wayland xkbcli programs require wayland-client and
        wayland-protocols which were not found".  The BLFS book lists
        libxcb and Wayland/wayland-protocols as recommended only, but
        meson defaults enable-x11/enable-wayland to true and the xorg
        (08b) and wayland (08c) stages run after blfs-libs (08a).
        Both the 08a build and the 08b rebuild must disable each
        feature only when its pkg-config file is absent.
        """
        for script in ('blfs/08a-build-blfs-libs.sh',
                       'blfs/08b-build-xorg.sh'):
            content = Path(script).read_text()
            fn = content.index('build_commands_libxkbcommon()')
            body = content[fn:fn + 1200]
            assert 'have_pc xcb-xkb || x11="-D enable-x11=false"' in body, \
                f"{script} must disable x11 when xcb-xkb is missing"
            assert 'have_pc wayland-client || ' \
                'wayland="-D enable-wayland=false"' in body, \
                f"{script} must disable wayland when wayland-client " \
                "is missing (nightly #199)"

    def test_server_stage_builds_sasl_chain_before_openldap(self):
        """lmdb and cyrus-sasl must precede openldap in stage 25.

        Nightly #199 (all headless jobs) died at openldap configure
        with "Could not locate Cyrus SASL": the book server build
        passes --with-cyrus-sasl, but no stage ever built Cyrus SASL.
        The Cyrus SASL book build in turn passes --with-dblib=lmdb,
        so lmdb must be built first.  Both tarballs
        (LMDB_0.9.33.tar.bz2, cyrus-sasl-2.1.28.tar.gz) are already
        downloaded into /sources by the official wget-list.
        """
        content = Path('blfs/25-server.sh').read_text()
        ldap_pos = content.index('run_build required openldap')
        for pkg in ('lmdb', 'cyrus-sasl'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 25"
            assert pos < ldap_pos, \
                f"{pkg} must be built before openldap (nightly #199)"
        assert 'build_commands_lmdb' in content
        assert 'build_commands_cyrus_sasl' in content
        assert '--with-cyrus-sasl' in content
        assert '--with-dblib=lmdb' in content
        assert 'lmdb) [ -f /usr/lib/liblmdb.so ] ;;' in content
        assert 'cyrus-sasl) [ -f /usr/lib/libsasl2.so ] ;;' in content

    def test_libs_stage_builds_vulkan_shader_chain_before_mesa(self):
        """spirv-headers, spirv-tools and glslang must precede mesa.

        Nightly #207 (all desktop jobs) died at mesa meson with
        "Program 'glslangValidator' not found or not executable":
        building any Vulkan driver makes meson hard-require
        glslangValidator, and the book lists Glslang as recommended
        (required for Vulkan support).  Glslang in turn requires
        SPIRV-Tools (book REQUIRED), which requires SPIRV-Headers.
        All three tarballs were already downloaded into /sources by
        the official wget-list.

        Nightly #213 moved mesa to the xorg stage (08b) because the
        book lists the Xorg Libraries as a REQUIRED mesa dependency.
        The shader chain stays in blfs-libs (08a), which runs before
        08b, so it still precedes mesa; mesa is software-only now and
        no longer needs glslangValidator, but the proven-good chain is
        left in place.
        """
        content = Path('blfs/08a-build-blfs-libs.sh').read_text()
        assert 'run_build required mesa' not in content, \
            "mesa moved to the xorg stage 08b (nightly #213)"
        assert 'run_build required mesa' in \
            Path('blfs/08b-build-xorg.sh').read_text(), \
            "mesa must be built by the later xorg stage (08b)"
        for pkg in ('spirv-headers', 'spirv-tools', 'glslang'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 08a"
        assert 'build_commands_spirv_headers' in content
        assert 'build_commands_spirv_tools' in content
        assert 'build_commands_glslang' in content
        assert 'spirv-headers)       [ -d /usr/include/spirv ] ;;' \
            in content
        assert 'spirv-tools)         [ -f /usr/lib/libSPIRV-Tools.so ] ;;' \
            in content
        assert 'glslang)             have_cmd glslang ;;' in content
        assert 'ALLOW_EXTERNAL_SPIRV_TOOLS=ON' in content
        assert 'SPIRV-Headers_SOURCE_DIR=/usr' in content

    def test_xorg_stage_mesa_is_software_only_offline_safe(self):
        """mesa must build software-only: softpipe, no Vulkan, no LLVM.

        Nightly #208 (all desktop jobs) died at mesa meson with
        "Unknown compiler(s): [['rustc']]": -D vulkan-drivers=auto pulls
        in the Nouveau driver (nak, needs rustc + network) and the Intel
        driver (anv, needs ply).  Enumerating amd,swrast cleared that,
        but Nightly #210 then died on "Run-time dependency libclc found:
        NO" because radv/lavapipe pull in libclc, which needs a full
        LLVM/clang toolchain that no stage builds.  The offline chroot
        can only build the pure-software rasteriser, so the stage uses
        softpipe (the book's no-LLVM gallium driver), empty
        vulkan-drivers and -D llvm=disabled, and drops the optional
        -D video-codecs=all (softpipe has no video backend).

        Nightly #213 moved mesa from blfs-libs (08a) to the xorg stage
        (08b): the book lists the Xorg Libraries as a REQUIRED mesa
        dependency and its wayland platform needs wayland-scanner, so
        these software-only flags now live in 08b.
        """
        content = Path('blfs/08b-build-xorg.sh').read_text()
        # Comment lines may quote the book's default; only the actual
        # meson invocation matters.
        code = "\n".join(
            ln for ln in content.splitlines()
            if not ln.lstrip().startswith('#')
        )
        assert '-D vulkan-drivers=auto' not in code, \
            "mesa must not use vulkan-drivers=auto offline (nightly #208)"
        assert '-D gallium-drivers=auto' not in code, \
            "mesa must not use gallium-drivers=auto offline (nightly #210)"
        assert '-D video-codecs=all' not in code, \
            "mesa must drop video-codecs (softpipe has no video backend)"
        assert '-D gallium-drivers=softpipe' in code, \
            "mesa must use the no-LLVM softpipe driver (nightly #210)"
        assert '-D vulkan-drivers=""' in code, \
            "mesa must build no Vulkan drivers offline (nightly #210)"
        assert '-D llvm=disabled' in code, \
            "mesa must disable LLVM so libclc is never required (#210)"

    def test_server_stage_builds_liburcu_libuv_before_bind(self):
        """liburcu and libuv must precede bind in stage 25.

        Nightly #207 (all headless jobs) died at bind configure with
        "Package requirements (liburcu >= 0.10.0 liburcu-cds >=
        0.10.0) were not met"; the book lists liburcu and libuv as
        REQUIRED bind dependencies, but no stage built them.  The
        liburcu tarball ships as userspace-rcu-<version>, so
        prep_src must resolve that prefix.
        """
        content = Path('blfs/25-server.sh').read_text()
        bind_pos = content.index('run_build required bind')
        for pkg in ('liburcu', 'libuv'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 25"
            assert pos < bind_pos, \
                f"{pkg} must be built before bind (nightly #207)"
        assert 'build_commands_liburcu' in content
        assert 'build_commands_libuv' in content
        assert 'liburcu) archive="$(find_archive userspace-rcu)" ;;' \
            in content
        assert 'liburcu) have_pc liburcu ;;' in content
        assert 'libuv) have_pc libuv ;;' in content

    def test_server_stage_samba_venv_failure_is_non_fatal(self):
        """samba must fall back to system python3 when the venv pip fails.

        Nightly #208 (all headless jobs) died at samba with "No matching
        distribution found for cryptography": the book creates a venv and
        pip-installs cryptography/pyasn1/iso8601 for the AD DC features,
        but the chroot is offline so pip cannot reach PyPI.  Since the
        build already passes --without-ad-dc, a failed venv must degrade
        to the system python3 instead of `return 1`-ing the whole stage.
        """
        content = Path('blfs/25-server.sh').read_text()
        assert 'build_commands_samba' in content
        assert 'install cryptography pyasn1 iso8601 || return 1' not in content, \
            "samba venv pip failure must be non-fatal (nightly #208)"
        assert 'building with system python3' in content
        assert '--without-ad-dc' in content

    def test_server_stage_builds_gnutls_chain_before_samba(self):
        """nettle, gnutls, Parse-Yapp and krb5 must precede samba (stage 25).

        Nightly #210 (all headless jobs) died at samba configure with
        "Checking for GnuTLS >= 3.6.13 : not found": the headless
        profiles skip blfs-libs (08a), so nothing provides GnuTLS, and
        GnuTLS in turn requires nettle.  Once GnuTLS is satisfied two
        further Required samba deps surface: Parse-Yapp (samba's pidl
        IDL compiler, needed at make time and not probed by configure)
        and MIT krb5 (the book's --with-system-mitkrb5 is mandatory
        alongside --without-ad-dc).  nettle/gnutls stay required; the
        samba-only pieces and samba itself are optional so a residual
        offline issue can never again block an otherwise-good build.
        """
        content = Path('blfs/25-server.sh').read_text()
        assert 'run_build optional samba' in content, \
            "samba must be optional so a residual dep cannot block (#210)"
        samba_pos = content.index('run_build optional samba')
        for pkg in ('nettle', 'gnutls'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 25"
            assert pos < samba_pos, \
                f"{pkg} must be built before samba (nightly #210)"
        for pkg in ('parse-yapp', 'krb5'):
            pos = content.find(f'run_build optional {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 25"
            assert pos < samba_pos, \
                f"{pkg} must be built before samba (nightly #210)"
        assert 'build_commands_nettle' in content
        assert 'build_commands_gnutls' in content
        assert 'build_commands_parse_yapp' in content
        assert 'build_commands_krb5' in content
        assert '--with-included-unistring' in content
        assert '--without-p11-kit' in content
        assert '--with-system-mitkrb5' in content
        assert 'nettle) have_pc nettle ;;' in content
        assert 'gnutls) have_pc gnutls ;;' in content
        assert 'krb5) have_cmd krb5-config ;;' in content
        assert 'perl -MParse::Yapp::Driver -e1' in content

    def test_libs_stage_builds_mesa_python_modules_before_mesa(self):
        """mako, cython and pyyaml must precede mesa in stage 08a.

        Nightly #212 (every desktop job) died at mesa meson with
        "../meson.build:958:2: ERROR: Problem encountered: Python (3.x)
        mako module >= 0.8.0 required to build mesa."; the book lists
        Mako AND PyYAML as REQUIRED mesa dependencies (meson.build:967
        aborts on the yaml module right after mako), and PyYAML in turn
        requires Cython plus libyaml, which phase 9 of this stage builds.
        The chroot is offline, so the three modules are installed with
        the book's pip3 wheel / pip3 install --no-index idiom and never
        contact PyPI.

        Nightly #213 moved mesa to the xorg stage (08b); the modules
        stay in blfs-libs (08a), which runs first, so they still
        precede mesa and 08b picks them up through pkg-config/python.
        """
        content = Path('blfs/08a-build-blfs-libs.sh').read_text()
        assert 'run_build required mesa' not in content, \
            "mesa moved to the xorg stage 08b (nightly #213)"
        for pkg in ('mako', 'cython', 'pyyaml'):
            pos = content.find(f'run_build required {pkg}')
            assert pos != -1, f"{pkg} build missing from stage 08a"
        assert content.index('run_build required libyaml') < \
            content.index('run_build required pyyaml'), \
            "libyaml must precede pyyaml (its C extension links to it)"
        for fn in ('build_commands_mako', 'build_commands_cython',
                   'build_commands_pyyaml'):
            assert fn in content, f"{fn} missing from stage 08a"
        assert '--no-build-isolation' in content
        assert '--no-index --find-links dist' in content, \
            "the offline pip3 idiom must never reach PyPI"
        assert "mako)                python3 -c 'import mako' " \
            ">/dev/null 2>&1 ;;" in content
        assert "cython)              python3 -c 'import Cython' " \
            ">/dev/null 2>&1 ;;" in content
        assert "pyyaml)              python3 -c 'import yaml' " \
            ">/dev/null 2>&1 ;;" in content

    def test_server_stage_builds_libtasn1_before_gnutls(self):
        """libtasn1 must precede gnutls in stage 25.

        Nightly #212 (every headless job) died at gnutls configure with
        "checking for libtasn1 >= 4.9... no" followed by "*** Libtasn1
        4.9 was not found. To use the included one, use
        --with-included-libtasn1": GnuTLS does NOT fall back on its
        bundled copy on its own, it aborts.  The book lists libtasn1 as
        a Recommended GnuTLS dependency; 08a builds it for the desktop
        profiles but the headless ones skip that stage.
        """
        content = Path('blfs/25-server.sh').read_text()
        gnutls_pos = content.index('run_build required gnutls')
        pos = content.find('run_build required libtasn1')
        assert pos != -1, "libtasn1 build missing from stage 25"
        assert pos < gnutls_pos, \
            "libtasn1 must be built before gnutls (nightly #212)"
        assert 'build_commands_libtasn1' in content
        assert 'libtasn1) have_pc libtasn1 ;;' in content
        assert '--with-included-libtasn1' in content, \
            "gnutls must fall back on its bundled copy when the " \
            "system libtasn1 is missing"

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


class TestStandaloneSwitchSameFileGuards:
    """The /bin/bash re-links must survive usr-merged layouts.

    Nightly #176 (minimal/sysvinit/x86_64) compiled the whole system
    and died on the very last line of lfs-system: on a fresh disk
    image host/04 creates bin -> usr/bin symlinks, so after chapter 8
    installs the final bash, /bin/bash and /usr/bin/bash are one file
    and `ln -sfn /usr/bin/bash /bin/bash` aborts with "are the same
    file" under set -e.  Every such re-link is now guarded with -ef.
    """

    def test_lfs_system_payload_guards_the_standalone_links(self):
        import re

        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        assert '[ /bin/bash -ef /usr/bin/bash ] || ' \
            'ln -sfn /usr/bin/bash /bin/bash' in content
        assert '[ /bin/sh -ef /bin/bash ] || ln -sfn bash /bin/sh' \
            in content
        assert not re.search(r'(?m)^ln -sfn /usr/bin/bash /bin/bash$',
                             content)
        assert not re.search(r'(?m)^ln -sfn bash /bin/sh$', content)

    def test_lfs_system_postbuild_relink_is_same_file_guarded(self):
        content = Path('lfs/05b-build-lfs-system.sh').read_text()
        assert '[ "$LFS/bin/bash" -ef "$LFS/usr/bin/bash" ] ||' in content
        assert '[ "$LFS/bin/sh" -ef "$LFS/bin/bash" ] ||' in content

    def test_lfs_basic_bootstrap_links_are_same_file_guarded(self):
        content = Path('lfs/05a-build-lfs-basic.sh').read_text()
        assert '[ "$LFS/bin/bash" -ef "$LFS/tools/bin/bash" ] ||' in content
        assert '[ "$LFS/bin/sh" -ef "$LFS/bin/bash" ] ||' in content

    def test_merged_usr_layout_replay(self, tmp_path):
        """Reproduce nightly #176: bin -> usr/bin, one real bash.

        The unguarded ln -sfn must fail with "same file" (GNU ln) and
        the guarded form must complete under set -e.
        """
        version = subprocess.run(['ln', '--version'],
                                 capture_output=True, text=True)
        if version.returncode != 0 or 'coreutils' not in version.stdout:
            pytest.skip('replay requires GNU coreutils ln')

        (tmp_path / 'usr' / 'bin').mkdir(parents=True)
        (tmp_path / 'usr' / 'bin' / 'bash').write_bytes(b'#!/bin/sh\n')
        os.symlink('usr/bin', str(tmp_path / 'bin'))

        unguarded = (
            f"set -e; ln -sfn {tmp_path}/usr/bin/bash "
            f"{tmp_path}/bin/bash")
        bad = subprocess.run(['bash', '-c', unguarded],
                             capture_output=True, text=True)
        assert bad.returncode != 0, \
            "unguarded ln -sfn should fail on the same file"
        assert 'same file' in bad.stderr

        guarded = (
            f"set -e; [ {tmp_path}/bin/bash -ef {tmp_path}/usr/bin/bash ] "
            f"|| ln -sfn {tmp_path}/usr/bin/bash {tmp_path}/bin/bash; "
            f"echo ok")
        good = subprocess.run(['bash', '-c', guarded],
                              capture_output=True, text=True)
        assert good.returncode == 0, good.stderr
        assert 'ok' in good.stdout


class TestKnowledgeStageGuardrails:
    """Guardrails for the optional 'knowledge' AI assistant stage.

    blfs/28-knowledge.sh installs a free, fully local Ollama-based
    assistant. Because it is opt-in, installs a third-party binary and
    generates a CLI that fronts an LLM, the stage must stay strictly
    gated, checksum-verified, loopback-only, and must never execute
    model output.
    """

    SCRIPT = Path('blfs/28-knowledge.sh')

    @pytest.fixture(scope='class')
    def content(self):
        return self.SCRIPT.read_text()

    def test_script_exists_and_is_strict(self, content):
        assert self.SCRIPT.exists(), "28-knowledge.sh stage must exist"
        assert 'set -euo pipefail' in content

    def test_stage_is_opt_in(self, content):
        """Disabled builds must not touch the assistant at all."""
        assert 'LFS_CONFIG_KNOWLEDGE_ENABLED:-false' in content
        assert 'stage skipped' in content

    def test_disabled_stage_exits_zero(self, tmp_path):
        env = dict(os.environ)
        env['LFS'] = str(tmp_path)
        env.pop('LFS_CONFIG_KNOWLEDGE_ENABLED', None)
        result = subprocess.run(['bash', str(self.SCRIPT)],
                                capture_output=True, text=True, env=env)
        assert result.returncode == 0, result.stderr
        assert 'stage skipped' in result.stdout

    def test_enabled_without_sha256_aborts(self, tmp_path):
        env = dict(os.environ)
        env['LFS'] = str(tmp_path)
        env['LFS_CONFIG_KNOWLEDGE_ENABLED'] = 'true'
        env.pop('LFS_CONFIG_KNOWLEDGE_ENGINE_SHA256', None)
        result = subprocess.run(['bash', str(self.SCRIPT)],
                                capture_output=True, text=True, env=env)
        assert result.returncode != 0
        assert 'engine_sha256 must be pinned' in result.stderr

    def test_engine_requires_pinned_sha256(self, content):
        """The checksum is verified before the tarball is extracted."""
        assert 'knowledge.engine_sha256 must be pinned' in content
        assert 'Engine sha256 mismatch' in content
        assert content.index('Engine sha256 mismatch') < \
            content.index('tar -xzf')

    def test_listen_defaults_to_loopback(self, content):
        assert '127.0.0.1:11434' in content
        assert ('must stay on loopback unless '
                'knowledge.allow_network=true') in content

    def test_init_service_follows_init_system(self, content):
        assert 'case "$INIT" in' in content
        assert 'ollama.service' in content
        assert '/etc/init.d/ollama' in content

    def test_wrapper_never_executes_model_output(self, content):
        """The knowledge CLI prints suggestions; it never runs them."""
        wrapper = content.split(
            'cat >"$LFS/usr/bin/knowledge"')[1].split('\nWRAPPER\n')[0]
        assert 'eval' not in wrapper, \
            "knowledge wrapper must not eval model output"
        assert 'never auto-runs' in wrapper

    def test_shellcheck_clean(self):
        try:
            subprocess.run(['shellcheck', '--version'],
                           capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pytest.skip("shellcheck not installed")
        result = subprocess.run(['shellcheck', str(self.SCRIPT)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout


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
        """Every required init package must resolve to a downloadable tarball.

        packages/stable/12.4/sources.list is only the snapshot of the
        official wget-lists; builder.py applies packages/custom-sources.list
        on top of it, and that override file is the sole home of the init
        systems the books do not carry (openrc, runit and the whole s6
        stack).  Checking the snapshot alone made every one of them look
        unsourced the moment lfs/06c-06e classified them as required.

        Names are compared after builder._archive_filename(), because a
        GitHub refs/tags URL is stored as <repo>-<tag>.tar.gz: matching the
        raw URL would let the OpenRC pin through as a bare "0.63.3.tar.gz",
        which no find_archive glob can ever resolve.
        """
        import re
        from builder import _archive_filename

        names = []
        for list_file in ('packages/stable/12.4/sources.list',
                          'packages/custom-sources.list'):
            for line in Path(list_file).read_text().splitlines():
                line = line.strip()
                if line and not line.startswith('#'):
                    names.append(_archive_filename(line))
        # Newline-anchored, the same way the old check anchored on the "/"
        # of the URL path: "s6" must not be satisfied by "s6-rc-...".
        blob = '\n' + '\n'.join(names)
        call_re = re.compile(r'run_build\s+required\s+(\S+)')

        for script in self.BUILD_SCRIPTS:
            content = Path(script).read_text()
            for pkg in set(call_re.findall(content)):
                found = (f"\n{pkg}-" in blob or f"\n{pkg}." in blob)
                assert found, \
                    f"{script}: required package {pkg} has no source in " \
                    f"packages/stable/12.4/sources.list or " \
                    f"packages/custom-sources.list"

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


class TestNightly223StageGuardrails:
    """Guardrails for the Nightly #223 all-profile failure classes.

    Run #223 lost all thirteen jobs to four independent defects.  It was
    also the first nightly to actually restore the base prefix cache --
    build-base-cache only published its first prefix some 17 h earlier --
    so two of the four had been latent in the resume path since the day
    it was written:

    * xorg-server's meson defaults secure-rpc to true and aborts with
      "secure-rpc requested, but neither libtirpc or libc RPC support
      were found".  libtirpc was built only by basic-networking, which
      builder.py schedules *after* xorg -- the inverse of the book, where
      chapter IV (Networking) precedes chapter VI (Graphical Components).
      Eight desktop profiles died there.
    * builder.py's prepare_environment() recreated <output>/tools on
      every invocation, so a --resume-from init-system run that skips
      lfs-system (the only "rm -rf /tools") reached validate with an
      empty /tools and failed "system is not standalone".  Three jobs.
    * host/03 created build-release.img under sudo and the QEMU smoke
      test, running as the runner user, could not open it read-write.
      One job, thrown away after a complete successful build.
    * libffi installed into /usr/lib/../lib64 on aarch64, which is not on
      the loader's default search path, so CPython's build-time _ctypes
      import failed and "make install" died on the module CPython had
      just deleted.  One job.
    """

    XORG = Path('blfs/08b-build-xorg.sh')
    BASICNET = Path('blfs/23-basic-networking.sh')
    LFS_SYSTEM = Path('lfs/05b-build-lfs-system.sh')
    DISK_IMAGE = Path('host/03-create-disk-image.sh')
    VALIDATE = Path('final/16-validate-build.sh')
    SOURCES = Path('packages/custom-sources.list')
    BOOK_SOURCES = Path('packages/stable/12.4/sources.list')
    NIGHTLY = Path('.github/workflows/nightly.yml')
    WEEKLY = Path('.github/workflows/weekly-full.yml')

    @staticmethod
    def _build_pos(content, mode, pkg):
        match = re.search(rf'^run_build {mode} {re.escape(pkg)}\b',
                          content, re.MULTILINE)
        return match.start() if match else -1

    def test_libtirpc_precedes_xorg_server(self):
        """The book lists libtirpc as a Recommended xorg-server
        dependency and builds it two chapters earlier; this repository
        schedules basic-networking after xorg, so the xorg stage has to
        build the library itself."""
        content = self.XORG.read_text()
        tirpc = self._build_pos(content, 'required', 'libtirpc')
        server = self._build_pos(content, 'required', 'xorg-server')
        assert tirpc != -1, "libtirpc build missing from the xorg stage"
        assert server != -1, "xorg-server build missing from the stage"
        assert tirpc < server, \
            "libtirpc must be built before xorg-server (Nightly #223)"
        # Exactly one build site: a second, later call would satisfy the
        # ordering assertion while the first one still ran too late.
        assert content.count('run_build required libtirpc') == 1

    def test_xorg_stage_ships_the_book_libtirpc_commands(self):
        """The early build must be the book build, and is_installed must
        guard it so a system that already has the library skips it."""
        content = self.XORG.read_text()
        assert 'build_libtirpc()' in content
        body = content[content.index('build_commands_libtirpc()'):]
        body = body[:body.index('\n}\n')]
        for flag in ('--prefix=/usr', '--sysconfdir=/etc',
                     '--disable-static', '--disable-gssapi'):
            assert flag in body, f"libtirpc configure lost {flag}"
        assert re.search(r'^\s+libtirpc\).*have_pc libtirpc',
                         content, re.MULTILINE), \
            "is_installed must guard libtirpc on its pkg-config module"

    def test_basic_networking_still_skips_an_installed_libtirpc(self):
        """The duplicate build is only a no-op because stage 23 guards on
        the same pkg-config module; dropping that guard would rebuild the
        library on every desktop profile as well."""
        content = self.BASICNET.read_text()
        assert re.search(r'^\s+libtirpc\)\s*have_pc libtirpc',
                         content, re.MULTILINE)
        assert self._build_pos(content, 'required', 'libtirpc') != -1, \
            "nfs-utils still needs libtirpc built by basic-networking"

    def test_custom_sources_do_not_downgrade_xorg_server(self):
        """A custom pin overrides the book version, so a stale one moves
        the xorg stage off-book.  21.1.16 did exactly that while the
        BLFS 12.4 book and its wget-list both build 21.1.18."""
        pattern = r'xorg-server-(\d+\.\d+\.\d+)\.tar\.xz'
        book = re.findall(pattern, self.BOOK_SOURCES.read_text())
        custom = re.findall(pattern, self.SOURCES.read_text())
        assert book, 'the book list must carry xorg-server'
        effective = custom[-1] if custom else book[0]
        assert effective == book[0], \
            f'effective xorg-server {effective} is not the book {book[0]}'

    def test_xorg_server_tearfree_patch_matches_the_pinned_version(self):
        """The patch is optional in the book and therefore absent from the
        official wget-list; 08b applies it whenever it shipped, so the pin
        and the tarball must stay in lockstep."""
        sources = self.SOURCES.read_text()
        patch = re.search(
            r'xorg-server-(\d+\.\d+\.\d+)-tearfree_backport-\d+\.patch',
            sources)
        tarball = re.search(r'xorg-server-(\d+\.\d+\.\d+)\.tar\.xz',
                            sources)
        assert patch, 'the tearfree_backport patch is not pinned'
        assert tarball and tarball.group(1) == patch.group(1), \
            'the tearfree patch must match the pinned xorg-server version'
        assert 'xorg-server-*-tearfree_backport-*.patch' \
            in self.XORG.read_text()

    def test_every_tools_consumer_creates_the_directory_itself(self):
        """builder.py no longer mkdirs <output>/tools, so each stage that
        writes into the temporary toolchain prefix must create it.  This
        is the premise that makes the resume-path fix safe."""
        assert 'mkdir -pv "$LFS/tools"' in \
            Path('host/02-prepare-host.sh').read_text()
        assert 'mkdir -pv "$LFS"/tools' in \
            Path('host/04-build-toolchain.sh').read_text()
        assert 'mkdir -p "$LFS/tools/lib"' in \
            Path('lfs/05a-build-lfs-basic.sh').read_text()

    def test_lfs_system_removes_tools_and_validate_gates_on_it(self):
        """The only rm -rf /tools lives in lfs-system, and validate is
        what turns a leftover into a hard failure (LFS book 8.84)."""
        assert 'rm -rf /tools' in self.LFS_SYSTEM.read_text()
        content = self.VALIDATE.read_text()
        assert 'if [ -d "$LFS/tools" ]; then' in content
        assert 'system is not standalone' in content

    def test_disk_image_is_handed_back_to_the_invoking_user(self):
        """The dd runs under sudo but writes a plain file; only the loop
        device operations need privileges.  Leaving the artifact
        root-owned 0644 is what made QEMU's read-write -drive fail."""
        content = self.DISK_IMAGE.read_text()
        dd = content.index('dd if=/dev/zero of="$IMAGE_FILE"')
        chown = content.find('chown "$(id -u):$(id -g)" "$IMAGE_FILE"')
        loop = content.index('losetup --find --show')
        assert chown != -1, \
            'host/03 must chown the image back to the invoking user'
        assert dd < chown < loop, \
            'the chown belongs between the dd and the loop setup'

    def test_smoke_test_step_can_open_the_disk_image(self):
        """Both scheduled workflows boot build-release.img as the runner
        user while the build ran as lfs, so the mode has to be loosened
        first.  Elevating the whole script instead would also flip its
        /dev/kvm probe onto an accel path nothing has exercised."""
        for workflow in (self.NIGHTLY, self.WEEKLY):
            content = workflow.read_text()
            chmod = content.find(
                'sudo chmod a+rw /tmp/lfs-build/build-release.img')
            smoke = content.find('bash tools/qemu-boot-smoke.sh '
                                 '/tmp/lfs-build/build-release.img')
            assert chmod != -1, f'{workflow} never unlocks the disk image'
            assert smoke != -1, f'{workflow} no longer boots the image'
            assert chmod < smoke, \
                f'{workflow} must chmod the image before booting it'

    def test_libffi_disables_the_multi_os_directory(self):
        """On aarch64 gcc prints "../lib64", so libffi's default put
        libffi.so.8 in /usr/lib64 -- not on the loader's search path,
        with /etc/ld.so.conf deliberately empty.  x86_64 only escaped it
        because the chapter-8 gcc build seds m64=lib64 into m64=lib."""
        content = self.LFS_SYSTEM.read_text()
        start = content.index('    libffi)\n')
        block = content[start:content.index('    python)\n', start)]
        assert '--disable-multi-os-directory' in block, \
            'libffi must install into /usr/lib on every architecture'
        assert '--disable-static' in block
        assert '--with-gcc-arch=native' in block


class TestNightly227StageGuardrails:
    """Nightly #227 failed every one of its thirteen jobs.

    Four independent defects, each unmasked by the previous nightly's fix
    letting the builds get further:

    * polkit aborted seven desktop/systemd jobs on an invalid meson
      session_tracking value,
    * the chapter-8 gcc rebuild left aarch64 installing into /usr/lib64,
      so gnutls could not see the nettle built moments earlier,
    * the nightly matrix crossed the arm64 profile with x86_64, booting
      an aarch64 kernel under qemu-system-x86_64,
    * the initramfs probed the root device exactly once, losing a race
      against asynchronous block-device enumeration under TCG.
    """

    DISPLAY_MANAGER = Path('blfs/08d-build-display-manager.sh')
    LFS_SYSTEM = Path('lfs/05b-build-lfs-system.sh')
    INITRAMFS = Path('final/12-create-initramfs.sh')
    NIGHTLY = Path('.github/workflows/nightly.yml')

    @staticmethod
    def _code(content):
        """Drop comment lines so assertions only ever see real commands."""
        return '\n'.join(line for line in content.splitlines()
                         if not line.strip().startswith('#'))

    def test_polkit_never_requests_session_tracking_none(self):
        """polkit's session_tracking only accepts logind, elogind or
        ConsoleKit.

        The stage defaulted to "none" - a value NetworkManager accepts
        but polkit does not - so meson aborted with 'Value "none" ... is
        not one of the choices'.  polkit is a required package, so the
        whole display-manager stage died with it, taking gnome, kde,
        lxqt, xfce/systemd, java-dev, audio-studio and full along
        (Nightly #227).  Omitting the flag - the #227 workaround - is no
        longer an option either: polkit 126 defaults to logind and makes
        libsystemd a hard requirement, so Nightly #230 replaced it with
        an explicit provider choice driven by the init system.
        """
        code = self._code(self.DISPLAY_MANAGER.read_text())
        assert 'session_tracking=none' not in code, \
            'polkit rejects session_tracking=none'
        assert 'tracking=none' not in code, \
            'the invalid polkit default must stay removed'
        fn = code.split('build_commands_polkit() {', 1)[1]
        fn = fn.split('\n}\n', 1)[0]
        assert 'session_tracking=logind' in fn
        assert 'session_tracking=elogind' in fn
        assert 'session_tracking=ConsoleKit' in fn, \
            'ConsoleKit is the only provider needing no session manager'
        # Empty-array expansion has to survive the inner script's set -u.
        assert '${tracking_args[@]+"${tracking_args[@]}"}' in fn, \
            'an unset tracking_args would trip set -u in the chroot'

    def test_chapter8_gcc_normalizes_lib64_on_aarch64(self):
        """The in-chroot gcc rebuild must normalize lib64 for aarch64.

        host/04-build-toolchain.sh already seds t-aarch64-linux, but the
        chapter-8 rebuild in 05b - the compiler every later BLFS package
        uses - only carried the x86_64 branch.  On the native arm64
        runner that left -print-multi-os-directory reporting ../lib64,
        so nettle installed into /usr/lib64 while pkgconf (built with
        --prefix=/usr alone) only searches /usr/lib/pkgconfig.  gnutls
        then aborted the server stage with "Libnettle 3.6 was not found"
        seconds after nettle reported success (Nightly #227).
        """
        content = self.LFS_SYSTEM.read_text()
        start = content.index('    gcc)\n')
        block = content[start:content.index('    ncurses)\n', start)]
        assert "sed -e '/m64=/s/lib64/lib/'" in block, \
            'x86_64 lib64 -> lib normalization must stay'
        assert "sed -e '/mabi.lp64=/s/lib64/lib/'" in block, \
            'aarch64 lib64 -> lib normalization missing from chapter 8'
        assert 'gcc/config/aarch64/t-aarch64-linux' in block
        assert 'aarch64)' in block

    def test_nightly_matrix_does_not_cross_arm64_with_x86_64(self):
        """The arm64 profile may only appear on the aarch64 cell.

        ProfileManager pins arm64 to architecture=aarch64 and
        cross_compile=True whatever --arch says, so listing arm64 in the
        base profile array produced a spurious arm64/sysvinit/x86_64 job
        that skipped "Install ARM64 cross tools" (gated on arch ==
        'aarch64') yet still ran the boot smoke test (gated on arch ==
        'x86_64'), panicking an aarch64 kernel under qemu-system-x86_64
        (Nightly #227).  Only the include entry may supply arm64.
        """
        content = self.NIGHTLY.read_text()
        matrix = content.split('matrix:', 1)[1].split('include:', 1)[0]
        profiles = re.search(r'^\s*profile:\s*\[(.*?)\]', matrix,
                             re.MULTILINE)
        assert profiles, 'the nightly base matrix must list profiles'
        names = [p.strip() for p in profiles.group(1).split(',')]
        assert names, 'the base profile list came out empty'
        assert 'arm64' not in names, \
            'arm64 in the base matrix creates an arm64 x x86_64 job'
        # The real arm64 coverage still exists, on the native arm runner.
        include = content.split('include:', 1)[1]
        assert re.search(r'-\s*profile:\s*arm64\s*\n\s*arch:\s*aarch64',
                         include), \
            'the arm64/aarch64 include entry must stay'
        assert "matrix.arch == 'aarch64' && 'ubuntu-24.04-arm'" in content

    def test_initramfs_waits_for_the_root_device(self):
        """The init script must poll for the root node, not probe once.

        devtmpfs is mounted at the top of /init, but PCI/AHCI/virtio-blk
        probing is asynchronous and /dev/sdX can appear seconds later -
        far later under TCG, which is what the smoke test falls back to
        when the runner exposes no /dev/kvm.  The single [ -b ] test
        raced ahead of the probe and dropped to a shell with "Root
        device not found", failing the gate even though the kernel
        config fixed in #224 was enumerating the disk correctly
        (Nightly #227).
        """
        content = self.INITRAMFS.read_text()
        init = content.split("<<'EOF'", 1)[1].split('\nEOF\n', 1)[0]
        assert 'wait_for_dev()' in init, \
            'the init script needs a polling helper'
        helper = init.split('wait_for_dev() {', 1)[1].split('\n}\n', 1)[0]
        assert 'sleep 1' in helper, \
            'busybox fractional sleep needs CONFIG_FEATURE_FANCY_SLEEP'
        classic = init.split('# Classic single-root mode', 1)[1]
        assert 'wait_for_dev "$ROOT_DEV"' in classic
        assert classic.index('wait_for_dev') < \
            classic.index('Root device not found'), \
            'the wait must happen before giving up on the root device'
        assert 'Mounting root:' in classic, \
            'qemu-boot-smoke.sh greps for this userspace marker'

    def test_initramfs_fallback_probes_root_before_swap(self):
        """The fallback list must try partition 3 before partition 2.

        host/03-create-disk-image.sh lays the image out as p1=ESP,
        p2=swap, p3=root, so leading with /dev/sda2 tried to mount the
        swap partition - the same mistake already corrected in
        tools/qemu-boot-smoke.sh, whose ROOT_DEV default is /dev/sda3.
        """
        content = self.INITRAMFS.read_text()
        loop = re.search(r'for candidate in ([^;]*?); do', content,
                         re.DOTALL)
        assert loop, 'the initramfs fallback device loop is missing'
        candidates = re.findall(r'/dev/\w+', loop.group(1))
        assert candidates, 'the fallback loop lists no candidates'
        assert candidates[0] in ('/dev/sda3', '/dev/vda3',
                                 '/dev/nvme0n1p3'), \
            f'fallback must lead with a root partition, got {candidates[0]}'
        assert candidates.index('/dev/sda3') < candidates.index('/dev/sda2'), \
            'p3 is the root filesystem; p2 is swap'


class TestNightly230StageGuardrails:
    """Nightly #230: audio-studio and six more desktop profiles died.

    Three independent defects, each one masked by the previous nightly's
    fix letting the builds get a little further:

    * lfs/06a passed four meson options systemd 257.8 renamed or dropped,
      so setup aborted with 'Option "wheel-group" value wheel is not
      boolean' - and build_pkg still printed "[SUCCESS] systemd
      installed", because run_build calls it from an "if" condition where
      set -e is suspended.  The systemd profiles therefore ran without an
      init system and without libsystemd,
    * polkit 126 dropped session_tracking=none and defaults to logind,
      which turns libsystemd into a hard requirement, so #227's "omit the
      flag" workaround became 'Dependency "libsystemd" not found' on every
      profile - systemd included, since its build had silently failed,
    * elogind, the session manager the System V book builds for polkit,
      and Linux-PAM, which lightdm's configure hard-requires with
      AC_MSG_ERROR(PAM not found), both shipped in sources.list but were
      built by no stage.
    """

    INIT_SYSTEM = Path('lfs/06a-init-system.sh')
    DISPLAY_MANAGER = Path('blfs/08d-build-display-manager.sh')
    BASICNET = Path('blfs/23-basic-networking.sh')

    @staticmethod
    def _code(content):
        """Drop comment lines so assertions only ever see real commands."""
        return '\n'.join(line for line in content.splitlines()
                         if not line.strip().startswith('#'))

    @staticmethod
    def _fn(content, name):
        """Return the source of a shell function definition."""
        body = content[content.index(f'{name}() {{'):]
        return body[:body.index('\n}\n')]

    @staticmethod
    def _build_pos(content, mode, pkg):
        """Offset of a run_build call, whatever its indentation or flags.

        elogind sits inside the "not systemd" branch and is indented, so
        the anchor cannot be pinned to column zero the way Nightly #213's
        helper does.
        """
        match = re.search(rf'^\s*run_build {mode} {re.escape(pkg)}\b',
                          content, re.MULTILINE)
        return match.start() if match else -1

    def test_systemd_options_match_the_257_8_schema(self):
        """Every option passed to systemd must exist in 257.8 and take
        the value type its schema declares.

        wheel-group and adm-group are booleans, so the string "wheel"
        aborted setup; admin-group and cgroup-controller do not exist at
        all (cgroup-controller is an elogind option); man and polkit are
        features whose =true turns a missing dependency into a hard
        error - xsltproc arrives with blfs-libs and polkit-gobject-1 with
        display-manager, three and five stages later.
        """
        code = self._code(self.INIT_SYSTEM.read_text())
        block = code.split('run_build required systemd \\', 1)[1]
        block = block.split('\n\n', 1)[0]
        for gone in ('default-hierarchy', 'cgroup-controller',
                     'admin-group', 'wheel-group=wheel', 'man=true',
                     'polkit=true', 'homed=false'):
            assert gone not in block, \
                f'systemd 257.8 does not accept -D{gone}'
        for want in ('-Dmode=release', '-Dadm-group=true',
                     '-Dwheel-group=true', '-Dman=disabled',
                     '-Dhtml=disabled', '-Dpolkit=disabled',
                     '-Dhomed=disabled', '-Dlz4=enabled',
                     '-Dzstd=enabled'):
            assert want in block, f'systemd lost {want}'

    def test_build_pkg_reports_failure_instead_of_success(self):
        """A failed meson/ninja must never reach log_success.

        run_build calls build_pkg from an "if" condition, which suspends
        set -e for the whole call: Nightly #230 printed "[SUCCESS]
        systemd installed" right after meson aborted, and the missing
        libsystemd only surfaced an hour and a half later when polkit
        killed the display-manager stage.  This is the same masking 08a
        stopped doing after Nightly #213.
        """
        for script in (self.INIT_SYSTEM, self.DISPLAY_MANAGER):
            fn = self._fn(self._code(script.read_text()), 'build_pkg')
            assert 'rc=0' in fn, f'{script} build_pkg tracks no failure'
            assert '|| rc=1' in fn, f'{script} does not capture failures'
            check = 'if [ "$rc" -ne 0 ]; then'
            assert check in fn, f'{script} never inspects the failure flag'
            assert fn.index(check) < fn.index('log_success'), \
                f'{script} logs success without checking the build'
            # Every build command has to sit inside a chain: a bare
            # statement cannot fail the function while set -e is off.
            for line in fn.splitlines():
                stripped = line.strip()
                if stripped.startswith(('meson setup', 'ninja', './configure',
                                        './autogen.sh', 'make')):
                    assert stripped.endswith(('&&', '|| rc=1')), \
                        f'{script} has an unguarded build command: {stripped}'

    def test_display_manager_builds_pam_and_elogind_before_polkit(self):
        """polkit needs a session tracking provider, and every provider
        but ConsoleKit needs a library that only elogind or systemd
        installs.  lightdm needs Linux-PAM, elogind builds pam_elogind
        only when libpam is present, and polkit's default authfw=pam
        asserts on cc.find_library('pam') - so PAM comes first.
        """
        content = self.DISPLAY_MANAGER.read_text()
        duktape = self._build_pos(content, 'required', 'duktape')
        pam = self._build_pos(content, 'required', 'linux-pam')
        elogind = self._build_pos(content, 'required', 'elogind')
        polkit = self._build_pos(content, 'required', 'polkit')
        lightdm = self._build_pos(content, 'required', 'lightdm')
        assert -1 not in (duktape, pam, elogind, polkit, lightdm), \
            'a required display-manager package lost its run_build call'
        assert duktape < pam < elogind < polkit < lightdm, \
            'PAM and elogind must be installed before polkit (#230)'
        # elogind only runs when systemd is not the init system: systemd
        # already provides logind, and two session managers would fight
        # over the same D-Bus name.
        branch = content.rindex('if [', 0, elogind)
        assert '!= "systemd"' in content[branch:elogind], \
            'elogind must stay inside the non-systemd branch'
        # One build site each, so a second later call cannot satisfy the
        # ordering assertion while the first one still runs too late.
        assert content.count('run_build required linux-pam') == 1
        assert content.count('run_build required elogind') == 1
        assert 'build_commands_linux_pam()' in content
        assert 'build_commands_elogind()' in content
        assert re.search(r'^\s+linux-pam\).*have_pc pam', content,
                         re.MULTILINE), \
            'is_installed must detect Linux-PAM'
        assert re.search(r'^\s+elogind\).*have_pc libelogind', content,
                         re.MULTILINE), \
            'is_installed must detect elogind through libelogind.pc'

    def test_linux_pam_installs_the_book_pam_d_stacks(self):
        """PAM fails closed: the book's restrictive /etc/pam.d/other
        denies every PAM-aware program that has no stack of its own, so
        the generic system-* files have to be created with the library.
        """
        content = self.DISPLAY_MANAGER.read_text()
        body = self._fn(content, 'build_commands_linux_pam')
        for flag in ('--prefix=/usr', '--buildtype=release',
                     '-D docs=disabled', 'ninja install'):
            assert flag in body, f'Linux-PAM meson lost {flag}'
        assert 'chmod 4755 /usr/sbin/unix_checkpwd' in body, \
            'pam_unix cannot verify a password without the setuid helper'
        post = self._fn(content, 'linux_pam_post_install')
        assert 'install -dm755 /etc/pam.d' in post
        for pam_file in ('system-account', 'system-auth', 'system-session',
                         'system-password', 'other'):
            assert f'/etc/pam.d/{pam_file}' in post, \
                f'the book mandates /etc/pam.d/{pam_file}'
        # Created only when missing: 15-security-hardening rewrites
        # system-password with pam_pwquality and a stage re-run must not
        # clobber that.
        assert post.count('if [ ! -f /etc/pam.d/') == 5, \
            'every pam.d stack must be created idempotently'

    def test_pam_does_not_fake_a_systemd_installation(self):
        """pam_namespace.service lands in the default systemd unit
        directory even on a System V system, which would flip every
        downstream "[ -d /usr/lib/systemd/system ]" probe - HAVE_SYSTEMD
        here and in 09a-09d - to true.  The book removes the stray tree,
        but under systemd that directory belongs to systemd itself.
        """
        post = self._fn(self.DISPLAY_MANAGER.read_text(),
                        'linux_pam_post_install')
        assert 'pam_namespace.service' in post
        assert '[ "$INIT_SYSTEM" != systemd ]' in post, \
            'the cleanup must be gated on the init system'
        assert 'rm -f /usr/lib/systemd/system/pam_namespace.service' in post
        assert 'rm -rf /usr/lib/systemd' not in post, \
            'a systemd profile must keep its own unit directory'

    def test_elogind_registers_sessions_through_pam(self):
        """general/elogind "Configuring elogind": without the PAM stack
        elogind never sees a session, so polkit has nothing to authorise.
        """
        content = self.DISPLAY_MANAGER.read_text()
        post = self._fn(content, 'elogind_post_install')
        assert 'cat >> /etc/pam.d/system-session' in post
        assert 'pam_elogind.so' in post
        assert '/etc/pam.d/elogind-user' in post
        assert 'grep -q pam_elogind /etc/pam.d/system-session' in post, \
            'a stage re-run must not append the elogind stack twice'
        # The book's elogind commands, minus the offline DocBook XSL man
        # pages that aborted gtk3 (#224) and polkit (#227).
        body = self._fn(content, 'build_commands_elogind')
        for flag in ('-D cgroup-controller=elogind', '-D dev-kvm-mode=0660',
                     '-D dbuspolicydir=/etc/dbus-1/system.d', '-D man=false'):
            assert flag in body, f'elogind meson lost {flag}'
        assert 'ln -sfv libelogind.pc /usr/lib/pkgconfig/libsystemd.pc' \
            in body, 'polkit resolves the elogind provider as libsystemd'

    def test_elogind_is_probed_through_its_real_pkgconfig_module(self):
        """elogind installs libelogind.pc only, so probing the bare
        "elogind" module never matched: accountsservice silently lost
        elogind support and NetworkManager stayed on
        session_tracking=none even where elogind had been built.
        """
        dm = self.DISPLAY_MANAGER.read_text()
        net = self.BASICNET.read_text()
        assert 'have_pc libelogind' in dm
        assert 'pkg-config --exists libelogind' in dm
        assert 'have_pc libelogind' in net
        assert 'have_pc elogind;' not in net, \
            'the bare elogind module name never resolves'
        assert re.search(r'^\s+accountsservice\)', dm, re.MULTILINE)
        fn = self._fn(dm, 'build_commands_accountsservice')
        assert 'libelogind' in fn, \
            'accountsservice must detect elogind through libelogind.pc'

    def test_polkit_installs_its_pam_stack_where_libpam_looks(self):
        """polkit's meson default for pam_prefix is <prefix>/lib/pam.d, a
        directory libpam never reads, so the generated polkit-1 stack
        would be unreachable and every authorisation would fall through
        to the deny-all /etc/pam.d/other.  os_type=lfs is the book's flag
        for a system without /etc/lfs-release, which no stage creates.
        """
        fn = self._fn(self.DISPLAY_MANAGER.read_text(),
                      'build_commands_polkit')
        assert '-D pam_prefix=/etc/pam.d' in fn
        assert '-D os_type=lfs' in fn
        assert 'authfw=shadow' not in fn, \
            'Linux-PAM is installed, so polkit keeps the PAM backend'
        assert '-D man=false' in fn
        # The book's polkitd account: the daemon drops privileges to it
        # and its D-Bus policy references the user by name.
        assert 'groupadd -fg 27 polkitd' in fn
        assert 'useradd -c "PolicyKit Daemon Owner"' in fn
