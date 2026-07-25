### Usage

- Shebang : doit être #!/bin/bash ou #!/usr/bin/env bash (pas /bin/sh).
- Options : recommandation d'utiliser set -e ou set -eu.
- Variables LFS : doit définir ou utiliser $LFS, $LFS_TGT, $INIT_SYSTEM, etc.
- Commandes interdites : sudo dans les scripts internes (sauf host/), chroot (sauf final/), ldconfig (doit être /sbin/ldconfig).
- Chemins : évite /usr/local, /opt (sauf exceptions).
- Bashismes (si le script s’exécute avec /bin/sh) : vérification de [[, $(<file) etc.
- Appel facultatif à shellcheck (si installé) pour une analyse approfondie.

```bash
python3 lfs_check.py                    # analyse les dossiers par défaut
```
```bash 
python3 lfs_check.py --dirs host lfs    # analyse uniquement host/ et lfs/
```

```bash 
python3 lfs_check.py --exclude blfs     # exclut blfs/
```
```bash 
python3 lfs_check.py --shellcheck       # lance aussi shellcheck (si installé)
```
```bash 
python3 lfs_check.py --verbose          # affiche plus de détails
```