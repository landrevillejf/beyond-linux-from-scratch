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
