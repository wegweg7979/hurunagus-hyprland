# hurunagus additions to ujust.
#
# This path is the upstream-provided hook -- ublue-os' /usr/share/ublue-os/justfile
# ends with `import? "/usr/share/ublue-os/just/60-custom.just"` -- so nothing
# upstream is modified to add a recipe here.
#
# Recipe names must not collide with an existing ujust recipe (just aborts its
# listing on a duplicate). Upstream already ships `enroll-secure-boot-key`,
# which enrolls *Universal Blue's* kernel key; that is not what verifies this
# image's kernel, hence the name below.

# Enroll the hurunagus kernel signing key so Secure Boot can be enabled (optional)
enroll-hurunagus-kernel-key:
    #!/usr/bin/bash
    exec /usr/bin/hurunagus-enroll-secure-boot-key
