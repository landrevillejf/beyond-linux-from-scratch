#!/usr/bin/env python3

import os
import re
import subprocess
from pathlib import Path

BOOTSTRAP_TOOLS = (
    "bash", "bison", "m4", "xz", "bzip2", "expr", "grep", "sed", "awk",
    "find", "xargs", "cut", "head", "tail", "wc", "tr", "sort", "uniq",
    "dirname", "basename", "tar", "uname", "make", "rm", "mkdir", "cp",
    "mv", "ln", "rmdir", "chmod",
)


def create_bootstrap_tools(lfs_dir, lfs_tgt):
    tools_dir = lfs_dir / "tools" / "bin"
    tools_dir.mkdir(parents=True, exist_ok=True)

    for tool in BOOTSTRAP_TOOLS:
        tool_path = tools_dir / tool
        tool_path.write_text("#!/bin/sh\nexit 0\n")
        tool_path.chmod(0o755)

    for tool in ("gcc", "ld", "as"):
        tool_path = tools_dir / f"{lfs_tgt}-{tool}"
        tool_path.write_text("#!/bin/sh\nexit 0\n")
        tool_path.chmod(0o755)


def test_lfs_system_bootstraps_shell_and_env(temp_dir):
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05a-build-lfs-basic.sh"
    lfs_dir = temp_dir / "lfs-root"
    fake_bin = temp_dir / "fake-bin"
    lfs_tgt = f"{os.uname().machine}-lfs-linux-gnu"

    (lfs_dir / "tools" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "usr" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "var").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources" / "placeholder.txt").write_text("ok\n")

    # ➕ Créer le répertoire parent "sources" pour que LEGACY_SOURCES_HOST existe
    (temp_dir / "sources").mkdir(parents=True, exist_ok=True)
    (temp_dir / "sources" / "placeholder.txt").write_text("ok\n")

    create_bootstrap_tools(lfs_dir, lfs_tgt)

    fake_bin.mkdir(parents=True, exist_ok=True)

    # Faux sudo, mount, umount, chroot, ldd, python3 (existants)
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
    [ -L "$root/bin/bash" ] || exit 1
    exit 0
fi
mkdir -p "$root/usr/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/bash"
chmod +x "$root/usr/bin/bash"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/env"
chmod +x "$root/usr/bin/env"
exit 0
""")
    (fake_bin / "ldd").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "python3").write_text("""#!/bin/sh
if echo "$*" | grep -q "get_path"; then
    printf ''
    exit 0
fi
exit 0
""")
    # ➕ Ajout d'un faux chown pour éviter l'erreur "illegal group name"
    (fake_bin / "chown").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "chown").chmod(0o755)

    for helper in ("sudo", "mount", "umount", "chroot", "ldd", "python3", "chown"):
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
    assert os.readlink(lfs_dir / "bin" / "bash") == "/tools/bin/bash"


def test_lfs_system_bootstrap_with_image_root_layout(temp_dir):
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05a-build-lfs-basic.sh"
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

    create_bootstrap_tools(lfs_dir, lfs_tgt)

    fake_bin.mkdir(parents=True, exist_ok=True)

    # Faux sudo, mount, umount, chroot, ldd, python3 (existants)
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
    [ -L "$root/bin/bash" ] || exit 1
    exit 0
fi
mkdir -p "$root/usr/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/bash"
chmod +x "$root/usr/bin/bash"
printf '#!/bin/sh\\nexit 0\\n' > "$root/usr/bin/env"
chmod +x "$root/usr/bin/env"
exit 0
""")
    (fake_bin / "ldd").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "python3").write_text("""#!/bin/sh
if echo "$*" | grep -q "get_path"; then
    printf ''
    exit 0
fi
exit 0
""")
    # ➕ Ajout d'un faux chown pour éviter l'erreur "illegal group name"
    (fake_bin / "chown").write_text("""#!/bin/sh
exit 0
""")
    (fake_bin / "chown").chmod(0o755)

    for helper in ("sudo", "mount", "umount", "chroot", "ldd", "python3", "chown"):
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
    assert os.readlink(lfs_dir / "bin" / "bash") == "/tools/bin/bash"


def test_lfs_system_diffutils_pathmax_workaround_present():
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    # The PATH_MAX workaround is now in a case statement within build_simple()
    assert 'diffutils)' in content
    assert 'grep -q "PATH_MAX" lib/stackvma.c' in content
    assert '! grep -q "#include <limits.h>" lib/stackvma.c' in content
    assert "sed -i '1s/^/#include <limits.h>\\n/' lib/stackvma.c" in content
    assert 'cflags="-D_GNU_SOURCE -DPATH_MAX=4096"' in content
    assert 'CFLAGS="$cflags" ./configure --prefix=/usr --sysconfdir=/etc' in content
    assert 'CFLAGS="$cflags" make -j$(nproc)' in content


def test_lfs_system_does_not_bind_mount_host_usr():
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05a-build-lfs-basic.sh"
    content = script.read_text()

    assert 'mount --bind /usr "$LFS"/usr' not in content
    assert 'umount "$LFS"/usr' not in content


def test_lfs_system_uses_toolchain_bootstrap_and_cross_compiler():
    repo_root = Path(__file__).resolve().parent.parent
    script_basic = repo_root / "lfs" / "05a-build-lfs-basic.sh"
    script_system = repo_root / "lfs" / "05b-build-lfs-system.sh"
    basic_content = script_basic.read_text()
    system_content = script_system.read_text()

    # The toolchain stage already installs Linux API headers to $LFS/usr/include
    # before lfs-system runs.  lfs-system must check for their presence and skip
    # reinstallation when they already exist, because the host gcc is not
    # accessible inside the chroot (PATH=/tools/bin:/bin:/usr/bin:/sbin).
    # When the headers are absent, the cross-compiler is used as HOSTCC with an
    # explicit --sysroot=/ override so that it can find the C headers (glibc +
    # Linux) that were installed to /usr/include by the toolchain stage.
    assert 'if [ -d /usr/include/linux ] && [ -f /usr/include/linux/types.h ]; then' in system_content
    assert 'make HOSTCC="${LFS_TGT}-gcc" HOSTCFLAGS="--sysroot=/" headers' in system_content
    assert 'make HOSTCC=gcc headers' not in system_content
    # Bootstrap function is in 05a
    assert 'local required_tools=(' in basic_content
    assert 'bash bison m4 xz bzip2 expr grep sed awk' in basic_content
    assert '[ ! -x "$LFS/tools/bin/$tool" ]' in basic_content
    assert 'ln -sfn /tools/bin/bash "$LFS/bin/bash"' in basic_content
    assert 'ln -sfn bash "$LFS/bin/sh"' in basic_content


def test_lfs_system_does_not_copy_host_python():
    """Python from the build host must not be copied into the target root."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    assert "copy_tool_with_libs" not in content
    assert 'command -v python3' not in content


def test_lfs_system_does_not_copy_host_bison_data():
    """Bison and its templates must be supplied by the temporary toolchain."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    assert "host_bison_datadir" not in content
    assert 'bison --print-datadir' not in content


def test_lfs_system_does_not_copy_host_libraries():
    """The target root must not inherit libraries from the build host."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    assert 'find /lib /usr/lib' not in content
    assert 'Copied libtinfo' not in content


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
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
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


def test_lfs_system_rebuilds_linker_cache_after_glibc_install():
    """The new target glibc must be preferred after it is installed."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    assert '/etc/ld.so.conf' in content
    assert '/sbin/ldconfig' in content
    assert "printf '/usr/lib" in content
    assert 'LD_LIBRARY_PATH=/usr/lib' in content

def test_lfs_system_binutils_build_disables_makeinfo():
    """Binutils 2.45 may still try to build doc/chew.stamp even with
    --disable-doc.  Pass MAKEINFO=missing so make skips info doc generation
    inside the chroot where texinfo/makeinfo is not yet installed, and set
    CC_FOR_BUILD to the cross-compiler so build-side host tools (e.g. chew)
    are not linked against the absent host gcc."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05b-build-lfs-system.sh"
    content = script.read_text()

    assert '--disable-doc' in content
    assert 'MAKEINFO=missing' in content
    assert 'CC_FOR_BUILD=' in content
    assert '--without-zstd' in content
    assert '--with-system-zlib' not in content.split('echo "binutils done"')[0]


def test_lfs_system_creates_dynamic_linker_symlink():
    """The cross-compiler embeds /tools/lib/ld-linux-x86-64.so.2 as the ELF
    PT_INTERP, but glibc installs the actual linker under /lib64 or /usr/lib.
    The ensure_bootstrap_chroot_shell function must create a symlink so the
    kernel can find the interpreter when executing /tools/bin/bash."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05a-build-lfs-basic.sh"
    content = script.read_text()

    # Must search for the linker in the standard glibc install locations
    assert 'lib64/ld-linux-x86-64.so.2' in content
    assert 'usr/lib/ld-linux-x86-64.so.2' in content
    # Must create the symlink at the expected location
    assert 'tools/lib/ld-linux-x86-64.so.2' in content
    assert 'ln -sf' in content


def test_lfs_system_dynamic_linker_symlink_created_at_lib64(temp_dir):
    """When glibc installs the dynamic linker at /lib64, the bootstrap must
    create a symlink at /tools/lib/ld-linux-x86-64.so.2 pointing to it."""
    repo_root = Path(__file__).resolve().parent.parent
    script = repo_root / "lfs" / "05a-build-lfs-basic.sh"
    lfs_dir = temp_dir / "lfs-root"
    fake_bin = temp_dir / "fake-bin"
    lfs_tgt = f"{os.uname().machine}-lfs-linux-gnu"

    (lfs_dir / "tools" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "usr" / "bin").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "var").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "sources" / "placeholder.txt").write_text("ok\n")
    (temp_dir / "sources").mkdir(parents=True, exist_ok=True)
    (temp_dir / "sources" / "placeholder.txt").write_text("ok\n")

    create_bootstrap_tools(lfs_dir, lfs_tgt)

    # Place a fake dynamic linker at /lib64 (simulating glibc install)
    (lfs_dir / "lib64").mkdir(parents=True, exist_ok=True)
    (lfs_dir / "lib64" / "ld-linux-x86-64.so.2").write_text("fake-linker")

    fake_bin.mkdir(parents=True, exist_ok=True)
    (fake_bin / "sudo").write_text('#!/bin/sh\n"$@"\n')
    (fake_bin / "mount").write_text('#!/bin/sh\nexit 0\n')
    (fake_bin / "umount").write_text('#!/bin/sh\nexit 0\n')
    (fake_bin / "chroot").write_text(f"""#!/bin/sh
root="$1"
shift
if [ "$1" = "/bin/bash" ] && [ "$2" = "-c" ] && [ "$3" = "exit 0" ]; then
    [ -L "$root/bin/bash" ] || exit 1
    exit 0
fi
exit 0
""")
    (fake_bin / "ldd").write_text('#!/bin/sh\nexit 0\n')
    (fake_bin / "chown").write_text('#!/bin/sh\nexit 0\n')
    for helper in ("sudo", "mount", "umount", "chroot", "ldd", "chown"):
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
    # Verify the symlink was created
    linker_symlink = lfs_dir / "tools" / "lib" / "ld-linux-x86-64.so.2"
    assert linker_symlink.is_symlink(), "Dynamic linker symlink not created"
    target = os.readlink(str(linker_symlink))
    assert "lib64" in target, f"Symlink should point to lib64 location, got: {target}"
