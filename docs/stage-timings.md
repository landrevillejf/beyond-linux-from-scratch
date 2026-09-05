# Stage Timings (Release Profile)

This timing guide is for the current release pipeline profile:

- **Profile:** `xfce`
- **Init:** `sysvinit`
- **Architecture:** `x86_64`
- **Live ISO:** enabled
- **Host:** GitHub Actions `ubuntu-latest`

Times are practical ranges (not guarantees). Network and mirror health can move totals significantly.

## Expected Duration by Stage

| Stage | Typical time |
|---|---:|
| host-check | 1-2 min |
| host-prepare | 2-5 min |
| disk-image | 2-6 min |
| toolchain | 1-3 min |
| lfs-basic | 15-35 min |
| lfs-system | 20-50 min |
| init-system | 1-3 min |
| service-abstraction | 1-3 min |
| configure-lfs | 1-3 min |
| blfs-base | 15-40 min |
| build-kernel | 8-20 min |
| desktop | 25-70 min |
| applications | 25-80 min |
| configure-desktop | 2-8 min |
| package-manager | 1-3 min |
| base-packages | 2-8 min |
| security | 2-8 min |
| branding | 1-3 min |
| first-boot | 1-3 min |
| system-updater | 1-3 min |
| package-updater | 1-3 min |
| lpm-advanced | 1-4 min |
| initramfs | 2-6 min |
| bootloader | 2-6 min |
| installer | 4-12 min |
| live-system | 10-30 min |

## Total Build Time (xfce live release)

- **Fast path (good mirrors/cache hits):** ~2h20
- **Typical path:** ~3h30 to ~4h30
- **Slow path (timeouts, retries, mirror issues):** ~5h+

## Why It Varies

Main factors:

1. Source mirror availability and retry behavior
2. Compression-heavy stages (`installer`, `live-system`)
3. Package compile cost in `desktop` and `applications`
4. Whether failed stages are resumed (`--resume-from`) vs full rebuild

## Measured nightly prefix (Nightly #215)

The ranges above predate the base prefix cache and are optimistic for the
toolchain and lfs stages. These are wall-clock times measured from the
Nightly #215 build logs on `ubuntu-latest`:

| stage | minimal / sysvinit | xfce / systemd | arm64 / x86_64 | server / sysvinit |
|---|---:|---:|---:|---:|
| host-check to disk-image | 0:27 | 0:27 | 0:27 | 0:47 |
| toolchain | 0:51:41 | 0:50:26 | 0:50:26 | 0:38:08 |
| lfs-system | 1:24:28 | 1:25:00 | 1:24:07 | 1:04:23 |
| **prefix total** | **2:16:36** | **2:15:54** | **2:15:01** | **1:43:19** |
| blfs-base | 0:22:04 | 0:22:32 | 0:22:09 | 0:17:04 |
| build-kernel | 0:05:09 | not reached | 0:03:40 | 0:03:47 |
| total to bootloader | 3:47:21 | failed at blfs-libs | 3:43:04 | 2:51:18 |

The prefix is profile-independent, which is what makes it cacheable:

- `host/04-build-toolchain.sh` has no `$PROFILE` or `LFS_PROFILE_*`
  reference at all.
- `lfs/05a-build-lfs-basic.sh` and `lfs/05b-build-lfs-system.sh` branch
  only on `INIT_SYSTEM` and `KERNEL_TYPE`.
- `blfs/08-build-blfs-base.sh` has no profile, init or desktop reference.
- `--arch x86_64` forces `cross_compile=false` and `bootloader.type=grub`,
  so the conditional `qemu-setup` and `uboot` stages never appear and
  every x86_64 job schedules the same list.

### Cache boundaries

**Tier 1 (current):** `BASE_STAGE=lfs-system`, `RESUME_STAGE=init-system`.
Publishes roughly 2h15m of shared work per `(init, arch)` pair.

**Tier 2 (designed, not yet enabled):** `BASE_STAGE=display-manager`,
`RESUME_STAGE=build-kernel`. `blfs/08a`, `08b` and `08c` read
`DESKTOP_TYPE` only to skip when it equals `none`, and `blfs/08d` builds
polkit, accountsservice, lightdm and lightdm-gtk-greeter unconditionally
with no gdm/sddm branch, so the whole display stack is shareable across
xfce, gnome, kde, lxqt and full. That is worth roughly another 1h50m per
desktop job. Enable it by editing `BASE_STAGE`/`RESUME_STAGE` in
`build-base-cache.yml` and `BASE_CACHE_RESUME_STAGE` in `nightly.yml` - no
code changes - but only once a nightly proves `xorg` through
`display-manager` completes.

With tier 1 alone the projected wall times are about 1h30m for minimal,
server, java-dev, audio-studio and arm64/x86_64, about 4h30m to 5h for
xfce and lxqt, and about 6h45m for gnome, with kde and full worse.
Tier 2 is what brings the heavy desktop profiles back inside the 6 h cap.

`aarch64` is excluded from the cache: its `lfs-system` alone ran 4h04m and
then failed, so it can neither produce a prefix nor fit inside one.
