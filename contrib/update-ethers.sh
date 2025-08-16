#!/usr/bin/env bash
#
# update-ethers.sh
#
#  - Scans local ARP (IPv4) and Neighbor (IPv6) caches
#  - Maintains /etc/ethers with "last-seen" epoch timestamps in comments
#  - Removes entries not seen for EXPIRE_DAYS
#  - Preserves manual entries (no # last-seen:)
#  - For a hostname that exists both manually and via auto-discovery,
#    prints the manual entry and then prints the auto entry as a fully
#    commented line (so the manual entry takes precedence).
#  - Dynamically adjusts ARP/neighbor cache timeout based on the largest
#    last-seen timestamp (+5min margin, rounded up to 15min, capped at 24h)
#
#  This script is part of bar/please. Its purpose is to maintain a persistent ethers database
#  so that for example 'wakeonlan' can be used with hostnames.
#
#  This should be placed into /etc/cron.hourly/ or otherwise arranged to be run at regular
#  intervals ranging from a few minutes to less than a day.

############################
# CONFIGURATION
ETHERS_FILE="/etc/ethers"
EXPIRE_DAYS=30
HOSTNAME_WIDTH=37       # width reserved for the hostname column (for alignment)
############################

export LC_ALL=C
current_epoch=$(date +%s)

# ---------------------------------------------------------------------
# Ensure ethers file exists
# ---------------------------------------------------------------------
[ -f "$ETHERS_FILE" ] || touch "$ETHERS_FILE"

# ---------------------------------------------------------------------
# Read existing ethers file
#   → manual entries → MANUAL_HOSTS[host]
#   → auto entries   → AUTO_HOSTS[host]=mac and AUTO_SEEN[host]
#   → track largest last-seen timestamp => last_run
# ---------------------------------------------------------------------
declare -A MANUAL_HOSTS
declare -A AUTO_HOSTS
declare -A AUTO_SEEN

last_run=0

while read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if echo "$line" | grep -q '# last-seen:'; then
        mac=$(echo "$line" | awk '{print $1}')
        host=$(echo "$line" | awk '{print $2}')
        epoch=$(echo "$line" | sed -n 's/.*# last-seen:[[:space:]]*\([0-9]\+\).*/\1/p')
        AUTO_HOSTS["$host"]="$mac"
        AUTO_SEEN["$host"]="$epoch"
        (( epoch > last_run )) && last_run=$epoch
    else
        host=$(echo "$line" | awk '{print $2}')
        MANUAL_HOSTS["$host"]="$line"
    fi
done < "$ETHERS_FILE"

# ---------------------------------------------------------------------
# Discover new IPv4 ARP entries
# ---------------------------------------------------------------------
while read -r host mac _iface; do
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || continue
    AUTO_HOSTS["$host"]="$mac"
    AUTO_SEEN["$host"]="$current_epoch"
done < <(arp | awk '$3 ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ {print $1, $3, $NF}')

# ---------------------------------------------------------------------
# Discover new IPv6 Neighbour entries
# ---------------------------------------------------------------------
while read -r line; do
    [[ "$line" =~ FAILED|INCOMPLETE ]] && continue
    ip=$(echo "$line" | awk '{print $1}')
    mac=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || continue
    host="$ip"
    AUTO_HOSTS["$host"]="$mac"
    AUTO_SEEN["$host"]="$current_epoch"
done < <(ip -6 neigh show)

# ---------------------------------------------------------------------
# Compute ARP/neighbor GC interval
# ---------------------------------------------------------------------
delta=$(( current_epoch - last_run ))
delta_plus_margin=$(( delta + 300 ))
gc_interval=$(( ((delta_plus_margin + 899)/900) * 900 ))
(( gc_interval > 86400 )) && gc_interval=86400

sysctl -w net.ipv4.neigh.default.base_reachable_time_ms=$((gc_interval * 1000)) >/dev/null
sysctl -w net.ipv4.neigh.default.gc_stale_time=$gc_interval >/dev/null
sysctl -w net.ipv6.neigh.default.base_reachable_time_ms=$((gc_interval * 1000)) >/dev/null
sysctl -w net.ipv6.neigh.default.gc_stale_time=$gc_interval >/dev/null

# ---------------------------------------------------------------------
# Rebuild ethers file
# ---------------------------------------------------------------------
expire_seconds=$(( EXPIRE_DAYS * 86400 ))
tmpfile=$(mktemp)

# Manual entries first (and print commented auto entries if conflicting)
for host in "${!MANUAL_HOSTS[@]}"; do
    echo "${MANUAL_HOSTS[$host]}" >> "$tmpfile"
    if [[ -n "${AUTO_HOSTS[$host]}" ]]; then
        mac="${AUTO_HOSTS[$host]}"
        seen="${AUTO_SEEN[$host]}"
        printf "# %s %-*s # last-seen: %s\n" \
            "$mac" "$((HOSTNAME_WIDTH - 2))" "$host" "$seen" >> "$tmpfile"
        unset "AUTO_HOSTS[$host]"
        unset "AUTO_SEEN[$host]"
    fi
done

# Remaining auto entries
for host in "${!AUTO_HOSTS[@]}"; do
    mac="${AUTO_HOSTS[$host]}"
    seen="${AUTO_SEEN[$host]}"
    (( current_epoch - seen > expire_seconds )) && continue
    printf "%s %-*s # last-seen: %s\n" \
        "$mac" "$HOSTNAME_WIDTH" "$host" "$seen" >> "$tmpfile"
done

mv "$tmpfile" "$ETHERS_FILE"
chmod 644 "$ETHERS_FILE"
exit 0
