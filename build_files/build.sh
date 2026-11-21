#!/bin/bash

# Build phases, split so the container build can cache the expensive, stable
# work and keep only the volatile tail fresh on every build. The Containerfile
# runs each phase as its own layer; `just build` on a workstation runs them all
# in one go, which is the behaviour this script has always had.
#
#   base    repos, the whole package install, system files, services  (cacheable)
#   kernel  the CachyOS kernel swap and its initramfs                 (weekly)
#   sign    Secure Boot signing of the kernel image                   (with the key)
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
#   * omacut and omawrite are Omarchy preinstalled apps that upstream itself
#     offers to remove via omarchy-remove-preinstalls.
#
# 4.5's other preinstalls (hype, monologue, signed) are NOT excluded, although
# they are the same class: 4.5 ships a migration for each of them, and every one
# of those migrations is nothing but `omarchy-pkg-add <app>`. With the app
# excluded, that call hits this helper's "bake it into the image build" refusal,
# exits 1, and - because omarchy-migrate is `set -e` - aborts the entire
# migration run, hiding every later migration. Baking them is also the only way
# they can exist at all: omarchy-pkg-drop refuses to remove a baked RPM, so
# excluding them would not make them removable, only absent.
#
# These match the RESOLVED RPM names, not the list's Arch names: the list says
# libreoffice-fresh and the map turns it into Fedora's libreoffice, so that entry
# is live even though the string is not in the list.
#
# A name belongs here only while the resolver still emits it. Upstream churns the
# lists every release - 4.5 dropped kdenlive, obs-studio, lazydocker and xournalpp
# - and an exclusion matching nothing only looks meaningful. Test it against the
# resolver's output (`python3 build_files/fedora-resolve.py --map
# build_files/fedora.toml build_files/omarchy-base.packages
# build_files/fedora-baseline.packages`), not against the list text.
#
# Keep this filter here instead of editing omarchy-base.packages so the
# vendored Omarchy list stays easy to compare with upstream.
EXCLUDED_PACKAGES=(
    chromium
    libreoffice
    omacut
    omawrite
    # The Docker stack. omarchy's list carries docker + docker-buildx +
    # docker-compose, and the map turns `docker` into Fedora's moby-engine +
    # docker-cli, which then drags containerd in behind it and leaves a disabled
    # daemon installed. Nothing on this desktop needs it (podman is what the
    # image recipes use), and the Install > Development > Docker DB row is gated
    # on `docker` being present, so dropping the stack hides the row instead of
    # offering a command that cannot run.
    moby-engine
    docker-cli
    docker-buildx
    docker-compose
    # CJK glyph coverage. The IME engines are skip-mapped in fedora.toml (the
    # runtime adders need that); these are the fonts. This filter only reaches
    # the build's OWN resolved list, so it is NOT sufficient on its own:
    # google-noto-sans-cjk-fonts also ships in the ublue base, and the three
    # *-cjk-vf-fonts packages are never on that list at all (they arrive as
    # dependencies of default-fonts-cjk-*). The removal block below is what
    # actually drops the stack — verify with `rpm -qa | grep -i cjk` on the
    # BUILT image, never on the resolver output.
    google-noto-sans-cjk-fonts
    google-noto-serif-cjk-fonts
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
    # The locale the desktop actually uses. The base arrives with
    # glibc-all-langpacks (all 200+ locales, ~227 MB); the trim below removes it,
    # so this must be present or the host falls back to C formatting for dates,
    # numbers and currency under LANG=en_GB.UTF-8.
    glibc-langpack-en
    # Voxtype, the dictation backend Setup > Defaults > Dictation offers. The RPM
    # is in the omedora COPR (voxtype.spec) and wtype is already here, so this is
    # the half that was missing: without it the menu row is gated away on an
    # immutable host, because `omarchy-pkg-add voxtype-bin` can only answer
    # "bake it into the image". Baked, the row shows and the installer's shared
    # setup runs with the package already satisfied.
    voxtype
    # Virtualisation host: qemu-kvm plus the libvirt daemons. Not an Omarchy
    # package -- this is a CAPABILITY every hurunagus box is meant to have, so
    # that a VM can be given a real LAN address. The reason bridging "never
    # worked" on this image family is not atomicity: session-mode libvirt (the
    # only thing the virt-manager flatpak can run) is rootless and therefore
    # cannot create a macvtap or bridge device at all, and a host on Wi-Fi
    # cannot bridge anyway (802.11 three-address framing). With the daemons
    # baked in, the flatpak GUI drives qemu:///system and a VM gets its own
    # DHCP lease from the router through macvtap on a wired NIC.
    # Deliberately NOT virt-manager: its RPM would duplicate
    # org.virt_manager.virt-manager in system-flatpaks.list and give the GUI a
    # second, rebuild-bound update path. Deliberately NOT swtpm or edk2-ovmf
    # (47 MB): no VM on these boxes asks for a TPM or UEFI firmware yet, and
    # both are one-line additions here when one does.
    qemu-kvm
    libvirt-daemon-kvm
    libvirt-daemon-config-network
    libvirt-client
    virt-install
)

# Brave browser repo
dnf5 -y config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 -y install brave-origin

# Hermes Desktop (GUI) - download from GitHub releases (not in Fedora repos)
HERMES_DESKTOP_URL="https://github.com/fathah/hermes-desktop/releases/download/v0.7.7/hermes-desktop-0.7.7.rpm"

echo "::group:: Installing the Hermes desktop app"
# The Hermes AGENT (CLI) is deliberately NOT installed here. Its official
# installer is strictly per-user: it clones into $HERMES_HOME (default
# ~/.hermes), publishes the launcher into ~/.local/bin, and wires that into the
# user's own shell rc. Run as root in this container build it installs under
# /root, so no desktop user would ever get the command -- which is what has been
# happening all along: the old `|| echo "warning: ..."` swallowed two faults at
# once, an installer flag it does not accept (it takes --non-interactive, not
# --no-prompt) and a per-user target that cannot exist at build time. The agent
# belongs to the user, so add-hermes-agent.service installs it for each user at
# first login instead, where a failure lands in `systemctl --user --failed`
# rather than hiding behind a green image build. Everything the installer needs
# is already in this image: git, python3, curl, node.
#
# The desktop app IS a system package, so it is installed here, unguarded.
echo "Installing Hermes Desktop..."
curl -fsSL -o /tmp/hermes-desktop.rpm "${HERMES_DESKTOP_URL}"
dnf5 install -y --nogpgcheck /tmp/hermes-desktop.rpm
rm -f /tmp/hermes-desktop.rpm

echo "::endgroup::"

# cliamp - terminal music player (Winamp-inspired) from GitHub releases.
# Not in Fedora, not built from source (prebuilt release binary). Ships as a
# plain executable in /usr/bin; links only glibc + libasound, so alsa-lib is
# its only runtime dep.
CLIAMP_URL="https://github.com/bjarneo/cliamp/releases/download/v2.4.0/cliamp-linux-amd64"

echo "::group:: Installing cliamp (terminal music player)"
# THE ONE SANCTIONED SOFT FAILURE in this script. cliamp is the media player the
# user actually uses, but it is not part of the desktop's function: a dead
# release URL must not block an update that carries fixes for everything else.
# Every other shipped-software install here goes red on failure.
if curl -fsSL -o /tmp/cliamp "${CLIAMP_URL}"; then
    install -Dm0755 /tmp/cliamp /usr/bin/cliamp
    dnf5 install -y alsa-lib || echo "warning: alsa-lib install failed; cliamp may not play" >&2
    rm -f /tmp/cliamp
    # Log line only, so it stays tolerant of a nonzero exit (no audio device in
    # a build container). The install itself is checked above.
    echo "cliamp installed: $(/usr/bin/cliamp version 2>/dev/null || true)"
else
    echo "warning: failed to download cliamp; shipping without it" >&2
fi
echo "::endgroup::"

# cava - the spectrum analyser huruwave draws. A ~90 KB console visualiser that
# taps the output device's monitor source and prints bar heights, which is why
# the player carries no DSP of its own. Deliberately unguarded: huruwave falls
# back to a synthetic animation when cava is missing, so a silent absence would
# be a green build shipping a player whose visualiser quietly does not work.
echo "::group:: Installing cava (spectrum analyser for huruwave)"
dnf5 install -y cava
echo "cava installed: $(rpm -q --qf '%{name}-%{version}-%{release}' cava)"
echo "::endgroup::"

# airgraph - Wi-Fi channel/congestion viewer (Qt Quick, unprivileged over
# NetworkManager D-Bus). Our own app: built from its own repo and published to
# its own COPR, so the image only has to install it. Every runtime dep it needs
# (qt6-qtbase/-qtdeclarative/-qtwayland, NetworkManager; iw via Recommends) is
# already present in this image. The repo is enabled only for the install --
# unlike the Omedora COPR above, nothing on the host updates from it.
echo "::group:: Installing airgraph (Wi-Fi channel viewer)"
dnf5 -y copr enable wegweg7979/airgraph
dnf5 install -y airgraph
dnf5 -y copr disable wegweg7979/airgraph
echo "airgraph installed: $(rpm -q --qf '%{name}-%{version}-%{release}' airgraph)"
echo "::endgroup::"

# huruwave - Omarchy-native music player: YouTube Music, the Apple Music catalog
# and local files in one window. Same shape as airgraph -- our own app, its own
# COPR, enabled only for the install. mpv and yt-dlp are already here, and cava
# (above) is what it draws its spectrum bars with.
#
# Since 0.2.0 it also plays Apple Music's FULL tracks in-window, through an
# embedded Chromium: that needs qt6-qtwebengine, which the app's own Requires pulls
# in from here (~+300 MiB installed, and the reason the panel can exist at all) --
# there is nothing to add to this script for it. What that panel uses at runtime is
# the user's own and never shipped: a Widevine CDM taken from a browser's profile
# and an Apple session borrowed by huruwave-apple-session.
#
# Deliberately unguarded: an image that silently ships without the player is worse
# than a red build.
echo "::group:: Installing huruwave (music player)"
dnf5 -y copr enable wegweg7979/huruwave
dnf5 install -y huruwave
dnf5 -y copr disable wegweg7979/huruwave
echo "huruwave installed: $(rpm -q --qf '%{name}-%{version}-%{release}' huruwave)"
echo "::endgroup::"

# huru-calendar - iCloud (CalDAV) calendar sync daemon. Headless Go, so unlike
# the other apps here it drags in no Qt at all; it is the data source behind the
# huru.calendar bar widget in the Hurunagus payload (system_files/usr/share/
# hurunagus/config/.config/omarchy/plugins/). Our own repo, our own COPR, so the
# image only installs it and turns the repo off again -- nothing on the host
# consumes it at runtime. Deliberately unguarded: an image that silently ships
# without the calendar is worse than a red build.
echo "::group:: Installing huru-calendar (iCloud calendar daemon)"
dnf5 -y copr enable wegweg7979/huru-calendar
dnf5 install -y huru-calendar
dnf5 -y copr disable wegweg7979/huru-calendar
echo "huru-calendar installed: $(rpm -q --qf '%{name}-%{version}-%{release}' huru-calendar)"
echo "::endgroup::"

# rclone - cloud storage (Google Drive, iCloud Drive) mounted as local folders so
# the remotes appear in Nautilus like any other filesystem. Plain Fedora repo
# package whose only deps are glibc/filesystem, and fuse3 is already in this
# image; the drive and iclouddrive backends are both compiled in. Deliberately
# unguarded: this is the app whose silent absence made the earlier attempt
# undiagnosable, so a red build beats an image that quietly lacks it. The
# per-user rclone.conf carries OAuth tokens and is never baked in here.
echo "::group:: Installing rclone (cloud storage mounts)"
dnf5 install -y rclone
echo "rclone installed: $(rclone version | head -n1)"
echo "::endgroup::"

# icloud-for-omarchy - the iCloud suite as native apps: iCloud Drive kept in sync
# both ways, the Photos app, and one shared Apple sign-in every component uses.
# Upstream is third-party (MIT, mostly Rust, no Fedora packaging of its own), so
# wegweg7979/icloud-for-omarchy-rpm holds the spec and this COPR builds it; the
# repo is enabled only for the install, like the other app COPRs above.
# Deliberately unguarded: an image that silently ships without it is worse than
# a red build. The suite needs gnome-keyring (the session cookies live there),
# nothing syncs until the user runs `icloud-session sign-in`, and iCloud Drive
# stays off until `icloud-drive start` - neither is done by the package.
echo "::group:: Installing icloud-for-omarchy (iCloud Drive, Photos, sign-in)"
dnf5 -y copr enable wegweg7979/icloud-for-omarchy
dnf5 install -y icloud-for-omarchy
dnf5 -y copr disable wegweg7979/icloud-for-omarchy
echo "icloud-for-omarchy installed: $(rpm -q --qf '%{name}-%{version}-%{release}' icloud-for-omarchy)"
echo "::endgroup::"

# hyprglaze - the shader wallpaper: GLSL effects on Hyprland's background layer,
# aware of windows, the cursor and music. NOT ours: upstream is
# github.com/slastra/hyprglaze (MIT, Arch PKGBUILD, Zig build), so
# wegweg7979/hyprglaze-rpm holds the spec and this COPR builds it; the repo is
# enabled only for the install, like the app COPRs above. It needs Hyprland >= 0.55
# with a Lua config (declared as Requires: hyprland-bin, which Omedora's
# hyprland-no-session Provides) and Zig 0.17.1 at BUILD time -- Fedora 45's zig is
# 0.16.0, so the spec pins the official Zig tarball as a second source.
# Deliberately unguarded: an image that silently ships without the wallpaper is
# worse than a red build. Nothing starts it by itself: the user switches it on and
# off with `omarchy hyprglaze on|off` (system_files/usr/bin/omarchy-hyprglaze),
# which wraps the packaged hyprglaze@<monitor>.service units and reloads Hyprland
# on the way out so the Lua watcher the daemon injects is dropped with the Lua
# state.
echo "::group:: Installing hyprglaze (Hyprland shader wallpaper daemon)"
dnf5 -y copr enable wegweg7979/hyprglaze
dnf5 install -y hyprglaze
dnf5 -y copr disable wegweg7979/hyprglaze
echo "hyprglaze installed: $(rpm -q --qf '%{name}-%{version}-%{release}' hyprglaze)"
echo "::endgroup::"

# flea - the Omarchy-native file manager: four views, Quick Look previews, undo on
# every write, colour tags, ranked search, network places, phones and cameras, and
# the shelf drop widget for the bar. NOT ours: upstream is
# github.com/thisisgm/flea (MIT, Arch-only recipe), so wegweg7979/flea-rpm holds
# the spec and this COPR builds it; the repo is enabled only for the install, like
# the app COPRs above. The COPR has enable_net on (cargo fetches crates.io and the
# pinned gpui fork) and builds thin-LTO, because upstream's fat-LTO link cannot
# finish inside COPR's build ceiling. Requires: omarchy resolves through omedora,
# and bsdtar (its own package on Fedora; libarchive ships only the library here) is
# what tar extraction uses.
# Deliberately unguarded: an image that silently ships without the file manager is
# worse than a red build. Nothing here makes it the desktop default: the user runs
# `flea --default` (folder handler, "Show in folder", Super+Shift+F, file chooser)
# and `flea --picker`, both undoable with `off`.
echo "::group:: Installing flea (file manager)"
dnf5 -y copr enable wegweg7979/flea
dnf5 install -y flea
dnf5 -y copr disable wegweg7979/flea
echo "flea installed: $(rpm -q --qf '%{name}-%{version}-%{release}' flea)"
echo "::endgroup::"

# Every package this image asks for is shipped software, so there is no optional
# tier: the bulk attempt is retried one package at a time purely to NAME the
# failures in the log, and then the build goes red. A green build that quietly
# lacks a package ships a broken box on the next reboot, which is the one outcome
# this image must never produce -- no update is always better than a bad one.
install_packages() {
    local failed=() package

    if dnf5 install -y "$@"; then
        return 0
    fi

    echo "Bulk install failed; retrying one package at a time to isolate failures." >&2
    for package in "$@"; do
        dnf5 install -y "${package}" || failed+=("${package}")
    done

    if (( ${#failed[@]} == 0 )); then
        return 0
    fi

    printf 'These packages could not be installed:\n' >&2
    printf '  %s\n' "${failed[@]}" >&2
    return 1
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
    echo "error: /usr/share/hurunagus/config is missing; /etc/skel not seeded" >&2
    exit 1
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

# A unit that is not in the image is skipped on purpose -- docker.socket is
# requested here while the Docker stack is deliberately excluded from it -- but a
# unit that IS present and cannot be enabled fails the build: that would ship a
# box whose service silently never starts.
enable_unit() {
    local unit="$1"
    if systemctl cat "${unit}" >/dev/null 2>&1; then
        if ! systemctl enable "${unit}"; then
            echo "error: could not enable ${unit}" >&2
            return 1
        fi
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
# sshd: the boxes share their ~/Public folder over SFTP (sftp://<alias>/var/home/dan/Public),
# so the server must listen out of the box. Fedora's 81-desktop.preset disables sshd
# and package-install presets do not fire inside the build container, which is why a
# fresh box has always come up without it; port 22 is already in firewalld's public
# zone, so this needs no firewall, SELinux or extra package.
enable_unit sshd.service
enable_unit cups.service
enable_unit cups-browsed.service
enable_unit avahi-daemon.service
enable_unit systemd-oomd.service
enable_unit podman.socket
enable_unit docker.socket

# Virtualisation: libvirt's daemons are socket-activated, and Fedora's
# 90-default.preset only enables them by way of `systemctl preset` during
# package install -- which does not fire inside the build container, exactly as
# with sshd above. Enable the two sockets this desktop uses: virtqemud serves
# qemu:///system (including the macvtap interfaces LAN-reachable VMs need),
# virtnetworkd serves the network objects. virtproxyd is deliberately left off:
# nothing here speaks the generic libvirt socket, and remote GUI access goes
# over virt-ssh-helper (from libvirt-daemon-common, already pulled in).
enable_unit virtqemud.socket
enable_unit virtnetworkd.socket

# Bake libvirt's default NAT network into every box up front. The RPM does this
# with `virsh net-define` in %post, which cannot work in the build container (no
# running daemon, systemctl silenced), so without these two files the network
# only exists after someone defines it by hand -- and virt-manager would list a
# connection whose "default" network is missing. The autostart symlink is the
# mechanism `virsh net-autostart` itself uses for file-based networks.
if [[ -f /usr/share/libvirt/networks/default.xml ]]; then
    install -Dm0644 /usr/share/libvirt/networks/default.xml /etc/libvirt/qemu/networks/default.xml
    install -d /etc/libvirt/qemu/networks/autostart
    ln -sfn ../default.xml /etc/libvirt/qemu/networks/autostart/default.xml
fi

# Units shipped by this image: these must be enabled.
systemctl enable flatpak-system-install.service
systemctl enable add-default-user-groups.service
# The Hermes agent is a PER-USER install, so its provisioning unit is a user unit
# enabled for every user (it runs in each user's first session, where --system
# has no meaning).
systemctl --global enable add-hermes-agent.service

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
    /usr/share/btrfsmaintenance/btrfsmaintenance-refresh-cron.sh systemd-timer
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
#   * Secure Boot signing is NOT done here: it is phase_sign below, one layer
#     further on, so that the signed artifact, its verification and the key's
#     provenance sit together (a build secret cannot be seen by the layer cache,
#     so signing must not share a layer with the kernel swap). This phase leaves
#     the kernel UNSIGNED on purpose.
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

phase_sign() {
# ---------------------------------------------------------------------------
# Secure Boot signing of the kernel image
# ---------------------------------------------------------------------------
# Upstream parity: Universal Blue's base kernel ships signed (by Fedora's signer
# *and* by a ublue MOK key of its own) so the image can boot with firmware
# Secure Boot on after a one-time enrollment of the public key. This phase does
# the same for the CachyOS kernel, with a key this image owns.
#
# The chain it plugs into, verified against the packages this image actually
# ships:
#   firmware -> shimx64.efi  (Microsoft-signed, so firmware trusts it)
#            -> grubx64.efi  (Fedora-signed, and grub carries the shim_lock
#                             verifier -- once Secure Boot is on, grub refuses to
#                             load a kernel whose signature it cannot check)
#            -> vmlinuz      (signed HERE with our key; trusted through the
#                             firmware MOK list or db)
#
# Scope:
#   * Only the kernel image needs signing. kernel-cachyos signs all ~6500 of its
#     modules with a key generated at kernel-build time and baked into this same
#     vmlinuz -- that is the key the kernel's module verifier trusts, so module
#     signing stays upstream's business.
#   * Secure Boot itself stays OPTIONAL: nothing in this image requires it, and
#     every hurunagus host may keep firmware Secure Boot off. This phase only
#     makes it possible (one MOK enrollment per machine, see
#     /usr/bin/hurunagus-enroll-secure-boot-key).
#   * The private key never enters the image: CI passes it as a podman build
#     secret (--secret id=sb_signing_key), so it exists only inside this RUN and
#     appears in neither the final filesystem nor the image config/history. It
#     is deliberately not a build arg -- build args are recorded in the image.
#   * The public half is committed at ${SB_CERT} and is the single source of
#     truth for both the signature and the enrollment helper. Rotating the key
#     means committing the new certificate, which also invalidates this layer's
#     cache by itself (the certificate is read from the image).
#
# SB_SIGNING=off is the deliberate opt-out; the default is to sign and to FAIL
# the build when the key is missing, because quietly shipping an unsigned kernel
# is the one outcome that must never reach the published tag.

if [[ "${SB_SIGNING:-on}" != "on" ]]; then
    echo "::group:: Signing the kernel for Secure Boot"
    echo "SB_SIGNING=${SB_SIGNING}: kernel left UNSIGNED on purpose (no MOK will verify it)"
    echo "::endgroup::"
    return 0
fi

echo "::group:: Signing the kernel for Secure Boot"

SB_CERT="/usr/share/hurunagus/secureboot/hurunagus-kernel.pem"
SB_CERT_DER="/usr/share/hurunagus/secureboot/hurunagus-kernel.der"
SB_KEY="${SB_SIGNING_KEY_FILE:-/run/secrets/sb_signing_key}"

if [[ ! -f "${SB_CERT}" ]]; then
    printf 'Secure Boot: the public certificate %s is missing from the image (expected from system_files)\n' \
        "${SB_CERT}" >&2
    exit 1
fi

KERNEL_VERSIONS=()
while IFS= read -r kernel_dir; do
    KERNEL_VERSIONS+=("${kernel_dir}")
done < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if (( ${#KERNEL_VERSIONS[@]} != 1 )); then
    printf 'Secure Boot: expected exactly one kernel in /usr/lib/modules, found %d: %s\n' \
        "${#KERNEL_VERSIONS[@]}" "${KERNEL_VERSIONS[*]}" >&2
    exit 1
fi
KERNEL_VERSION="${KERNEL_VERSIONS[0]}"
VMLINUZ="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

# Re-running this phase by hand against an already-built image (the cheap way to
# test it) must not stack a second signature on top of the first.
if command -v sbverify >/dev/null 2>&1 && sbverify --cert "${SB_CERT}" "${VMLINUZ}" >/dev/null 2>&1; then
    echo "${VMLINUZ} is already signed with ${SB_CERT}; nothing to do"
else
    if [[ ! -f "${SB_KEY}" ]]; then
        cat >&2 <<EOF
Secure Boot: no signing key at ${SB_KEY}, so ${VMLINUZ} would ship UNSIGNED.

Pass the private key as a podman build secret, e.g.
    podman build --secret id=sb_signing_key,src=<private key> ...
or export SB_SIGNING_KEY_FILE for 'just build'. Only set SB_SIGNING=off to skip
signing on purpose -- CI does that for pull requests, which are never published.
EOF
        exit 1
    fi

    dnf5 install -y sbsigntools

    # Sign a copy and install it back, keeping mode 0755. sbsign appends a PE
    # signature table (~2.4 KB on this kernel); the deployed
    # /boot/ostree/<csum>/vmlinuz-<kver> is a byte-for-byte copy of this file
    # (verified: identical sha256), which is what carries the signature to the
    # bootloader. dracut's initramfs does not embed the kernel image, so signing
    # after the kernel phase is equivalent to signing before its dracut run.
    install -m0755 "${VMLINUZ}" "${VMLINUZ}.unsigned"
    sbsign --key "${SB_KEY}" --cert "${SB_CERT}" \
        --output "${VMLINUZ}.signed" "${VMLINUZ}.unsigned"
    install -m0755 "${VMLINUZ}.signed" "${VMLINUZ}"
    rm -f "${VMLINUZ}.unsigned" "${VMLINUZ}.signed"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "${VMLINUZ}" 2>/dev/null || true
    fi

    # The signature is the whole point of this phase, so verify the artifact
    # that will ship rather than the sbsign exit code alone.
    if ! sbverify --cert "${SB_CERT}" "${VMLINUZ}" >/dev/null 2>&1; then
        printf 'Secure Boot: %s does not verify against %s -- refusing to ship it\n' \
            "${VMLINUZ}" "${SB_CERT}" >&2
        sbverify --list "${VMLINUZ}" 2>&1 | head -n 20 >&2
        exit 1
    fi
fi

# DER twin of the same certificate, which is what mokutil imports (the PEM is
# not accepted) and what hurunagus-enroll-secure-boot-key reads.
openssl x509 -in "${SB_CERT}" -outform DER -out "${SB_CERT_DER}"
chmod 0644 "${SB_CERT_DER}"

# sbsigntools stays installed on purpose: /usr is read-only on a booted host, so
# sbverify could not be added later, and it is the only way for someone on the
# machine to check what the deployed kernel is actually signed with.
echo "kernel signed: ${VMLINUZ}"
sbverify --list "${VMLINUZ}" | sed 's/^/  /'
printf 'certificate: %s\n' "$(openssl x509 -in "${SB_CERT}" -noout -subject | sed 's/^subject=//')"
printf 'sha256 fingerprint: %s\n' "$(openssl x509 -in "${SB_CERT}" -noout -fingerprint -sha256 | cut -d= -f2)"
echo "enroll it on a host with: hurunagus-enroll-secure-boot-key (ujust enroll-hurunagus-kernel-key)"
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
# Deliberately unguarded: the cached layer holds the PREVIOUS commit's omedora,
# and this phase is supposed to be gated on the COPR build for the new one having
# reached "succeeded". A failed refresh means that gate was missed, so fail here
# rather than ship a stale runtime against a fresh base.
dnf5 -y --refresh upgrade omedora omedora-settings
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
    echo "error: /usr/share/sddm/themes/omarchy is missing; theme not mirrored" >&2
    exit 1
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Clean build artifacts so they don't ship in the image
# ---------------------------------------------------------------------------
# Trimming what the base image drags in that nothing here uses
# ---------------------------------------------------------------------------
echo "::group:: Trimming unused packages"

# None of these is a weak dependency of anything THIS build installs: the
# parents are base-image packages (linux-firmware recommends the NVIDIA firmware
# blobs; gnome-shell recommends ibus) or the package is an orphan already in the
# base's set. So `--setopt=install_weak_deps=False` would NOT remove them, and
# the KEEPERS that flag would have taken by accident (mesa-vulkan-drivers,
# vulkan-loader, iw for the Wi-Fi tooling, linux-firmware itself) are
# deliberately absent from the list below.
#
#   nvidia-gpu-firmware    NVIDIA firmware blobs; this desktop is Intel iGPU.
#   glibc-all-langpacks    all 200+ locales. LANG=en_GB.UTF-8 needs only the
#                          `en` langpack, which EXTRA_PACKAGES now installs;
#                          removing this without that would strand the host on C.
#   python3-botocore       AWS SDK bindings; nothing in this image or in omedora
#                          talks to AWS.
#   cosign                 signature CLI. containers/image verifies this image
#                          through the sigstoreSigned policy in
#                          /etc/containers/policy.json using its vendored
#                          library, not this binary, and no file in the image
#                          repo, system_files or omedora calls it — but it IS a
#                          signing tool, so re-check it after the next rebase.
#   ibus, ibus-*, cldr-*   ibus plus every engine and its CLDR data. The CJK
#                          input methods are skip-mapped in fedora.toml (no CJK
#                          typing on this desktop), fcitx5 does not need ibus,
#                          and nothing in system_files or omedora references it.
#   qt6-qtmultimedia-devel build-only Qt headers that arrived with the toolkit;
#                          the base's own list has no such package and nothing
#                          installed requires or recommends it. The runtime
#                          qt6-qtmultimedia stays.
#   google-noto-*cjk-*     the CJK font stack, ~241 MiB, none of it used here.
#   default-fonts-cjk-*    The four font packages are BASE packages (or arrive
#                          as deps of the three metas), which is why the
#                          EXCLUDED_PACKAGES filter above cannot drop them: it
#                          only prunes this build's resolved list. Remove the
#                          metas together with the fonts, or the -vf packages
#                          come straight back. Cost: CJK text renders as tofu.
#
# Transaction preview before spending a build (changes nothing):
#   dnf5 remove -y --assumeno <the list below>
dnf5 remove -y \
    nvidia-gpu-firmware \
    glibc-all-langpacks \
    python3-botocore \
    cosign \
    ibus \
    ibus-anthy \
    ibus-anthy-python \
    ibus-hangul \
    ibus-libpinyin \
    ibus-m17n \
    ibus-setup \
    ibus-typing-booster \
    cldr-emoji-annotation \
    cldr-emoji-annotation-dtd \
    qt6-qtmultimedia-devel \
    google-noto-sans-cjk-fonts \
    google-noto-sans-cjk-vf-fonts \
    google-noto-serif-cjk-vf-fonts \
    google-noto-sans-mono-cjk-vf-fonts \
    default-fonts-cjk-sans \
    default-fonts-cjk-serif \
    default-fonts-cjk-mono || true

echo "::endgroup::"

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
  sign) phase_sign ;;
  fresh) phase_fresh ;;
  all) phase_base; phase_kernel; phase_sign; phase_fresh ;;
  *)
    echo "build.sh: unknown phase '${PHASE}' (expected base|kernel|sign|fresh|all)" >&2
    exit 1
    ;;
esac
