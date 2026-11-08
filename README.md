# hurunagus-hyprland
<img width="959" height="540" alt="image" src="https://github.com/user-attachments/assets/1c967de0-b16b-4046-9373-709a73241dbc" />

Declarative, atomic, immutable Linux system. Fedora Silverblue, with the
Hyprland + Omarchy desktop, automatic weekly updates and all the
apps I need preinstalled. It is fedora, but it is omarchy...

Reason to exist: making all my computers run identical systems, administered in
one place, from a single repo. Automatic builds once a week on a Tuesday.

Dont use this — make your own, it is not too difficult and quite fun.
https://github.com/ublue-os/image-template

Be aware installed apps and features will be added or removed as I see fit at
anytime. Hence the warning to not consider this a "stable" OS for anyone except
myself. It is, despite that, a rock solid, efficient and fully featured operating
system suitable for multimedia and modern computing in 2026. If you are the admin
for more than one machine, you should really take the time to make your own for
exactly YOUR needs.

rebase an existing atomic Fedora installation:

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

- **Hyprland** as the window manager.
- **Omarchy** dotfiles under `~/.config/hypr` and `~/.config/omarchy` for the
  look & feel, keybindings and first-boot provisioning.
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
  boot. They will also be re-installed at boot if the user has uninstalled them. 



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

### If you're rebasing from a *different* atomic distro

Your existing `$HOME` is preserved across the rebase — atomic rebases never touch
it. That means the Omarchy defaults this image ships in `/etc/skel` (dotfiles for
`~/.config/hypr` and `~/.config/omarchy`, the branding/screensaver files, themes,
toggles, migration markers) will **not** be seeded into your current user's home.
To adopt them, run this once **after your first login** on the new system:

```sh
omarchy-reinstall-configs
```

New users (fresh installs, or accounts created after the rebase) get these
automatically from `/etc/skel` and do not need this step.

## References

- ublue-os image-template: https://github.com/ublue-os/image-template
- Omarchy: https://github.com/omacom/omarchy
- Omedora (omeadora): https://github.com/AndrewGaspar/omadora
- Original Hurunagus ublue project: https://github.com/wegweg7979/hurunagus-ublue
