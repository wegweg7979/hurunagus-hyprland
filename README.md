# hurunagus-hyprland
<img width="959" height="540" alt="image" src="https://github.com/user-attachments/assets/1c967de0-b16b-4046-9373-709a73241dbc" />

Declarative, atomic, immutable Linux system. Fedora Silverblue, with
Hyprland + Omarchy desktop, Cachyos kernel , automatic weekly updates and all the
apps I need preinstalled. It is fedora, but it is omarchy, but its Cachyos....

Reason to exist: making all my computers run identical systems, administered in
one place, from a single repo. Automatic builds once a week on a Tuesday, silently applied in the background and applied on reboot.
Stability of Fedora. Immutability and build process of Silverblue. Omarchy bling. CachyOs performance. Batteries included from Universal Blue.
The best of Linux in one distro. 

Dont use this — make your own, it is not too difficult and quite fun.
https://github.com/ublue-os/image-template

Be aware installed apps and features will be added or removed as I see fit at
anytime. Hence the warning to not consider this a "stable" OS for anyone except
myself. It is, despite that, a rock solid, efficient and fully featured operating
system suitable for multimedia and modern computing in 2026. I need my computer to work properly, and this does "just work". If you are the admin
for more than one machine, you should really take the time to make your own for
exactly YOUR needs.

rebase an existing atomic Fedora installation — the safe, scripted path is
[`hurubase`](#install), and these are the same steps by hand:

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
- **Omedora** forked and modified to function correctly on immutable fedora (rpm-ostree / bootc).
- **Scrolling window layout** as the default Hyprland layout. (niri like)
- **Wallpapers imported** from the original project into
  `~/.local/share/backgrounds` and `/usr/share/backgrounds/hurunagus`.
- **SDDM user picker** — the Omarchy login theme with added user picker for multi-user systems.
- **Flatpak list imported** so all of the favourite apps are installed on first
  boot. They will also be re-installed at boot if the user has uninstalled them. 
- **Btrfs maintenance** via `btrfsmaintenance`: a monthly checksum-verifying
  scrub of the btrfs filesystem.
- **CachyOS kernel** — the stock Fedora kernel is replaced at build time with
  `kernel-cachyos` from the official CachyOS Fedora port: BORE CPU scheduler,
  1000 Hz tick, full preemption, BFQ/Kyber I/O schedulers, x86_64-v3. A matching
  initramfs is generated for it. The kernel is unsigned, so Secure Boot would
  need a MOK enrolled by hand.



## Install

The safe way in is [`hurubase`](https://github.com/wegweg7979/hurunagus-rebase).
It resolves and digest-pins the address, reads your container signature policy to
decide whether the signed image works directly or the two-step below is needed,
refuses a staged deployment / low disk / an address that will not resolve, and
after the reboot adopts this image's `/etc/skel` payload into your `$HOME` and
fixes a session record that still points at the old desktop — asking before each
change.

```sh
./hurubase ghcr.io/wegweg7979/hurunagus-hyprland:latest        # preflight and plan
sudo ./hurubase ghcr.io/wegweg7979/hurunagus-hyprland:latest   # apply
```

If you prefer to do it yourself, `hurubase` does exactly this:

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

Re-running [`hurubase`](https://github.com/wegweg7979/hurunagus-rebase) with the
same image address does this adoption for you, along with resetting a session
record that still names the other distro's session (which is what leaves you on a
black screen or bouncing back to the greeter) — each change offered separately,
with backups.

<img width="512" height="512" alt="Gemini_Generated_Image_rokat0rokat0roka" src="https://github.com/user-attachments/assets/d0bfbdca-0e15-4e00-a0f9-16cf8704a825" />


## References

- ublue-os image-template: https://github.com/ublue-os/image-template
- Omarchy: https://github.com/omacom/omarchy
- Omedora (omeadora): https://github.com/AndrewGaspar/omadora
- Original Hurunagus ublue project: https://github.com/wegweg7979/hurunagus-ublue
- hurubase — safe rebase helper: https://github.com/wegweg7979/hurunagus-rebase
