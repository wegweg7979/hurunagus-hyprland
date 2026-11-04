# hurunagus-hyprland

Declarative, atomic, immutable Linux system. Fedora 44 base, from ublue, with the
Hyprland + Omarchy desktop (for Hurunagus), automatic weekly updates and all the
apps I need preinstalled.

Reason to exist: making all my computers run identical systems, administered in
one place, from a single repo. Automatic builds once a week on a Tuesday.

Dont use this — make your own, it is not too difficult and quite fun.
https://github.com/ublue-os/image-template

Be aware installed apps and features will be added or removed as I see fit at
anytime. Hence the warning to not consider this a "stable" OS for anyone except
myself. It is, in fact, a rock solid, efficient and fully featured operating
system suitable for multimedia and modern computing in 2026. If you are the admin
for more than one machine, you should really take the time to make your own for
exactly YOUR needs.

OR: to rebase an existing atomic Fedora installation:

- First rebase to the unsigned image, to get the proper signing keys and policies
  installed:
  ```sh
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/wegweg7979/hurunagus-hyprland:latest
  ```
- Reboot to complete the rebase:
  ```sh
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```sh
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/wegweg7979/hurunagus-hyprland:latest
  ```
- Reboot again to complete the installation:
  ```sh
  systemctl reboot
  ```

## Desktop

This image ships **Hyprland** with **Omarchy** dotfiles, based on the omadora
variant of Omarchy. Highlights:

- **Hyprland** as the window manager (replaces Niri / Dank Material Shell).
- **Omarchy** dotfiles under `~/.config/hypr` and `~/.config/omarchy` for the
  look & feel, keybindings and first-boot provisioning.
- **1080p default** — the desktop starts at 1920×1080 regardless of what the
  display advertises.
- **Scrolling window layout** as the default Hyprland layout.
- **Wallpapers imported** from the original project into
  `~/.local/share/backgrounds` and `/usr/share/backgrounds/hurunagus`.
- **SDDM user picker** — the Omarchy login theme lists every human account
  instead of assuming a single last user. It still remembers the last login
  when `/var/lib/sddm/state.conf` exists, and falls back to the first account
  on a fresh install or rebase. Click a name, or use Up/Down while the
  password field is focused. Switching accounts clears the password and any
  failed-login state. The theme is mirrored into Omarchy's default theme path
  as well, so `omarchy-refresh-sddm` keeps the picker.
- **Flatpak list imported** so all of the favourite apps are installed on first
  boot.

## Variants
### Desktop (default)
The standard image with 1080p default, scrolling layout, Omarchy dotfiles, and
wallpapers imported. Built with:

```sh
just build-iso
just build-server-iso
```

### Server variant (user creation during install)
A variant where user accounts are provisioned DURING install (in the installer's
`%post` phase), not on first boot. This is useful for server deployments where
you want the default user and groups to exist as soon as the machine reboots
after install.

Built with:
```sh
just build-server-iso
just build-server-qcow2
```

The server variant kicks off user creation in `%post` (before the `bootc switch`)
and disables the first-boot `add-default-user-groups.service` so user setup is
not duplicated on first boot.

## Build
```sh
# Build the container image (Podman)
just build

# Build a bootable disk image (Bootc Image Builder)
just build-qcow2
just build-raw
just build-iso
just build-server-iso   # Server variant: user creation during install

# Or from the Justfile directly
just _rebuild-bib localhost/wegweg7979/hurunagus-hyprland latest qcow2 disk_config/disk.toml
```

## Install

- First rebase to the unsigned image, to get the proper signing keys and policies
  installed:
  ```sh
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/wegweg7979/hurunagus-hyprland:latest
  ```
- Reboot to complete the rebase:
  ```sh
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```sh
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/wegweg7979/hurunagus-hyprland:latest
  ```
- Reboot again to complete the installation:
  ```sh
  systemctl reboot
  ```

## References

- ublue-os image-template: https://github.com/ublue-os/image-template
- Omarchy: https://github.com/omacom/omarchy
- Omedora (omeadora): https://github.com/AndrewGaspar/omadora
- Original Hurunagus ublue project: https://github.com/wegweg7979/hurunagus-ublue
