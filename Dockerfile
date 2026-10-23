# Pinned by manifest-list digest for hermetic, reproducible host toolchains:
# a bare `22.04` tag mutates under you, so a build months apart would resolve
# different base layers. Bump the digest deliberately, not implicitly.
# Resolve a newer one with: docker manifest inspect ubuntu:22.04
FROM ubuntu:22.04@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956

# Installer les dépendances
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bison flex gawk texinfo \
    wget curl git python3 python3-pip \
    grub-pc-bin \
    grub-efi-amd64-bin \
    xorriso isolinux mtools dosfstools squashfs-tools \
    parted rsync sudo \
    && rm -rf /var/lib/apt/lists/*

# Créer un utilisateur non-root
RUN useradd -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER builder
WORKDIR /home/builder

# Copier les scripts
COPY --chown=builder:builder . /home/builder/lfs-builder

WORKDIR /home/builder/lfs-builder

# Lancer le build
CMD ["python3", "builder.py", "--profile", "xfce", "--output", "/output"]