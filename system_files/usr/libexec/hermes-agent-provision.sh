#!/bin/bash
# Install Hermes Agent for the invoking user, at first login.
#
# The agent's official installer is strictly per-user (checkout in $HERMES_HOME,
# launcher in ~/.local/bin, PATH wired into the user's own shell rc), so it can
# only ever run as the user, never during the image build. This runs from
# add-hermes-agent.service, a user unit enabled globally by the image.
set -euo pipefail

INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"

if [[ ${EUID} -eq 0 ]]; then
    echo "error: this must run as the user, not as root" >&2
    exit 1
fi

# Wait for the network, bounded, because first login can happen before DHCP or
# Wi-Fi is up. This is HERE rather than as After=/Wants=network-online.target in
# the unit: network-online.target is system-scope, so a user unit's dependency on
# it resolves to nothing and the unit would start regardless (podman ships
# podman-user-wait-network-online.service for exactly this reason -- a user unit
# cannot order itself after the system's target). Probing the URL the install
# actually needs is the only check that means anything.
wait_for_network() {
    local deadline=$((SECONDS + 120))
    until curl -fsS --max-time 8 -o /dev/null "$INSTALL_URL"; do
        if ((SECONDS >= deadline)); then
            echo "error: no network after 120s; will retry at next login" >&2
            return 1
        fi
        sleep 3
    done
}

# The installer flag is --non-interactive; --no-prompt does not exist and used to
# abort the install silently (that bug is why no image ever shipped the agent).
# The browser and computer-use driver are skipped on purpose: this desktop
# already ships Chromium and Brave, and both are one command away when wanted
# (`hermes pm install chromium`, `hermes pm install cua-driver`).
wait_for_network
curl -fsSL --retry 3 --retry-delay 2 "$INSTALL_URL" |
    bash -s -- --non-interactive --skip-browser --skip-computer-use
