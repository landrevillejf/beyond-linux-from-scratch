# LPM as an LFS build tool — ✅ Implemented

> **Status:** Done. The `.lpm` recipes described below now live in
> [`recipes/lfs/`](../recipes/lfs/). Use `recipes/lfs/build-all.sh` to build a
> complete LFS 13.0 system through LPM. See `recipes/lfs/README.md`.

## Rationale

Avec la commande `build` et les recettes, LPM peut être utilisé **durant la
construction du système LFS** pour compiler et installer les paquets un par un,
de manière automatisée et reproductible.

On remplace les traditionnels `tar -xf`, `./configure`, `make`, `make install`
par des recettes LPM qui décrivent exactement les mêmes étapes. LPM s'occupe
alors de :

- Télécharger / décompresser les sources
- Compiler avec les bons flags (ceux de la configuration LFS)
- Installer dans le bon `$LFS`
- Empaqueter proprement le résultat
- Enregistrer le paquet dans la base

## What was delivered

- **103 recipes** covering the whole LFS 13.0 book, split by phase:
  - `recipes/lfs/toolchain/`  — Chapter 5 (cross toolchain)
  - `recipes/lfs/temp-tools/` — Chapters 6–7 (temporary tools)
  - `recipes/lfs/system/`     — Chapter 8 (basic system software, tracked packages)
- `recipes/lfs/build-order.txt` — canonical, dependency-correct build order.
- `recipes/lfs/build-all.sh`    — driver (`--phase`, `--start`, `--dry-run`, `--list`).
- `recipes/lfs/lib.sh`          — shared helpers (companion-tarball fetcher).
- `recipes/lfs/TEMPLATE.lpm`    — template for new recipes.

## Recipe contract

Each recipe declares metadata and a `build()` function. When `build()` runs, the
current directory is the extracted source and the engine exports:

- `PKG`  — staging directory (`make DESTDIR="$PKG" install` → tracked package)
- `SRC`  — extracted source directory
- `JOBS` — parallel job count

Example (binutils pass 1):

```bash
name="binutils-pass1"
version="2.45"
source="https://sourceware.org/pub/binutils/releases/binutils-2.45.tar.xz"
desc="GNU Binutils - cross toolchain pass 1"
deps=""
build() {
    mkdir -v build && cd build
    ../configure --prefix="$LFS/tools" \
                 --with-sysroot="$LFS" \
                 --target="$LFS_TGT"   \
                 --disable-nls         \
                 --enable-gprofng=no   \
                 --disable-werror
    make -j"$(nproc)"
    make install
}
```

Run it with:

```bash
lpm --sysroot "$LFS" build recipes/lfs/toolchain/binutils-pass1.lpm
```

## Benefits

- Toutes les opérations sont tracées dans la base LPM.
- Chaque paquet du système final est empaqueté puis peut être réinstallé,
  vérifié (`lpm verify`), désinstallé et mis à jour.
- En cas d'erreur d'installation, la transaction est annulée (rollback).

## Scope notes

- Toolchain/temp recipes install directly into `$LFS` exactly as the book does
  (they are throwaway phase recipes, built with `--no-install`).
- Runtime configuration that cannot be captured as staged files (locale
  generation, `pwconv`, `ldconfig`, `systemd-machine-id-setup`, bootscripts,
  kernel configuration, …) remains the responsibility of the `lfs/` and `final/`
  stage scripts.
- Optional test-only packages (Tcl, Expect, DejaGNU, Check) are intentionally
  omitted. The kernel (Chapter 10) is built by the dedicated `final/` stage.
