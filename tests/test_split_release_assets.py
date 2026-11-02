"""Behavioral tests for tools/split-release-assets.sh.

GitHub's Release API rejects any asset whose size is not strictly "less than
2147483648" bytes.  lg3d Nightly #69 hit exactly that with its 2 856 MB live
ISO: every small asset of the release uploaded, both ISOs were refused, and the
nightly published a release with nothing bootable in it.  The helper cuts such
a payload into 1900 MiB parts and writes the manifest a consumer needs to put
them back together.

These tests run the real script with a shrunk cap (a 2.8 GiB fixture would be
silly) and prove the parts restore the original bytes, because a split that is
not byte-exact is worse than no split at all.
"""

import hashlib
import os
import stat
import subprocess
from pathlib import Path

HELPER = Path("tools/split-release-assets.sh")
MAX_BYTES = 2 * 1024 * 1024 - 1  # split anything above 2 MiB
PART_SIZE = "1m"
ISO_NAME = "lfs-0.57.4-lg3d-x86_64-systemd-20261102.iso"
RELEASE_URL = (
    "https://github.com/o/r/releases/download/"
    "lg3d-nightly-20261102/" + ISO_NAME
)


def run_helper(*args, expect=0):
    result = subprocess.run(
        ["bash", str(HELPER), *args],
        capture_output=True,
        text=True,
    )
    assert result.returncode == expect, (
        f"exit {result.returncode}\nstdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
    return result


def make_iso(directory, size=3 * 1024 * 1024 + 7):
    """Write an odd size so a lost or duplicated tail byte is caught."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ISO_NAME
    data = os.urandom(size)
    path.write_bytes(data)
    return path, hashlib.sha256(data).hexdigest()


def make_pointer(directory, digest):
    pointer = directory / "lfs-installer.iso.pointer"
    pointer.write_text(
        f"iso_name={ISO_NAME}\nsha256={digest}\ndownload_url={RELEASE_URL}\n"
    )
    pointer.chmod(0o644)
    return pointer


def manifest_of(directory):
    return (directory / f"{ISO_NAME}.parts").read_text()


def kv(text, key):
    for line in text.splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1]
    raise AssertionError(f"{key}= missing from manifest:\n{text}")


class TestSplitReleaseAssetsHelper:
    def test_script_exists_and_is_strict(self):
        assert HELPER.is_file()
        text = HELPER.read_text()
        assert "set -euo pipefail" in text
        assert "bash -n" not in text
        # The cap is what the API states, verbatim; a typo here is the bug.
        assert "ASSET_CAP_BYTES=2147483648" in text

    def test_syntax_is_valid(self):
        run_helper("--help")  # proves the file parses and runs at all

    def test_splits_and_removes_the_original(self, tmp_path):
        leg = tmp_path / "artifacts/release-artifacts-lg3d-systemd-x86_64"
        _, digest = make_iso(leg)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(tmp_path / "artifacts"))
        parts = sorted(leg.glob(f"{ISO_NAME}.part-*"))
        assert [p.name for p in parts] == [
            f"{ISO_NAME}.part-00",
            f"{ISO_NAME}.part-01",
            f"{ISO_NAME}.part-02",
            f"{ISO_NAME}.part-03",
        ]
        assert not (leg / ISO_NAME).exists()
        assert (leg / f"{ISO_NAME}.parts").is_file()
        assert (leg / f"{ISO_NAME}.parts.sha256").is_file()
        assert kv(manifest_of(leg), "sha256") == digest

    def test_parts_never_exceed_the_asset_cap(self, tmp_path):
        leg = tmp_path / "leg"
        make_iso(leg, size=12 * 1024 * 1024)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        for part in leg.glob(f"{ISO_NAME}.part-*"):
            assert part.stat().st_size <= MAX_BYTES

    def test_reassembly_is_byte_exact(self, tmp_path):
        leg = tmp_path / "leg"
        _, digest = make_iso(leg)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        # Follow the manifest's own assemble line, exactly as a downloader
        # would, rather than a glob the test invented.
        assemble = kv(manifest_of(leg), "assemble")
        subprocess.run(["bash", "-c", f"cd {leg} && {assemble}"], check=True)
        assert hashlib.sha256((leg / ISO_NAME).read_bytes()).hexdigest() == digest

    def test_manifest_declares_the_whole_file(self, tmp_path):
        leg = tmp_path / "leg"
        path, digest = make_iso(leg)
        size = path.stat().st_size
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        text = manifest_of(leg)
        assert kv(text, "file") == ISO_NAME
        assert kv(text, "size") == str(size)
        assert kv(text, "sha256") == digest
        assert kv(text, "part_count") == "4"
        assert kv(text, "parts") == " ".join(
            f"{ISO_NAME}.part-{i:02d}" for i in range(4)
        )
        # Explicit list, not a glob: a re-dispatched dated tag can leave a
        # stale tail part on the release, and `cat *.part*` would also pull in
        # this very manifest.
        assert "$(ls" not in text
        assert "*.part*" in text  # the warning about it

    def test_part_checksums_are_verifiable(self, tmp_path):
        leg = tmp_path / "leg"
        make_iso(leg)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        checks = subprocess.run(
            ["sha256sum", "-c", f"{ISO_NAME}.parts.sha256"],
            cwd=leg, capture_output=True, text=True,
        )
        assert checks.returncode == 0, checks.stdout + checks.stderr
        assert ": OK" in checks.stdout

    def test_pointer_is_repaired_not_dangling(self, tmp_path):
        leg = tmp_path / "leg"
        _, digest = make_iso(leg)
        pointer = make_pointer(leg, digest)
        before = stat.S_IMODE(pointer.stat().st_mode)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        text = pointer.read_text()
        assert f"download_url=https://github.com/o/r/releases/download/" \
               f"lg3d-nightly-20261102/{ISO_NAME}.parts" in text
        assert f"parts_manifest={ISO_NAME}.parts" in text
        assert text.startswith(f"iso_name={ISO_NAME}")
        assert f"sha256={digest}" in text  # the whole-ISO digest survives
        assert "assemble=cat " in text
        # mktemp's 0600 must not leak into a published pointer.
        assert stat.S_IMODE(pointer.stat().st_mode) == before

    def test_files_under_the_cap_are_untouched(self, tmp_path):
        leg = tmp_path / "leg"
        keep = leg / "vmlinuz-lg3d-x86_64-systemd"
        keep.parent.mkdir(parents=True)
        keep.write_bytes(os.urandom(1024 * 1024))
        result = run_helper("--max-bytes", str(MAX_BYTES), "--part-size",
                            PART_SIZE, str(leg))
        assert keep.is_file()
        assert "nothing to split" in result.stdout

    def test_size_exactly_at_the_cap_is_left_alone(self, tmp_path):
        # The API rejects "not less than 2147483648", so a file of exactly
        # MAX_BYTES still uploads whole and must not be cut.
        leg = tmp_path / "leg"
        make_iso(leg, size=MAX_BYTES)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        assert (leg / ISO_NAME).is_file()

    def test_one_byte_over_the_cap_is_cut(self, tmp_path):
        leg = tmp_path / "leg"
        make_iso(leg, size=MAX_BYTES + 1)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        assert not (leg / ISO_NAME).exists()
        assert len(list(leg.glob(f"{ISO_NAME}.part-*"))) == 2

    def test_second_run_does_not_resplit_or_rename_parts(self, tmp_path):
        leg = tmp_path / "leg"
        make_iso(leg)
        args = ("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                str(leg))
        run_helper(*args)
        names = sorted(p.name for p in leg.iterdir())
        result = run_helper(*args)
        assert "nothing to split" in result.stdout
        assert sorted(p.name for p in leg.iterdir()) == names

    def test_dry_run_changes_nothing(self, tmp_path):
        leg = tmp_path / "leg"
        path, _ = make_iso(leg)
        result = run_helper("--max-bytes", str(MAX_BYTES), "--part-size",
                            PART_SIZE, "--dry-run", str(leg))
        assert "would split" in result.stdout
        assert path.is_file()
        assert not list(leg.glob(f"{ISO_NAME}.part-*"))

    def test_multiple_legs_in_one_download_tree(self, tmp_path):
        # create-release downloads one subdirectory per matrix leg; the ISO
        # two levels down is the actual production layout (Nightly #69).
        for init in ("systemd", "sysvinit"):
            leg = tmp_path / f"artifacts/release-artifacts-lg3d-{init}-x86_64"
            leg.mkdir(parents=True)
            (leg / f"lfs-0.57.4-lg3d-x86_64-{init}-20261102.iso").write_bytes(
                os.urandom(3 * 1024 * 1024)
            )
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(tmp_path / "artifacts"))
        for init in ("systemd", "sysvinit"):
            leg = tmp_path / f"artifacts/release-artifacts-lg3d-{init}-x86_64"
            stem = f"lfs-0.57.4-lg3d-x86_64-{init}-20261102.iso"
            assert not (leg / stem).exists()
            assert len(list(leg.glob(f"{stem}.part-*"))) == 3

    def test_outputs_stay_readable_when_invoked_through_sudo(self, tmp_path,
                                                              monkeypatch):
        """release.yml and build-iso-from-cache.yml split inside a root-owned
        build-release/, so the parts are created by root while the step that
        uploads them runs as the runner.  Nightly #221 lost three profiles to
        exactly that mismatch; the helper must hand every file it writes back to
        the caller.  Emulated with a restrictive umask and SUDO_UID/SUDO_GID set
        to the current user."""
        leg = tmp_path / "leg"
        make_iso(leg)
        make_pointer(leg, "0" * 64)
        monkeypatch.setenv("SUDO_UID", str(os.getuid()))
        monkeypatch.setenv("SUDO_GID", str(os.getgid()))
        result = subprocess.run(
            ["bash", "-c",
             f"umask 077; bash {HELPER} --max-bytes {MAX_BYTES} "
             f"--part-size {PART_SIZE} {leg}"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        created = [leg / f"{ISO_NAME}.part-{i:02d}" for i in range(4)] + [
            leg / f"{ISO_NAME}.parts",
            leg / f"{ISO_NAME}.parts.sha256",
            leg / "lfs-installer.iso.pointer",
        ]
        for path in created:
            assert path.is_file(), f"{path} missing"
            assert stat.S_IMODE(path.stat().st_mode) == 0o644, (
                f"{path.name} is {oct(path.stat().st_mode)}, "
                f"so the unprivileged uploader cannot read it"
            )

    def test_part_size_must_itself_fit_under_the_cap(self, tmp_path):
        leg = tmp_path / "leg"
        leg.mkdir()
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", "1g",
                   str(leg), expect=2)

    def test_missing_directory_is_a_usage_error(self, tmp_path):
        run_helper(str(tmp_path / "nope"), expect=2)

    def test_no_directory_is_a_usage_error(self):
        result = run_helper(expect=2)
        assert "no directory given" in result.stderr

    def test_unknown_option_is_a_usage_error(self, tmp_path):
        run_helper("--frobnicate", str(tmp_path), expect=2)

    def test_numeric_suffix_widens_past_ninety_nine_parts(self, tmp_path):
        # -a 2 stops at 99 pieces; a payload needing more must still get an
        # ordered, zero-padded set rather than silently truncating.
        leg = tmp_path / "leg"
        make_iso(leg, size=101 * 1024 * 1024)
        run_helper("--max-bytes", str(MAX_BYTES), "--part-size", PART_SIZE,
                   str(leg))
        parts = sorted(leg.glob(f"{ISO_NAME}.part-*"))
        assert len(parts) == 101
        assert parts[0].name.endswith(".part-000")
        assert parts[-1].name.endswith(".part-100")
        subprocess.run(
            ["bash", "-c", f"cd {leg} && {kv(manifest_of(leg), 'assemble')}"],
            check=True,
        )
        assert (leg / ISO_NAME).stat().st_size == 101 * 1024 * 1024
