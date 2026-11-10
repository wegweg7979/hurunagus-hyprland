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
#
# The kernel is NOT the base image's stock Fedora kernel: build.sh swaps in
# kernel-cachyos (BORE scheduler, 1000 Hz, x86_64-v3) from the bieszczaders
# COPR, so the baked kernel version moves on every build. It is unsigned --
# enabling Secure Boot requires enrolling a MOK yourself.

### CACHE-BUSTING INPUTS
## The build is split into three layers below, ordered by how often their
## content really changes. A layer is invalidated when the build arg it
## references changes, so freshness is paid for where it is needed instead of
## throwing the whole layer cache away (`--no-cache`, which this replaced).
##
##   OMEDORA_BUST  every build (CI passes the run id). The Omedora COPR mutates
##                 between builds of the same commit, so the volatile tail is
##                 always re-resolved. This is the old --no-cache, scoped down.
##   KERNEL_BUST   weekly scheduled builds and manual "fresh" runs: re-resolve
##                 the CachyOS kernel from its COPR.
##   ALL_BUST      weekly scheduled builds and manual "fresh" runs: rebuild every
##                 layer from scratch, i.e. exactly what --no-cache used to do.
ARG OMEDORA_BUST=0
ARG KERNEL_BUST=0
ARG ALL_BUST=0

### [IM]MUTABLE /opt
## Fedora's base image symlinks /opt -> /var/opt. RPMs such as brave-origin
## unpack into /opt and fail with "cpio: mkdir failed - File exists" unless
## /opt is a real directory.
RUN rm /opt && mkdir /opt

### MODIFICATIONS
## Everything (packages, SDDM, Omarchy defaults, Hurunagus overrides) happens in
## build.sh. It is mounted at /ctx so it can see build_files/ and system_files/.
## Each RUN below is one phase (see the header of build.sh) and one cacheable
## layer; ALL_BUST is threaded through all three so a scheduled build can force
## a full rebuild the way --no-cache used to.

## Phase 1/3 -- the stable bulk: repos, the whole package install, system files,
## services. This is the ~10 minute part and the one worth reusing.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ALL_BUST="${ALL_BUST}" /ctx/build.sh base

## Phase 2/3 -- the CachyOS kernel swap and its initramfs. The kernel COPR moves
## on its own schedule, so this is refreshed by the weekly build rather than by
## every push.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ALL_BUST="${ALL_BUST}" KERNEL_BUST="${KERNEL_BUST}" /ctx/build.sh kernel

## Phase 3/3 -- the volatile tail: re-resolve the Omedora payload, re-mirror its
## SDDM theme, clean build artifacts. Invalidated on every build.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ALL_BUST="${ALL_BUST}" OMEDORA_BUST="${OMEDORA_BUST}" /ctx/build.sh fresh

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
