#!/usr/bin/env bash
#
# Install Tailscale onto a Kobo.
#
# Two ways to install:
#
#   ./install.sh kobo                 copy over SSH to a networked device
#   ./install.sh /media/you/KOBO      copy to a USB-mounted device
#
# The first form takes any ssh target (a host from ~/.ssh/config, user@ip, or
# a Tailscale name). The second takes the mount point of the Kobo's user
# partition -- the folder that appears when you plug the device in.
#
# Options:
#   --no-nickelmenu       skip the home-screen menu entry
#   --authkey tskey-...   log in non-interactively during install (SSH only)
#
# KOReader's built-in SSH server listens on a non-standard port and often with
# no password, which plain ssh cannot do unattended. Override the commands for
# that case:
#
#   SSH="sshpass -p '' ssh -p 2222" SCP="sshpass -p '' scp -P 2222" \
#       ./install.sh root@192.168.2.192

set -euo pipefail

# Where things land on the device.
DEST_REL=".adds/tailscale"
NM_REL=".adds/nm"
ONBOARD="/mnt/onboard"

SSH=${SSH:-ssh}
SCP=${SCP:-scp}

usage() {
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
    exit 1
}

WITH_NM=1
AUTHKEY=""
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-nickelmenu) WITH_NM=0 ;;
        --authkey) AUTHKEY="${2:-}"; shift ;;
        --authkey=*) AUTHKEY="${1#*=}" ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) TARGET="$1" ;;
    esac
    shift
done
[[ -n "$TARGET" ]] || usage

cd "$(dirname "$0")"

if [[ ! -x vendor/bin/tailscaled || ! -x vendor/bin/tailscale ]]; then
    echo "error: vendor/bin is empty -- run: ./tools/fetch-tailscale.sh" >&2
    exit 1
fi
VERSION=$(tr -d '[:space:]' < TAILSCALE_VERSION)

# --- USB-mounted device -----------------------------------------------------
if [[ -d "$TARGET" ]]; then
    DEST="$TARGET/$DEST_REL"
    echo "Installing tailscale $VERSION to $DEST"
    mkdir -p "$DEST/bin" "$DEST/log"
    cp vendor/bin/tailscale vendor/bin/tailscaled "$DEST/bin/"
    cp device/tailscale-ctl.sh "$DEST/"
    # Never clobber settings the user has edited on the device.
    [[ -f "$DEST/tailscale.conf" ]] || cp device/tailscale.conf "$DEST/"
    chmod +x "$DEST/tailscale-ctl.sh" "$DEST/bin/tailscale" "$DEST/bin/tailscaled" 2>/dev/null || true

    # A USB install cannot log in -- the Kobo isn't running its OS in storage
    # mode. Seeding the key lets the first toggle authenticate itself instead.
    if [[ -n "$AUTHKEY" ]]; then
        sed "s|^[[:space:]]*AUTHKEY=.*|AUTHKEY=\"$AUTHKEY\"|" "$DEST/tailscale.conf" > "$DEST/.conf.tmp" \
            && cat "$DEST/.conf.tmp" > "$DEST/tailscale.conf"
        rm -f "$DEST/.conf.tmp"
        grep -q "^AUTHKEY=\"$AUTHKEY\"$" "$DEST/tailscale.conf" \
            || { echo "error: failed to seed the auth key into tailscale.conf" >&2; exit 1; }
        echo "Seeded the auth key; the first toggle will log in by itself."
    fi

    if [[ $WITH_NM -eq 1 ]]; then
        if [[ ! -d "$TARGET/$NM_REL" ]]; then
            echo "warning: no NickelMenu at $TARGET/$NM_REL -- skipping menu entry" >&2
        else
            cp nickelmenu/tailscale "$TARGET/$NM_REL/tailscale"
            echo "Installed the NickelMenu entry."
        fi
    fi

    sync
    if [[ -n "$AUTHKEY" ]]; then
        cat <<'EOF'

Done. Eject the device, then tap "Tailscale" on the home screen -- it brings
WiFi up, logs in with the seeded key, and clears the key from the config.
EOF
    else
        cat <<EOF

Done. Eject the device.

One-time login, over SSH once the Kobo is back on WiFi:

    ssh kobo $ONBOARD/$DEST_REL/tailscale-ctl.sh login

Then the "Tailscale" entry on the home screen toggles it. To skip the SSH step
entirely, reinstall with --authkey tskey-auth-... instead.
EOF
    fi
    exit 0
fi

# --- Over SSH ---------------------------------------------------------------
echo "Installing to $TARGET over SSH"

# --- preflight: check the device before copying 65 MB to it -----------------
echo "==> preflight"
PREFLIGHT=$($SSH "$TARGET" '
    echo "arch=\"$(uname -m)\""
    echo "kernel=\"$(uname -r)\""
    if [ -c /dev/net/tun ]; then
        echo "tun=node"
    elif [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -q "^CONFIG_TUN=y"; then
        echo "tun=builtin"
    elif [ -f /proc/config.gz ]; then
        echo "tun=missing"
    else
        echo "tun=unknown"
    fi
    echo "freekb=\"$(df -k /mnt/onboard 2>/dev/null | awk "NR==2 {print \$4}")\""
    [ -d /mnt/onboard/.adds/nm ] && echo "nm=yes" || echo "nm=no"
') || { echo "error: could not reach $TARGET over SSH" >&2; exit 1; }

eval "$(echo "$PREFLIGHT" | sed 's/^/DEV_/')"
DEV_freekb=${DEV_freekb:-0}
echo "    arch ${DEV_arch}, kernel ${DEV_kernel}, tun ${DEV_tun}, $((DEV_freekb / 1024)) MB free"

case "$DEV_arch" in
    arm*) ;;
    *) echo "error: unexpected architecture '$DEV_arch'; vendor/bin is 32-bit ARM" >&2; exit 1 ;;
esac

case "$DEV_tun" in
    node|builtin) ;;
    missing)
        echo "error: this kernel has no TUN support (CONFIG_TUN is not set)." >&2
        echo "       Kernel-mode Tailscale cannot work here." >&2
        exit 1 ;;
    unknown)
        echo "warning: no /dev/net/tun and no /proc/config.gz to check against." >&2
        echo "         Continuing; 'tailscale-ctl.sh start' will fail loudly if TUN is absent." >&2 ;;
esac

if (( DEV_freekb > 0 && DEV_freekb < 150000 )); then
    echo "error: only $((DEV_freekb / 1024)) MB free on /mnt/onboard; need ~150 MB" >&2
    exit 1
fi

# --- copy -------------------------------------------------------------------
DEST="$ONBOARD/$DEST_REL"
echo "==> copying tailscale $VERSION to $DEST"
$SSH "$TARGET" "mkdir -p '$DEST/bin' '$DEST/log'"
$SCP -q vendor/bin/tailscale vendor/bin/tailscaled "$TARGET:$DEST/bin/"
$SCP -q device/tailscale-ctl.sh "$TARGET:$DEST/"
# Never clobber settings the user has edited on the device.
$SSH "$TARGET" "[ -f '$DEST/tailscale.conf' ]" ||
    $SCP -q device/tailscale.conf "$TARGET:$DEST/"
$SSH "$TARGET" "chmod +x '$DEST/tailscale-ctl.sh' '$DEST/bin/tailscale' '$DEST/bin/tailscaled' 2>/dev/null || true"

if [[ $WITH_NM -eq 1 ]]; then
    if [[ "${DEV_nm:-no}" != "yes" ]]; then
        echo "warning: no NickelMenu at $ONBOARD/$NM_REL -- skipping menu entry" >&2
    else
        $SCP -q nickelmenu/tailscale "$TARGET:$ONBOARD/$NM_REL/tailscale"
        echo "==> installed the NickelMenu entry"
    fi
fi

# --- log in -----------------------------------------------------------------
if [[ -n "$AUTHKEY" ]]; then
    echo "==> logging in with the supplied auth key"
    $SSH "$TARGET" "'$DEST/tailscale-ctl.sh' login --authkey='$AUTHKEY'"
else
    cat <<EOF

Done. One-time login (prints a URL to open in a browser):

    $SSH $TARGET $DEST/tailscale-ctl.sh login

After that, the "Tailscale" entry on the home screen toggles it, and
"Tailscale status" shows the device's tailnet address in a toast.
EOF
fi
