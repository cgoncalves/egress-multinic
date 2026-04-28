#!/bin/bash
# /usr/local/bin/egress-multinic-reconciler.sh
#
# Steers egress traffic from configured Pod IPs/CIDRs through nodes labeled
# k8s.ovn.org/egress-assignable="", with SNAT on the egress node.
# Self-determines role (worker vs egress) each reconcile cycle.
#
# On egress nodes, also configures per-interface SNAT rules for the EgressIP
# destination-based routing workaround. EgressIP traffic (arriving via OVN's
# management port) is SNAT'd to an admin-configured /32 IP per interface.
# Non-EgressIP traffic (routed by egress-gateway) is masqueraded to the
# interface's host IP.
#
# Health detection: filters NotReady nodes via API + parallel ping probes.
# ECMP: distributes traffic across all healthy egress nodes.
#
# Usage:
#   egress-multinic-reconciler.sh           # run reconciler loop
#   egress-multinic-reconciler.sh cleanup   # tear down all rules and exit

set -uo pipefail

# --- Configuration ---
CONFIG_FILE="/etc/egress-multinic/egress-multinic.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[error] configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Derived / internal
OC_ARGS="--server=${API_SERVER} --certificate-authority=${CA_FILE} --token=$(cat "${TOKEN_FILE}")"

# --- State tracking ---
LAST_STATE=""

# --- Helpers ---

get_self_ip() {
  ip route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}

get_node_name() {
  local self_ip
  self_ip=$(get_self_ip)
  oc ${OC_ARGS} get nodes -o json 2>/dev/null \
  | jq -r --arg ip "$self_ip" '
    .items[]
    | select(.status.addresses[]? | select(.type=="InternalIP" and .address==$ip))
    | .metadata.name
  ' | head -1
}

is_egress_node() {
  local labels
  labels=$(oc ${OC_ARGS} get node "$1" \
    -o jsonpath='{.metadata.labels}' 2>/dev/null)
  echo "$labels" | grep -q 'k8s.ovn.org/egress-assignable'
}

get_egress_nodes() {
  local output rc
  output=$(oc ${OC_ARGS} get nodes \
    -l 'k8s.ovn.org/egress-assignable=' \
    -o json 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[error] API query failed: ${output}" >&2
    return 1
  fi
  echo "$output" | jq -r '
    .items[]
    | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))
    | .metadata.name as $name
    | [.status.addresses[]? | select(.type=="InternalIP").address] as $ips
    | ($ips | map(select(test("^[0-9]+\\."))) | first // "") as $v4
    | ($ips | map(select(test(":"))) | first // "") as $v6
    | "\($name),\($v4),\($v6)"
  ' | sort
}

get_healthy_egress_ips() {
  local egress_nodes="$1"
  local pids=() entries=()

  while IFS=',' read -r name ipv4 ipv6; do
    [ -z "$ipv4" ] && continue
    entries+=("${name},${ipv4},${ipv6}")
    ping -c 1 -W "$PING_TIMEOUT" "$ipv4" &>/dev/null &
    pids+=($!)
  done <<< "$egress_nodes"

  for i in "${!pids[@]}"; do
    IFS=',' read -r name ipv4 ipv6 <<< "${entries[$i]}"
    if wait "${pids[$i]}"; then
      echo "${ipv4},${ipv6}"
    else
      echo "[warn] egress node ${name} (${ipv4}) is Ready but unreachable" >&2
    fi
  done
}

# --- Setup / Cleanup ---

setup_worker() {
  local healthy_ips="$1"
  local nexthops_v4="" nexthops_v6=""

  while IFS=',' read -r ipv4 ipv6; do
    [ -n "$ipv4" ] && nexthops_v4="${nexthops_v4} nexthop via ${ipv4} weight 1"
    [ -n "$ipv6" ] && nexthops_v6="${nexthops_v6} nexthop via ${ipv6} weight 1"
  done <<< "$healthy_ips"

  local v6_prerouting_rule=""
  if [ -n "${POD_CIDRS_V6:-}" ]; then
    v6_prerouting_rule="ip6 saddr ${POD_CIDRS_V6} ip6 daddr != { ${EXCLUDE_CIDRS_V6} } ct direction original meta mark set ${FWMARK}"
  fi

  nft -f - <<EOF
table inet ${NFT_TABLE_WORKER}
flush table inet ${NFT_TABLE_WORKER}
table inet ${NFT_TABLE_WORKER} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip saddr ${POD_CIDRS} ip daddr != { ${EXCLUDE_CIDRS} } ct direction original meta mark set ${FWMARK}
    ${v6_prerouting_rule}
  }
}
EOF

  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip rule add fwmark "$FWMARK" table "$RT_TABLE" priority "$RT_PRIO"

  sysctl -qw net.ipv4.fib_multipath_hash_policy="${FIB_MULTIPATH_HASH_POLICY:-1}"

  ip route replace default table "$RT_TABLE" ${nexthops_v4}

  if [ -n "${POD_CIDRS_V6:-}" ] && [ -n "$nexthops_v6" ]; then
    ip -6 rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
    ip -6 rule add fwmark "$FWMARK" table "$RT_TABLE" priority "$RT_PRIO"
    ip -6 route replace default table "$RT_TABLE" ${nexthops_v6}
    sysctl -qw net.ipv6.fib_multipath_hash_policy="${FIB_MULTIPATH_HASH_POLICY:-1}"
  fi
}

cleanup_worker() {
  nft delete table inet "$NFT_TABLE_WORKER" 2>/dev/null || true
  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip route flush table "$RT_TABLE" 2>/dev/null || true
  ip -6 rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip -6 route flush table "$RT_TABLE" 2>/dev/null || true
}

block_worker() {
  local v6_prerouting_rule=""
  if [ -n "${POD_CIDRS_V6:-}" ]; then
    v6_prerouting_rule="ip6 saddr ${POD_CIDRS_V6} ip6 daddr != { ${EXCLUDE_CIDRS_V6} } ct direction original meta mark set ${FWMARK}"
  fi

  nft -f - <<EOF
table inet ${NFT_TABLE_WORKER}
flush table inet ${NFT_TABLE_WORKER}
table inet ${NFT_TABLE_WORKER} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip saddr ${POD_CIDRS} ip daddr != { ${EXCLUDE_CIDRS} } ct direction original meta mark set ${FWMARK}
    ${v6_prerouting_rule}
  }
}
EOF

  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip rule add fwmark "$FWMARK" table "$RT_TABLE" priority "$RT_PRIO"

  ip route replace unreachable default table "$RT_TABLE"
  if [ -n "${POD_CIDRS_V6:-}" ]; then
    ip -6 rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
    ip -6 rule add fwmark "$FWMARK" table "$RT_TABLE" priority "$RT_PRIO"
    ip -6 route replace unreachable default table "$RT_TABLE"
  fi
}

setup_egress() {
  local fwmark_fwd="0x3000"
  local fwmark_eip="0x3001"

  # Build per-interface SNAT rules for EgressIP workaround.
  # 0x3001-marked traffic (from ovn-k8s-mp0) gets /32 SNAT only if the
  # source IP is in the egressip-pods set. EgressService traffic (source
  # in egresssvc-pods) is skipped so OVN's egress-services chain handles it.
  # All other traffic on alternate interfaces gets masquerade fallback.
  local snat_rules=""
  local masq_fallback=""
  for entry in "${EGRESSIP_SNAT[@]+"${EGRESSIP_SNAT[@]}"}"; do
    [ -z "$entry" ] && continue
    IFS=':' read -r iface snat_ip <<< "$entry"
    snat_rules="${snat_rules}
    meta mark ${fwmark_eip} ip saddr @egressip-pods oifname \"${iface}\" snat ip to ${snat_ip}"
    masq_fallback="${masq_fallback}
    oifname \"${iface}\" masquerade"
  done

  local v6_forward_rule=""
  if [ -n "${POD_CIDRS_V6:-}" ]; then
    v6_forward_rule="ip6 daddr != { ${EXCLUDE_CIDRS_V6} } meta mark set ${fwmark_fwd}"
  fi

  nft -f - <<EOF
table inet ${NFT_TABLE_EGRESS}
flush table inet ${NFT_TABLE_EGRESS}
table inet ${NFT_TABLE_EGRESS} {
  set egressip-pods {
    type ipv4_addr
    comment "EgressIP pod IPs -- /32 SNAT applied"
  }
  set egresssvc-pods {
    type ipv4_addr
    comment "EgressService pod IPs -- excluded from /32 SNAT"
  }
  chain forward {
    type filter hook forward priority filter - 1; policy accept;
    iifname "${OVN_MGMT_PORT}" meta mark set ${fwmark_eip} return
    ip daddr != { ${EXCLUDE_CIDRS} } meta mark set ${fwmark_fwd}
    ${v6_forward_rule}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    meta mark ${fwmark_fwd} masquerade
    ip saddr @egresssvc-pods return${snat_rules}${masq_fallback}
  }
}
EOF

  sync_egressip_set
  sync_egresssvc_set
}

# Syncs the egressip-pods nftables set with pod IPs from ip rules at
# priority 6000 (EgressIP rules created by OVN).
sync_egressip_set() {
  local rule_ips
  rule_ips=$(ip rule show priority 6000 2>/dev/null \
    | grep -oP 'from \K\d+\.\d+\.\d+\.\d+' | sort)

  local current_set_ips
  current_set_ips=$(nft list set inet "$NFT_TABLE_EGRESS" egressip-pods 2>/dev/null \
    | grep -oP '\d+\.\d+\.\d+\.\d+' | sort)

  if [ "$rule_ips" = "$current_set_ips" ]; then
    return
  fi

  nft flush set inet "$NFT_TABLE_EGRESS" egressip-pods 2>/dev/null || return

  if [ -n "$rule_ips" ]; then
    local elements
    elements=$(echo "$rule_ips" | paste -sd, -)
    nft add element inet "$NFT_TABLE_EGRESS" egressip-pods "{ ${elements} }" 2>/dev/null
    echo "[egress] updated egressip-pods set: ${elements}"
  fi
}

# Syncs the egresssvc-pods nftables set with OVN's egress-service-snat-v4 map.
# EgressService pod IPs are excluded from our /32 SNAT so OVN's
# egress-services chain can SNAT them to the LoadBalancer IP instead.
sync_egresssvc_set() {
  local ovn_map_ips
  ovn_map_ips=$(nft list map inet ovn-kubernetes egress-service-snat-v4 2>/dev/null \
    | grep -oP '\d+\.\d+\.\d+\.\d+(?= comment)' | sort)

  local current_set_ips
  current_set_ips=$(nft list set inet "$NFT_TABLE_EGRESS" egresssvc-pods 2>/dev/null \
    | grep -oP '\d+\.\d+\.\d+\.\d+' | sort)

  if [ "$ovn_map_ips" = "$current_set_ips" ]; then
    return
  fi

  nft flush set inet "$NFT_TABLE_EGRESS" egresssvc-pods 2>/dev/null || return

  if [ -n "$ovn_map_ips" ]; then
    local elements
    elements=$(echo "$ovn_map_ips" | paste -sd, -)
    nft add element inet "$NFT_TABLE_EGRESS" egresssvc-pods "{ ${elements} }" 2>/dev/null
    echo "[egress] updated egresssvc-pods set: ${elements}"
  fi
}

cleanup_egress() {
  nft delete table inet "$NFT_TABLE_EGRESS" 2>/dev/null || true
}

# Validates that the egress nftables table matches what setup_egress() would
# create. Returns non-zero if the table is missing or stale (e.g., missing
# SNAT rules after a boot-time race).
validate_egress() {
  local current
  current=$(nft list table inet "$NFT_TABLE_EGRESS" 2>/dev/null) || return 1

  echo "$current" | grep -q "iifname \"${OVN_MGMT_PORT}\".*meta mark set 0x00003001" || return 1

  for entry in "${EGRESSIP_SNAT[@]+"${EGRESSIP_SNAT[@]}"}"; do
    [ -z "$entry" ] && continue
    IFS=':' read -r iface snat_ip <<< "$entry"
    echo "$current" | grep -q "oifname \"${iface}\".*snat.*${snat_ip}" || return 1
  done

  return 0
}

cleanup_all() {
  cleanup_worker
  cleanup_egress
  echo "[cleanup] all egress-multinic rules removed"
  LAST_STATE=""
}

# --- Main loop ---

main() {
  if [ "${1:-}" = "cleanup" ]; then
    cleanup_all
    exit 0
  fi

  if ! oc ${OC_ARGS} get nodes &>/dev/null; then
    echo "[error] cannot reach API at ${API_SERVER}"
    exit 1
  fi

  local node_name
  node_name=$(get_node_name)
  if [ -z "$node_name" ]; then
    echo "[error] cannot determine node name"
    exit 1
  fi

  local snat_info=""
  if [ ${#EGRESSIP_SNAT[@]} -gt 0 ] 2>/dev/null; then
    snat_info=" egressip_snat=${#EGRESSIP_SNAT[@]} interfaces"
  fi
  echo "[init] node=${node_name} pod_cidrs=${POD_CIDRS}${POD_CIDRS_V6:+ pod_cidrs_v6=${POD_CIDRS_V6}}${snat_info}"

  trap 'cleanup_all; exit 0' SIGTERM SIGINT

  while true; do
    local egress_nodes

    if ! egress_nodes=$(get_egress_nodes); then
      echo "[warn] API unreachable, keeping current rules"
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    if [ -z "$egress_nodes" ]; then
      if [ "$LAST_STATE" != "blocked" ]; then
        echo "[warn] no Ready egress nodes found, blocking routed traffic"
        cleanup_egress
        block_worker
        LAST_STATE="blocked"
      fi
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    if is_egress_node "$node_name"; then
      local desired_state="egress"
      local needs_apply=false
      if [ "$desired_state" != "$LAST_STATE" ]; then
        needs_apply=true
      elif ! validate_egress; then
        echo "[egress] nftables rules are stale, re-applying"
        needs_apply=true
      fi
      if [ "$needs_apply" = true ]; then
        echo "[egress] accepting routed traffic for ${POD_CIDRS}${POD_CIDRS_V6:+ ${POD_CIDRS_V6}}"
        cleanup_worker
        setup_egress
        LAST_STATE="$desired_state"
      else
        sync_egressip_set
        sync_egresssvc_set
      fi
    else
      local self_ip healthy_ips
      self_ip=$(get_self_ip)
      healthy_ips=$(get_healthy_egress_ips "$egress_nodes" | grep -v "^${self_ip},")

      if [ -z "$healthy_ips" ]; then
        if [ "$LAST_STATE" != "blocked" ]; then
          echo "[warn] no reachable egress nodes, blocking routed traffic"
          cleanup_egress
          block_worker
          LAST_STATE="blocked"
        fi
        sleep "$RECONCILE_INTERVAL"
        continue
      fi

      local desired_state="worker:${healthy_ips}"
      if [ "$desired_state" != "$LAST_STATE" ]; then
        echo "[worker] routing ${POD_CIDRS} -> egress ECMP [$(echo "$healthy_ips" | tr '\n' ' ')]"
        cleanup_egress
        setup_worker "$healthy_ips"
        LAST_STATE="$desired_state"
      fi
    fi

    sleep "$RECONCILE_INTERVAL"
  done
}

main "$@"
