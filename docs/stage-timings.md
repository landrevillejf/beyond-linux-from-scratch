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
