# VRV9527 root SSH — full walkthrough

Device: Spark Smart Modem 3 (Arcadyan VRV9527, firmware v1.00.08_build02, aarch64)
Situation: ISP contract ended, the unit is owned outright, goal is full control.

This documents the entire exploration, including every dead end (there were
many more dead ends than working paths), so you don't have to repeat them.

## 0. Attack surface

Full-port nmap results:

| Port | Service | Notes |
|---|---|---|
| 53 | DNS | Akamai CacheServe |
| 80/443 | Web admin | Arcadyan custom |
| 8110 | halcap | Proprietary binary protocol, not explored |
| 43597 | MiniUPnP | |
| 55661 | lighttpd 1.4.53 | JSON API, unknown paths, ~16 guesses all 404 |

22 (SSH), 23 (Telnet), 7547 (TR-069 server) all closed.

## 1. Web login crypto (replicated — tools/vrv.py)

`login.htm` embeds a spacer GIF whose data-URI base64 carries extra data
after the standard 78-char GIF header: `key[32] + iv[16] + httoken[48]`.
The submitted username/password values are AES-256-CBC(key, iv) of the
ASCII bytes of `SHA512(MD5(x))` hex, nopad, percent-encoded as `%xx`.
POST `/login.cgi` with fields in the order `httoken,pws,usr` and a
**mandatory `Referer: /login.htm`**.

Gotchas: single-session firmware (re-login → err=2, hit logout.cgi first);
repeated wrong passwords → ~15 s lockout (err=7); non-login pages use a
different GIF data layout, so the httoken extraction differs.

## 2. Config backup crypto (works)

- Export: `/cgi/cgi_sys_bk.js?_tn=<token>&_t=<ms>` generates the file,
  `/tmp/SmartModem_backup.cfg` downloads it
- Decrypt/encrypt: the VRV9517 `arcadyan_util.py` works as-is
  (key = factory main WiFi password)
- Main config `.glbcfg`: 7000+ lines of `ARC_*` key=value pairs

Restore took many attempts to figure out:

- A **timed-out response is normal** — the file was applied (verify by
  re-downloading the backup and checking a marker value)
- Instant `G_err=-8` = bad repack: uid/gid must be 0, original member
  order, `.glbcfg` mode 0666
- **Sanitizer**: keys like `ARC_SSHD_ENABLE`, `ARC_SSHD_AUTO_DISABLE`,
  `ARC_SYS_SCHEDULER_*` are forced back to factory values — the restore
  path can never enable SSH. Drop that idea early.

## 3. Dead ends (all experimentally verified)

- **Telnet**: `ARC_TELNETD_ENABLE=1` survives reboot, but port 23 never
  opens — the daemon is compiled out of production firmware
- **Scheduler command injection (via restore)**: Command sanitized back
  to `reboot`
- **Tar slip in the config tgz**: `../`, absolute paths — all filtered
- **Service config injection**: editing the tarball's samba config does
  nothing; runtime configs are regenerated from `.glbcfg`
- **DDNS/NTP semicolon injection**: rejected server-side
- **Stock firmware reversing**: v1.00.06 image downloadable from the ISP
  but fully encrypted, binwalk finds zero signatures
- **SMB symlink escape**: ext4 USB stick + debugfs-planted `escape -> /`;
  the router mounts it and a marker file is readable, but following the
  link gives Permission denied (smbd wide links=no)
- **FTP chroot escape**: chrooted at /tmp/usb, no way out

## 4. TR-069 (the breakthrough)

CWMP is enabled in `.glbcfg` (`ARC_TR69_EnableCWMP=1`), pointing at the
ISP's ACS. Relevant keys:

```
ARC_TR69_URL=http://<ISP-ACS>:7547/...
ARC_TR69_Username=<OUI>-<ProductClass>-<Serial>   # also the ConnectionRequest digest creds
ARC_TR69_Password=...
ARC_TR69_ConnectionRequestURL=http://<WAN-IP>:8081/ConnectionRequest
```

Steps:

1. Run a minimal ACS (tools/acs.py), set `ARC_TR69_URL` to it (this key is
   NOT sanitized), restore the config
2. The router Informs immediately (VALUE CHANGE); from then on,
   ConnectionRequest (digest auth, WAN IP reachable via NAT hairpin)
   forces sessions on demand
3. Enumerate with `GetParameterNames Device.` layer by layer; under
   `Device.X_ARC_COM.` there is **`SSHEnable`, Writable=1**
4. `SetParameterValues SSHEnable=1` (Status=0, applied instantly) →
   port 22 opens, `root / Spark@Modem3`, uid=0

CWMP protocol notes: Inform → InformResponse; the ACS may only send a
request in reply to an empty CPE POST; echo the `cwmp:ID` header; reuse
the device's self-reported namespace (urn:dslforum-org:cwmp-1-2).

## 5. Persistence (the twistiest part)

After SSH opens, three problems surface:

1. `sshd_delay_close -s restart -t 24:00:00`: after 24 hours it runs
   `mngcli set ARC_SSHD_ENABLE=0; mngcli commit`
2. sshd does NOT start at boot even when flash has `ARC_SSHD_ENABLE=1`
   (observed over 10 minutes); it is mng-event-driven, only started by a
   CWMP/UI action
3. Every enable (CWMP or mngcli) resets `ARC_SSHD_AUTO_DISABLE=1` and
   respawns the watchdog — so just flipping the config key is useless

Persistence primitives explored:

- `/data`: persistent ext4 rw partition ✓ can host the script
- `/etc/crond/root`: tmpfs, rebuilt at boot; busybox crond itself works
  (standard `* * * * *` lines execute fine)
- Scheduler → crontab: config is persistent and the entry is rebuilt at
  boot, BUT it is written as `$Time $Command` verbatim, so `Time=06:30`
  produces an invalid line (busybox crond chokes on it, even getting
  stuck in a restart loop)
- **Breakthrough**: since it's verbatim, set `ARC_SYS_SCHEDULER_0_Time`
  to `*/5 * * * *` — the concatenation IS a valid cron line. mngcli does
  no format validation.

Final setup:

```
mngcli set "ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh"
mngcli set "ARC_SYS_SCHEDULER_0_Time=*/5 * * * *"
mngcli set ARC_SYS_SCHEDULER_0_Enable=1
mngcli commit
```

`/data/keepssh.sh`: kill sshd_delay_close; if sshd is down, start it
directly with `/usr/sbin/sshd -p 22` (direct start does NOT spawn the
watchdog, and password login works with it).

Verified: cron fires every 5 min ✓; sshd revived within 5 min of being
killed ✓; SSH up by itself after reboot ✓.

## 6. Miscellaneous notes

- No `setsid`/`nohup` in busybox here, and `killall sshd` kills your own
  session — use cron as the detacher for suicide-and-revive tests
- `sed` on `/etc/config/.glbcfg` is useless: `mng_cli commit` writes the
  mng daemon's in-memory config and clobbers your edit. Always use
  `mngcli set` + `mngcli commit`
- SSH host keys are regenerated at every boot (/etc/ssh is ro squashfs
  plus a tmpfs staging area) — set `UserKnownHostsFile=/dev/null` on the
  client
- After changing `ARC_TR69_URL`, the ISP ACS is locked out — that's the
  point. The periodic inform interval can be shortened to 3600 s via CWMP
  for faster self-healing
