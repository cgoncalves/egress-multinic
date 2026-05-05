#!/bin/bash
#
# Verifies the OAM/signaling example.
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/08-verify.sh

set -uo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_NODE="${GATEWAY_NODE:-$(oc get nodes -l k8s.ovn.org/egress-assignable="" -o jsonpath='{.items[0].metadata.name}')}"

PASS=0
FAIL=0
SKIP=0

check_source() {
    local test_name="$1" expected="$2" actual="$3"
    if [ "$actual" = "source: ${expected}" ]; then
        echo "[PASS] ${test_name}"
        echo "  ${actual}"
        ((PASS++))
    else
        echo "[FAIL] ${test_name}"
        echo "  expected: source: ${expected}"
        echo "  got:      ${actual}"
        ((FAIL++))
    fi
    echo ""
}

check_ok() {
    local test_name="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "[PASS] ${test_name}"
        ((PASS++))
    else
        echo "[FAIL] ${test_name}"
        echo "  ${result}"
        ((FAIL++))
    fi
    echo ""
}

echo "=== EgressIP status ==="
oc get egressip egressip-oam -o jsonpath='{.status}' | python3 -m json.tool 2>/dev/null || \
    oc get egressip egressip-oam -o yaml
echo ""

# --- Tests on worker nodes (iifname differentiation works) ---

RESULT=$(oc exec -n demo-egressip egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
check_source "Test 1: EgressIP pod -> OAM (expect /32 192.168.150.200)" "192.168.150.200" "$RESULT"

RESULT=$(oc exec -n demo-egressip egressip-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 2>/dev/null || echo "(failed)")
check_source "Test 2: EgressIP pod -> signaling (expect /32 192.168.200.200)" "192.168.200.200" "$RESULT"

RESULT=$(oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
check_source "Test 3: Non-EgressIP pod -> OAM (expect host 192.168.150.10)" "192.168.150.10" "$RESULT"

RESULT=$(oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 2>/dev/null || echo "(failed)")
check_source "Test 4: Non-EgressIP pod -> signaling (expect host 192.168.200.10)" "192.168.200.10" "$RESULT"

# --- EgressService tests ---

LB_IP=$(oc get svc egressservice-lb -n demo-egressip -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -n "${LB_IP}" ]; then
    RESULT=$(oc exec -n demo-egressip egressservice-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
    check_source "Test 5: EgressService pod -> OAM (expect LB ${LB_IP})" "${LB_IP}" "$RESULT"

    RESULT=$(oc exec -n demo-egressip egressservice-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 2>/dev/null || echo "(failed)")
    check_source "Test 6: EgressService pod -> signaling (expect LB ${LB_IP})" "${LB_IP}" "$RESULT"
else
    echo "[SKIP] Tests 5-6: EgressService (no LoadBalancer IP)"
    echo ""
    ((SKIP+=2))
fi

# --- Tests on gateway node (all ovn-k8s-mp0 traffic gets /32 SNAT) ---

if oc get pod -n demo-egressip gw-egressip-pod &>/dev/null; then
    RESULT=$(oc exec -n demo-egressip gw-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
    check_source "Test 7: EgressIP pod ON GATEWAY -> OAM (expect /32 192.168.150.200)" "192.168.150.200" "$RESULT"

    RESULT=$(oc exec -n demo-egressip gw-non-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
    check_source "Test 8: Non-EgressIP pod ON GATEWAY -> OAM (expect host 192.168.150.10)" "192.168.150.10" "$RESULT"

    GW_LB_IP=$(oc get svc gw-egressservice-lb -n demo-egressip -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "${GW_LB_IP}" ]; then
        RESULT=$(oc exec -n demo-egressip gw-egressservice-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 2>/dev/null || echo "(failed)")
        check_source "Test 9: EgressService pod ON GATEWAY -> OAM (expect LB ${GW_LB_IP})" "${GW_LB_IP}" "$RESULT"
    else
        echo "[SKIP] Test 9: EgressService on gateway (no LoadBalancer IP)"
        echo ""
        ((SKIP++))
    fi
else
    echo "[SKIP] Tests 7-9: Gateway node pods (not deployed)"
    echo ""
    ((SKIP+=3))
fi

# --- Sanity checks ---

HTTP_CODE=$(oc exec -n demo-egressip non-egressip-pod -- curl -s --max-time 10 -o /dev/null -w "%{http_code}" http://1.1.1.1:80 2>/dev/null)
if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    check_ok "Test 10: Non-EgressIP pod -> external via br-ex (HTTP ${HTTP_CODE})" "ok"
else
    check_ok "Test 10: Non-EgressIP pod -> external via br-ex" "HTTP ${HTTP_CODE:-timeout}"
fi

DNS_RESULT=$(oc exec -n demo-egressip egressip-pod -- getent hosts kubernetes.default.svc.cluster.local 2>/dev/null)
if [ -n "$DNS_RESULT" ]; then
    check_ok "Test 11: Cluster DNS resolution" "ok"
else
    check_ok "Test 11: Cluster DNS resolution" "resolution failed"
fi

NODE_IP=$(oc get node "${GATEWAY_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
KUBELET_CODE=$(oc exec -n demo-egressip egressip-pod -- curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "https://${NODE_IP}:10250/healthz" 2>/dev/null)
if [ "$KUBELET_CODE" = "200" ] || [ "$KUBELET_CODE" = "401" ] || [ "$KUBELET_CODE" = "403" ]; then
    check_ok "Test 12: Pod-to-Node connectivity (HTTP ${KUBELET_CODE} to ${NODE_IP})" "ok"
else
    check_ok "Test 12: Pod-to-Node connectivity (${NODE_IP})" "HTTP ${KUBELET_CODE:-timeout}"
fi

# --- Summary ---

echo "=========================================="
echo " Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "=========================================="
echo ""

# --- Gateway node state ---

echo "=== Gateway node state (${GATEWAY_NODE}) ==="
VERIFY_B64=$(base64 -w0 "${SCRIPT_DIR}/aux/verify-node.sh")
oc debug node/${GATEWAY_NODE} -- bash -c "echo ${VERIFY_B64} | base64 -d | nsenter -t 1 -m -u -i -n -p -- bash" 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use"
