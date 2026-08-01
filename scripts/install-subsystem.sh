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
#   SUBSYS_IP       dedicated subsystem IP (default 192.168.3.1; its own
#                   /24 so L2 relays/proxy-ARP between you and the router
#                   can't break it — clients reach it via the router's
#                   normal address as gateway. NOT 192.168.2.x: that /24
#                   is the router's guest-wifi bridge br1)
#   VRV_NEW_ROOT_PW if set, the router root password (and the subsystem
#                   dropbear password) is changed to this and pinned in
#                   the keepalive hook. If unset, you'll be prompted;
#                   empty input keeps the current password.
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
#   6. installs dropbear inside the chroot for direct SSH access on
#      $SUBSYS_IP:2222 (port 22 is taken by the host sshd, which binds
#      0.0.0.0). Root password is set to $VRV_ROOT_PW.
#   7. security hardening: the firmware ACCEPTs SSH from the WAN side
#      (ppp0) — on a public IP that is a wide-open door. The installer
#      inserts a DROP rule (now + keepalive hook) and optionally changes
#      the root password (pinned in the keepalive hook, since /etc is
#      tmpfs and rebuilt on every boot).
#
# Requires on your computer: bash, curl, sshpass, ssh.
set -euo pipefail

VRV_HOST="${VRV_HOST:-192.168.1.254}"
VRV_ROOT_PW="${VRV_ROOT_PW:?set VRV_ROOT_PW to the router root SSH password}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64}"
SUBSYS_DIR="${SUBSYS_DIR:-/data/alpine}"
SUBSYS_IP="${SUBSYS_IP:-192.168.3.1}"

command -v sshpass >/dev/null || { echo "need sshpass (macOS: brew install hudochenkov/sshpass/sshpass; Debian/Ubuntu: apt install sshpass)"; exit 1; }
command -v curl    >/dev/null || { echo "need curl"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SSH="sshpass -p $VRV_ROOT_PW ssh $SSH_OPTS root@$VRV_HOST"

echo "[1/6] locating latest Alpine aarch64 minirootfs..."
FILE=$(curl -fsSL "$ALPINE_MIRROR/" | grep -oE 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' | sort -V | tail -1)
[ -n "$FILE" ] || { echo "could not find minirootfs tarball at $ALPINE_MIRROR"; exit 1; }
echo "      -> $FILE"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "[2/6] downloading..."
curl -fsSL -o "$TMP/$FILE" "$ALPINE_MIRROR/$FILE"

echo "[3/6] pushing to router (raw stream over ssh, this takes a minute)..."
$SSH "cat > /data/$FILE" < "$TMP/$FILE"
$SSH "ls -la /data/$FILE"

echo "[4/6] security hardening (WAN SSH lockdown + root password)..."
# keepssh.sh ends with "exit 0" on a fresh setup — strip it before
# appending hooks, or anything we append never executes
$SSH "sed -i '/^exit 0$/d' /data/keepssh.sh"

# the firmware ACCEPTs SSH from ppp0 (WAN). Kill that, now and after
# every boot/firewall rebuild (hook is idempotent).
$SSH "iptables -C INPUT -i ppp0 -p tcp --dport 22 -j DROP 2>/dev/null || iptables -I INPUT 1 -i ppp0 -p tcp --dport 22 -j DROP"
$SSH "grep -q 'WAN lockdown' /data/keepssh.sh || cat >> /data/keepssh.sh" <<'WANHOOK'

# WAN lockdown: never expose SSH on the public interface (firmware adds
# an ACCEPT ppp0:22 rule; our DROP must sit ahead of it)
iptables -C INPUT -i ppp0 -p tcp --dport 22 -j DROP 2>/dev/null || iptables -I INPUT 1 -i ppp0 -p tcp --dport 22 -j DROP
WANHOOK

NEW_PW="${VRV_NEW_ROOT_PW:-}"
if [ -z "$NEW_PW" ] && [ -t 0 ]; then
  read -r -s -p "New router root password (empty = keep current): " NEW_PW; echo
fi
if [ -n "$NEW_PW" ]; then
  command -v openssl >/dev/null || { echo "need openssl to hash the password"; exit 1; }
  HASH=$(openssl passwd -1 "$NEW_PW")
  # /etc is tmpfs: change takes effect now but is lost on reboot, so pin
  # the hash in the keepalive hook (it re-applies every 5 minutes)
  $SSH "sed -i 's|^root:[^:]*:|root:$HASH:|' /etc/passwd"
  $SSH "ROOTHASH='$HASH' sh -s" <<'PWHOOK'
grep -q "root password lock" /data/keepssh.sh || cat >> /data/keepssh.sh <<EOF

# root password lock: /etc is tmpfs (rebuilt on boot & ssh re-enable),
# pin the custom hash back every patrol
ROOTHASH='$ROOTHASH'
grep -q "^root:\$ROOTHASH:" /etc/passwd 2>/dev/null || sed -i "s|^root:[^:]*:|root:\$ROOTHASH:|" /etc/passwd
EOF
PWHOOK
  VRV_ROOT_PW="$NEW_PW"
  SSH="sshpass -p $VRV_ROOT_PW ssh $SSH_OPTS root@$VRV_HOST"
  echo "      root password changed and pinned in the keepalive hook"
else
  echo "      keeping current root password"
  echo "      WARNING: if it is still the factory default, change it — WAN SSH"
  echo "      is firewalled off now, but default creds on the LAN are still risky"
fi

echo "[5/6] unpacking and setting up..."
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
# Direct SSH into the subsystem (port 2222; 22 is taken by the host
# sshd which binds 0.0.0.0):
/usr/sbin/dropbear -p $SUBSYS_IP:2222 -R
#
# More examples (apk add first):
#   /usr/sbin/crond
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

# dropbear for direct SSH into the subsystem on $SUBSYS_IP:2222
# (root password = the router root password)
$SSH "chroot $SUBSYS_DIR /sbin/apk add dropbear >/dev/null 2>&1 || true"
echo "root:$VRV_ROOT_PW" | $SSH "chroot $SUBSYS_DIR /usr/sbin/chpasswd"
$SSH "pidof dropbear >/dev/null 2>&1 || chroot $SUBSYS_DIR /usr/sbin/dropbear -p $SUBSYS_IP:2222 -R"

echo "[6/6] smoke test..."
$SSH "grep -q ' $SUBSYS_DIR/proc ' /proc/mounts || mount --bind /proc $SUBSYS_DIR/proc; chroot $SUBSYS_DIR /bin/sh -c 'cat /etc/alpine-release'"

echo ""
echo "Done. Direct SSH into the subsystem:"
echo "  ssh -p 2222 root@$SUBSYS_IP      (password: same as router root)"
echo "Or hop via the router:"
echo "  ssh root@$VRV_HOST /data/enter-alpine.sh"
echo "Inside, 'apk update && apk add <pkg>' works (Alpine brings its own"
echo "working TLS stack — the stock firmware's broken one is bypassed)."
echo ""
echo "Autostart: put commands in $SUBSYS_DIR/etc/subsystem.autostart —"
echo "they run once per router boot inside the chroot (dropbear is"
echo "already in there)."
echo "Dedicated IP: services can bind $SUBSYS_IP (own /24, reached via the"
echo "router as gateway; survives L2 relays that break proxy-ARP)."
echo "Uninstall: ssh root@$VRV_HOST 'rm -rf $SUBSYS_DIR /data/enter-alpine.sh'"
