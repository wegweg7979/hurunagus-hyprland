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
# COPR, so the baked kernel version moves on every build. It is then signed for
# Secure Boot with the hurunagus kernel signing key (phase 3/4, and see
# system_files/usr/share/hurunagus/secureboot/README.md). Secure Boot stays OFF
# unless you turn it on, and turning it on needs one MOK enrollment per machine
# (ujust enroll-hurunagus-kernel-key), because firmware only trusts keys it has
# been told about.

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
##
##   KERNEL_PIN    an exact kernel NEVRA, declared at phase 2 rather than here so a
##                 bump re-runs the kernel layer and later ones while the base stays
##                 cached. See that block for how (and when) it moves.
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
## layer; ALL_BUST is threaded through all of them so a scheduled build can force
## a full rebuild the way --no-cache used to.

## Phase 1/4 -- the stable bulk: repos, the whole package install, system files,
## services. This is the ~10 minute part and the one worth reusing.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ALL_BUST="${ALL_BUST}" /ctx/build.sh base

## Phase 2/4 -- the CachyOS kernel swap and its initramfs, pinned to an exact NEVRA.
##
## The COPR publishes daily, so this installs KERNEL_PIN rather than floating.
## Note what the pin is NOT doing: it does not stop this layer from re-running. A
## RUN's cache key includes its PARENT layer, and phase 1 -- which installs the
## payload -- sits above this one, so any commit touching build_files/ or
## system_files/ re-runs this phase whatever it mounts (mounting a narrower context
## would change nothing here; the layer chain decides). Putting the kernel ahead of
## the payload would need the plymouth theme in its own earlier phase, because the
## theme has to be in place before dracut generates the initramfs.
##
## What the pin buys is the part that actually bites: a re-run installs the SAME
## kernel. It moves only when the weekly build resolves a new one, proves it
## builds, and commits it on success (.github/workflows/build.yml) -- so a new
## kernel arrives on Tuesday, or not at all.
##
## Declared here rather than with the ARGs above on purpose: a bump then
## invalidates this phase and everything after it, while the ~10 minute base layer
## stays cached.
ARG KERNEL_PIN=7.3.6-2.cachyos1.fc45
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    ALL_BUST="${ALL_BUST}" KERNEL_BUST="${KERNEL_BUST}" KERNEL_PIN="${KERNEL_PIN}" \
    /ctx/build.sh kernel

## Phase 3/4 -- Secure Boot signing of the kernel image. Its own layer on purpose:
## the layer cache key CANNOT see a build secret's contents, so signing must not
## ride inside the kernel layer -- a cached kernel layer would ship an unsigned
## kernel on an otherwise green build, and the phase's own assertion could not
## catch it, because a cached layer is not executed at all. A new instruction runs
## at least once, and rotating the key means committing a new certificate, which
## is read from the image (phase 1) and so invalidates this layer by itself.
## The secret is optional here only so that PR builds, which receive no secrets,
## can pass --build-arg SB_SIGNING=off and still build; with signing on and no
## key the phase fails, deliberately.
ARG SB_SIGNING=on
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=secret,id=sb_signing_key,required=false \
    SB_SIGNING="${SB_SIGNING}" \
    SB_SIGNING_KEY_FILE=/run/secrets/sb_signing_key \
    /ctx/build.sh sign

## Phase 4/4 -- the volatile tail: re-resolve the Omedora payload, re-mirror its
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
