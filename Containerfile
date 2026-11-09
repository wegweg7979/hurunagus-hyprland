# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
FROM ghcr.io/ublue-os/base-main:latest
## Other possible base images include:
# FROM ghcr.io/ublue-os/bazzite:testing
# FROM ghcr.io/ublue-os/aurora:stable
#
# The Omedora COPR we install from publishes fedora-44-x86_64 and
# fedora-45-x86_64 only. base-main:latest currently tracks Fedora 45 (the
# 2026-11-08 build shipped kernel 7.2.15-300.fc45); pin a date tag here if you
# need a reproducible build.

### [IM]MUTABLE /opt
## Fedora's base image symlinks /opt -> /var/opt. RPMs such as brave-origin
## unpack into /opt and fail with "cpio: mkdir failed - File exists" unless
## /opt is a real directory.
RUN rm /opt && mkdir /opt

### MODIFICATIONS
## Everything (packages, SDDM, Omarchy defaults, Hurunagus overrides) happens in
## build.sh. It is mounted at /ctx so it can see build_files/ and system_files/.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Rebrand system identifiers in /usr/lib/os-release
RUN sed -i \
    -e 's/^ID=.*/ID=fedora/' \
    -e 's/^ID_LIKE=.*/ID_LIKE="fedora"/' \
    -e 's/^NAME=.*/NAME="hurunagus-hyprland"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="hurunagus-hyprland"/' \
    -e 's/^VERSION_CODENAME=.*/VERSION_CODENAME=hurunagus-hyprland/' \
    -e 's/^VARIANT=.*/VARIANT="Hurunagus Hyprland"/' \
    -e 's/^VARIANT_ID=.*/VARIANT_ID=hurunagus-hyprland/' \
    -e 's/^DEFAULT_HOSTNAME=.*/DEFAULT_HOSTNAME="hurunagus"/' \
    /usr/lib/os-release

# Copy custom Flatpak list into the system configuration path. The first-boot
# flatpak-system-install.service installs anything missing.
COPY system-flatpaks.list /usr/share/ublue-os/flatpaks/system-flatpaks.list

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
