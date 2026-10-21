#!/bin/bash
# Runs every minute from cron on the gateway host:
#   * * * * * /root/vpn-watchdog.sh
# Pings the WireGuard hub and restarts the tunnel if it does not answer.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HUB=10.50.0.1          # hub address inside the tunnel
LOG=/var/log/vpn-watchdog.log

if ! ping -I wg0 -c 3 -W 5 "$HUB" > /dev/null 2>&1; then
    echo "$(date): VPN down (ping failed). Restarting service..." >> "$LOG"
    systemctl restart wg-quick@wg0
    sleep 10
    if ping -I wg0 -c 1 -W 2 "$HUB" > /dev/null 2>&1; then
        echo "$(date): Recovered." >> "$LOG"
    else
        echo "$(date): Still down." >> "$LOG"
    fi
fi
