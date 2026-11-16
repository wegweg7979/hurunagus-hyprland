# hurunagus-hyprland
<img width="959" height="540" alt="image" src="https://github.com/user-attachments/assets/1c967de0-b16b-4046-9373-709a73241dbc" />

Declarative, atomic, immutable Linux system. Fedora Silverblue, Omarchy desktop, Cachyos kernel , automatic weekly updates and all the
apps I need preinstalled. It is fedora, but it is omarchy, but its Cachyos....

Reason to exist: making all my computers run identical systems, administered in
one place, from a single repo. Automatic builds once a week on a Tuesday, silently applied in the background and applied on reboot.
Stability of Fedora. Immutability and build process of Silverblue. Omarchy bling. CachyOs performance. Batteries included from Universal Blue.
The best of Linux in one distro. 


- Hyprland as the window manager.
- Omarchy ported to fedora (Omedora)
- Omedora forked and modified to function correctly on immutable fedora (rpm-ostree / bootc).
- SDDM user picker — the Omarchy login theme with added user picker for multi-user systems.
- Btrfs maintenance via `btrfsmaintenance`: a monthly checksum-verifying
  scrub of the btrfs filesystem.
- CachyOS kernel — from the official CachyOS Fedora port: BORE CPU scheduler,
  1000 Hz tick, full preemption, BFQ/Kyber I/O schedulers, x86_64-v3. A matching
  initramfs is generated for it, and it is signed with this image's own key, so
  Secure Boot can be turned on after one MOK enrollment per machine. Off by
  default, and nothing here requires it.
- Omarchy Agent skills modified to fit immutable fedora.  
- iCloud Photos, iCloud drive, iCloud calendar ready to log in.
- Google drive ready to login
- Hardware accelerated video fully set up for intel gpu
- Pre-install list of flatpak software.

Dont use this —you can make your own, it is not too difficult and quite fun.
https://github.com/ublue-os/image-template

Be aware installed apps and features will be added or removed as I see fit at
anytime. Hence the warning to not consider this a "stable" OS for anyone except
myself. It is, despite that, a rock solid, efficient and fully featured operating
system suitable for multimedia and modern computing in 2026. I need my computer to work properly, and this does "just work". If you are the admin
for more than one machine, you should really take the time to make your own for
exactly YOUR needs.


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


<img width="512" height="512" alt="Gemini_Generated_Image_rokat0rokat0roka" src="https://github.com/user-attachments/assets/d0bfbdca-0e15-4e00-a0f9-16cf8704a825" />


## Secure Boot (optional)

The kernel is signed with a key this image owns (Fedora signs no third party, and
the CachyOS port ships no signed flavour). Turning Secure Boot on is one
enrollment per machine, because firmware only trusts keys it has been told about:

```sh
ujust enroll-hurunagus-kernel-key   # set a one-time password, then reboot
# blue MokManager screen -> Enroll MOK -> that password
# then enable Secure Boot in firmware setup
```

`mokutil --sb-state` reports the result afterwards. The certificate and the
key-rotation notes live in `/usr/share/hurunagus/secureboot/`. The inherited
`ujust enroll-secure-boot-key` enrolls Universal Blue's key, not this one.

## References

- ublue-os image-template: https://github.com/ublue-os/image-template
- Omarchy: https://github.com/omacom/omarchy
- Omedora (omeadora): https://github.com/AndrewGaspar/omadora
- Original Hurunagus ublue project: https://github.com/wegweg7979/hurunagus-ublue
- hurubase — safe rebase helper: https://github.com/wegweg7979/hurunagus-rebase
