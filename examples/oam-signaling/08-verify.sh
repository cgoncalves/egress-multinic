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
echo "Note: requires egress-gateway active on worker nodes. Without it, all pod"
echo "      traffic enters via ovn-k8s-mp0 and gets /32 SNAT instead."
oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.250.1:8080 || echo "(failed)"
echo ""

echo "=== Test 4: Non-EgressIP pod -> signaling server (192.168.251.1:8081) ==="
echo "Expected source: 192.168.200.10 (masquerade to host IP on sig-host)"
oc exec -n demo-egressip non-egressip-pod -- curl -s --connect-timeout 5 192.168.251.1:8081 || echo "(failed)"
echo ""

echo "=== Gateway node state (${GATEWAY_NODE}) ==="
VERIFY_B64=$(base64 -w0 "${SCRIPT_DIR}/aux/verify-node.sh")
oc debug node/${GATEWAY_NODE} -- bash -c "echo ${VERIFY_B64} | base64 -d | nsenter -t 1 -m -u -i -n -p -- bash" 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use"
