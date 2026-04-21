#!/bin/bash
# Creates the ServiceAccount and extracts credentials for the example.
#
# Usage:
#   export KUBECONFIG=<path>
#   bash examples/oam-signaling/00-setup-serviceaccount.sh

set -euo pipefail

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."

"${PROJECT_DIR}/setup-serviceaccount.sh" create \
    -o "${SCRIPT_DIR}/aux"

# Copy API_SERVER from the project config (updated by setup-serviceaccount.sh)
# into the example config used by generate-machineconfig.sh.
API_SERVER=$(grep "^API_SERVER=" "${PROJECT_DIR}/egress-multinic.conf" | cut -d'"' -f2)
sed -i "s|^API_SERVER=.*|API_SERVER=\"${API_SERVER}\"|" "${SCRIPT_DIR}/egress-multinic.conf"
echo "Updated API_SERVER in ${SCRIPT_DIR}/egress-multinic.conf"
