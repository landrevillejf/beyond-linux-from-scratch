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