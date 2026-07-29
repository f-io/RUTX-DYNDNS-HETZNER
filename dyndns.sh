#!/bin/sh
# VERSION=4.6
# DynDNS updater for Hetzner DNS via the new Cloud API (api.hetzner.cloud)
# Target: Teltonika RutOS / OpenWrt (BusyBox ash)
# No extra packages required - BusyBox tools and curl only.
#
# Default mode is "auto": both address families are probed and every
# family that is actually usable gets its RRset updated - IPv4 only,
# IPv6 only, or both. A detected IPv4 is only used when it is really
# assigned to a local interface: this skips both shared carrier NAT
# (CGNAT) and the egress IP of a foreign uplink (e.g. WiFi-as-WAN
# behind someone else's router). For LTE APNs that provide a 1:1-NAT
# public IP (interface shows a private address, but the public IP is
# routed to this line) set DYNDNS_NAT_CHECK='0' in /root/dyndns.conf.

# load configuration (seeded by /etc/rc.local on first boot)
[ -f /root/dyndns.conf ] && . /root/dyndns.conf

# strip CR (files edited/pasted with Windows line endings) and blanks
trim() { echo "$1" | tr -d '\r' | sed 's/^ *//;s/ *$//'; }

auth_api_token=$(trim "${HETZNER_TOKEN:-}")
zone_name=$(trim "${ZONE_NAME:-}")
zone_id=$(trim "${ZONE_ID:-}")
record_name=$(trim "${RECORD_NAME:-}")
record_ttl=$(trim "${RECORD_TTL:-300}")
nat_check=$(trim "${DYNDNS_NAT_CHECK:-1}")
# optional: bind the IP detection to one uplink (e.g. 'qmimux0' for LTE)
# so a higher-priority WAN (WiFi-as-WAN) can never leak into the records
bind_iface=$(trim "${DYNDNS_IFACE:-}")
record_type=""

api_base="https://api.hetzner.cloud/v1"

log() {
  echo "${1}: ${record_name}: ${2}"
  logger -t dyndns "${1}: ${record_name}: ${2}"
}

display_help() {
  cat << HELP
Hetzner Cloud DNS DynDNS updater (RutOS/OpenWrt)

Usage: $0 [OPTIONS]

  -z ZONE_ID     - zone id (numeric, optional if -Z or the conf is set)
  -Z ZONE_NAME   - zone name, e.g. example.com
  -n RECORD_NAME - record name, e.g. router ("@" for the zone apex)
  -t TTL         - TTL in seconds (default: 300)
  -T TYPE        - only update this record type: A or AAAA
                   (default: auto - update every family that is available)
  -h             - show this help

Examples:
  $0                             # auto: A and/or AAAA, whatever works
  $0 -T AAAA                     # IPv6 only
  $0 -Z example.com -n router    # auto for router.example.com
HELP
  exit 1
}

while getopts ":z:Z:n:t:T:h" opt; do
  case "$opt" in
    z) zone_id="$OPTARG";;
    Z) zone_name="$OPTARG";;
    n) record_name="$OPTARG";;
    t) record_ttl="$OPTARG";;
    T) record_type="$OPTARG";;
    h) display_help;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1;;
    :) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
  esac
done

case "$record_type" in
  ""|A|AAAA) ;;
  *) log Error "Only record type A or AAAA is supported for DynDNS."; exit 1;;
esac

case "$record_ttl" in
  ''|*[!0-9]*) log Error "TTL must be a number: ${record_ttl}"; exit 1;;
esac

if [ -z "$auth_api_token" ] || [ "$auth_api_token" = "YOUR_HETZNER_CLOUD_API_TOKEN" ]; then
  log Error "No API token set. Edit /root/dyndns.conf."
  exit 1
fi

if [ -z "$record_name" ] || [ "$record_name" = "YOUR_RECORD_NAME" ]; then
  log Error "No record name set. Edit /root/dyndns.conf or use -n <name>."
  exit 1
fi

# helper for Cloud API calls: api <METHOD> <endpoint> [json-body]
api() {
  if [ -n "${3:-}" ]; then
    curl -s --connect-timeout 10 -X "$1" "${api_base}/$2" \
      -H "Authorization: Bearer ${auth_api_token}" \
      -H "Content-Type: application/json" \
      -d "$3"
  else
    curl -s --connect-timeout 10 -X "$1" "${api_base}/$2" \
      -H "Authorization: Bearer ${auth_api_token}"
  fi
}

# the API pretty-prints its JSON - flatten it so the patterns below match
json_norm() { tr -d '\n\r' | sed 's/[[:space:]]*:[[:space:]]*/:/g; s/,[[:space:]]*/,/g'; }
# extract the first "key":"string" value from a normalized JSON response
json_str() { grep -o "\"$1\":\"[^\"]*\"" | head -n1 | cut -d'"' -f4; }
# extract the first "key":number value from a normalized JSON response
json_num() { grep -o "\"$1\":[0-9]*" | head -n1 | cut -d: -f2; }

# ---------------------------------------------------------------------
# detect the public addresses (empty result = family not available)
# ---------------------------------------------------------------------
get_pub_ip() {
  if [ -n "$bind_iface" ]; then
    set -- "-$1" --interface "$bind_iface"
  else
    set -- "-$1"
  fi
  addr=$(curl -s "$@" --connect-timeout 10 https://ip.hetzner.com 2>/dev/null)
  if [ -z "$addr" ]; then
    addr=$(curl -s "$@" --connect-timeout 10 https://ifconfig.co 2>/dev/null)
  fi
  echo "$addr"
}

ipv4=""
ipv6=""
if [ -z "$record_type" ] || [ "$record_type" = "A" ]; then
  ipv4=$(get_pub_ip 4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
fi
if [ -z "$record_type" ] || [ "$record_type" = "AAAA" ]; then
  ipv6=$(get_pub_ip 6 | grep -E '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$' | tr 'A-F' 'a-f')
fi

# only use an IPv4 that is really assigned to a local interface - this
# skips carrier NAT (CGNAT) and foreign uplinks (WiFi-as-WAN). Set
# DYNDNS_NAT_CHECK='0' for APNs that provide a 1:1-NAT public IP.
if [ -n "$ipv4" ] && [ "$nat_check" = "1" ]; then
  if ! ip -4 addr 2>/dev/null | grep -oE 'inet [0-9.]+' | grep -qx "inet ${ipv4}"; then
    log Info "IPv4 ${ipv4} is not assigned locally (carrier NAT?) - skipping A record."
    ipv4=""
  fi
fi

if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
  log Error "No usable public IP address (IPv4 or IPv6) found."
  exit 1
fi

# ---------------------------------------------------------------------
# resolve zone (skipped if ZONE_ID is set in the conf or via -z)
# ---------------------------------------------------------------------
if [ -z "$zone_id" ]; then
  zone_info=$(api GET "zones?per_page=50" | json_norm)

  if [ -z "$zone_info" ]; then
    log Error "No response from Hetzner Cloud API."
    exit 1
  fi

  if echo "$zone_info" | grep -q '"error":{'; then
    log Error "API error while fetching zones: $(echo "$zone_info" | json_str message)"
    exit 1
  fi

  # zone objects start with "id":<num>,"name":"<zone>" - match them as a pair
  zone_id=$(echo "$zone_info" | grep -o "\"id\":[0-9]*,\"name\":\"${zone_name}\"" \
    | head -n1 | cut -d: -f2 | cut -d, -f1)

  if [ -z "$zone_id" ]; then
    log Error "Zone not found: ${zone_name} (wrong project token?)"
    exit 1
  fi
fi

if [ -z "$zone_id" ]; then
  log Error "Could not determine the zone id for: ${zone_name}"
  exit 1
fi

log Info "Zone: ${zone_name:-$zone_id} (ID: ${zone_id})"

# ---------------------------------------------------------------------
# create or update one RRset: update_rrset <A|AAAA> <address>
# returns 0 on success (incl. "already up to date"), 1 on failure
# ---------------------------------------------------------------------
update_rrset() {
  rtype="$1"
  addr="$2"

  payload=$(printf '{"name":"%s","type":"%s","ttl":%s,"records":[{"value":"%s"}]}' \
    "$record_name" "$rtype" "$record_ttl" "$addr")

  # fetch exactly this rrset - 404/not_found means it does not exist yet
  rrset=$(api GET "zones/${zone_id}/rrsets/${record_name}/${rtype}" | json_norm)

  if echo "$rrset" | grep -q '"not_found"'; then
    log Info "${rtype}: RRset does not exist - creating it (${addr})."
    response=$(api POST "zones/${zone_id}/rrsets" "$payload" | json_norm)
    if echo "$response" | grep -q '"error":{'; then
      log Error "${rtype}: failed to create RRset: $(echo "$response" | json_str message)"
      return 1
    fi
    log Info "${rtype}: RRset created successfully."
    return 0
  fi

  if echo "$rrset" | grep -q '"error":{'; then
    log Error "${rtype}: API error while fetching RRset: $(echo "$rrset" | json_str message)"
    return 1
  fi

  current_value=$(echo "$rrset" | json_str value | tr 'A-F' 'a-f')
  if [ "$addr" = "$current_value" ]; then
    log Info "${rtype}: record is up to date (${addr}) - nothing to do."
    return 0
  fi

  log Info "${rtype}: IP changed ${current_value:-<none>} -> ${addr} - updating RRset."
  api DELETE "zones/${zone_id}/rrsets/${record_name}/${rtype}" >/dev/null
  response=$(api POST "zones/${zone_id}/rrsets" "$payload" | json_norm)
  if echo "$response" | grep -q '"error":{'; then
    log Error "${rtype}: failed to update RRset: $(echo "$response" | json_str message)"
    return 1
  fi
  log Info "${rtype}: RRset updated successfully."
  return 0
}

# ---------------------------------------------------------------------
# update every family that is available
# ---------------------------------------------------------------------
rc=0

if [ -n "$ipv4" ]; then
  update_rrset A "$ipv4" || rc=1
elif [ "$record_type" = "A" ]; then
  log Error "No usable public IPv4 address found."
  exit 1
else
  log Info "No usable public IPv4 - A record not touched."
fi

if [ -n "$ipv6" ]; then
  update_rrset AAAA "$ipv6" || rc=1
elif [ "$record_type" = "AAAA" ]; then
  log Error "No usable public IPv6 address found."
  exit 1
elif [ -z "$record_type" ]; then
  log Info "No public IPv6 - AAAA record not touched."
fi

exit $rc
