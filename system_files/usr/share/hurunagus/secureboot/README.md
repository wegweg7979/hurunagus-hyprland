# hurunagus kernel signing

The CachyOS kernel this image ships is signed with the key whose public half is
`hurunagus-kernel.pem` here (and its DER twin, generated at build time, which is
what `mokutil` imports).

Secure Boot is **optional** on this image: nothing here requires it, and every
host may leave firmware Secure Boot off. Enabling it needs one enrollment per
machine, because firmware only trusts keys it knows about:

    ujust enroll-hurunagus-kernel-key      # or: hurunagus-enroll-secure-boot-key

then reboot and finish at the blue MokManager screen (*Enroll MOK*), and only
then turn Secure Boot on in firmware setup. Verify what actually booted with
`mokutil --sb-state` (and `sbverify --list /boot/ostree/*/vmlinuz-*` for the
signature on the deployed kernel).

Why an own key instead of Fedora's: Fedora signs its own kernels and does not
sign for third parties, and the CachyOS COPR publishes no signed flavour, so the
image signs its own. The same shape upstream ships — Universal Blue signs its
kernel with a MOK key of its own and enrolls it the same way.

## The private half

It is deliberately **not** in this repository. It lives in the
`SB_SIGNING_KEY` GitHub Actions secret and reaches the image build only as a
podman build secret, so it never appears in the image, its config or its layer
history. A local build signs with `SB_SIGNING_KEY_FILE=/path/to/hurunagus-kernel.key`
(`just build`).

Rotating the key: replace `hurunagus-kernel.pem` with the new certificate
(which invalidates the signing layer's build cache by itself), update the
secret, rebuild, and re-enroll on every host — the firmware MOK list holds
several keys, so the old one can stay until it is removed with
`mokutil --delete`.
