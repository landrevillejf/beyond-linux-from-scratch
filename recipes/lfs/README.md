# LPM Recipes for Linux From Scratch 13.0

This directory contains [LPM](../../docs/lpm.md) build recipes (`.lpm` files) that
reproduce the entire **LFS 13.0** build — from the very first cross-toolchain
brick up to a complete, bootable base system — one package at a time, driven by
the `lpm build` command.

Each recipe replaces the traditional `tar -xf … ; ./configure ; make ; make
install` dance with a declarative file that LPM uses to download, compile,
install, package and register the software in its database. Final-system
packages can therefore be verified (`lpm verify`), reinstalled, upgraded and
removed like any other LPM package.

## Layout

```
recipes/lfs/
├── build-order.txt     # canonical build order (one recipe per line)
├── build-all.sh        # driver that walks build-order.txt calling `lpm build`
├── lib.sh              # shared helpers (companion-tarball fetcher, njobs)
├── TEMPLATE.lpm        # starting point for new recipes
├── toolchain/          # Ch. 5  — cross toolchain      (installs into $LFS)
├── temp-tools/         # Ch. 6-7 — temporary tools      (installs into $LFS / chroot)
└── system/             # Ch. 8  — basic system software (tracked LPM packages)
```

## The recipe contract

A recipe is a Bash fragment that LPM sources. It declares metadata and a
`build()` function:

```bash
name="zlib"
version="1.3.1"
source="https://zlib.net/fossils/zlib-1.3.1.tar.gz"
desc="Compression library"
deps="glibc"

build() {
    ./configure --prefix=/usr
    make -j"$JOBS"
    make DESTDIR="$PKG" install
}
```

When `build()` runs, the current directory is the extracted source tree and the
LPM engine exports:

| Variable | Meaning |
|----------|---------|
| `PKG`    | Staging directory. Install here (`make DESTDIR="$PKG" install`) so the result is packaged and tracked. |
| `SRC`    | The extracted source directory (equal to the current directory). |
| `JOBS`   | Configured parallel job count. |

Recipes that need companion tarballs (e.g. GCC unpacking GMP/MPFR/MPC) source
the helper library and call `companion`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
gmp=$(companion "gmp-6.3.0.tar.xz" "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz")
tar -xf "$gmp"
```

## Phases and how they install

* **`toolchain/` (Chapter 5)** and **`temp-tools/` (Chapters 6-7)** follow the
  LFS book exactly: they install *directly* into `$LFS` (or the chroot). They are
  throwaway "phase" recipes, so `build-all.sh` builds them with `--no-install`
  (LPM runs their `build()` and records an empty package).
* **`system/` (Chapter 8)** recipes install into the `$PKG` staging directory via
  `DESTDIR`. LPM archives those files, registers them in its database and installs
  them into the LPM root — producing a fully **tracked** base system.

> Runtime *configuration* that cannot be captured as staged files — locale
> generation, `pwconv`, `systemd-machine-id-setup`, `ldconfig`, bootscript
> installation, kernel configuration, etc. — is intentionally **not** performed
> by these recipes. Those steps remain the responsibility of the LFS stage
> scripts under `lfs/` and `final/`. The recipes cover package **construction**.

## Requirements before running

The toolchain and temporary-tool recipes expect the standard LFS environment to
be prepared already (see `host/` and `lfs/` stages):

* `LFS` — the target build root (e.g. `/mnt/lfs`), with `$LFS/tools` and
  `$LFS/sources` present.
* `LFS_TGT` — the cross triplet (e.g. `x86_64-lfs-linux-gnu`).
* A configured `PATH`, `LC_ALL=POSIX`, the `lfs` build user, etc., exactly as the
  LFS book (and `host/04-build-toolchain.sh`) set them up.

## Usage

Build everything (from outside the chroot, staging into `$LFS`):

```bash
export LFS=/mnt/lfs
export LFS_TGT=x86_64-lfs-linux-gnu
lpm --sysroot "$LFS" --version >/dev/null   # ensure lpm is available

# Dry-run to preview the commands:
recipes/lfs/build-all.sh --dry-run

# Build a single phase:
recipes/lfs/build-all.sh --phase toolchain

# Build the whole book, forwarding --sysroot to lpm for the system phase:
recipes/lfs/build-all.sh -- --sysroot "$LFS"

# Resume after a failure:
recipes/lfs/build-all.sh --start system/gcc.lpm -- --sysroot "$LFS"
```

Build a single package by hand:

```bash
lpm --sysroot "$LFS" build recipes/lfs/system/zlib.lpm
```

List the resolved order:

```bash
recipes/lfs/build-all.sh --list
```

## Notes and caveats

* **Versions** are pinned to LFS 13.0 as published in `packages/sources.list`.
  When bumping a package, update its `.lpm` file *and* any companion URLs in
  `lib.sh`-using recipes.
* **Patches** hosted by upstream LFS are fetched on demand from
  `https://www.linuxfromscratch.org/patches/lfs/13.0/`. If that path changes,
  the affected recipes (`glibc`, `bzip2`, `coreutils`, `kbd`) will need updating.
* **Init system**: `system/systemd.lpm` is the default. For a SysVinit userland,
  swap it for the appropriate sysvinit/eudev/bootscripts recipes and adjust
  `build-order.txt`.
* **Optional test tooling** from the book (Tcl, Expect, DejaGNU, Check) is *not*
  included — those packages only exist to run upstream test suites and are not
  part of a minimal bootable system.
* **The kernel** (Chapter 10) is configuration-specific and is built by the
  dedicated `final/` kernel stage rather than a recipe here.
