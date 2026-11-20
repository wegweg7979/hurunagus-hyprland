#!/bin/bash
set -euo pipefail

MARKER="/var/lib/.user-groups-initialized"
[[ -f "$MARKER" ]] && exit 0

users=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | paste -sd, -)
[[ -z "$users" ]] && exit 0

# Append local override entries to /etc/group for the standard device groups.
# The base groups live in /usr/lib/group; /etc/group entries override them.
echo "audio:x:63:${users}" >> /etc/group
echo "video:x:39:${users}" >> /etc/group
echo "kvm:x:36:${users}" >> /etc/group
echo "render:x:105:${users}" >> /etc/group
echo "input:x:104:${users}" >> /etc/group

# libvirt: the qemu:///system API the flatpak virt-manager drives once this
# image ships the libvirt daemons. Unlike the groups above (fixed base-image
# ids) this gid is allocated by the packaging's sysusers file, so read it
# rather than hardcoding one.
libvirt_gid="$(getent group libvirt | cut -d: -f3 || true)"
if [[ -n "${libvirt_gid}" ]]; then
    echo "libvirt:x:${libvirt_gid}:${users}" >> /etc/group
fi

touch "$MARKER"
