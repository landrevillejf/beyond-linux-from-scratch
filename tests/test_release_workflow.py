from pathlib import Path


def test_release_workflow_restores_lfs_ownership_after_cache_copy():
    workflow = Path(".github/workflows/release.yml").read_text()
    copy_command = "sudo cp -v /tmp/lfs-sources/* /tmp/lfs-build/build-release/sources/ 2>/dev/null || true"
    chown_command = "sudo chown -R lfs:lfs /tmp/lfs-build/build-release"

    assert copy_command in workflow
    assert chown_command in workflow
    assert workflow.index(copy_command) < workflow.index(chown_command)


def test_release_workflow_ensures_lfs_owns_build_dir_before_builder_runs():
    """Verify a full-tree chown is run immediately before builder.py.

    The root cause of the v0.52.14 release-job failure was a PermissionError
    when ``sudo -u lfs python3 builder.py`` tried to create its log directory
    inside ``/tmp/lfs-build/build-release/``.  Directories created by earlier
    steps with ``sudo mkdir`` are root-owned; the per-step ``chown`` scoped to
    ``build-release/`` is not sufficient when the cache is absent or a future
    step leaves root-owned content elsewhere in the tree.

    This test asserts that a defensive ``sudo chown -R lfs:lfs /tmp/lfs-build``
    (covering the whole build tree) is present in the workflow AND is ordered
    AFTER the test step but BEFORE the builder invocation.
    """
    workflow = Path(".github/workflows/release.yml").read_text()

    run_tests_cmd = "python3 -m pytest tests/"
    full_chown_cmd = "sudo chown -R lfs:lfs /tmp/lfs-build"
    build_cmd = "sudo -u lfs python3 builder.py"

    assert run_tests_cmd in workflow, "Run-tests step not found in release workflow"
    assert full_chown_cmd in workflow, (
        "Missing 'sudo chown -R lfs:lfs /tmp/lfs-build' step in release workflow"
    )
    assert build_cmd in workflow, "builder.py invocation not found in release workflow"

    # The *last* occurrence of the full-tree chown must appear after the test
    # runner step and before the builder.py invocation, ensuring lfs owns the
    # entire /tmp/lfs-build tree at the moment builder.py starts.
    last_chown_pos = workflow.rfind(full_chown_cmd)
    tests_pos = workflow.index(run_tests_cmd)
    build_pos = workflow.index(build_cmd)

    assert tests_pos < last_chown_pos, (
        "Full-tree chown must appear after the test step to guard against any "
        "root-owned content created during test collection or coverage reporting"
    )
    assert last_chown_pos < build_pos, (
        "Full-tree chown must appear before the builder.py invocation so that "
        "the lfs user can create its log directory without a PermissionError"
    )


class TestReleasePipelineHardening:
    """Guardrails for signing, compat pointers and 2 GB asset splitting."""

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def test_nightly_signing_step_is_secret_guarded(self):
        workflow = self._read("nightly.yml")
        assert "HAVE_GPG_KEY: ${{ secrets.GPG_PRIVATE_KEY != '' }}" in workflow
        assert "if: env.HAVE_GPG_KEY == 'true'" in workflow
        assert "gpg --batch --import" in workflow
        assert "--detach-sign --armor" in workflow

    def test_nightly_publishes_compat_iso_pointer(self):
        workflow = self._read("nightly.yml")
        assert "lfs-installer.iso.pointer" in workflow
        build_section = workflow.split("create-release:")[0]
        assert "iso_name=$ISO" in build_section
        assert "sha256=$SHA" in build_section

    def test_nightly_exports_split_rootfs_for_selected_profiles(self):
        workflow = self._read("nightly.yml")
        # Rootfs is only useful (and heavy) for the reference desktop and
        # the ARM target; other profiles must not pay the asset cost.
        assert "if: matrix.profile == 'xfce' || matrix.profile == 'arm64'" \
            in workflow
        assert "split -b 1900m" in workflow
        assert "rootfs-*.tar.zst.part-*" in workflow

    def test_nightly_prunes_old_releases(self):
        workflow = self._read("nightly.yml")
        create_release = workflow.split("create-release:")[1]
        assert "30 days ago" in create_release
        assert "gh release delete" in create_release

    def test_rootfs_cache_release_uses_split_parts(self):
        workflow = self._read("build-rootfs-cache.yml")
        # A single rootfs archive breaks the day it exceeds the 2 GB
        # release-asset cap; the cache must stream into split parts.
        assert "split -b 1900m" in workflow
        assert "rootfs-cache-*.tar.zst.part-*" in workflow

    def test_iso_from_cache_reassembles_all_parts(self):
        workflow = self._read("build-iso-from-cache.yml")
        # The consumer must fetch every part of the rootfs-cache-latest
        # release, not just the first asset it finds.
        assert "releases/tags/rootfs-cache-latest" in workflow
        assert "head -n1" not in workflow
        assert "part_urls<<EOF" in workflow

    def test_release_workflow_publishes_compat_iso_pointer(self):
        workflow = Path(".github/workflows/release.yml").read_text()
        # The pointer must reach both the Actions artifact and the GitHub
        # release so releases/latest/download/lfs-installer.iso.pointer
        # stays a stable machine-readable alias.
        assert workflow.count("lfs-installer.iso.pointer") >= 3
        assert "download_url=https://github.com/${{ github.repository }}" \
            "/releases/download/${GITHUB_REF_NAME}/$ISO" in workflow


class TestNightlyCoverageAndBootSmoke:
    """Guardrails for audit gaps G3/G4 and the QEMU boot smoke test.

    G3: GNOME/KDE/LXQt stages had zero CI coverage.  G4: only sysvinit
    was CI-proven.  Reliability: every regression since nightly #169
    was caught during the build, never by booting the artifact.
    """

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def test_nightly_matrix_covers_all_desktop_environments(self):
        workflow = self._read("nightly.yml")
        for profile in ("gnome", "kde", "lxqt"):
            assert f"profile: {profile}" in workflow, \
                f"{profile} has no nightly coverage"

    def test_nightly_matrix_covers_systemd(self):
        workflow = self._read("nightly.yml")
        assert "init: systemd" in workflow

    def test_pipelines_boot_artifacts_with_reusable_smoke_script(self):
        """All release pipelines must boot the artifact through
        tools/qemu-boot-smoke.sh; the old inline 90s variant swallowed
        QEMU failures (|| true) and passed -append without -kernel."""
        for name in ("nightly.yml", "release.yml",
                     "build-iso-from-cache.yml"):
            workflow = self._read(name)
            assert "tools/qemu-boot-smoke.sh" in workflow, name
            assert "timeout 90s qemu-system-x86_64" not in workflow, name

    def test_nightly_headless_profiles_accept_disk_image(self):
        """minimal/server ship no live ISO; verify and the smoke test
        must fall back to the disk image instead of failing."""
        workflow = self._read("nightly.yml")
        assert "build-release.img" in workflow


class TestNightlyRootfsPaths:
    """builder.py sets LFS to the resolved output directory, so the rootfs
    *is* build-release/.  build-release/image/ is created empty by
    prepare_environment() and populated by nothing, yet nightly.yml used it
    for the kernel lookup, the rootfs export and the QEMU smoke test.
    """

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def test_no_command_references_the_phantom_image_dir(self):
        workflow = self._read("nightly.yml")
        offenders = [
            line.strip() for line in workflow.splitlines()
            if "build-release/image" in line and not line.strip().startswith("#")
        ]
        assert offenders == [], f"phantom image/ path still used: {offenders}"

    def test_kernel_lookup_uses_the_real_boot_dir(self):
        """final/13, final/14, final/15 and final/16 all install into
        $LFS/boot; looking anywhere else finds no kernel."""
        workflow = self._read("nightly.yml")
        assert 'find /tmp/lfs-build/build-release/boot -name "vmlinuz*"' \
            in workflow

    def test_rootfs_export_tars_the_rootfs_and_skips_scaffolding(self):
        workflow = self._read("nightly.yml")
        assert "-C /tmp/lfs-build/build-release \\" in workflow
        for excluded in ("sources", "logs", "live", "image"):
            assert f"--exclude=./{excluded}" in workflow, excluded
        # Parts must be written outside the tree tar is reading, otherwise
        # the archive tries to contain its own growing output.
        assert workflow.index('"/tmp/lfs-build/rootfs-${SUFFIX}.tar.zst.part-"') \
            < workflow.index("sudo mv /tmp/lfs-build/rootfs-")

    def test_qemu_smoke_points_at_the_rootfs_tree(self):
        workflow = self._read("nightly.yml")
        assert "bash tools/qemu-boot-smoke.sh /tmp/lfs-build/build-release.img \\\n" \
            "              /tmp/lfs-build/build-release\n" in workflow


class TestBasePrefixCache:
    """Guardrails for the nightly base prefix cache.

    All thirteen nightly jobs rebuilt the same 2h15m prefix (host-check
    through lfs-system) before any of them could do anything
    profile-specific.  build-base-cache.yml publishes that prefix once per
    (init, arch) pair; nightly.yml restores it and resumes.  Each assertion
    below protects one way this could quietly stop being true.
    """

    KEY_PATHS = (
        "host",
        "lfs/05a-build-lfs-basic.sh",
        "lfs/05b-build-lfs-system.sh",
        "config",
        "packages/sources.list",
        "packages/custom-sources.list",
        "builder.py",
        "VERSION",
    )

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def _step(self, workflow, name):
        """Slice out one step so ordering assertions stay local to it."""
        marker = f"- name: {name}\n"
        assert marker in workflow, f"step {name!r} not found"
        start = workflow.index(marker)
        end = workflow.find("\n      - name: ", start + len(marker))
        return workflow[start:] if end == -1 else workflow[start:end]

    def _key_block(self, workflow):
        start = workflow.index("git ls-tree -r HEAD --")
        return workflow[start:workflow.index("cut -c1-12", start)]

    def test_publisher_and_consumer_hash_identical_inputs(self):
        """A nightly must never restore a base built from other inputs.

        The two key computations are byte-identical on purpose: if one
        drifts, every job silently misses the cache and nobody notices
        until the wall-clock budget is gone again.
        """
        publisher = self._read("build-base-cache.yml")
        nightly = self._read("nightly.yml")
        for name, workflow in (("publisher", publisher), ("nightly", nightly)):
            assert "| sha256sum | cut -c1-12" in workflow, name
            block = self._key_block(workflow)
            for path in self.KEY_PATHS:
                assert path in block, f"{path} missing from the {name} key"
        assert self._key_block(publisher) == self._key_block(nightly)

    def test_both_workflows_agree_on_the_boundary_stage(self):
        publisher = self._read("build-base-cache.yml")
        nightly = self._read("nightly.yml")
        assert "BASE_STAGE: lfs-system" in publisher
        assert '--stop-after "$BASE_STAGE"' in publisher
        published_resume = publisher.split("RESUME_STAGE: ")[1].splitlines()[0]
        consumed_resume = nightly.split("BASE_CACHE_RESUME_STAGE: ")[1].splitlines()[0]
        assert published_resume.strip() == consumed_resume.strip() == "init-system"

    def test_canary_excludes_exactly_minimal_sysvinit_x86_64(self):
        """One job must keep proving the from-scratch path every night,
        otherwise a broken publisher would go unnoticed until everything
        depended on it."""
        workflow = self._read("nightly.yml")
        assert "USE_BASE_CACHE: ${{ !(matrix.profile == 'minimal' " \
            "&& matrix.init == 'sysvinit' && matrix.arch == 'x86_64') }}" \
            in workflow
        assert "if: env.USE_BASE_CACHE == 'true'" in workflow

    def test_restore_verifies_the_checksum_before_extracting(self):
        """The package-cache step downloads SHA256SUMS and never checks it;
        an unverified multi-GB rootfs is not an acceptable repeat."""
        step = self._step(self._read("nightly.yml"), "Restore base prefix cache")
        assert 'sha256sum -c "${PREFIX}.sha256"' in step
        assert "--xattrs" in step
        assert step.index("sha256sum -c") < step.index("sudo tar --zstd")

    def test_restore_extracts_into_the_rootfs_not_the_phantom_dir(self):
        step = self._step(self._read("nightly.yml"), "Restore base prefix cache")
        assert "-xf - -C /tmp/lfs-build/build-release" in step
        # The lfs uid is not guaranteed identical across runners.
        assert "sudo chown -R \"$(id -u lfs):$(id -g lfs)\"" in step

    def test_cache_miss_degrades_to_a_full_build(self):
        """A missing, corrupt or superseded cache must cost wall time, not
        the nightly itself."""
        step = self._step(self._read("nightly.yml"), "Restore base prefix cache")
        assert "HIT=false" in step
        assert 'echo "hit=${HIT}" >> "$GITHUB_OUTPUT"' in step
        assert "exit 1" not in step

    def test_resume_is_gated_on_a_verified_hit(self):
        step = self._step(
            self._read("nightly.yml"),
            "Build release profile ${{ matrix.profile }} / ${{ matrix.init }}"
            " / ${{ matrix.arch }}")
        assert 'RESUME_ARGS=""' in step
        guard = 'if [ "${{ steps.base_cache.outputs.hit }}" == "true" ]; then'
        assert guard in step
        assert step.index(guard) < step.index('RESUME_ARGS="--resume-from')
        assert step.count("--resume-from") == 1
        assert "$RESUME_ARGS \\" in step

    def test_disk_image_is_recreated_after_a_restore(self):
        """Headless profiles verify and smoke-boot build-release.img, which
        only host/03 creates; a restored rootfs does not contain it.

        Resuming and stopping on the same stage runs host/03 alone.
        Letting host/02 run as well would rebuild $LFS/tools, which
        lfs/05b removes once the system is self-hosting.
        """
        workflow = self._read("nightly.yml")
        step = self._step(workflow, "Recreate disk image after cache restore")
        assert "if: steps.base_cache.outputs.hit == 'true'" in step
        assert '--resume-from "$BASE_CACHE_IMAGE_STAGE"' in step
        assert '--stop-after "$BASE_CACHE_IMAGE_STAGE"' in step
        assert "BASE_CACHE_IMAGE_STAGE: disk-image" in workflow
        # The image must exist before the real build resumes past the
        # prefix, otherwise the job rebuilds what it just restored.
        assert workflow.index("Recreate disk image after cache restore") \
            < workflow.index("Build release profile")

    def test_publisher_verifies_the_prefix_before_publishing(self):
        """A hollow cache would poison every job that restores it."""
        workflow = self._read("build-base-cache.yml")
        for check in ("test -x usr/bin/gcc", "test -x bin/bash",
                      "test -f etc/passwd", "test ! -d tools"):
            assert check in workflow, check
        assert workflow.index("test ! -d tools") \
            < workflow.index("softprops/action-gh-release@v2")

    def test_publisher_excludes_the_build_scaffolding(self):
        """sources/ and logs/ share $LFS with the rootfs and are several GB
        of tarballs the consumer re-downloads anyway."""
        workflow = self._read("build-base-cache.yml")
        for excluded in ("sources", "logs", "cache", "backups", "live",
                         "image", "tools", "packages"):
            assert f"--exclude=./{excluded}" in workflow, excluded

    def test_publisher_prunes_superseded_assets(self):
        """base-cache-latest is a rolling tag; without pruning it grows by
        one full prefix every time the key changes."""
        workflow = self._read("build-base-cache.yml")
        assert "gh release delete-asset base-cache-latest" in workflow
        assert "tag_name: base-cache-latest" in workflow
        assert "prerelease: true" in workflow

    def test_nightly_budget_guards(self):
        """480 sits above GitHub's hard 6 h cap, so the platform killed
        runaway jobs before the log-upload step could run."""
        workflow = self._read("nightly.yml")
        assert "timeout-minutes: 480" not in workflow
        assert "timeout-minutes: 330" in workflow
        assert "group: nightly-builds" in workflow
        assert "cancel-in-progress: false" in workflow

    def test_publisher_covers_both_init_systems(self):
        """lfs/05b branches on INIT_SYSTEM, so one prefix cannot serve
        both; the matrix has to publish each separately."""
        workflow = self._read("build-base-cache.yml")
        assert "init: [sysvinit, systemd]" in workflow
        assert "arch: [x86_64]" in workflow

    @staticmethod
    def _indent(line):
        return len(line) - len(line.lstrip())

    def _continuations(self, workflow):
        """Yield (lineno, line, next line) for each backslash continuation."""
        lines = workflow.split("\n")
        for i, line in enumerate(lines[:-1]):
            nxt = lines[i + 1]
            if line.rstrip().endswith("\\") and nxt.strip():
                yield i + 1, line, nxt

    def test_shell_continuations_use_the_repository_indent(self):
        """Every workflow indents a backslash continuation by 0 or 2 spaces.

        Ragged deltas - and a continuation that dedents below the command it
        belongs to - read as broken indentation in review even though YAML
        and bash both accept them, so they survive every other gate.
        """
        offenders = []
        for name in ("nightly.yml", "build-base-cache.yml"):
            for lineno, line, nxt in self._continuations(self._read(name)):
                delta = self._indent(nxt) - self._indent(line)
                if delta not in (0, 2):
                    offenders.append(f"{name}:{lineno} delta {delta:+d}")
        assert offenders == [], offenders

    def test_sidecar_metadata_is_written_without_a_heredoc(self):
        """A heredoc body has to sit at the shell's own column to survive
        the YAML block dedent, which is indistinguishable from an
        indentation mistake.  printf in a brace group avoids the ambiguity.

        The version also has to come from the authoritative VERSION file by
        absolute path: the step used to cd into /tmp/base-cache and import
        builder, which is not on sys.path from there.
        """
        step = self._step(self._read("build-base-cache.yml"),
                          "Write cache metadata sidecar")
        assert "<<EOF" not in step
        assert "from builder import" not in step
        assert "cat /tmp/lfs-build/VERSION" in step
        assert '} > "/tmp/base-cache/${PREFIX}.json"' in step


class TestNightly221PostBuildPrivileges:
    """Every nightly step runs as the unprivileged runner user, but the
    rootfs is installed from inside a chroot, so build-release/ and most
    of what it holds are root-owned.

    Nightly #221 completed the entire build for three profiles (both
    minimal jobs and arm64/x86_64) and then lost all three in the first
    post-build step on "cp: cannot create regular file
    '/tmp/lfs-build/build-release/vmlinuz-...': Permission denied".  The
    same defect was latent in the three steps that follow it, which no
    profile had ever reached.
    """

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def _step(self, name):
        workflow = self._read("nightly.yml")
        marker = f"- name: {name}\n"
        assert marker in workflow, f"step {name!r} not found"
        start = workflow.index(marker)
        end = workflow.find("\n      - name: ", start + len(marker))
        return workflow[start:] if end == -1 else workflow[start:end]

    def test_kernel_copy_and_checksum_are_privileged(self):
        step = self._step("Verify kernel and boot artifact")
        assert 'sudo cp "$KERNEL_SRC"' in step
        assert '| sudo tee "SHA256SUMS-${SUFFIX}"' in step
        # A bare redirection creates the file as the runner user and dies
        # on the root-owned directory exactly like the cp did.
        assert '> "SHA256SUMS-${SUFFIX}"' not in step

    def test_compat_pointer_write_is_privileged(self):
        step = self._step("Create compat ISO pointer")
        assert "| sudo tee lfs-installer.iso.pointer" in step
        assert "} > lfs-installer.iso.pointer" not in step

    def test_rootfs_checksum_append_is_privileged(self):
        """SHA256SUMS is created root-owned by the kernel step, so the
        rootfs parts have to be appended through the same privilege."""
        step = self._step("Export split rootfs tarball")
        assert '| sudo tee -a "SHA256SUMS-${SUFFIX}"' in step
        assert '>> "SHA256SUMS-${SUFFIX}"' not in step

    def test_artifact_renames_are_privileged(self):
        """Renaming needs write permission on the containing directory,
        which the runner user does not have."""
        step = self._step("Rename shared-name artifacts per profile")
        assert 'sudo mv build_info.json "build_info-${SUFFIX}.json"' in step
        assert 'sudo mv sbom.spdx.json "sbom-${SUFFIX}.spdx.json"' in step
        assert 'sudo mv "$f" "lpm-repo/$(basename "$f")-${SUFFIX}"' in step
        # No unprivileged top-level mv may survive the fix.
        assert "\n          mv " not in step


class TestBaseCacheRun7VerifyStep:
    """build-base-cache #7 built two complete 21G prefixes, 2h each, and
    published neither: the verification step's informational size report
    walked the rootfs as the runner user, could not read the directories
    the chroot created root-only (./var/cache/ldconfig is mode 700) and
    exited non-zero, which failed the step even though every real check
    above it had passed.
    """

    def _step(self):
        workflow = Path(".github/workflows/build-base-cache.yml").read_text()
        marker = "- name: Verify the base prefix is real\n"
        start = workflow.index(marker)
        end = workflow.find("\n      - name: ", start + len(marker))
        return workflow[start:] if end == -1 else workflow[start:end]

    def test_size_report_cannot_abort_the_step(self):
        step = self._step()
        assert "sudo du -sh . || true" in step
        # An unprivileged du both under-reports and fails the step.
        assert "\n          du -sh .\n" not in step

    def test_real_checks_still_gate_the_publish(self):
        """Tolerating the size report must not weaken the verification:
        the prefix content checks are what stop a hollow cache from
        poisoning every nightly that restores it."""
        step = self._step()
        for check in ("test -x usr/bin/gcc", "test -x bin/bash",
                      "test -f etc/passwd", "test ! -d tools"):
            assert check in step, check
            assert step.index(check) < step.index("sudo du -sh ."), check


class TestEmulatedArm64StageBudget:
    """The two scheduled aarch64 workflows invoked builder.py with no
    --stage-timeout, so lfs-system was killed at the 7200s default having
    used every second of it (ARM64 XFCE #41, Cross-Compile #106).  Under
    qemu-user emulation that stage needs far longer than a native one.
    """

    WORKFLOWS = ("arm64-xfce.yml", "cross-compile.yml")

    def _read(self, name):
        return Path(f".github/workflows/{name}").read_text()

    def test_stage_timeout_is_raised_but_still_fits_the_job_cap(self):
        """10800 leaves room for the remaining stages inside GitHub's hard
        6h job cap; a larger value would only trade a self-reported stage
        timeout for a platform cancellation with no diagnostics at all."""
        for name in self.WORKFLOWS:
            workflow = self._read(name)
            assert "--stage-timeout 10800" in workflow, name

    def test_download_resilience_matches_nightly(self):
        """The 30s/3-attempt defaults are what made a degraded GNU mirror
        unrecoverable; nightly.yml already asks for 600s and 5 attempts."""
        for name in self.WORKFLOWS:
            workflow = self._read(name)
            assert "--download-timeout 600" in workflow, name
            assert "--download-retries 5" in workflow, name


class TestSameArchQemuSkip:
    """host/00-setup-qemu.sh ran whenever CROSS_COMPILE was set, and
    builder.py sets cross_compile for any --arch other than x86_64 - on a
    host that already is that arch included.  On a native ARM runner the
    stage would demand a qemu-aarch64-static it has no use for, exit 1 when
    it is missing, and register a binfmt_misc handler for the host's own
    architecture.
    """

    def _script(self):
        return Path("host/00-setup-qemu.sh").read_text()

    def test_same_arch_exits_before_any_emulator_work(self):
        script = self._script()
        assert 'HOST_ARCH="$(uname -m)"' in script
        guard = '[ "$HOST_ARCH" = "$TARGET_ARCH" ]'
        assert guard in script
        # Ordering is the whole point: a guard placed after the install or
        # the registration prevents nothing.
        start = script.index(guard)
        assert start < script.index("apt-get install -y -qq qemu-user-static")
        assert start < script.index("binfmt_misc/register")
        assert start < script.index('command -v "$QEMU_BIN"')

    def test_guard_survives_an_unset_arch(self):
        """TARGET_ARCH defaults to aarch64, so the guard still fires on an
        ARM runner if builder.py ever stops exporting ARCH."""
        assert 'TARGET_ARCH="${ARCH:-aarch64}"' in self._script()
