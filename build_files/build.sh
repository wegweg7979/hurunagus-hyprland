#!/bin/bash

# Build phases, split so the container build can cache the expensive, stable
# work and keep only the volatile tail fresh on every build. The Containerfile
# runs each phase as its own layer; `just build` on a workstation runs them all
# in one go, which is the behaviour this script has always had.
#
#   base    repos, the whole package install, system files, services  (cacheable)
#   kernel  the CachyOS kernel swap and its initramfs                 (weekly)
#   fresh   re-resolve the Omedora payload, re-mirror its SDDM theme,
#           clean build artifacts                                    (every build)
#   all     every phase in order (default)
PHASE="${1:-all}"

set -ouex pipefail

phase_base() {
# ---------------------------------------------------------------------------
# Build tooling + the Omedora COPR
# ---------------------------------------------------------------------------
echo "::group:: Installing build tooling"
dnf5 install -y dnf5-plugins python3
echo "::endgroup::"

echo "::group:: Enabling the Omedora COPR"
dnf5 -y copr enable wegweg7979/omedora-4
# Deliberately left enabled: omedora's package helpers use this repo for
# updates and for the on-demand apps that are only packaged there.
echo "::endgroup::"

echo "::group:: Installing the Omarchy runtime (Omedora)"
dnf5 install -y omedora omedora-settings
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Resolve the vendored Omarchy package lists against fedora.toml
# ---------------------------------------------------------------------------
fedora_version="$(rpm -E %fedora)"
echo "::group:: Resolving Omarchy's package list (Fedora ${fedora_version})"
python3 /ctx/fedora-resolve.py \
    --map /ctx/fedora.toml \
    --fedora-version "${fedora_version}" \
    --copr-out /tmp/hurunagus-coprs.txt \
    /ctx/omarchy-base.packages \
    /ctx/fedora-baseline.packages \
    > /tmp/hurunagus-packages.txt

if [[ -s /tmp/hurunagus-coprs.txt ]]; then
    while IFS= read -r copr; do
        [[ -n "${copr}" ]] || continue
        dnf5 -y copr enable "${copr}"
    done < /tmp/hurunagus-coprs.txt
fi

mapfile -t PACKAGES < /tmp/hurunagus-packages.txt

# Packages we deliberately do not ship, even though Omarchy's base list
# includes them:
#
#   * chromium is duplicated by the system Flatpaks in system-flatpaks.list.
#   * omacut, omawrite, hype, monologue and signed are Omarchy preinstalled
#     apps that upstream itself offers to remove via omarchy-remove-preinstalls
#     (4.5 added the last three). omasnap and owe are NOT in this class - the
#     screenshot overlay and the wallpaper engine are wired into the desktop
#     with no fallback (omarchy-capture-screenshot execs omasnap;
#     omarchy-theme-bg-boot-intro drives owe) - and disktree is 4.5's disk tool,
#     the replacement for the dua-cli it dropped.
#
# A name belongs here only while it is still in omarchy-base.packages. Upstream
# churns that list every release - 4.5 dropped kdenlive, obs-studio, lazydocker
# and xournalpp - and an exclusion that matches nothing only looks meaningful.
# Re-check this block after every base bump.
#
# Keep this filter here instead of editing omarchy-base.packages so the
# vendored Omarchy list stays easy to compare with upstream.
EXCLUDED_PACKAGES=(
    chromium
    hype
    monologue
    omacut
    omawrite
    signed
)

filtered_packages=()
for package in "${PACKAGES[@]}"; do
    for excluded in "${EXCLUDED_PACKAGES[@]}"; do
        if [[ "${package}" == "${excluded}" ]]; then
            continue 2
        fi
    done
    filtered_packages+=("${package}")
done
PACKAGES=("${filtered_packages[@]}")

echo "Resolved ${#PACKAGES[@]} packages after exclusions"
echo "::endgroup::"

# Packages that are not in Omarchy's lists but that this bootc image needs:
# SDDM (with its Wayland greeter), the Hyprland/Omarchy desktop stack, and the
# hardware/font helpers the original Hurunagus image shipped.
EXTRA_PACKAGES=(
    sddm
    sddm-wayland-generic
    xorg-x11-server-Xwayland
    polkit
    firefox
    adwaita-fonts-all
    igt-gpu-tools
    lm_sensors
    fprintd
    # PAM module for the fingerprint reader. fprintd alone leaves
    # /usr/lib64/security/pam_fprintd.so unloadable, which logs a dlopen failure
    # on every sudo/PAM authentication.
    fprintd-pam
    kf6-kimageformats
    libatomic
    # Btrfs maintenance timers (monthly scrub). Tuned by
    # /etc/default/btrfsmaintenance, which this image ships.
    btrfsmaintenance
)

# Brave browser repo
dnf5 -y config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 -y install brave-origin

# Hermes Desktop (GUI) - download from GitHub releases (not in Fedora repos)
HERMES_DESKTOP_URL="https://github.com/fathah/hermes-desktop/releases/download/v0.7.7/hermes-desktop-0.7.7.rpm"

echo "::group:: Installing Hermes Agent and Desktop"
# Install Hermes Agent using official install script (not available as RPM)
echo "Installing Hermes Agent via official installer..."
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --no-prompt 2>/dev/null || \
    echo "warning: Hermes Agent installation failed" >&2

# Install Hermes Desktop RPM
if [[ ! -f /tmp/hermes-desktop.rpm ]]; then
    curl -fsSL -o /tmp/hermes-desktop.rpm "${HERMES_DESKTOP_URL}" || \
        echo "warning: failed to download hermes-desktop RPM" >&2
fi

if [[ -f /tmp/hermes-desktop.rpm ]]; then
    dnf5 install -y --nogpgcheck /tmp/hermes-desktop.rpm || \
        echo "warning: hermes-desktop installation failed or not available" >&2
    rm -f /tmp/hermes-desktop.rpm
fi

echo "::endgroup::"

# cliamp - terminal music player (Winamp-inspired) from GitHub releases.
# Not in Fedora, not built from source (prebuilt release binary). Ships as a
# plain executable in /usr/bin; links only glibc + libasound, so alsa-lib is
# its only runtime dep.
CLIAMP_URL="https://github.com/bjarneo/cliamp/releases/download/v2.4.0/cliamp-linux-amd64"

echo "::group:: Installing cliamp (terminal music player)"
if [[ ! -f /tmp/cliamp ]]; then
    curl -fsSL -o /tmp/cliamp "${CLIAMP_URL}" || \
        echo "warning: failed to download cliamp binary" >&2
fi

if [[ -x /tmp/cliamp || -f /tmp/cliamp ]]; then
    install -Dm0755 /tmp/cliamp /usr/bin/cliamp
    dnf5 install -y alsa-lib || echo "warning: alsa-lib install failed" >&2
    rm -f /tmp/cliamp
    echo "cliamp installed: $(/usr/bin/cliamp version 2>/dev/null || true)"
fi
echo "::endgroup::"

install_packages() {
    local failed=() package required_failed=0

    if dnf5 install -y "$@"; then
        return 0
    fi

    echo "Bulk install failed; retrying one package at a time to isolate failures." >&2
    for package in "$@"; do
        if ! dnf5 install -y "${package}"; then
            failed+=("${package}")
        fi
    done

    if (( ${#failed[@]} == 0 )); then
        return 0
    fi

    printf 'Failed packages:\n' >&2
    printf '  %s\n' "${failed[@]}" >&2

    for package in "${failed[@]}"; do
        case "${package}" in
            omedora|omedora-settings|omedora-nerd-fonts|hyprland-no-session|uwsm|quickshell|sddm|sddm-wayland-generic|ttfx|foot|xdg-desktop-portal-hyprland)
                required_failed=1
                ;;
        esac
    done

    if (( required_failed )); then
        echo "A required desktop package failed to install." >&2
        return 1
    fi

    echo "Only optional packages failed; continuing." >&2
    return 0
}

echo "::group:: Installing the Omarchy desktop packages"
install_packages "${PACKAGES[@]}" "${EXTRA_PACKAGES[@]}"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Hurunagus system files, SDDM theme, session and first-boot services
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Hurunagus system files, SDDM theme, session and first-boot services
# ---------------------------------------------------------------------------
echo "::group:: Copying Hurunagus system files"
cp -avf /ctx/system_files/. /
echo "::endgroup::"

# The Hurunagus look-and-feel payload lives in /usr/share/hurunagus/config and is
# replayed into a live $HOME by omarchy-hurunagus-configs (user-run, never
# automatic). Seed /etc/skel from that same tree so a brand new user starts with
# the identical settings -- one source of truth, no second copy to drift.
echo "::group:: Seeding /etc/skel from the Hurunagus config payload"
if [[ -d /usr/share/hurunagus/config ]]; then
    while IFS= read -r -d '' entry; do
        rel="${entry#/usr/share/hurunagus/config/}"
        mkdir -p "/etc/skel/${rel%/*}"
        rm -f "/etc/skel/${rel}"
        cp -a "${entry}" "/etc/skel/${rel}"
    done < <(find /usr/share/hurunagus/config -mindepth 1 \( -type f -o -type l \) -print0)
    chown -R root:root /etc/skel
    echo "seeded $(find /usr/share/hurunagus/config -mindepth 1 \( -type f -o -type l \) | wc -l) files into /etc/skel"
else
    echo "warning: /usr/share/hurunagus/config is missing; /etc/skel not seeded" >&2
fi
echo "::endgroup::"

# The reinstall helper is user-run: keep it executable even if a checkout lost
# the mode bit.
chmod 0755 /usr/bin/omarchy-hurunagus-configs

# omarchy-plymouth-set --refresh-sddm (and omarchy-refresh-sddm) copies
# /usr/share/omarchy/default/sddm/omarchy over the live theme. Mirror the
# Hurunagus theme there so a refresh keeps the user picker and branding.
echo "::group:: Mirroring the Hurunagus SDDM theme into Omarchy's defaults"
mkdir -p /usr/share/omarchy/default/sddm
rm -rf /usr/share/omarchy/default/sddm/omarchy
chown -R root:root /usr/share/sddm/themes/omarchy
chmod -R go-w /usr/share/sddm/themes/omarchy
cp -a /usr/share/sddm/themes/omarchy /usr/share/omarchy/default/sddm/omarchy
chown -R root:root /usr/share/omarchy/default/sddm/omarchy
chmod -R go-w /usr/share/omarchy/default/sddm/omarchy
echo "::endgroup::"

# omedora-settings ships an Omedora session entry and hyprland-no-session ships
# no session entry; keep Hurunagus as the only Hyprland login session.
rm -f \
    /usr/share/wayland-sessions/omedora.desktop \
    /usr/share/wayland-sessions/hyprland.desktop \
    /usr/share/wayland-sessions/hyprland-uwsm.desktop

enable_unit() {
    local unit="$1"
    if systemctl cat "${unit}" >/dev/null 2>&1; then
        systemctl enable "${unit}" >/dev/null 2>&1 ||
            echo "warning: could not enable ${unit}; continuing" >&2
    fi
}

echo "::group:: Enabling services"
# SDDM is the display manager. Make sure no base-image DM keeps the
# display-manager.service alias first.
for dm in gdm.service gdm3.service lightdm.service greetd.service ly.service; do
    if systemctl cat "${dm}" >/dev/null 2>&1; then
        systemctl disable "${dm}" >/dev/null 2>&1 || true
    fi
done
rm -f /etc/systemd/system/display-manager.service
systemctl enable sddm.service

enable_unit bluetooth.service
enable_unit NetworkManager.service
enable_unit cups.service
enable_unit cups-browsed.service
enable_unit avahi-daemon.service
enable_unit systemd-oomd.service
enable_unit podman.socket
enable_unit docker.socket

# Units shipped by this image: these must be enabled.
systemctl enable flatpak-system-install.service
systemctl enable add-default-user-groups.service

# Btrfs maintenance: scrub only. Periods come from
# /etc/default/btrfsmaintenance (shipped in system_files/); balance, defrag and
# trim stay off and are disabled explicitly here in case a future preset turns
# them on (fstrim.timer plus discard=async already handle trim).
enable_unit btrfs-scrub.timer
enable_unit btrfsmaintenance-refresh.path
systemctl disable btrfs-balance.timer btrfs-trim.timer btrfs-defrag.timer >/dev/null 2>&1 || true

# Bake the timer schedule drop-in (OnCalendar=<period>) into the image so first
# boot does not depend on a runtime refresh. The refresh script's own systemctl
# enable/start calls are no-ops inside the build container, which is why the
# enable_unit calls above are required.
if [[ -x /usr/share/btrfsmaintenance/btrfsmaintenance-refresh-cron.sh ]]; then
    /usr/share/btrfsmaintenance/btrfsmaintenance-refresh-cron.sh systemd-timer >/dev/null 2>&1 ||
        echo "warning: btrfsmaintenance refresh failed; scrub schedule may be missing" >&2
fi

systemctl set-default graphical.target
echo "::endgroup::"
}

phase_kernel() {
# ---------------------------------------------------------------------------
# CachyOS kernel swap
# ---------------------------------------------------------------------------
# Ported from hurunagus-silverblue's BlueBuild custom-kernel module
# (modules/custom-kernel/custom-kernel.sh) -- the proven mechanic for swapping a
# kernel into an atomic image. Kept in dnf5 form and trimmed to what this image
# actually needs:
#
#   * Secure Boot signing is NOT ported: this image boots with Secure Boot
#     disabled, so sbsign/sign-file/MOK enrollment would be dead weight. The
#     kernel is therefore UNSIGNED -- enrolling a MOK is a prerequisite if
#     Secure Boot is ever switched on.
#   * The NVIDIA/akmods half is NOT ported: this image targets Intel iGPUs and
#     installs no out-of-tree kernel modules. -devel-matched is still installed
#     so that stays possible later.
#   * An initramfs IS generated, and that part is not optional here: the base
#     image bakes /usr/lib/modules/$kver/initramfs.img and 50-dracut.install is
#     stubbed during the swap, so nothing else would produce one for the new
#     kernel -- a kernel without an initramfs cannot boot.
#
# Kernel source: bieszczaders/kernel-cachyos, the official CachyOS port to
# Fedora. It carries the CachyOS patch set (BORE CPU scheduler, 1000 Hz tick,
# PREEMPT_DYNAMIC, BFQ/Kyber, BBR, x86_64-v3). kernel-cachyos is the GCC build;
# kernel-cachyos-lto is its clang/ThinLTO twin with an otherwise identical
# config (vmlinuz ~3% smaller), so switching between them is the one-line
# KERNEL_FLAVOR below.
echo "::group:: Swapping in the CachyOS kernel"

KERNEL_FLAVOR="cachyos"

case "${KERNEL_FLAVOR}" in
    cachyos)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos
            kernel-cachyos-core
            kernel-cachyos-modules
            kernel-cachyos-devel-matched
        )
        ;;
    cachyos-lto)
        KERNEL_COPR="bieszczaders/kernel-cachyos-lto"
        KERNEL_PACKAGES=(
            kernel-cachyos-lto
            kernel-cachyos-lto-core
            kernel-cachyos-lto-modules
            kernel-cachyos-lto-devel-matched
        )
        ;;
    cachyos-lts)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos-lts
            kernel-cachyos-lts-core
            kernel-cachyos-lts-modules
            kernel-cachyos-lts-devel-matched
        )
        ;;
    cachyos-lts-lto)
        KERNEL_COPR="bieszczaders/kernel-cachyos-lto"
        KERNEL_PACKAGES=(
            kernel-cachyos-lts-lto
            kernel-cachyos-lts-lto-core
            kernel-cachyos-lts-lto-modules
            kernel-cachyos-lts-lto-devel-matched
        )
        ;;
    cachyos-rt)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos-rt
            kernel-cachyos-rt-core
            kernel-cachyos-rt-modules
            kernel-cachyos-rt-devel-matched
        )
        ;;
    *)
        echo "Unsupported KERNEL_FLAVOR: ${KERNEL_FLAVOR}" >&2
        exit 1
        ;;
esac

# The kernel's %posttrans guards `kernel-install add` behind
# `[ ! -e /run/ostree-booted ]`. Inside a container build that path does not
# exist, so the kernel-install hooks really do run: 05-rpmostree.install would
# try to drive rpm-ostree, and 50-dracut.install would build an initramfs with
# flags we do not control. Stub both for the duration of the swap, restore after.
KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)

disable_kernel_install_hooks() {
    local hook
    for hook in "${KERNEL_HOOKS[@]}"; do
        [[ -f "${hook}" ]] || continue
        mv "${hook}" "${hook}.bak"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"${hook}"
        chmod +x "${hook}"
    done
}

restore_kernel_install_hooks() {
    local hook
    for hook in "${KERNEL_HOOKS[@]}"; do
        if [[ -f "${hook}.bak" ]]; then
            mv -f "${hook}.bak" "${hook}"
        fi
    done
}

disable_kernel_install_hooks

# Because kernel-install runs during the transaction below (see the note above),
# it writes boot artifacts into /boot: /boot/vmlinuz-*, config-*, System.map-*
# and symvers-*.zst (hardlinks to the module dir) plus a /boot/loader/ dir. The
# base image's /boot is deliberately empty and bootc manages /boot on the
# deployed host, so snapshot /boot here and delete only what appears. Snapshot
# rather than hardcoding paths, so a future base image that ships something in
# /boot is not clobbered.
KERNEL_BOOT_SNAPSHOT="$(mktemp)"
find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort >"${KERNEL_BOOT_SNAPSHOT}"

echo "Removing the stock Fedora kernel"
dnf5 remove -y \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

echo "Enabling ${KERNEL_COPR}"
dnf5 -y copr enable "${KERNEL_COPR}"

echo "Installing ${KERNEL_PACKAGES[*]}"
# Deliberately strict: with the stock kernel already removed, a failure here
# would leave the image with no kernel at all, so abort rather than ship one
# that cannot boot.
dnf5 install -y "${KERNEL_PACKAGES[@]}"

mapfile -t KERNEL_VERSIONS < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if (( ${#KERNEL_VERSIONS[@]} != 1 )); then
    printf 'Expected exactly one kernel in /usr/lib/modules, found %d: %s\n' \
        "${#KERNEL_VERSIONS[@]}" "${KERNEL_VERSIONS[*]}" >&2
    exit 1
fi
KERNEL_VERSION="${KERNEL_VERSIONS[0]}"
echo "Kernel version: ${KERNEL_VERSION}"

restore_kernel_install_hooks

# Undo the /boot pollution described above, keeping only what was there before
# the swap. Without this the image ships stale /boot content and bootc's
# nonempty-boot lint flips from pass to warning (verified: 12 passed/2 warnings
# becomes 11 passed/3 warnings).
NEW_BOOT_ENTRIES=()
while IFS= read -r boot_entry; do
    [[ -n "${boot_entry}" ]] || continue
    NEW_BOOT_ENTRIES+=("${boot_entry}")
done < <(comm -13 "${KERNEL_BOOT_SNAPSHOT}" <(find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort))
rm -f "${KERNEL_BOOT_SNAPSHOT}"
if (( ${#NEW_BOOT_ENTRIES[@]} )); then
    echo "Removing ${#NEW_BOOT_ENTRIES[@]} /boot entries left by the kernel transaction: ${NEW_BOOT_ENTRIES[*]}"
    for boot_entry in "${NEW_BOOT_ENTRIES[@]}"; do
        rm -rf -- "/boot/${boot_entry}"
    done
fi

# Only the CachyOS repo is dropped. The omedora COPR is deliberately left
# enabled above -- omedora's helpers use it -- so never wildcard this pattern.
rm -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:bieszczaders:*.repo

echo "Generating the initramfs for ${KERNEL_VERSION}"
# Match how the base image's own initramfs is built: the image sets hostonly=no
# (20-atomic-nohostonly.conf) and adds the ostree+bootc dracut modules
# (20-atomic-bootc-ostree.conf), so those come from config; the explicit flags
# below are belt-and-braces.
DRACUT_NO_XATTR=1 dracut \
    --no-hostonly \
    --kver "${KERNEL_VERSION}" \
    --reproducible \
    --add ostree \
    -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"

# dracut writes this file outside any RPM transaction, so no scriptlet labels
# it. The base image's own initramfs is mode 0600; match it and relabel when
# policy is available in the build container.
chmod 0600 "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
if command -v restorecon >/dev/null 2>&1; then
    restorecon "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" 2>/dev/null || true
fi

# Assert the initramfs really exists and is plausibly sized. `set -e` already
# catches a non-zero dracut, but dracut can log a failure and still exit 0 (it
# prints "dracut-install: ERROR: installing '/root' to '/root'" on this image
# because /root is a symlink to var/roothome with no target in the build
# container -- harmless, and the stock initramfs omits /root too). A kernel with
# no usable initramfs cannot boot, so never let that through silently.
INITRAMFS_MIN_BYTES=$((100 * 1024 * 1024))
INITRAMFS_SIZE="$(stat -c %s "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" 2>/dev/null || echo 0)"
if (( INITRAMFS_SIZE < INITRAMFS_MIN_BYTES )); then
    printf 'initramfs for %s is missing or implausibly small (%s bytes, expected >%s); refusing to ship a likely-unbootable image\n' \
        "${KERNEL_VERSION}" "${INITRAMFS_SIZE}" "${INITRAMFS_MIN_BYTES}" >&2
    exit 1
fi
echo "initramfs verified: ${INITRAMFS_SIZE} bytes"

echo "CachyOS kernel ${KERNEL_VERSION} installed"
echo "::endgroup::"
}

phase_fresh() {
# ---------------------------------------------------------------------------
# Volatile tail: the Omedora COPR mutates between builds of the same commit
# ---------------------------------------------------------------------------
# `dnf5 install omedora` above is a no-op whenever the base layer is a cache
# hit, which would silently freeze the payload at whatever the COPR served the
# first time. This phase is invalidated on every build (OMEDORA_BUST), so it is
# where the payload is re-resolved: cheap next to the full package transaction
# it replaces, and always current. Every other package follows the weekly
# scheduled rebuild, which passes ALL_BUST and rebuilds from scratch.
echo "::group:: Refreshing the Omarchy runtime (Omedora)"
dnf5 -y --refresh upgrade omedora omedora-settings || \
    echo "warning: omedora refresh failed; shipping the version baked into the cached layer" >&2
echo "::endgroup::"

# The cached base layer mirrored the SDDM theme from whatever omedora was
# installed then. Redo it here in case the refresh replaced the packaged theme.
echo "::group:: Re-mirroring the Hurunagus SDDM theme into Omarchy's defaults"
if [[ -d /usr/share/sddm/themes/omarchy ]]; then
    mkdir -p /usr/share/omarchy/default/sddm
    rm -rf /usr/share/omarchy/default/sddm/omarchy
    chown -R root:root /usr/share/sddm/themes/omarchy
    chmod -R go-w /usr/share/sddm/themes/omarchy
    cp -a /usr/share/sddm/themes/omarchy /usr/share/omarchy/default/sddm/omarchy
    chown -R root:root /usr/share/omarchy/default/sddm/omarchy
    chmod -R go-w /usr/share/omarchy/default/sddm/omarchy
else
    echo "warning: /usr/share/sddm/themes/omarchy is missing; theme not mirrored" >&2
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Clean build artifacts so they don't ship in the image
# ---------------------------------------------------------------------------
echo "::group:: Cleaning up"
dnf5 clean all
rm -rf \
    /run/dnf \
    /run/selinux-policy \
    /run/tuned \
    /var/lib/dnf \
    /var/lib/fprint \
    /var/lib/rpm-state \
    /var/cache/libdnf5 \
    /var/log/dnf.log \
    /var/log/dnf.librepo.log \
    /var/log/dnf.rpm.log \
    /var/log/hawkey.log
echo "::endgroup::"
}

case "$PHASE" in
  base) phase_base ;;
  kernel) phase_kernel ;;
  fresh) phase_fresh ;;
  all) phase_base; phase_kernel; phase_fresh ;;
  *)
    echo "build.sh: unknown phase '${PHASE}' (expected base|kernel|fresh|all)" >&2
    exit 1
    ;;
esac
