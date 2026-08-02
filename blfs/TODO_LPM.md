### TODO

Oui, absolument. Avec la nouvelle commande `build` et les recettes, LPM peut être utilisé **durant la construction du système LFS** pour compiler et installer les paquets un par un, de manière automatisée et reproductible.

C’est même l’un des cas d’usage principaux de cette fonctionnalité : on peut remplacer les traditionnels `tar -xf`, `./configure`, `make`, `make install` par des recettes LPM qui décrivent exactement les mêmes étapes. LPM s’occupera alors de :

- Télécharger/décompresser les sources
- Compiler avec les bons flags (ceux de la configuration LFS)
- Installer dans le bon `$LFS`
- Empaqueter proprement le résultat
- Enregistrer le paquet dans la base

### Ce qu’il faut faire

- Créer un fichier `.lpm` pour chaque paquet du livre LFS, en reprenant les instructions de compilation (les fameuses pages « 5.5. GCC-14.2.0 - Pass 1 », etc.).
- Utiliser `--sysroot $LFS` pour que l’installation aille bien dans l’arborescence cible.
- Définir les variables d’environnement nécessaires (comme `LFS_TGT`, `PATH`, `LC_ALL`) avant d’appeler LPM.

Exemple de recette pour binutils pass 1 (extrait) :
```bash
# binutils-pass1.lpm
name="binutils"
version="2.44"
source="https://sourceware.org/pub/binutils/releases/binutils-2.44.tar.xz"
desc="GNU Binutils (pass 1)"
deps=""
build() {
    mkdir -v build
    cd build
    ../configure --prefix=/tools \
                 --with-sysroot=$LFS \
                 --target=$LFS_TGT \
                 --disable-nls \
                 --enable-gprofng=no \
                 --disable-werror
    make -j$(nproc)
}
```

Puis on lance :
```bash
lpm --sysroot $LFS build binutils-pass1.lpm
```

L’avantage est immense :
- Toutes les opérations sont tracées dans la base LPM.
- Chaque paquet est empaqueté et peut être réinstallé, vérifié (`lpm verify`), désinstallé, mis à jour.
- En cas d’erreur, la transaction est annulée (rollback) et le système reste propre.

Bien sûr, il faut construire les recettes avec soin et respecter scrupuleusement l’ordre et les dépendances du livre LFS, mais c’est tout à fait faisable. C’est d’ailleurs la direction naturelle pour LPM : devenir un outil de construction complet pour LFS, depuis les toutes premières briques jusqu’à un système complet.