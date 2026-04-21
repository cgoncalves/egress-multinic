#!/bin/bash
#
# Sets up OAM and signaling network infrastructure on all egress-assignable
# gateway nodes using Linux network namespaces.
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/03-setup-infra.sh

set -euo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATEWAY_NODES=$(oc get nodes -l k8s.ovn.org/egress-assignable="" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [ -z "${GATEWAY_NODES}" ]; then
    echo "ERROR: no nodes found with label k8s.ovn.org/egress-assignable"
    exit 1
fi

NODE_SCRIPT_B64=$(base64 -w0 "${SCRIPT_DIR}/aux/setup-infra-node.sh")

for node in ${GATEWAY_NODES}; do
    echo "=== Setting up infrastructure on ${node} ==="
    oc debug node/"${node}" -- bash -c "echo ${NODE_SCRIPT_B64} | base64 -d | nsenter -t 1 -m -u -i -n -p -- bash"
    echo ""
done
