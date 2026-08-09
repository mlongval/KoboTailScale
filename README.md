# Kobo TailScale

![platform](https://img.shields.io/badge/platform-Kobo%20eReader-2f3437?style=flat-square)
![device](https://img.shields.io/badge/tested%20on-Elipsa%20v1-6b4fbb?style=flat-square)
![NickelMenu](https://img.shields.io/badge/NickelMenu-toggle-3b7dd8?style=flat-square)
![mode](https://img.shields.io/badge/networking-kernel%20TUN-2e8b57?style=flat-square)
![tailscale](https://img.shields.io/badge/tailscale-1.102.2-c05621?style=flat-square)

Put a Kobo on your tailnet, so KOReader can reach tailnet services — calibre-web,
an OPDS catalogue, ReadItEventually — from any network, not just the one at home.
A **Tailscale** entry on the home screen turns it on and off.

Built for a **Kobo Elipsa (v1)**. Nothing here is Elipsa-specific beyond the
preflight checks, so it should work on any Kobo whose kernel has TUN.

## Why this is simpler than it looks

Most e-reader Tailscale write-ups fall back to userspace networking, where
tailscaled is only a SOCKS5 proxy and every app has to be told about it. That
isn't necessary on a Kobo:

- **The Kobo kernel has `CONFIG_TUN=y`** ([confirmed for the Elipsa and Sage by
  NiLuJe](https://www.mobileread.com/forums/showthread.php?t=342174)), so this
  uses a real `tailscale0` interface. KOReader needs no proxy settings; it just
  works.
- **`tailscale` and `tailscaled` are static, CGO-free Go binaries.** The glibc
  pain in the older Kobo Sage write-up came from needing `iptables`, which this
  skips with `--netfilter-mode=off` — legitimate, because the Kobo here is a
  leaf node, not an exit node or subnet router.

## Installing

```sh
./tools/fetch-tailscale.sh --latest   # download + verify the ARM binaries
./install.sh kobo                     # over SSH; "kobo" is any ssh target
./install.sh /media/you/KOBO          # or to a USB-mounted device
```

The SSH form runs a preflight first — architecture, TUN support, free space —
and refuses rather than copying 65 MB onto a device that can't run it. Add
`--no-nickelmenu` to skip the home-screen entry.

Then log in once, from your computer:

```sh
ssh kobo /mnt/onboard/.adds/tailscale/tailscale-ctl.sh login
```

It prints a URL; open it in a browser and approve the device. That's the only
interactive step — after it, the state is stored and the toggle is enough.

To skip the browser entirely, generate an auth key in the Tailscale admin
console and pass it at install time:

```sh
./install.sh kobo --authkey tskey-auth-...
```

## Using it

On the home screen:

| Entry | What it does |
|---|---|
| **Tailscale** | Toggles the daemon. Starting takes a few seconds. |
| **Tailscale status** | Toasts `Tailscale: up · 100.x.y.z · 7 peers`. |

Over SSH, `tailscale-ctl.sh` takes `start`, `stop`, `restart`, `toggle`,
`status`, `login`, `logs`, `hosts sync|clear`, and `ts <args>` for the raw
Tailscale CLI (`tailscale-ctl.sh ts ping ubuntu-s1`).

### In KOReader

Once Tailscale is up, tailnet machines are reachable **by name** — add an OPDS
catalogue at `http://ubuntu-s1:8083/opds` and it works from anywhere. Names work
because of the `/etc/hosts` trick below, so use the short hostname exactly as it
appears in `tailscale status`.

Note that KOReader manages WiFi itself. If KOReader drops the WiFi, Tailscale
goes with it and reconnects when the link returns; the daemon survives.

## How it works

```
/mnt/onboard/.adds/tailscale/bin/{tailscale,tailscaled}   the binaries (65 MB)
/mnt/onboard/.adds/tailscale/tailscale-ctl.sh             all the logic
/mnt/onboard/.adds/tailscale/tailscale.conf               your settings
/mnt/onboard/.adds/tailscale/log/tailscaled.log           rotated at 1 MB
/usr/local/tailscale/tailscaled.state                     on the root filesystem
/tmp/tailscaled.sock                                      on the root filesystem
```

The split is deliberate. The binaries are far too big for the ~300 MB root
filesystem, so they live on the user partition. But that partition is vfat,
which **cannot hold the 0600 the state file needs and cannot host a unix socket
at all** — so the state file (a few KB) and the control socket go on the root
filesystem. Putting either on `/mnt/onboard` breaks tailscaled.

Three more things the control script handles:

- **`/dev/net/tun` is created on every start.** `/dev` is devtmpfs and is rebuilt
  at each boot, so this can't be a one-time install step.
- **DNS is left alone.** The Kobo has no DNS manager, so Tailscale would simply
  overwrite `/etc/resolv.conf` — which WiFi reassociation then overwrites back.
  So `--accept-dns=false`, and MagicDNS is replaced by a marker-delimited block
  of tailnet peers written into `/etc/hosts` on start and removed on stop. That
  block is rewritten idempotently, never appended to.
- **The daemon is detached** with `setsid` and given a small `renice` boost, so
  Nickel doesn't reap or starve it.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Tailscale: no /dev/net/tun` | `mknod` failed — not running as root. |
| `Tailscale: needs login` | Never authenticated; run `tailscale-ctl.sh login`. |
| Toggle does nothing | `tailscale-ctl.sh logs` — the daemon log is the truth. |
| Peers ping but names don't resolve | `tailscale-ctl.sh hosts sync` after a new machine joins the tailnet. |
| Works at home, not on cellular | Genuine connectivity issue, not this script — check the peer is online. |

Uninstall by deleting `/mnt/onboard/.adds/tailscale`, `/mnt/onboard/.adds/nm/tailscale`
and `/usr/local/tailscale`, after running `tailscale-ctl.sh stop` so the
`/etc/hosts` block is removed.

## Out of scope

Using the Kobo as an **exit-node client** (routing all its traffic through, say,
the Mullvad gateway) is not supported here: that needs working `iptables` on the
device, which stock Kobo firmware does not have.

## Credits

Prior art that saved a lot of guessing:
[videah/kobo-tailscale](https://github.com/videah/kobo-tailscale),
[Dylan Staley's Kobo Sage write-up](https://dstaley.com/posts/tailscale-on-kobo-sage/),
and NiLuJe's kernel-config answer on
[MobileRead](https://www.mobileread.com/forums/showthread.php?t=342174).
