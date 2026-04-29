#!/bin/bash
#
# Node-level script that sets up OAM and signaling network namespaces.
# Called by 01-setup-infra.sh.

set -uo pipefail

setup_netns() {
    local ns=$1 veth_host=$2 veth_ns=$3 host_ip=$4 router_ip=$5
    local dummy_name=$6 dummy_ip=$7 dest_cidr=$8 listen_port=$9

    echo "--- Setting up netns: ${ns} ---"

    # Create network namespace
    ip netns add "${ns}" 2>/dev/null || echo "  netns ${ns} already exists"

    # Create veth pair and move peer into netns
    if ip link show "${veth_host}" &>/dev/null; then
        echo "  veth ${veth_host} already exists"
    else
        ip link add "${veth_host}" type veth peer name "${veth_ns}"
        ip link set "${veth_ns}" netns "${ns}"
    fi

    # Configure host side
    ip addr add "${host_ip}/24" dev "${veth_host}" 2>/dev/null || true
    ip link set "${veth_host}" up
    ip route add "${dest_cidr}" via "${router_ip}" dev "${veth_host}" 2>/dev/null || true

    # Configure netns side (acts as external router)
    ip netns exec "${ns}" bash -c "
        ip addr add ${router_ip}/24 dev ${veth_ns} 2>/dev/null || true
        ip link set ${veth_ns} up
        ip link set lo up
        sysctl -q -w net.ipv4.ip_forward=1

        # Dummy interface simulating external host
        ip link add ${dummy_name} type dummy 2>/dev/null || true
        ip link set ${dummy_name} up
        ip addr add ${dummy_ip}/32 dev ${dummy_name} 2>/dev/null || true
        ip route add ${dest_cidr} dev ${dummy_name} 2>/dev/null || true
    "

    # Start HTTP listener that returns the client source IP.
    # Uses systemd-run to create a transient service that persists after
    # the oc debug session exits.
    cat > /usr/local/bin/http-echo-server.py << 'PYEOF'
import http.server, socketserver, sys

port = int(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"source: {self.client_address[0]}\n".encode())
    def log_message(self, *args):
        pass

with socketserver.TCPServer(("", port), Handler) as s:
    s.serve_forever()
PYEOF
    chmod 755 /usr/local/bin/http-echo-server.py

    systemctl stop http-server-${ns}.service 2>/dev/null || true
    systemd-run --unit=http-server-${ns} \
        --property=SELinuxContext=unconfined_u:unconfined_r:unconfined_t:s0 \
        nsenter --net=/var/run/netns/"${ns}" \
        python3 /usr/local/bin/http-echo-server.py "${listen_port}"

    # Add default route so replies to any external IP (e.g., MetalLB LB IPs)
    # can reach the gateway node via the veth pair.
    ip netns exec "${ns}" bash -c "
        ip route add default via ${host_ip} 2>/dev/null || true
    "

    echo "  HTTP listener on port ${listen_port} in netns ${ns}"
}

# OAM network
setup_netns "oam" \
    "oam-host" "oam-ns" \
    "192.168.150.10" "192.168.150.1" \
    "oam-ext" "192.168.250.1" \
    "192.168.250.0/24" \
    8080

# Signaling network
setup_netns "signaling" \
    "sig-host" "sig-ns" \
    "192.168.200.10" "192.168.200.1" \
    "sig-ext" "192.168.251.1" \
    "192.168.251.0/24" \
    8081

echo ""
echo "=== Infrastructure ready ==="
echo "OAM server:       192.168.250.1:8080 (via oam-host)"
echo "Signaling server: 192.168.251.1:8081 (via sig-host)"
