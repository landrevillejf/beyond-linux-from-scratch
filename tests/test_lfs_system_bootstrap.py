#!/usr/bin/env python3

import os
import subprocess
from pathlib import Path


def test_lfs_system_bootstraps_shell_and_env(temp_dir):
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    lfs_dir = temp_dir / "lfs-root"
    fake_bin = temp_dir / "fake-bin"
    lfs_tgt = f"{os.uname().machine}-lfs-linux-gnu"

    (lfs_dir / "tools" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "usr" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "var").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources" / "placeholder.txt").write_text("ok\n")

    for tool in ("gcc", "ld", "as"):
        tool_path = lfs_dir / "tools" / "bin" / f"{lfs_tgt}-{tool}"
        tool_path.write_text("#!/bin/sh\nexit 0\n")
        tool_path.chmod(0o755)

    fake_bin.mkdir(parents=True, exist_ok=True)

    (fake_bin / "sudo").write_text("""#!/bin/sh
"$@"
""")
    (fake_bin / "mount").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "umount").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "chroot").write_text(f"""#!/bin/sh
root="$1"
shift

if [ "$1" = "/bin/bash" ] && [ "$2" = "-c" ] && [ "$3" = "exit 0" ]; then
    [ -x "$root/bin/bash" ] || exit 1
    exit 0
fi

mkdir -p "$root/usr/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/bash"
chmod +x "$root/usr/bin/bash"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/env"
chmod +x "$root/usr/bin/env"
exit 0
""")

    for helper in ("sudo", "mount", "umount", "chroot"):
        (fake_bin / helper).chmod(0o755)

    env = {
        **os.environ,
        "LFS": str(lfs_dir),
        "LFS_TGT": lfs_tgt,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
    }

    result = subprocess.run(
        ["bash", str(script)],
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert os.path.lexists(lfs_dir / "bin" / "bash")
    assert (lfs_dir / "bin" / "sh").is_symlink()
    assert os.readlink(lfs_dir / "bin" / "sh") == "bash"
    assert (lfs_dir / "usr" / "bin" / "env").exists()


def test_lfs_system_bootstrap_with_image_root_layout(temp_dir):
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    output_dir = temp_dir / "build-output"
    lfs_dir = output_dir / "image"
    fake_bin = temp_dir / "fake-bin"
    lfs_tgt = f"{os.uname().machine}-lfs-linux-gnu"

    (lfs_dir / "tools" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources").mkdir(parents=True, exist_ok=True)
    (output_dir / "sources").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "usr" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "var").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources" / "placeholder.txt").write_text("ok\n")
    (output_dir / "sources" / "placeholder.txt").write_text("ok\n")

    for tool in ("gcc", "ld", "as"):
        tool_path = lfs_dir / "tools" / "bin" / f"{lfs_tgt}-{tool}"
        tool_path.write_text("#!/bin/sh\nexit 0\n")
        tool_path.chmod(0o755)

    fake_bin.mkdir(parents=True, exist_ok=True)

    (fake_bin / "sudo").write_text("""#!/bin/sh
"$@"
""")
    (fake_bin / "mount").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "umount").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "chroot").write_text(f"""#!/bin/sh
root="$1"
shift

if [ "$1" = "/bin/bash" ] && [ "$2" = "-c" ] && [ "$3" = "exit 0" ]; then
    [ -x "$root/bin/bash" ] || exit 1
    exit 0
fi

mkdir -p "$root/usr/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/bash"
chmod +x "$root/usr/bin/bash"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/env"
chmod +x "$root/usr/bin/env"
exit 0
""")

    for helper in ("sudo", "mount", "umount", "chroot"):
        (fake_bin / helper).chmod(0o755)

    env = {
        **os.environ,
        "LFS": str(output_dir),
        "LFS_TGT": lfs_tgt,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
    }

    result = subprocess.run(
        ["bash", str(script)],
        cwd=repo_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert os.path.lexists(lfs_dir / "bin" / "bash")
    assert (lfs_dir / "bin" / "sh").is_symlink()
    assert os.readlink(lfs_dir / "bin" / "sh") == "bash"
    assert (lfs_dir / "usr" / "bin" / "env").exists()


def test_lfs_system_diffutils_pathmax_workaround_present():
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    assert 'if [ "$pkg" = "diffutils" ]; then' in content
    assert 'grep -q "PATH_MAX" lib/stackvma.c' in content
    assert '! grep -q "#include <limits.h>" lib/stackvma.c' in content
    assert "sed -i '1s/^/#include <limits.h>\\n/' lib/stackvma.c" in content
    assert 'cflags="-D_GNU_SOURCE -DPATH_MAX=4096"' in content
    assert 'CFLAGS="$cflags" ./configure --prefix=/usr --sysconfdir=/etc' in content
    assert 'CFLAGS="$cflags" make -j$(nproc)' in content


def test_lfs_system_does_not_bind_mount_host_usr():
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    assert 'mount --bind /usr "$LFS"/usr' not in content
    assert 'umount "$LFS"/usr' not in content


def test_lfs_system_uses_cross_compiler_hostcc_for_linux_headers():
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    # The toolchain stage already installs Linux API headers to $LFS/usr/include
    # before lfs-system runs.  lfs-system must check for their presence and skip
    # reinstallation when they already exist, because the host gcc is not
    # accessible inside the chroot (PATH=/tools/bin:/bin:/usr/bin:/sbin).
    # When the headers are absent, the cross-compiler is used as HOSTCC with an
    # explicit --sysroot=/ override so that it can find the C headers (glibc +
    # Linux) that were installed to /usr/include by the toolchain stage.
    assert 'if [ -d /usr/include/linux ] && [ -f /usr/include/linux/types.h ]; then' in content
    assert 'make HOSTCC="${LFS_TGT}-gcc" HOSTCFLAGS="--sysroot=/" headers' in content
    assert 'make HOSTCC=gcc headers' not in content
    expected_tool_loop = (
        "for tool in env xz bzip2 expr grep sed awk find xargs cut head tail"
        " wc tr sort uniq dirname basename tar uname make rm mkdir cp mv ln rmdir chmod ld bison m4; do"
    )
    assert expected_tool_loop in content
    assert 'copy_tool_with_libs "$(command -v python3)" "$LFS/usr/bin/python3"' in content
    assert 'ln -sfn python3 "$LFS/usr/bin/python"' in content


def test_lfs_system_copies_python_stdlib_into_chroot():
    """glibc 2.39+ runs Python scripts (gen-as-const.py) during compilation.
    Without the Python standard library in the chroot, the build fails with
    'ModuleNotFoundError: No module named encodings'.  The script must copy
    the stdlib directory into the chroot alongside the python3 binary."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    assert 'python3 -c "import sysconfig; print(sysconfig.get_path(\'stdlib\'))"' in content
    assert 'run_privileged cp -r "$PYTHON_STDLIB"/. "$LFS$PYTHON_STDLIB"/' in content


def test_lfs_system_copies_bison_datadir_into_chroot():
    """Bootstrapped host bison needs its datadir templates in the chroot.
    Without /usr/share/bison/m4sugar/m4sugar.m4, glibc's gettext build fails."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    assert '[ ! -f "$LFS/usr/share/bison/m4sugar/m4sugar.m4" ]' in content
    assert 'host_bison_datadir="$(bison --print-datadir 2>/dev/null || true)"' in content
    assert 'run_privileged cp -r "$host_bison_datadir"/. "$LFS$host_bison_datadir"/' in content


def test_lfs_system_glibc_install_uses_toolchain_bash():
    """glibc 2.34+ ld.so requires the private __nptl_change_stack_perm symbol
    from any libc.so.6 it loads.  The bootstrapped /bin/bash is linked against
    the HOST libc (e.g. /lib/x86_64-linux-gnu/libc.so.6 on ubuntu-latest) which
    does not expose that private symbol, so make recipes fail the moment the new
    ld.so is installed.  The inner build script must export
    SHELL=/tools/bin/bash and the glibc 'make install' must also pass
    SHELL=/tools/bin/bash explicitly so that all make recipe subshells use the
    cross-compiled toolchain bash, which links against /usr/lib/libc.so.6
    (replaced by the new glibc early in the install sequence) and is therefore
    always ABI-compatible with the new ld.so."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05-build-lfs-system.sh"
    content = script.read_text()

    # Inner script env must use the toolchain bash, not the HOST-bootstrapped one
    assert 'export SHELL=/tools/bin/bash' in content
    assert 'export CONFIG_SHELL=/tools/bin/bash' in content
    assert 'export SHELL=/bin/bash' not in content
    assert 'export CONFIG_SHELL=/bin/bash' not in content

    # glibc make install must also explicitly pass the toolchain bash
    assert 'make RM=/tools/bin/rm SHELL=/tools/bin/bash install' in content
    # The old workaround that used HOST-libc paths must be gone
    assert 'LD_LIBRARY_PATH=/lib:/lib/x86_64-linux-gnu make' not in content
