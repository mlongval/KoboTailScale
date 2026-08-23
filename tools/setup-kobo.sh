#!/usr/bin/env bash
#
# One-shot setup of a Kobo over SSH: write the "kobo" alias into ~/.ssh/config,
# check the connection, fetch the binaries if needed, install, and log in.
#
#   ./tools/setup-kobo.sh 192.168.1.50              # IP from KOReader's SSH server dialog
#   ./tools/setup-kobo.sh 192.168.1.50 --authkey tskey-auth-...
#
# Options:
#   --alias NAME          ssh alias to create (default: kobo)
#   --port N              KOReader SSH server port (default: 2222)
#   --authkey tskey-...   log in non-interactively (no browser step)
#   --no-nickelmenu       passed through to install.sh
#   --no-login            install only; skip the login step
#
# Needs: ssh, sshpass (KOReader's server has a blank root password, which plain
# ssh refuses to send unattended). After this, `sshpass -p '' ssh kobo` works
# and every `kobo` in the README means this device.

set -euo pipefail

ALIAS="kobo"
PORT="2222"
AUTHKEY=""
DO_LOGIN=1
INSTALL_ARGS=()
IP=""

usage() {
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --alias) ALIAS="${2:-}"; shift ;;
        --alias=*) ALIAS="${1#*=}" ;;
        --port) PORT="${2:-}"; shift ;;
        --port=*) PORT="${1#*=}" ;;
        --authkey) AUTHKEY="${2:-}"; shift ;;
        --authkey=*) AUTHKEY="${1#*=}" ;;
        --no-nickelmenu) INSTALL_ARGS+=(--no-nickelmenu) ;;
        --no-login) DO_LOGIN=0 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) IP="$1" ;;
    esac
    shift
done
[[ -n "$IP" ]] || usage

cd "$(dirname "$0")/.."

for tool in ssh scp sshpass; do
    command -v "$tool" >/dev/null || {
        echo "error: $tool not found -- on Debian/Ubuntu: sudo apt install openssh-client sshpass" >&2
        exit 1
    }
done

# --- ~/.ssh/config ------------------------------------------------------------
CONF="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$CONF" && chmod 600 "$CONF"

BLOCK="Host $ALIAS
    HostName $IP
    Port $PORT
    User root
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new"

if grep -qE "^Host[[:space:]]+$ALIAS([[:space:]]|$)" "$CONF"; then
    # Replace the existing block: from "Host <alias>" up to the next Host line.
    awk -v alias="$ALIAS" -v block="$BLOCK" '
        $1 == "Host" && $2 == alias { print block; skip = 1; next }
        $1 == "Host" { skip = 0 }
        !skip { print }
    ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    echo "==> updated 'Host $ALIAS' in $CONF -> $IP:$PORT"
else
    { [[ -s "$CONF" ]] && echo; echo "$BLOCK"; } >> "$CONF"
    echo "==> added 'Host $ALIAS' to $CONF -> $IP:$PORT"
fi

# --- can we reach it? ---------------------------------------------------------
SSH="sshpass -p '' ssh -F $CONF"
SCP="sshpass -p '' scp -F $CONF"
export SSH SCP

echo "==> testing the connection"
if ! $SSH -o ConnectTimeout=8 "$ALIAS" 'uname -m' ; then
    cat >&2 <<EOM
error: cannot reach root@$IP:$PORT.
  - Is KOReader's SSH server running?  KOReader -> Network -> SSH server
  - Is the Kobo on the same WiFi, and is $IP the address that dialog shows?
EOM
    exit 1
fi

# --- binaries, install, login -------------------------------------------------
if [[ ! -x vendor/bin/tailscaled || ! -x vendor/bin/tailscale ]]; then
    echo "==> fetching the Tailscale binaries"
    ./tools/fetch-tailscale.sh
fi

if [[ -n "$AUTHKEY" ]]; then
    INSTALL_ARGS+=(--authkey "$AUTHKEY")
fi
./install.sh "$ALIAS" "${INSTALL_ARGS[@]}"

if [[ -z "$AUTHKEY" && $DO_LOGIN -eq 1 ]]; then
    echo "==> logging in (open the URL below in a browser and approve the device)"
    $SSH "$ALIAS" /mnt/onboard/.adds/tailscale/tailscale-ctl.sh login
fi

cat <<EOM

Done. From now on:
    sshpass -p '' ssh $ALIAS                      # a shell on the Kobo
    sshpass -p '' ssh $ALIAS /mnt/onboard/.adds/tailscale/tailscale-ctl.sh status
EOM
