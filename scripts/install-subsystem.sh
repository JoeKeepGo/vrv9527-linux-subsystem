#!/usr/bin/env bash
# install-subsystem.sh — one-click Alpine Linux subsystem (chroot) installer
# for the Spark Smart Modem 3 / Arcadyan VRV9527.
#
# Run from a computer on the same LAN as the router:
#
#   VRV_ROOT_PW='Spark@Modem3' ./install-subsystem.sh
#
# Optional env vars:
#   VRV_HOST        router IP            (default 192.168.1.254)
#   ALPINE_MIRROR   Alpine releases dir  (default dl-cdn latest-stable aarch64)
#   SUBSYS_DIR      install root on /data (default /data/alpine)
#   SUBSYS_IP       dedicated subsystem IP (default 192.168.2.253; its own
#                   /24 so L2 relays/proxy-ARP between you and the router
#                   can't break it — clients reach it via the router's
#                   normal address as gateway)
#
# What it does (all reversible — see README):
#   1. downloads the latest Alpine aarch64 minirootfs on YOUR computer
#      (the stock firmware's curl/wget are broken for HTTPS — a broken
#      OpenSSL — so the router cannot download it by itself)
#   2. pushes it to the router over SSH (raw stream through stdin; the stock
#      firmware has no scp/sftp, and its busybox `base64 -d` is broken, so
#      binary data must go through `cat` unencoded)
#   3. unpacks it to $SUBSYS_DIR, writes DNS config
#   4. installs /data/enter-alpine.sh (bind-mounts + chroot entry point)
#   5. hooks boot-time recovery into /data/keepssh.sh: bind-mounts, a
#      dedicated subsystem IP on br0, and a one-shot autostart hook
#      ($SUBSYS_DIR/etc/subsystem.autostart) — all idempotent
#
# Requires on your computer: bash, curl, sshpass, ssh.
set -euo pipefail

VRV_HOST="${VRV_HOST:-192.168.1.254}"
VRV_ROOT_PW="${VRV_ROOT_PW:?set VRV_ROOT_PW to the router root SSH password}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64}"
SUBSYS_DIR="${SUBSYS_DIR:-/data/alpine}"
SUBSYS_IP="${SUBSYS_IP:-192.168.2.253}"

command -v sshpass >/dev/null || { echo "need sshpass (macOS: brew install hudochenkov/sshpass/sshpass; Debian/Ubuntu: apt install sshpass)"; exit 1; }
command -v curl    >/dev/null || { echo "need curl"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SSH="sshpass -p $VRV_ROOT_PW ssh $SSH_OPTS root@$VRV_HOST"

echo "[1/5] locating latest Alpine aarch64 minirootfs..."
FILE=$(curl -fsSL "$ALPINE_MIRROR/" | grep -oE 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' | sort -V | tail -1)
[ -n "$FILE" ] || { echo "could not find minirootfs tarball at $ALPINE_MIRROR"; exit 1; }
echo "      -> $FILE"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "[2/5] downloading..."
curl -fsSL -o "$TMP/$FILE" "$ALPINE_MIRROR/$FILE"

echo "[3/5] pushing to router (raw stream over ssh, this takes a minute)..."
$SSH "cat > /data/$FILE" < "$TMP/$FILE"
$SSH "ls -la /data/$FILE"

echo "[4/5] unpacking and setting up..."
$SSH "SUBSYS_DIR='$SUBSYS_DIR' FILE='$FILE' sh -s" <<'REMOTE'
set -e
R="$SUBSYS_DIR"
mkdir -p "$R"
tar xzf "/data/$FILE" -C "$R"
rm -f "/data/$FILE"

# DNS: the router itself is the LAN resolver
if [ -f /etc/resolv.conf ]; then
  cp /etc/resolv.conf "$R/etc/resolv.conf"
else
  echo "nameserver 192.168.1.254" > "$R/etc/resolv.conf"
fi

cat > /data/enter-alpine.sh <<EOS
#!/bin/sh
# Enter the Alpine subsystem. Bind-mounts are idempotent.
R=$SUBSYS_DIR
for d in proc sys dev dev/pts; do
  mkdir -p "\$R/\$d"
  grep -q " \$R/\$d " /proc/mounts || mount --bind "/\$d" "\$R/\$d"
done
exec chroot "\$R" /bin/sh -l
EOS
chmod +x /data/enter-alpine.sh

# autostart template: runs once per boot inside the chroot
cat > $SUBSYS_DIR/etc/subsystem.autostart <<EOS
#!/bin/sh
# Runs once per router boot, inside the Alpine chroot (as root), after
# bind-mounts are restored. Started by /data/keepssh.sh.
# Services can bind the dedicated IP $SUBSYS_IP — LAN clients reach it
# via the router's address as gateway, so L2 relays / proxy-ARP boxes
# between client and router can't break it (a secondary IP on the
# router's own subnet would not survive such relays).
#
# Examples (apk add first):
#   /usr/sbin/crond
#   /usr/sbin/dropbear -p $SUBSYS_IP:22 -R
EOS
chmod +x $SUBSYS_DIR/etc/subsystem.autostart

# hook into the SSH keepalive so everything comes back after reboot.
# keepssh.sh ends with "exit 0" — strip it or appended hooks never run.
if [ -f /data/keepssh.sh ]; then
sed -i '/^exit 0$/d' /data/keepssh.sh
if ! grep -q "alpine subsystem" /data/keepssh.sh; then
cat >> /data/keepssh.sh <<EOS

# alpine subsystem bind mounts
if [ -d $SUBSYS_DIR ]; then
  for d in proc sys dev dev/pts; do
    mkdir -p "$SUBSYS_DIR/\$d"
    grep -q " $SUBSYS_DIR/\$d " /proc/mounts || mount --bind "/\$d" "$SUBSYS_DIR/\$d" 2>/dev/null
  done
fi

# alpine subsystem: dedicated IP on its own /24
if command -v ip >/dev/null 2>&1 && ! ip addr show br0 | grep -q "$SUBSYS_IP"; then
  ip addr add $SUBSYS_IP/24 dev br0 2>/dev/null
fi

# alpine subsystem: run user autostart once per boot (/tmp is cleared on reboot)
if [ -x $SUBSYS_DIR/etc/subsystem.autostart ] && [ ! -f /tmp/alpine_started ]; then
  touch /tmp/alpine_started
  echo "\$(date) running alpine autostart" >> /data/keepssh.log
  chroot $SUBSYS_DIR /bin/sh -l /etc/subsystem.autostart >> /data/keepssh.log 2>&1 &
fi
EOS
fi
fi
REMOTE

# bring up the dedicated IP right away (the hook redoes it after reboots)
$SSH "ip addr show br0 | grep -q '$SUBSYS_IP' || ip addr add $SUBSYS_IP/24 dev br0"

echo "[5/5] smoke test..."
$SSH "grep -q ' $SUBSYS_DIR/proc ' /proc/mounts || mount --bind /proc $SUBSYS_DIR/proc; chroot $SUBSYS_DIR /bin/sh -c 'cat /etc/alpine-release'"

echo ""
echo "Done. Enter the subsystem with:"
echo "  ssh root@$VRV_HOST /data/enter-alpine.sh"
echo "Inside, 'apk update && apk add <pkg>' works (Alpine brings its own"
echo "working TLS stack — the stock firmware's broken one is bypassed)."
echo ""
echo "Autostart: put commands in $SUBSYS_DIR/etc/subsystem.autostart —"
echo "they run once per router boot inside the chroot."
echo "Dedicated IP: services can bind $SUBSYS_IP (own /24, reached via the"
echo "router as gateway; survives L2 relays that break proxy-ARP)."
echo "Uninstall: ssh root@$VRV_HOST 'rm -rf $SUBSYS_DIR /data/enter-alpine.sh'"
