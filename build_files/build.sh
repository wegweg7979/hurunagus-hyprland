#!/bin/bash

set -ouex pipefail

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
#   * chromium, kdenlive, obs-studio are duplicated by the system Flatpaks
#     in system-flatpaks.list.
#   * The rest are Omarchy preinstalled apps that upstream itself offers to
#     remove via omarchy-remove-preinstalls (libreoffice-fresh maps to
#     libreoffice on Fedora).
#
# Keep this filter here instead of editing omarchy-base.packages so the
# vendored Omarchy list stays easy to compare with upstream.
EXCLUDED_PACKAGES=(
    chromium
    kdenlive
    obs-studio
    libreoffice
    xournalpp
    omacut
    omacalc
    omawrite
    lazydocker
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
    kf6-kimageformats
    libatomic
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

systemctl set-default graphical.target
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
    /var/cache/libdnf5 \
    /var/log/dnf.log \
    /var/log/dnf.librepo.log \
    /var/log/dnf.rpm.log \
    /var/log/hawkey.log
echo "::endgroup::"
