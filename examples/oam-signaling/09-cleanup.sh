#!/bin/bash
#
# Tears down the OAM/signaling example.
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/09-cleanup.sh

set -euo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."

echo "=== Cleaning up OAM/signaling example ==="

echo "--- Deleting Kubernetes resources ---"
oc delete egressip egressip-oam --ignore-not-found
oc delete namespace demo-egressip --ignore-not-found
oc delete nncp egress-multinic-oam-sig --ignore-not-found

# Delete the MachineConfig and wait for the pool to reconcile before
# deleting the pool. Deleting both simultaneously leaves nodes stuck
# referencing a deleted rendered config.
if oc get machineconfig 99-egress-multinic &>/dev/null; then
    echo "Deleting MachineConfig..."
    oc delete machineconfig 99-egress-multinic
    echo "Waiting for worker MachineConfigPool to finish updating..."
    oc wait machineconfigpool worker --for=condition=Updated=True --timeout=600s 2>/dev/null || true
fi

echo ""
echo "--- Cleaning up gateway node infrastructure ---"
CLEANUP_B64=$(base64 -w0 "${SCRIPT_DIR}/aux/cleanup-node.sh")

GATEWAY_NODES=$(oc get nodes -l k8s.ovn.org/egress-assignable="" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for node in ${GATEWAY_NODES}; do
    echo "Cleaning ${node}..."
    oc debug node/"${node}" -- bash -c "echo ${CLEANUP_B64} | base64 -d | nsenter -t 1 -m -u -i -n -p -- bash" 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use"
done

echo ""
echo "--- Deleting ServiceAccount resources ---"
"${PROJECT_DIR}/setup-serviceaccount.sh" delete

echo ""
echo "=== Cleanup complete ==="
