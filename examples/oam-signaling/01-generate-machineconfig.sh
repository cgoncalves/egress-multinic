#!/bin/bash
# Generates the MachineConfig for the OAM/signaling example.
#
# Usage:
#   bash examples/oam-signaling/01-generate-machineconfig.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."

"${PROJECT_DIR}/generate-machineconfig.sh" \
    -a "${SCRIPT_DIR}/aux/ca.crt" \
    -k "${SCRIPT_DIR}/aux/token" \
    -c "${SCRIPT_DIR}/egress-multinic.conf" \
    -o "${SCRIPT_DIR}/02-machineconfig-final.yaml"
