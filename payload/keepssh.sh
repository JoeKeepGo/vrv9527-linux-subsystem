#!/bin/sh
# VRV9527 SSH keepalive
# - kills sshd_delay_close (the factory "SSH auto-closes after 24h" watchdog)
# - restarts sshd directly if it is not running
#
# Install:  cp keepssh.sh /data/keepssh.sh && chmod +x /data/keepssh.sh
# Schedule: see README.md — the Scheduler Time-field cron injection trick
#           (ARC_SYS_SCHEDULER_0_Time="*/5 * * * *") rebuilds a valid cron
#           entry for this script at every boot.

killall sshd_delay_close 2>/dev/null
if ! pidof sshd >/dev/null 2>&1; then
  echo "$(date) sshd down, direct start" >> /data/keepssh.log
  /usr/sbin/sshd -p 22 2>>/data/keepssh.log
fi
exit 0
