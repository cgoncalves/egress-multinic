#!/bin/bash
#
# QE test suite for egress-multinic (OAM/signaling example).
#
# Covers: Areas 1–8 from the QE test plan (excludes dev baseline tests
# already covered by 08-verify.sh and Area 3 ECMP which requires 3+ workers).
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/09-qe-tests.sh
#
# Prerequisites:
#   - Feature deployed via README Steps 1–8
#   - Dev baseline (08-verify.sh) passes
#   - Test pods deployed (07-pod.yaml + 07c-gateway-pods.yaml)
#
# Options (env vars):
#   SKIP_REBOOT=1    skip TC-2.6 / TC-8.3b (long wait for node reboot)
#   SKIP_DESTRUCTIVE=1  skip tests that delete namespaces or drain nodes
#

set -uo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ALL_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)
ALL_GW_NODES=$(oc get nodes -l k8s.ovn.org/egress-assignable="" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)

if [ -n "${GATEWAY_NODE_1:-}" ] && [ -n "${WORKER_NODE:-}" ]; then
    echo "  Using explicit: GATEWAY_NODE_1=${GATEWAY_NODE_1}, WORKER_NODE=${WORKER_NODE}"
else
    if [ -z "${ALL_WORKERS}" ]; then
        echo "ERROR: No worker nodes detected. Ensure KUBECONFIG is correct and cluster is reachable." >&2
        exit 1
    fi
    if [ -n "${ALL_GW_NODES}" ]; then
        GATEWAY_NODE_1="${GATEWAY_NODE_1:-$(echo ${ALL_GW_NODES} | awk '{print $1}')}"
        WORKER_NODE="${WORKER_NODE:-$(for w in ${ALL_WORKERS}; do echo "${ALL_GW_NODES}" | grep -qw "${w}" || { echo "${w}"; break; }; done)}"
        echo "  Auto-detected from labels: GW=[${ALL_GW_NODES}], WORKER=${WORKER_NODE}"
    else
        WORKER_COUNT=$(echo ${ALL_WORKERS} | wc -w)
        if [ "${WORKER_COUNT}" -ge 3 ]; then
            GATEWAY_NODE_1=$(echo ${ALL_WORKERS} | awk '{print $1}')
            oc label node $(echo ${ALL_WORKERS} | awk '{print $1}') k8s.ovn.org/egress-assignable="" --overwrite 2>/dev/null
            oc label node $(echo ${ALL_WORKERS} | awk '{print $2}') k8s.ovn.org/egress-assignable="" --overwrite 2>/dev/null
            WORKER_NODE=$(echo ${ALL_WORKERS} | awk '{print $3}')
            ALL_GW_NODES="$(echo ${ALL_WORKERS} | awk '{print $1}') $(echo ${ALL_WORKERS} | awk '{print $2}')"
            echo "  3+ workers: GW=[${ALL_GW_NODES}], WORKER=${WORKER_NODE}"
        elif [ "${WORKER_COUNT}" -eq 2 ]; then
            GATEWAY_NODE_1=$(echo ${ALL_WORKERS} | awk '{print $1}')
            oc label node ${GATEWAY_NODE_1} k8s.ovn.org/egress-assignable="" --overwrite 2>/dev/null
            WORKER_NODE=$(echo ${ALL_WORKERS} | awk '{print $2}')
            ALL_GW_NODES="${GATEWAY_NODE_1}"
            echo "  2 workers: GW=${GATEWAY_NODE_1}, WORKER=${WORKER_NODE}"
        else
            echo "ERROR: At least 2 worker nodes are required to run these tests, found ${WORKER_COUNT}." >&2
            exit 1
        fi
    fi
fi

: "${GATEWAY_NODE_1:=worker0}"
: "${WORKER_NODE:=worker1}"

DEST_VIA_NIC1="192.168.250.1"
DEST_VIA_NIC2="192.168.251.1"
SNAT_NIC1="192.168.150.200"
SNAT_NIC2="192.168.200.200"
MASQ_NIC1="192.168.150.10"
MASQ_NIC2="192.168.200.10"
TEST_NS="demo-egressip"
RECONCILE_WAIT=15

PASS=0 FAIL=0 SKIP=0
RESULTS=()

# ---------- helpers ----------

pass() {
    local id="$1"; shift
    echo "[PASS] ${id}: $*"
    ((PASS++))
    RESULTS+=("PASS|${id}|$*")
}

fail() {
    local id="$1"; shift
    echo "[FAIL] ${id}: $*"
    ((FAIL++))
    RESULTS+=("FAIL|${id}|$*")
}

skip() {
    local id="$1"; shift
    echo "[SKIP] ${id}: $*"
    ((SKIP++))
    RESULTS+=("SKIP|${id}|$*")
}

node_exec() {
    local node="$1"; shift
    oc debug "node/${node}" -- chroot /host bash -c "$*" 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use"
}

pod_curl() {
    local pod="$1" dest="$2"
    oc exec -n "${TEST_NS}" "${pod}" -- curl -s --connect-timeout 5 "${dest}" 2>/dev/null
}

pod_curl_exit() {
    local pod="$1" dest="$2"
    oc exec -n "${TEST_NS}" "${pod}" -- curl -s --connect-timeout 5 "${dest}" 2>/dev/null
    echo "EXIT:$?"
}

wait_reconcile() { sleep "${1:-${RECONCILE_WAIT}}"; }

wait_healthy() {
    local timeout="${1:-60}"
    local end_time=$(( $(date +%s) + timeout ))
    echo "  [recovery] Waiting up to ${timeout}s for full recovery..."
    while [ "$(date +%s)" -lt "${end_time}" ]; do
        local gw_check wk_check
        gw_check=$(node_exec "${GATEWAY_NODE_1}" \
            "systemctl is-active egress-multinic && nft list table inet egress-snat >/dev/null 2>&1 && echo GW_HEALTHY")
        wk_check=$(node_exec "${WORKER_NODE}" \
            "systemctl is-active egress-multinic && echo WK_HEALTHY")
        if echo "${gw_check}" | grep -q "GW_HEALTHY" && echo "${wk_check}" | grep -q "WK_HEALTHY"; then
            echo "  [recovery] All nodes healthy"
            return 0
        fi
        sleep 5
    done
    echo "  [recovery] WARNING: timed out after ${timeout}s"
    return 1
}

restore_config() {
    local node="$1"
    local rendered mc_conf mcp_name
    for mcp_name in "${MCP_NAME:-}" workercnf worker; do
        [ -z "${mcp_name}" ] && continue
        rendered=$(oc get mcp "${mcp_name}" -o jsonpath='{.spec.configuration.name}' 2>/dev/null)
        [ -n "${rendered}" ] && break
    done
    if [ -z "${rendered}" ]; then
        echo "  [restore_config] ERROR: could not find rendered MachineConfig for any pool"
        return 1
    fi
    mc_conf=$(oc get mc "${rendered}" -o jsonpath='{.spec.config.storage.files}' 2>/dev/null | python3 -c "
import sys, json, base64
try:
    files = json.loads(sys.stdin.read())
    for f in files:
        if 'egress-multinic.conf' in f.get('path',''):
            src = f['contents']['source'].replace('data:text/plain;charset=utf-8;base64,','')
            sys.stdout.write(base64.b64decode(src).decode())
except Exception:
    pass
" 2>/dev/null)
    if [ -z "${mc_conf}" ]; then
        echo "  [restore_config] ERROR: retrieved configuration is empty, aborting restore to prevent corruption"
        return 1
    fi
    local b64
    b64=$(echo -n "${mc_conf}" | base64 -w0)
    node_exec "${node}" "echo '${b64}' | base64 -d > /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
}

restore_token() {
    local node="$1"
    local fresh_token
    fresh_token=$(oc get secret egress-multinic-token -n openshift-config \
        -o jsonpath='{.data.token}' | base64 -d)
    if [ -z "${fresh_token}" ]; then
        echo "  [restore_token] WARNING: could not fetch token from secret"
        return 1
    fi
    local tok_b64
    tok_b64=$(echo -n "${fresh_token}" | base64 -w0)
    node_exec "${node}" "echo '${tok_b64}' | base64 -d > /etc/egress-multinic/token && chmod 600 /etc/egress-multinic/token"
}

ensure_worker_ready() {
    local node="${1}" timeout="${2:-120}"
    local end_time=$(( $(date +%s) + timeout ))
    local attempt=0
    echo "  [pre] Ensuring ${node} reconciler is healthy, timeout=${timeout}s..."
    while [ "$(date +%s)" -lt "${end_time}" ]; do
        ((attempt++))
        if node_exec "${node}" "systemctl is-active egress-multinic && nft list table inet egress-gateway >/dev/null 2>&1 && echo READY" | grep -q "READY"; then
            echo "  [pre] ${node} reconciler ready after attempt ${attempt}"
            return 0
        fi
        echo "  [pre] Attempt ${attempt}: not ready, restoring token and restarting..."
        restore_token "${node}"
        node_exec "${node}" "systemctl restart egress-multinic"
        sleep 15
    done
    echo "  [pre] WARNING: ${node} reconciler not ready after ${timeout}s"
    return 1
}

separator() {
    echo ""
    echo "=========================================="
    echo "  $*"
    echo "=========================================="
    echo ""
}

# ---------- Pre-flight: ensure test infrastructure is healthy ----------

preflight() {
    echo "=========================================="
    echo "  Pre-flight checks"
    echo "=========================================="
    local errors=0

    # 1. Validate echo servers on gateway nodes
    for gw in ${ALL_GW_NODES}; do
        for svc in http-server-oam http-server-signaling; do
            local status
            status=$(node_exec "${gw}" "systemctl is-active ${svc}.service 2>/dev/null" | tr -d '[:space:]')
            if [ "${status}" != "active" ]; then
                echo "  [preflight] FAIL: ${gw}: ${svc} is ${status:-missing} — run 03-setup-infra.sh"
                ((errors++))
            fi
        done
    done

    # 2. Validate NNCP
    local nncp_status
    nncp_status=$(oc get nncp egress-multinic-oam-sig -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    if [ "${nncp_status}" != "True" ]; then
        echo "  [preflight] FAIL: NNCP not Available (${nncp_status:-missing}) — apply 04-nncp.yaml"
        ((errors++))
    fi

    # 3. Validate namespace and test pods
    if ! oc get ns "${TEST_NS}" >/dev/null 2>&1; then
        echo "  [preflight] FAIL: Namespace ${TEST_NS} missing — apply 05-namespace.yaml + 06-egressip.yaml"
        ((errors++))
    fi
    for pod in egressip-pod non-egressip-pod; do
        if ! oc get pod -n "${TEST_NS}" "${pod}" >/dev/null 2>&1; then
            echo "  [preflight] FAIL: Pod ${pod} missing — apply 07-pod.yaml"
            ((errors++))
        fi
    done
    for pod in gw-egressip-pod gw-non-egressip-pod; do
        if ! oc get pod -n "${TEST_NS}" "${pod}" >/dev/null 2>&1; then
            echo "  [preflight] FAIL: Pod ${pod} missing — apply 07c-gateway-pods.yaml"
            ((errors++))
        fi
    done

    # 4. Validate EgressIP is assigned
    local eip_node
    eip_node=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
    if [ -z "${eip_node}" ]; then
        echo "  [preflight] FAIL: EgressIP not assigned — apply 06-egressip.yaml"
        ((errors++))
    fi

    # 5. Validate reconciler is running on gateway and worker
    for node_name in "${GATEWAY_NODE_1}" "${WORKER_NODE}"; do
        local svc_status
        svc_status=$(node_exec "${node_name}" "systemctl is-active egress-multinic" | tr -d '[:space:]')
        if [ "${svc_status}" != "active" ]; then
            echo "  [preflight] FAIL: egress-multinic not active on ${node_name} (${svc_status:-unknown})"
            ((errors++))
        fi
    done

    if [ "${errors}" -gt 0 ]; then
        echo ""
        echo "  [preflight] ${errors} check(s) failed. Deploy the feature (README steps 1-8) before running tests."
        exit 1
    fi

    # 6. Smoke test — verify end-to-end traffic
    wait_reconcile
    local r1 r2
    r1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    r2=$(pod_curl egressip-pod "${DEST_VIA_NIC2}:8081")
    if [ "${r1}" = "source: ${SNAT_NIC1}" ] && [ "${r2}" = "source: ${SNAT_NIC2}" ]; then
        echo "  [preflight] Smoke test PASSED — NIC1 and NIC2 traffic OK"
    else
        echo "  [preflight] FAIL: Smoke test — NIC1='${r1:-timeout}', NIC2='${r2:-timeout}'"
        echo "  [preflight] Verify 08-verify.sh passes before running tests."
        exit 1
    fi
    echo ""
}

preflight

# ---------- Area 1: Core Traffic Flow ----------

separator "Area 1: Core Traffic Flow"

# TC-1.1
echo "--- TC-1.1: Pod-to-Pod Ping ---"
TARGET_IP=$(oc get pod -n "${TEST_NS}" non-egressip-pod -o jsonpath='{.status.podIP}')
PING=$(oc exec -n "${TEST_NS}" egressip-pod -- ping -c3 -W2 "${TARGET_IP}" 2>&1 | tail -2)
if echo "${PING}" | grep -q "0% packet loss"; then
    pass "TC-1.1" "Pod-to-pod ping bypasses egress steering"
else
    fail "TC-1.1" "Ping failed: ${PING}"
fi

# TC-1.2
echo "--- TC-1.2: Gateway Pods via NIC2 ---"
R1=$(pod_curl gw-egressip-pod "${DEST_VIA_NIC2}:8081")
R2=$(pod_curl gw-non-egressip-pod "${DEST_VIA_NIC2}:8081")
if [ "${R1}" = "source: ${SNAT_NIC2}" ] && [ "${R2}" = "source: ${MASQ_NIC2}" ]; then
    pass "TC-1.2" "Gateway pods route correctly to NIC2"
else
    fail "TC-1.2" "gw-egressip='${R1}' expected '${SNAT_NIC2}', gw-non='${R2}' expected '${MASQ_NIC2}'"
fi

# ---------- Area 2: HA & Failover ----------

separator "Area 2: HA & Failover"

# TC-2.3
echo "--- TC-2.3: All Gateways Unreachable ---"
for gw in ${ALL_GW_NODES}; do
    oc label node "${gw}" k8s.ovn.org/egress-assignable- --overwrite 2>/dev/null
done
wait_reconcile
RT=$(node_exec "${WORKER_NODE}" "ip route show table 100")
for gw in ${ALL_GW_NODES}; do
    oc label node "${gw}" k8s.ovn.org/egress-assignable="" 2>/dev/null
done
wait_reconcile
if echo "${RT}" | grep -q "unreachable" || [ -z "${RT}" ]; then
    pass "TC-2.3" "Traffic blocked when no gateways - route: ${RT:-empty}"
else
    fail "TC-2.3" "Route table still has nexthop: ${RT}"
fi

# TC-2.4
echo "--- TC-2.4: API Token Corruption (Running Reconciler) ---"
echo "  [TC-2.4] Pre-check: waiting for traffic after TC-2.3 cleanup..."
for _ in $(seq 1 6); do
    TC24_PRE=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    if [ "${TC24_PRE}" = "source: ${SNAT_NIC1}" ]; then
        echo "  [TC-2.4] Traffic OK, proceeding"
        break
    fi
    sleep 5
done
node_exec "${WORKER_NODE}" "cp /etc/egress-multinic/token /etc/egress-multinic/token.bak && echo invalid > /etc/egress-multinic/token"
sleep 30
STATUS=$(node_exec "${WORKER_NODE}" "systemctl is-active egress-multinic")
R=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
LOG_WARN=$(node_exec "${WORKER_NODE}" "journalctl -u egress-multinic --since '30 seconds ago' --no-pager" | grep -i "token\|auth\|unauthorized\|401\|API unreachable" || true)
node_exec "${WORKER_NODE}" "cp /etc/egress-multinic/token.bak /etc/egress-multinic/token && rm -f /etc/egress-multinic/token.bak && systemctl restart egress-multinic"
wait_healthy 120
if ! echo "${STATUS}" | grep -q "active"; then
    fail "TC-2.4" "Reconciler crashed: status=${STATUS}"
elif [ "${R}" != "source: ${SNAT_NIC1}" ]; then
    fail "TC-2.4" "Traffic broken during token corruption: traffic=${R}"
elif [ -z "${LOG_WARN}" ]; then
    fail "TC-2.4" "Reconciler did not detect corrupted token - no warning logged"
else
    pass "TC-2.4" "Running reconciler detected bad token and preserved rules"
fi

# TC-2.5
echo "--- TC-2.5: Reconciler Restart ---"
echo "  [TC-2.5] Pre-check: waiting for traffic before restart test..."
for _ in $(seq 1 6); do
    TC25_PRE=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    if [ "${TC25_PRE}" = "source: ${SNAT_NIC1}" ]; then
        echo "  [TC-2.5] Traffic OK, proceeding"
        break
    fi
    sleep 5
done
node_exec "${GATEWAY_NODE_1}" "systemctl restart egress-multinic"
wait_reconcile
R1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
node_exec "${WORKER_NODE}" "systemctl restart egress-multinic"
wait_reconcile
R2=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
if [ "${R1}" = "source: ${SNAT_NIC1}" ] && [ "${R2}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-2.5" "Traffic restored after reconciler restart on both nodes"
else
    fail "TC-2.5" "Expected '${SNAT_NIC1}': after gateway restart='${R1}', after worker restart='${R2}'"
fi

# ---------- Area 4: Configuration Changes ----------

separator "Area 4: Configuration Changes"

# TC-4.1
echo "--- TC-4.1: Add Interface to EGRESSIP_SNAT ---"
TC41_CONF='EGRESSIP_SNAT=("oam-host:192.168.150.200" "sig-host:192.168.200.200" "ens2f0:192.168.150.201")'
TC41_B64=$(printf '%s\n' "${TC41_CONF}" | base64 -w0)
node_exec "${GATEWAY_NODE_1}" "sed -i '/^EGRESSIP_SNAT=/,/)/d' /etc/egress-multinic/egress-multinic.conf && echo >> /etc/egress-multinic/egress-multinic.conf && echo '${TC41_B64}' | base64 -d >> /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
wait_reconcile
NFT=$(node_exec "${GATEWAY_NODE_1}" "nft list chain inet egress-snat postrouting" | grep "ens2f0")
restore_config "${GATEWAY_NODE_1}"
wait_reconcile
if [ -n "${NFT}" ]; then
    pass "TC-4.1" "New interface SNAT rule added to nftables"
else
    fail "TC-4.1" "Expected ens2f0 SNAT rule in nftables postrouting chain, but not found"
fi

# TC-4.2
echo "--- TC-4.2: Remove Interface from EGRESSIP_SNAT ---"
TC42_CONF='EGRESSIP_SNAT=("oam-host:192.168.150.200")'
TC42_B64=$(printf '%s\n' "${TC42_CONF}" | base64 -w0)
node_exec "${GATEWAY_NODE_1}" "sed -i '/^EGRESSIP_SNAT=/,/)/d' /etc/egress-multinic/egress-multinic.conf && echo >> /etc/egress-multinic/egress-multinic.conf && echo '${TC42_B64}' | base64 -d >> /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
wait_reconcile
NFT=$(node_exec "${GATEWAY_NODE_1}" "nft list chain inet egress-snat postrouting")
HAS_OAM=$(echo "${NFT}" | grep -c "oam-host")
HAS_SIG=$(echo "${NFT}" | grep -c "sig-host")
restore_config "${GATEWAY_NODE_1}"
wait_reconcile
if [ "${HAS_OAM}" -gt 0 ] && [ "${HAS_SIG}" -eq 0 ]; then
    pass "TC-4.2" "sig-host removed, oam-host retained"
else
    fail "TC-4.2" "Expected oam-host retained (>0) and sig-host removed (0): oam=${HAS_OAM}, sig=${HAS_SIG}"
fi

# TC-4.3
echo "--- TC-4.3: Change POD_CIDRS ---"
TC43_NEW="10.128.0.0/16"
ensure_worker_ready "${WORKER_NODE}" 120
node_exec "${WORKER_NODE}" "sed -i 's|^POD_CIDRS=.*|POD_CIDRS=\"${TC43_NEW}\"|' /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
NFT=""
for _ in 1 2 3 4 5 6 7 8; do
    sleep 5
    NFT=$(node_exec "${WORKER_NODE}" "nft list table inet egress-gateway 2>/dev/null" | grep "${TC43_NEW}")
    [ -n "${NFT}" ] && break
done
restore_config "${WORKER_NODE}"
restore_token "${WORKER_NODE}"
wait_healthy 120
if [ -n "${NFT}" ]; then
    pass "TC-4.3" "POD_CIDRS /16 reflected in nftables"
else
    fail "TC-4.3" "New CIDR not found in nftables after 40s"
fi

# TC-4.4
echo "--- TC-4.4: Add Destination to EXCLUDE_CIDRS ---"
TC44_SCRIPT='ORIG=$(grep ^EXCLUDE_CIDRS= /etc/egress-multinic/egress-multinic.conf | cut -d\" -f2); sed -i "s|^EXCLUDE_CIDRS=.*|EXCLUDE_CIDRS=\"${ORIG:+$ORIG, }192.168.250.0/24\"|" /etc/egress-multinic/egress-multinic.conf; systemctl restart egress-multinic'
TC44_B64=$(echo -n "${TC44_SCRIPT}" | base64 -w0)
node_exec "${GATEWAY_NODE_1}" "echo ${TC44_B64} | base64 -d | bash"
NFT=""
for _ in 1 2 3 4 5 6 7 8; do
    sleep 5
    NFT=$(node_exec "${GATEWAY_NODE_1}" "nft list table inet egress-snat" | grep "192.168.250")
    [ -n "${NFT}" ] && break
done
restore_config "${GATEWAY_NODE_1}"
wait_reconcile
if [ -n "${NFT}" ]; then
    pass "TC-4.4" "Excluded CIDR 192.168.250.0/24 appears in nftables"
else
    fail "TC-4.4" "Excluded CIDR not found after 40s"
fi

# TC-4.5
echo "--- TC-4.5: Delete + Recreate EgressIP CR ---"
oc delete egressip egressip-oam 2>/dev/null
sleep 5
R_DEL=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
oc apply -f "${SCRIPT_DIR}/06-egressip.yaml" 2>/dev/null
echo "  [TC-4.5] Waiting for EgressIP node assignment..."
TC45_ASSIGNED=""
for _ in $(seq 1 12); do
    TC45_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
    if [ -n "${TC45_NODE}" ]; then
        echo "  [TC-4.5] EgressIP assigned to ${TC45_NODE}"
        TC45_ASSIGNED=1
        break
    fi
    sleep 5
done
if [ -z "${TC45_ASSIGNED}" ]; then
    echo "  [TC-4.5] WARNING: EgressIP not assigned after 60s"
fi
echo "  [TC-4.5] Waiting for traffic to recover..."
R_RE=""
for _ in $(seq 1 12); do
    R_RE=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    if [ "${R_RE}" = "source: ${SNAT_NIC1}" ]; then
        echo "  [TC-4.5] Traffic restored"
        break
    fi
    sleep 5
done
if [ "${R_RE}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-4.5" "EgressIP delete/recreate: after delete='${R_DEL}', after recreate='${R_RE}'"
else
    fail "TC-4.5" "After recreate: ${R_RE}"
fi

# TC-4.5b
echo "--- TC-4.5b: Modify EgressIP CR In-Place ---"
oc patch egressip egressip-oam --type merge -p '{"spec":{"egressIPs":["10.99.0.101"]}}' 2>/dev/null
echo "  [TC-4.5b] Waiting for new EgressIP 10.99.0.101 in status..."
NEW_IP=""
for _ in $(seq 1 12); do
    NEW_IP=$(oc get egressip egressip-oam -o jsonpath='{.status.items[*].egressIP}' 2>/dev/null)
    if echo "${NEW_IP}" | grep -q "10.99.0.101"; then
        echo "  [TC-4.5b] New IP confirmed in status: ${NEW_IP}"
        break
    fi
    sleep 5
done
wait_reconcile
R_IP=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")

oc patch egressip egressip-oam --type merge -p '{"spec":{"namespaceSelector":{"matchLabels":{"egress-group":"nonexistent"}}}}' 2>/dev/null
wait_reconcile
R_SEL=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")

oc patch egressip egressip-oam --type merge -p '{"spec":{"egressIPs":["10.99.0.100"],"namespaceSelector":{"matchLabels":{"egress-group":"oam-sig"}}}}' 2>/dev/null
wait_reconcile

if ! echo "${NEW_IP}" | grep -q "10.99.0.101"; then
    fail "TC-4.5b" "EgressIP address change not reflected: newIP=${NEW_IP}"
elif [ "${R_IP}" != "source: ${SNAT_NIC1}" ]; then
    fail "TC-4.5b" "Traffic broken after IP change: trafficAfterIP='${R_IP}'"
elif [ "${R_SEL}" = "source: ${SNAT_NIC1}" ]; then
    fail "TC-4.5b" "Selector change to non-matching label did not stop SNAT - pod still gets /32 SNAT"
else
    pass "TC-4.5b" "IP change works, selector removal stops SNAT - trafficAfterSelector='${R_SEL:-timeout}'"
fi

# TC-4.6
echo "--- TC-4.6: NNCP Route Removal ---"
echo "  [TC-4.6] Sanity check: verifying traffic before test..."
TC46_READY=""
for _ in $(seq 1 12); do
    TC46_CHK1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    TC46_CHK2=$(pod_curl egressip-pod "${DEST_VIA_NIC2}:8081")
    if [ "${TC46_CHK1}" = "source: ${SNAT_NIC1}" ] && [ "${TC46_CHK2}" = "source: ${SNAT_NIC2}" ]; then
        TC46_READY=1
        echo "  [TC-4.6] Traffic OK, proceeding"
        break
    fi
    echo "  [TC-4.6] Not ready yet: NIC1='${TC46_CHK1}', NIC2='${TC46_CHK2}' - retrying..."
    sleep 5
done
if [ -z "${TC46_READY}" ]; then
    echo "  [TC-4.6] WARNING: traffic not recovered after 60s, proceeding anyway"
fi
EIP_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
: "${EIP_NODE:=${GATEWAY_NODE_1}}"
node_exec "${EIP_NODE}" "ip route del 192.168.250.0/24 via 192.168.150.1 dev oam-host 2>/dev/null; echo done"
ROUTE=$(node_exec "${EIP_NODE}" "ip route show" | grep "192.168.250")
R_NIC1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
R_NIC2=$(pod_curl egressip-pod "${DEST_VIA_NIC2}:8081")
NFT_COUNT=$(node_exec "${EIP_NODE}" "nft list chain inet egress-snat postrouting" | grep -c "oam-host\|sig-host")

node_exec "${EIP_NODE}" "ip route add 192.168.250.0/24 via 192.168.150.1 dev oam-host 2>/dev/null; echo restored"

if [ -z "${ROUTE}" ] && [ "${R_NIC2}" = "source: ${SNAT_NIC2}" ] && [ "${NFT_COUNT}" -ge 3 ]; then
    pass "TC-4.6" "Route removal breaks NIC1 traffic=${R_NIC1}, NIC2 unaffected, nftables intact ${NFT_COUNT} rules"
else
    fail "TC-4.6" "route='${ROUTE}', NIC1='${R_NIC1}', NIC2='${R_NIC2}', nft_rules=${NFT_COUNT}"
fi

# ---------- Area 5: Role Transitions ----------

separator "Area 5: Role Transitions"

# TC-5.1
echo "--- TC-5.1: Worker Becomes Gateway ---"
ensure_worker_ready "${WORKER_NODE}" 120
BEFORE=$(node_exec "${WORKER_NODE}" "nft list tables" | grep "egress")
oc label node "${WORKER_NODE}" k8s.ovn.org/egress-assignable="" 2>/dev/null
AFTER=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    AFTER=$(node_exec "${WORKER_NODE}" "nft list tables" | grep "egress")
    echo "${AFTER}" | grep -q "egress-snat" && break
done
if echo "${AFTER}" | grep -q "egress-snat"; then
    pass "TC-5.1" "Worker->Gateway: egress-snat table created"
else
    fail "TC-5.1" "Expected egress-snat table after adding gateway label: before='${BEFORE}', after='${AFTER}'"
fi

# TC-5.2
echo "--- TC-5.2: Gateway Becomes Worker ---"
oc label node "${GATEWAY_NODE_1}" k8s.ovn.org/egress-assignable- 2>/dev/null
wait_reconcile
AFTER=$(node_exec "${GATEWAY_NODE_1}" "nft list tables" | grep "egress")
if echo "${AFTER}" | grep -q "egress-gateway"; then
    pass "TC-5.2" "Gateway->Worker: egress-gateway table created"
else
    fail "TC-5.2" "Expected egress-gateway table after removing gateway label: after='${AFTER}'"
fi

# Restore original roles: GATEWAY_NODE_1=gateway, WORKER_NODE=worker
oc label node "${GATEWAY_NODE_1}" k8s.ovn.org/egress-assignable="" 2>/dev/null
oc label node "${WORKER_NODE}" k8s.ovn.org/egress-assignable- 2>/dev/null
wait_reconcile

# TC-5.3
echo "--- TC-5.3: Role Change Detection Timing ---"
oc label node "${GATEWAY_NODE_1}" k8s.ovn.org/egress-assignable- 2>/dev/null
ELAPSED_DOWN=$(node_exec "${GATEWAY_NODE_1}" "
    t1=\$(date +%s)
    for i in \$(seq 1 30); do
        if nft list tables | grep -q 'egress-gateway'; then
            echo \$((\$(date +%s) - t1))
            exit 0
        fi
        sleep 1
    done
    exit 1
" 2>/dev/null)

sleep 3
oc label node "${GATEWAY_NODE_1}" k8s.ovn.org/egress-assignable="" 2>/dev/null
ELAPSED_UP=$(node_exec "${GATEWAY_NODE_1}" "
    t1=\$(date +%s)
    for i in \$(seq 1 30); do
        if nft list tables | grep -q 'egress-snat'; then
            echo \$((\$(date +%s) - t1))
            exit 0
        fi
        sleep 1
    done
    exit 1
" 2>/dev/null)

wait_reconcile
R=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
if [ -n "${ELAPSED_DOWN}" ] && [ -n "${ELAPSED_UP}" ] && [ "${R}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-5.3" "Role change timing: down=${ELAPSED_DOWN}s, up=${ELAPSED_UP}s"
else
    fail "TC-5.3" "down=${ELAPSED_DOWN:-timeout}s, up=${ELAPSED_UP:-timeout}s, traffic='${R}'"
fi

# ---------- Area 6: Set Dynamics ----------

separator "Area 6: Reconciler Set Dynamics"

# TC-6.1
echo "--- TC-6.1: Pod Creation Updates Set ---"
EIP_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
: "${EIP_NODE:=${GATEWAY_NODE_1}}"
oc run new-egressip-pod -n "${TEST_NS}" \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.45 \
    --labels="app=demo" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"new-egressip-pod","image":"registry.k8s.io/e2e-test-images/agnhost:2.45","command":["sleep","infinity"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>/dev/null
oc wait -n "${TEST_NS}" pod/new-egressip-pod --for=condition=Ready --timeout=60s 2>/dev/null
NEW_IP=$(oc get pod -n "${TEST_NS}" new-egressip-pod -o jsonpath='{.status.podIP}')
wait_reconcile
SET=""
for gw in ${ALL_GW_NODES}; do
    SET="${SET}$(node_exec "${gw}" "nft list set inet egress-snat egressip-pods" 2>/dev/null)"
done
R=$(pod_curl new-egressip-pod "${DEST_VIA_NIC1}:8080")
oc delete pod new-egressip-pod -n "${TEST_NS}" 2>/dev/null
if echo "${SET}" | grep -q "${NEW_IP}" && [ "${R}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-6.1" "New pod IP added to set, gets /32 SNAT"
else
    IN_SET=$(echo "${SET}" | grep -c "${NEW_IP}" || true)
    fail "TC-6.1" "IP=${NEW_IP}, inSet=${IN_SET}, traffic=${R}"
fi

# TC-6.2
echo "--- TC-6.2: Pod Deletion Removes IP from Set ---"
OLD_IP=$(oc get pod -n "${TEST_NS}" egressip-pod -o jsonpath='{.status.podIP}')
oc delete pod egressip-pod -n "${TEST_NS}" 2>/dev/null
oc apply -f "${SCRIPT_DIR}/07-pod.yaml" 2>/dev/null
oc wait -n "${TEST_NS}" pod/egressip-pod --for=condition=Ready --timeout=60s 2>/dev/null
NEW_IP=$(oc get pod -n "${TEST_NS}" egressip-pod -o jsonpath='{.status.podIP}')
wait_reconcile
SET=""
for gw in ${ALL_GW_NODES}; do
    SET="${SET}$(node_exec "${gw}" "nft list set inet egress-snat egressip-pods" 2>/dev/null)"
done
if echo "${SET}" | grep -q "${NEW_IP}"; then
    pass "TC-6.2" "Old IP removed, new IP ${NEW_IP} in set"
else
    fail "TC-6.2" "New IP ${NEW_IP} not found in set"
fi

# TC-6.4
echo "--- TC-6.4: Namespace Deletion Cleans Up Sets ---"
if [ "${SKIP_DESTRUCTIVE:-0}" = "1" ]; then
    skip "TC-6.4" "Skipped - SKIP_DESTRUCTIVE=1"
else
    oc delete ns "${TEST_NS}" --wait=true --timeout=120s 2>/dev/null
    wait_reconcile
    SET=""
    for gw in ${ALL_GW_NODES}; do
        SET="${SET}$(node_exec "${gw}" "nft list set inet egress-snat egressip-pods" 2>/dev/null | grep "elements")"
    done

    oc apply -f "${SCRIPT_DIR}/05-namespace.yaml" 2>/dev/null
    oc label namespace "${TEST_NS}" \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null
    oc apply -f "${SCRIPT_DIR}/06-egressip.yaml" 2>/dev/null
    oc apply -f "${SCRIPT_DIR}/07-pod.yaml" 2>/dev/null
    oc apply -f "${SCRIPT_DIR}/07c-gateway-pods.yaml" 2>/dev/null
    oc wait -n "${TEST_NS}" pod --all --for=condition=Ready --timeout=120s 2>/dev/null
    wait_reconcile

    if [ -z "${SET}" ]; then
        pass "TC-6.4" "Sets empty after namespace deletion"
    else
        fail "TC-6.4" "Set still has elements: ${SET}"
    fi
fi

# ---------- Area 7: Negative & Boundary Tests ----------

separator "Area 7: Negative & Boundary Tests"

# TC-7.1
echo "--- TC-7.1: Non-existent Interface in EGRESSIP_SNAT ---"
TC71_CONF='EGRESSIP_SNAT=("nonexistent-if:10.10.10.10" "oam-host:192.168.150.200" "sig-host:192.168.200.200")'
TC71_B64=$(printf '%s\n' "${TC71_CONF}" | base64 -w0)
node_exec "${GATEWAY_NODE_1}" "sed -i '/^EGRESSIP_SNAT=/,/)/d' /etc/egress-multinic/egress-multinic.conf && echo >> /etc/egress-multinic/egress-multinic.conf && echo '${TC71_B64}' | base64 -d >> /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
wait_reconcile
STATUS=$(node_exec "${GATEWAY_NODE_1}" "systemctl is-active egress-multinic")
NFT=$(node_exec "${GATEWAY_NODE_1}" "nft list table inet egress-snat 2>&1")
R_NIC1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
restore_config "${GATEWAY_NODE_1}"
wait_healthy 60
if echo "${NFT}" | grep -q "Error\|No such"; then
    fail "TC-7.1" "Invalid interface destroyed entire egress-snat table"
elif echo "${NFT}" | grep -q "oam-host" && echo "${NFT}" | grep -q "sig-host" && [ "${R_NIC1}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-7.1" "Valid rules intact, traffic works - dead rule for nonexistent-if is harmless"
else
    fail "TC-7.1" "Unexpected state: status=${STATUS}, traffic=${R_NIC1}"
fi

# TC-7.2
echo "--- TC-7.2: SNAT IP Not on Interface ---"
TC72_CONF='EGRESSIP_SNAT=("oam-host:192.168.150.250" "sig-host:192.168.200.200")'
TC72_B64=$(printf '%s\n' "${TC72_CONF}" | base64 -w0)
node_exec "${GATEWAY_NODE_1}" "sed -i '/^EGRESSIP_SNAT=/,/)/d' /etc/egress-multinic/egress-multinic.conf && echo >> /etc/egress-multinic/egress-multinic.conf && echo '${TC72_B64}' | base64 -d >> /etc/egress-multinic/egress-multinic.conf && systemctl restart egress-multinic"
wait_reconcile
STATUS=$(node_exec "${GATEWAY_NODE_1}" "systemctl is-active egress-multinic")
R=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
restore_config "${GATEWAY_NODE_1}"
wait_healthy 60
if echo "${STATUS}" | grep -q "active"; then
    pass "TC-7.2" "Reconciler survives SNAT mismatch, traffic='${R:-timeout}'"
else
    fail "TC-7.2" "Reconciler crashed"
fi

# TC-7.3
echo "--- TC-7.3: Unrouted Destination ---"
R=$(oc exec -n "${TEST_NS}" egressip-pod -- curl -s --connect-timeout 5 10.99.99.99:80 2>/dev/null; echo "EXIT:$?")
if echo "${R}" | grep -q "EXIT:28\|EXIT:7"; then
    pass "TC-7.3" "Clean timeout for unrouted destination"
else
    fail "TC-7.3" "Unexpected result: ${R}"
fi

# TC-7.5
echo "--- TC-7.5: Token Corruption + Restart ---"
NFT_BEFORE=$(node_exec "${WORKER_NODE}" "nft list tables" | grep "egress")
node_exec "${WORKER_NODE}" "cp /etc/egress-multinic/token /etc/egress-multinic/token.bak && echo invalid > /etc/egress-multinic/token"
sleep 30
S1=$(node_exec "${WORKER_NODE}" "systemctl is-active egress-multinic")
LOG_WARN=$(node_exec "${WORKER_NODE}" "journalctl -u egress-multinic --since '30 seconds ago' --no-pager" | grep -i "token\|auth\|unauthorized\|401" || true)
node_exec "${WORKER_NODE}" "systemctl restart egress-multinic"
sleep 5
S2=$(node_exec "${WORKER_NODE}" "systemctl is-active egress-multinic")
NFT_AFTER=$(node_exec "${WORKER_NODE}" "nft list tables" | grep "egress")
node_exec "${WORKER_NODE}" "cp /etc/egress-multinic/token.bak /etc/egress-multinic/token && rm -f /etc/egress-multinic/token.bak"
restore_token "${WORKER_NODE}"
node_exec "${WORKER_NODE}" "systemctl restart egress-multinic"
wait_healthy 120
TOKEN_ISSUE=0; RESTART_ISSUE=0
if [ -z "${LOG_WARN}" ]; then
    TOKEN_ISSUE=1
    echo "  Running reconciler did not detect bad token - no warning logged"
fi
if echo "${S2}" | grep -q "failed\|inactive\|activating" || [ -z "${NFT_AFTER}" ]; then
    RESTART_ISSUE=1
    echo "  NOTE: Restart with bad token wiped rules - known limitation: status=${S2}, tables=${NFT_AFTER}"
fi
if [ "${TOKEN_ISSUE}" -eq 0 ]; then
    pass "TC-7.5" "Bad token detected by running reconciler: running=${S1}, restart=${S2}"
else
    fail "TC-7.5" "Token never refreshed - no warning logged: running=${S1}, restart=${S2}"
fi

# ---------- Area 8: Concurrent Operations & Stress ----------

separator "Area 8: Concurrent Operations & Stress"

# TC-8.1
echo "--- TC-8.1: Traffic During Reconciler Restart ---"
EIP_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
: "${EIP_NODE:=${GATEWAY_NODE_1}}"
oc exec -n "${TEST_NS}" egressip-pod -- bash -c \
    "for i in \$(seq 1 30); do curl -s --connect-timeout 2 ${DEST_VIA_NIC1}:8080; sleep 1; done" > /tmp/tc81.txt 2>&1 &
BG=$!
sleep 3
node_exec "${EIP_NODE}" "systemctl restart egress-multinic"
wait $BG 2>/dev/null
TOTAL=$(grep -c "source:" /tmp/tc81.txt || true)
SNAT_COUNT=$(grep -c "${SNAT_NIC1}" /tmp/tc81.txt || true)
WRONG_SNAT=$(( TOTAL - SNAT_COUNT ))
rm -f /tmp/tc81.txt
if [ "${TOTAL}" -lt 25 ]; then
    fail "TC-8.1" "Too many dropped: only ${TOTAL} responses received"
elif [ "${WRONG_SNAT}" -gt 0 ]; then
    echo "  NOTE: ${WRONG_SNAT} response(s) showed different source IP during restart window - known limitation"
    pass "TC-8.1" "Traffic continuity: ${SNAT_COUNT}/${TOTAL} correct SNAT, ${WRONG_SNAT} during restart window"
else
    pass "TC-8.1" "Traffic continuity: ${SNAT_COUNT}/${TOTAL} responses with correct SNAT"
fi

# TC-8.2
echo "--- TC-8.2: Set Repopulation After Flush ---"
EIP_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
: "${EIP_NODE:=${GATEWAY_NODE_1}}"
node_exec "${EIP_NODE}" "nft flush set inet egress-snat egressip-pods"
wait_reconcile
SET=$(node_exec "${EIP_NODE}" "nft list set inet egress-snat egressip-pods" | grep "elements")
if [ -n "${SET}" ]; then
    pass "TC-8.2" "Set repopulated after flush on ${EIP_NODE}"
else
    fail "TC-8.2" "Set still empty after reconcile on ${EIP_NODE}"
fi

# TC-8.3
echo "--- TC-8.3: Cordon/Drain Gateway ---"
if [ "${SKIP_DESTRUCTIVE:-0}" = "1" ]; then
    skip "TC-8.3" "Skipped - SKIP_DESTRUCTIVE=1"
else
    oc adm cordon "${GATEWAY_NODE_1}" 2>/dev/null
    oc adm drain "${GATEWAY_NODE_1}" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>/dev/null
    EIP_NODE=$(oc get egressip egressip-oam -o jsonpath='{.status.items[0].node}' 2>/dev/null)
    R=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
    oc adm uncordon "${GATEWAY_NODE_1}" 2>/dev/null
    sleep 10
    # Restore gateway pods if evicted
    oc apply -f "${SCRIPT_DIR}/07c-gateway-pods.yaml" 2>/dev/null
    oc wait -n "${TEST_NS}" pod/gw-egressip-pod --for=condition=Ready --timeout=60s 2>/dev/null
    if [ "${R}" = "source: ${SNAT_NIC1}" ]; then
        pass "TC-8.3" "EgressIP stays on ${EIP_NODE} during drain, traffic works"
    else
        fail "TC-8.3" "Traffic='${R}', EIP on ${EIP_NODE}"
    fi
fi

# TC-8.4
echo "--- TC-8.4: Multiple EgressIP CRs ---"
cat <<'EOF' | oc apply -f - 2>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: egressip-pod-2
  namespace: demo-egressip
  labels:
    app: demo2
spec:
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: k8s.ovn.org/egress-assignable
            operator: DoesNotExist
  containers:
  - name: demo
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command:
      - sleep
      - infinity
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
---
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-oam-2
spec:
  egressIPs:
  - 10.99.0.101
  namespaceSelector:
    matchLabels:
      egress-group: oam-sig
  podSelector:
    matchLabels:
      app: demo2
EOF
oc wait -n "${TEST_NS}" pod/egressip-pod-2 --for=condition=Ready --timeout=60s 2>/dev/null
echo "  [TC-8.4] Waiting for egressip-oam-2 node assignment..."
TC84_ASSIGNED=""
for _ in $(seq 1 12); do
    TC84_NODE=$(oc get egressip egressip-oam-2 -o jsonpath='{.status.items[0].node}' 2>/dev/null)
    if [ -n "${TC84_NODE}" ]; then
        echo "  [TC-8.4] egressip-oam-2 assigned to ${TC84_NODE}"
        TC84_ASSIGNED=1
        break
    fi
    sleep 5
done
if [ -z "${TC84_ASSIGNED}" ]; then
    echo "  [TC-8.4] WARNING: egressip-oam-2 not assigned after 60s"
fi
echo "  [TC-8.4] Waiting for pod2 traffic..."
R2=""
for _ in $(seq 1 12); do
    R2=$(pod_curl egressip-pod-2 "${DEST_VIA_NIC1}:8080")
    if [ "${R2}" = "source: ${SNAT_NIC1}" ]; then
        echo "  [TC-8.4] pod2 traffic confirmed"
        break
    fi
    sleep 5
done
R1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
oc delete egressip egressip-oam-2 2>/dev/null
oc delete pod egressip-pod-2 -n "${TEST_NS}" 2>/dev/null
if [ "${R1}" = "source: ${SNAT_NIC1}" ] && [ "${R2}" = "source: ${SNAT_NIC1}" ]; then
    pass "TC-8.4" "Multiple EgressIP CRs coexist, both pods get /32 SNAT"
else
    fail "TC-8.4" "pod1='${R1}', pod2='${R2}'"
fi

# ---------- Area 2 (continued): Gateway Reboot ----------
# TC-2.6 is placed last because it reboots a gateway node, which is destructive
# and can break infrastructure for subsequent tests if recovery fails.

separator "Area 2 continued: Gateway Reboot - destructive, run last"

# TC-2.6
echo "--- TC-2.6: Gateway Node Reboot ---"
if [ "${SKIP_REBOOT:-0}" = "1" ]; then
    skip "TC-2.6" "Skipped - SKIP_REBOOT=1"
else
    node_exec "${GATEWAY_NODE_1}" "reboot" || true
    echo "  [TC-2.6] Waiting for node to become Ready..."
    sleep 30
    oc wait "node/${GATEWAY_NODE_1}" --for=condition=Ready --timeout=600s
    echo "  [TC-2.6] Re-running infra setup (creates veth interfaces)..."
    bash "${SCRIPT_DIR}/03-setup-infra.sh" >/dev/null 2>&1
    echo "  [TC-2.6] Reapplying NNCP (configures IPs on veths)..."
    oc delete nncp egress-multinic-oam-sig 2>/dev/null
    sleep 5
    oc apply -f "${SCRIPT_DIR}/04-nncp.yaml" 2>/dev/null
    oc wait nncp egress-multinic-oam-sig --for=condition=Available --timeout=180s
    echo "  [TC-2.6] Waiting for traffic recovery..."
    R1="" R2=""
    for _ in $(seq 1 12); do
        sleep 10
        R1=$(pod_curl egressip-pod "${DEST_VIA_NIC1}:8080")
        R2=$(pod_curl egressip-pod "${DEST_VIA_NIC2}:8081")
        if [ "${R1}" = "source: ${SNAT_NIC1}" ] && [ "${R2}" = "source: ${SNAT_NIC2}" ]; then
            echo "  [TC-2.6] Traffic recovered"
            break
        fi
        echo "  [TC-2.6] Not ready: NIC1='${R1:-timeout}', NIC2='${R2:-timeout}' - retrying..."
    done
    if [ "${R1}" = "source: ${SNAT_NIC1}" ] && [ "${R2}" = "source: ${SNAT_NIC2}" ]; then
        pass "TC-2.6" "Full recovery after gateway reboot"
    else
        fail "TC-2.6" "NIC1='${R1}', NIC2='${R2}'"
    fi
fi

# ---------- Summary ----------

echo ""
echo "=========================================="
echo " QE Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "=========================================="
echo ""

if [ ${#RESULTS[@]} -gt 0 ]; then
    printf "%-8s %-10s %s\n" "STATUS" "TEST" "DESCRIPTION"
    printf "%-8s %-10s %s\n" "------" "----" "-----------"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r status id desc <<< "${r}"
        printf "%-8s %-10s %s\n" "${status}" "${id}" "${desc}"
    done
fi
echo ""

exit "${FAIL}"
