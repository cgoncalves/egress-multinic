#!/bin/bash
#
# Verifies the OAM/signaling example.
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/08-verify.sh

set -euo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_NODE="${GATEWAY_NODE:-$(oc get nodes -l k8s.ovn.org/egress-assignable="" -o jsonpath='{.items[0].metadata.name}')}"

echo "=== EgressIP status ==="
oc get egressip egressip-oam -o jsonpath='{.status}' | python3 -m json.tool 2>/dev/null || \
    oc get egressip egressip-oam -o yaml
echo ""

# --- Tests on worker nodes ---

echo "=== Test 1: EgressIP pod -> OAM server (192.168.250.1:8080) ==="
echo "Expected source: 192.168.150.200 (SNAT /32 on oam-host)"
oc exec -n demo-egressip egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
echo ""

echo "=== Test 2: EgressIP pod -> signaling server (192.168.251.1:8081) ==="
echo "Expected source: 192.168.200.200 (SNAT /32 on sig-host)"
oc exec -n demo-egressip egressip-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 || echo "(failed)"
echo ""

echo "=== Test 3: Non-EgressIP pod -> OAM server (192.168.250.1:8080) ==="
echo "Expected source: 192.168.150.10 (masquerade to host IP on oam-host)"
oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
echo ""

echo "=== Test 4: Non-EgressIP pod -> signaling server (192.168.251.1:8081) ==="
echo "Expected source: 192.168.200.10 (masquerade to host IP on sig-host)"
oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 || echo "(failed)"
echo ""

# --- EgressService tests ---

LB_IP=$(oc get svc egressservice-lb -n demo-egressip -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -n "${LB_IP}" ]; then
    echo "=== Test 5: EgressService pod -> OAM server (192.168.250.1:8080) ==="
    echo "Expected source: ${LB_IP} (EgressService SNAT to LoadBalancer IP)"
    oc exec -n demo-egressip egressservice-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
    echo ""

    echo "=== Test 6: EgressService pod -> signaling server (192.168.251.1:8081) ==="
    echo "Expected source: ${LB_IP} (EgressService SNAT to LoadBalancer IP)"
    oc exec -n demo-egressip egressservice-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 || echo "(failed)"
    echo ""
else
    echo "=== Tests 5-6: EgressService (SKIPPED - no LoadBalancer IP) ==="
    echo ""
fi

# --- Tests on gateway node ---

if oc get pod -n demo-egressip gw-egressip-pod &>/dev/null; then
    echo "=== Test 7: EgressIP pod ON GATEWAY -> OAM server (192.168.250.1:8080) ==="
    echo "Expected source: 192.168.150.200 (SNAT /32 -- ovn-k8s-mp0 traffic on gateway)"
    oc exec -n demo-egressip gw-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
    echo ""

    echo "=== Test 8: Non-EgressIP pod ON GATEWAY -> OAM server (192.168.250.1:8080) ==="
    echo "Expected source: 192.168.150.200 (SNAT /32 -- ovn-k8s-mp0 traffic on gateway)"
    echo "Note: all ovn-k8s-mp0 traffic on the gateway gets /32 SNAT regardless of"
    echo "      EgressIP association. See 'experimental' branch for set-based fix."
    oc exec -n demo-egressip gw-non-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
    echo ""

    GW_LB_IP=$(oc get svc gw-egressservice-lb -n demo-egressip -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "${GW_LB_IP}" ]; then
        echo "=== Test 9: EgressService pod ON GATEWAY -> OAM server (192.168.250.1:8080) ==="
        echo "Expected source: ${GW_LB_IP} (EgressService SNAT to LoadBalancer IP)"
        oc exec -n demo-egressip gw-egressservice-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
        echo ""
    else
        echo "=== Test 9: EgressService on gateway (SKIPPED - no LoadBalancer IP) ==="
        echo ""
    fi
else
    echo "=== Tests 7-9: Gateway node pods (SKIPPED - pods not deployed) ==="
    echo ""
fi

echo "=== Gateway node state (${GATEWAY_NODE}) ==="
VERIFY_B64=$(base64 -w0 "${SCRIPT_DIR}/aux/verify-node.sh")
oc debug node/${GATEWAY_NODE} -- bash -c "echo ${VERIFY_B64} | base64 -d | nsenter -t 1 -m -u -i -n -p -- bash" 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use"
