# Guide de démarrage des ISO LG3D dans VirtualBox

## Problème identifié

Les deux ISO produites par le workflow `lg3d.yml` sont des images **bootables uniquement en mode BIOS (Legacy)**. Elles **ne peuvent pas démarrer en mode UEFI** car le fichier EFI bootloader (`/EFI/BOOT/BOOTX64.EFI`) est absent.

### Pourquoi ?

Le script `final/15-create-live-system.sh` cherche le fichier EFI à la ligne 117 :
```bash
EFI_FILE="$LFS/boot/efi/EFI/BOOT/BOOTX64.EFI"
```

Si le fichier n'existe pas, l'ISO est créée en mode BIOS uniquement (ligne 123-124) :
```bash
echo "[WARNING] No EFI bootloader found – building BIOS-only ISO"
EFI_OPTION=""
```

**Cause racine :** Le processus de build n'installe pas le paquet `grub-efi-amd64` ou `shim-signed` qui générerait le fichier BOOTX64.EFI. Seul GRUB pour BIOS (`i386-pc`) est installé.

---

## Solution rapide : Configurer VirtualBox en mode BIOS

### Étapes pour créer une machine virtuelle bootable

1. **Ouvrir VirtualBox** et cliquer sur **"Nouvelle"**

2. **Nom et système d'exploitation :**
   - Nom : `LG3D Live` (ou ce que vous voulez)
   - Type : `Linux`
   - Version : `Other Linux (64-bit)`
   - Cliquer sur **Suivant**

3. **Taille de la mémoire :**
   - **2048 MB** minimum (LG3D est un bureau Java, donc gourmand)
   - **4096 MB** recommandé
   - Cliquer sur **Suivant**

4. **Disque dur :**
   - Sélectionner **"Ne pas ajouter de disque dur virtuel"**
   - Cliquer sur **Créer**

5. **⚠️ ÉTAPE CRITIQUE : Désactiver EFI**
   - Sélectionner la VM créée dans le panneau de gauche
   - Cliquer sur **"Configuration"** (icône engrenage)
   - Aller dans **"Système"** → onglet **"Carte mère"**
   - **DÉCOCHER** ☐ **"Activer EFI (OS spéciaux uniquement)"**
   - Cela force la VM à utiliser le **mode BIOS/CSM Legacy**
   - Cliquer sur **OK**

6. **Attacher l'ISO :**
   - Dans **"Configuration"** → **"Stockage"**
   - Sous **"Contrôleur: IDE"**, cliquer sur l'icône de disque vide
   - Cliquer sur l'icône de disque à droite → **"Choisir un fichier de disque..."**
   - Sélectionner : `lfs-0.57.4-lg3d-x86_64-systemd-20261103.iso` (ou sysvinit)
   - Cliquer sur **OK**

7. **Ordre de démarrage :**
   - Dans **"Système"** → **"Carte mère"**
   - Dans **"Ordre d'amorçage"**, cocher **"Optique"** et le mettre **en premier**
   - Utiliser les flèches pour prioriser : `Optique → Disque dur → Réseau`
   - Cliquer sur **OK**

8. **Démarrer la VM :**
   - Cliquer sur **"Démarrer"**
   - Le menu **ISOLINUX** doit apparaître avec :
     - `live` (démarrage normal, mode silencieux)
     - `live-verbose` (affiche les messages de boot)
   - Appuyer sur **Entrée** pour démarrer

---

## Séquence de démarrage attendue

```
ISOLINUX 6.04 2023-xx-xx  Copyright (C) 1994-2023 H. Peter Anvin et al.
[menu de boot]
Loading vmlinuz...
Loading initrd.img...
[    0.000000] Linux version 6.x.x ...
...
[    5.123456] VFS: Mounted root (squashfs filesystem) readonly
...
[   12.345678] INIT: version 3.x booting
...
Welcome to Way Beyond Linux From Scratch (LG3D)
live@lg3d-live:~$
```

---

## Comparaison des deux ISO

| Caractéristique | systemd | sysvinit |
|-----------------|---------|----------|
| **Taille** | 1.38 GiB | 1.38 GiB |
| **Secteur de boot** | MBR (ISOLINUX) | MBR (ISOLINUX) |
| **Support EFI** | ❌ Aucun | ❌ Aucun |
| **Squashfs** | 1.47 GB | 1.46 GB |
| **Noyau** | Identique | Identique |
| **Système init** | systemd | sysvinit |
| **MD5** | `2e266f67283e9fd095fa54d334ac234a` | `8b1f03a0ae30821774ad35756b12b06b` |

**Différence :** Le système init et les services dans `live.squashfs` diffèrent, mais le mécanisme de boot est identique.

---

## Structure des ISO

```
ISO 9660 (DOS/MBR boot sector) 'LFS_LIVE'
├── [BOOT]/
│   └── Boot-NoEmul.img          (2048 bytes - El Torito boot image)
├── boot/
│   └── grub/                    (vide)
├── EFI/
│   └── BOOT/                    (⚠️ VIDE - pas de BOOTX64.EFI)
├── isolinux/
│   ├── boot.cat                 (catalogue de boot)
│   ├── initrd.img               (7.5-8.0 MB)
│   ├── isolinux.bin             (38 KB - bootloader)
│   ├── isolinux.cfg             (configuration)
│   └── vmlinuz                  (7.8 MB - noyau Linux)
└── live.squashfs                (1.46-1.47 GB - système de fichiers racine)
```

**Configuration de boot (isolinux.cfg) :**
```
default live
label live
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro quiet
label live-verbose
  kernel vmlinuz
  append initrd=initrd.img root=/dev/sr0 ro
```

---

## Dépannage

### Problème : "No bootable medium found" dans VirtualBox

**Cause :** La VM est configurée en mode EFI/UEFI, mais l'ISO est BIOS-only.

**Solution :** Désactiver EFI dans les paramètres de la VM (voir étape 5 ci-dessus).

### Problème : Le menu ISOLINUX apparaît, mais le kernel panic

**Symptômes :**
```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**Cause :** Le paramètre `root=/dev/sr0` ne correspond pas au périphérique CD-ROM dans la VM.

**Solution :** Éditer la commande de boot au menu ISOLINUX :
1. Au prompt `boot:`, taper : `live-verbose`
2. Appuyer sur **Tab** pour éditer la ligne de commande
3. Changer `root=/dev/sr0` en `root=/dev/sr1` ou `root=/dev/sda`
4. Appuyer sur **Entrée**

### Problème : Le boot reste bloqué à "Loading initial ramdisk..."

**Cause :** Mémoire RAM insuffisante allouée à la VM.

**Solution :** Augmenter la mémoire à **2048 MB** minimum (**4096 MB** recommandé pour LG3D).

### Problème : Écran noir après le menu ISOLINUX

**Cause :** Incompatibilité du mode graphique avec l'émulation VGA de VirtualBox.

**Solution :** Ajouter `nomodeset` à la ligne de commande du noyau :
1. Au prompt `boot:`, taper : `live nomodeset`
2. Appuyer sur **Entrée**

---

## Comment corriger les ISO pour supporter UEFI (avancé)

Si vous avez besoin du support UEFI, vous devez modifier le processus de build pour installer le bootloader EFI.

### Modification requise

Ajouter dans un stage BLFS (probablement `blfs/08-build-blfs-base.sh`) l'installation de `grub-efi-amd64` :

```bash
# Dans le chroot LFS
cd /sources/grub-2.12
./configure --prefix=/usr \
            --sbindir=/usr/sbin \
            --mandir=/usr/share/man \
            --infodir=/usr/share/info \
            --build=x86_64-linux-gnu \
            --host=x86_64-linux-gnu \
            --with-platform=efi \
            --disable-efiemu
make
make install

# Installer les binaires EFI à l'emplacement standard
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=GRUB \
             --removable
```

Puis relancer `final/15-create-live-system.sh` qui détectera `/boot/efi/EFI/BOOT/BOOTX64.EFI` et créera une ISO hybride BIOS+UEFI.

---

## Résumé

| Aspect | Statut |
|--------|--------|
| **Mode de boot ISO** | BIOS-only (MBR, ISOLINUX) |
| **Support UEFI** | ❌ Manquant (`/EFI/BOOT/BOOTX64.EFI` absent) |
| **VirtualBox 7.x** | Nécessite de désactiver EFI dans les paramètres |
| **VirtualBox 6.1** | Devrait booter par défaut |
| **Matériel réel** | Nécessite mode CSM/Legacy BIOS |
| **Création USB bootable** | `dd` standard fonctionne (ISO hybride) |
| **Correction requise** | Installer `grub-efi-amd64` dans le processus de build |

---

## Liens utiles

- **Documentation ISOLINUX :** https://wiki.syslinux.org/wiki/index.php/ISOLINUX
- **Standard El Torito :** https://en.wikipedia.org/wiki/El_Torito_(CD-ROM_standard)
- **Modes de boot VirtualBox :** https://docs.oracle.com/en/virtualization/virtualbox/7.0/user/vboxconfigdata.html
- **Installation GRUB EFI :** https://www.gnu.org/software/grub/manual/grub/html_node/Installing-GRUB-using-grub_002dinstall.html

---

**Version du document :** 1.0  
**Dernière mise à jour :** 2026-11-03  
**S'applique aux builds :** LG3D nightly de `lg3d.yml`
