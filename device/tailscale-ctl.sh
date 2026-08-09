#!/bin/sh
# tailscale-ctl.sh — run Tailscale on a Kobo. POSIX sh, for the device's busybox ash.
#
#   tailscale-ctl.sh start | stop | toggle | restart
#   tailscale-ctl.sh status          one line, sized for a NickelMenu toast
#   tailscale-ctl.sh login           one-time interactive auth (run over SSH)
#   tailscale-ctl.sh logs            tail the daemon log
#   tailscale-ctl.sh ts <args...>    raw tailscale CLI against our socket
#
# Design notes, because none of these are arbitrary:
#   * The Kobo kernel has CONFIG_TUN=y, so this uses a real tailscale0 interface
#     rather than userspace networking — KOReader then needs no proxy settings.
#   * /dev is devtmpfs and is rebuilt on every boot, so the tun node is created
#     on every start, not once at install time.
#   * The state file and the control socket live on the root filesystem: vfat
#     cannot hold the 0600 the state file needs, and cannot host a unix socket
#     at all. Only the (large) binaries live on /mnt/onboard.
#   * --netfilter-mode=off: the Kobo has no iptables. Safe here because this is
#     a leaf node — not an exit node, not a subnet router.
#   * --accept-dns=false: the Kobo has no DNS manager, so Tailscale would just
#     overwrite /etc/resolv.conf, which WiFi reassociation then overwrites back.
#     MagicDNS is replaced by the /etc/hosts block this script maintains.

set -u

HERE="$(dirname "$(readlink -f "$0")")"
BIN="$HERE/bin"
LOG_DIR="$HERE/log"
LOG="$LOG_DIR/tailscaled.log"

STATE_DIR="/usr/local/tailscale"
STATE="$STATE_DIR/tailscaled.state"
SOCK="/tmp/tailscaled.sock"
PIDFILE="/tmp/tailscaled.pid"

HOSTNAME_TS="kobo-elipsa"
UP_ARGS="--accept-dns=false --accept-routes"
MANAGE_HOSTS=1
HOSTS_FILE="/etc/hosts"
HOSTS_BEGIN="# >>> kobo-tailscale >>>"
HOSTS_END="# <<< kobo-tailscale <<<"
WIFI_WAIT=20
LOG_MAX=1048576

[ -r "$HERE/tailscale.conf" ] && . "$HERE/tailscale.conf"

TS="$BIN/tailscale --socket=$SOCK"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# --- daemon lifecycle --------------------------------------------------------

daemon_pid() {
	# Trust the pidfile only if it still points at a live tailscaled.
	[ -f "$PIDFILE" ] || { pidof tailscaled 2>/dev/null; return; }
	pid="$(cat "$PIDFILE" 2>/dev/null)"
	if [ -n "$pid" ] && [ -d "/proc/$pid" ] &&
	   grep -qs tailscaled "/proc/$pid/comm" 2>/dev/null; then
		printf '%s\n' "$pid"
	else
		rm -f "$PIDFILE"
		pidof tailscaled 2>/dev/null
	fi
}

is_running() { [ -n "$(daemon_pid)" ]; }

ensure_tun() {
	if [ ! -c /dev/net/tun ]; then
		mkdir -p /dev/net
		mknod /dev/net/tun c 10 200 || return 1
		chmod 600 /dev/net/tun
		log "created /dev/net/tun"
	fi
	return 0
}

wait_for_network() {
	i=0
	while [ "$i" -lt "$WIFI_WAIT" ]; do
		if ip route 2>/dev/null | grep -q '^default'; then return 0; fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

rotate_log() {
	mkdir -p "$LOG_DIR"
	if [ -f "$LOG" ]; then
		size="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
		[ "$size" -gt "$LOG_MAX" ] && mv "$LOG" "$LOG.1"
	fi
	: >> "$LOG"
}

start_daemon() {
	rotate_log

	if ! ensure_tun; then
		log "FATAL: could not create /dev/net/tun"
		echo "Tailscale: no /dev/net/tun" >&2
		return 1
	fi

	if ! wait_for_network; then
		# Not fatal: tailscaled copes with the link arriving later.
		log "no default route after ${WIFI_WAIT}s; starting anyway"
	fi

	mkdir -p "$STATE_DIR"
	chmod 700 "$STATE_DIR"

	log "starting tailscaled"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$BIN/tailscaled" \
			--tun=tailscale0 \
			--state="$STATE" \
			--statedir="$STATE_DIR" \
			--socket="$SOCK" \
			--netfilter-mode=off \
			--port=41641 >> "$LOG" 2>&1 &
	else
		nohup "$BIN/tailscaled" \
			--tun=tailscale0 \
			--state="$STATE" \
			--statedir="$STATE_DIR" \
			--socket="$SOCK" \
			--netfilter-mode=off \
			--port=41641 >> "$LOG" 2>&1 &
	fi
	pid=$!
	printf '%s\n' "$pid" > "$PIDFILE"

	# Nickel is aggressive about background work; make sure we are not the
	# first thing the scheduler starves.
	renice -n -5 -p "$pid" >/dev/null 2>&1

	# Wait for the control socket rather than guessing with a fixed sleep.
	i=0
	while [ "$i" -lt 15 ]; do
		[ -S "$SOCK" ] && return 0
		[ -d "/proc/$pid" ] || { log "tailscaled exited during startup"; return 1; }
		i=$((i + 1))
		sleep 1
	done
	log "control socket did not appear"
	return 1
}

# --- /etc/hosts, standing in for MagicDNS ------------------------------------

hosts_strip() {
	[ -f "$HOSTS_FILE" ] || return 0
	sed "/^$HOSTS_BEGIN\$/,/^$HOSTS_END\$/d" "$HOSTS_FILE" > /tmp/hosts.$$ &&
		cat /tmp/hosts.$$ > "$HOSTS_FILE"
	rm -f /tmp/hosts.$$
}

hosts_sync() {
	[ "$MANAGE_HOSTS" = "1" ] || return 0

	# `tailscale status` lists one peer per line: <100.x.y.z> <host> <user> ...
	# Self is the first line. Short name only — no MagicDNS suffix to guess at.
	peers="$("$BIN"/tailscale --socket="$SOCK" status 2>/dev/null |
		awk '$1 ~ /^100\./ && $2 != "" { print $1 "\t" $2 }')"
	[ -n "$peers" ] || return 0

	hosts_strip
	{
		printf '%s\n' "$HOSTS_BEGIN"
		printf '%s\n' "$peers"
		printf '%s\n' "$HOSTS_END"
	} >> "$HOSTS_FILE"
	log "synced $(printf '%s\n' "$peers" | wc -l) tailnet hosts into $HOSTS_FILE"
}

# --- commands ----------------------------------------------------------------

cmd_start() {
	if is_running; then
		log "already running"
	else
		start_daemon || return 1
	fi

	if [ ! -f "$STATE" ]; then
		log "no state file: this device has never logged in"
		echo "Tailscale: needs login (run 'tailscale-ctl.sh login' over SSH)"
		return 1
	fi

	# Idempotent, and needed because `stop` leaves WantRunning=false.
	$TS up --hostname="$HOSTNAME_TS" $UP_ARGS --timeout=30s >> "$LOG" 2>&1 || {
		log "tailscale up failed; see log"
		echo "Tailscale: up failed"
		return 1
	}

	hosts_sync
	cmd_status
}

cmd_stop() {
	if is_running; then
		$TS down >> "$LOG" 2>&1
		pid="$(daemon_pid)"
		[ -n "$pid" ] && kill "$pid" 2>/dev/null
		i=0
		while [ "$i" -lt 10 ] && [ -n "$(daemon_pid)" ]; do
			i=$((i + 1)); sleep 1
		done
		pid="$(daemon_pid)"
		[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
		rm -f "$PIDFILE" "$SOCK"
		log "stopped"
	fi
	hosts_strip
	echo "Tailscale: stopped"
}

cmd_status() {
	if ! is_running; then
		echo "Tailscale: stopped"
		return 1
	fi
	ip4="$($TS ip -4 2>/dev/null | head -n1)"
	if [ -z "$ip4" ]; then
		echo "Tailscale: starting…"
		return 0
	fi
	# Count 100.x lines and drop one for ourselves.
	peers="$($TS status 2>/dev/null | awk '$1 ~ /^100\./' | wc -l)"
	[ "$peers" -gt 0 ] && peers=$((peers - 1))
	echo "Tailscale: up · $ip4 · $peers peers"
}

cmd_login() {
	is_running || start_daemon || return 1
	echo "Opening a login URL — visit it in a browser, then this returns."
	$TS up --hostname="$HOSTNAME_TS" $UP_ARGS "$@" || return 1
	hosts_sync
	cmd_status
}

case "${1:-status}" in
	start)   cmd_start ;;
	stop)    cmd_stop ;;
	restart) cmd_stop; cmd_start ;;
	toggle)  if is_running; then cmd_stop; else cmd_start; fi ;;
	status)  cmd_status ;;
	login)   shift; cmd_login "$@" ;;
	logs)    tail -n "${2:-50}" "$LOG" ;;
	# Re-read the peer list into /etc/hosts without restarting -- useful after
	# a new machine joins the tailnet.
	hosts)
		case "${2:-sync}" in
			sync)  hosts_sync ;;
			clear) hosts_strip ;;
			*)     echo "usage: $0 hosts {sync|clear}" >&2; exit 2 ;;
		esac
		;;
	ts)      shift; $TS "$@" ;;
	*)
		echo "usage: $0 {start|stop|restart|toggle|status|login|logs|hosts|ts <args>}" >&2
		exit 2
		;;
esac
