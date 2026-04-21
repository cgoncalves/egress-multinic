# Egress Multi-NIC

Egress traffic routing and EgressIP destination-based routing for OpenShift clusters with multiple network interfaces.

## Overview

This solution combines two capabilities:

1. **Egress gateway**: routes Pod egress traffic through designated gateway nodes (labeled `k8s.ovn.org/egress-assignable=""`), with SNAT to the gateway node's IP. Non-EgressIP pod traffic is masqueraded to the gateway's host IP on the outgoing interface.

2. **EgressIP multi-NIC SNAT**: on gateway nodes with multiple network interfaces, EgressIP-bound pod traffic is routed to alternate interfaces based on destination IP and SNAT'd to an admin-configured /32 IP address per interface (instead of the EgressIP address assigned by OVN).

A bash reconciler script runs as a systemd service on every worker node. It self-determines whether the node is a gateway or a regular worker and configures nftables rules and policy routing accordingly. Gateway node health is monitored via API status checks and direct ping probes, with automatic failover.

### Traffic differentiation on gateway nodes

EgressIP traffic enters the gateway node via OVN's Geneve tunnel (`ovn-k8s-mp0`). Egress-gateway traffic enters via the physical network (`br-ex`). The reconciler uses the ingress interface (`iifname`) in the nftables forward chain to distinguish the two:

- **EgressIP traffic** (`iifname "ovn-k8s-mp0"`): not marked, SNAT'd to the admin-configured /32 IP on the outgoing interface.
- **Egress-gateway traffic** (all other forwarded non-cluster traffic): marked with `0x3000`, masqueraded to the outgoing interface's host IP.

## Prerequisites

- **OVN-Kubernetes** with `routingViaHost: true` and `ipForwarding: Global`:
  ```bash
  oc apply -f network-operator-patch.yaml
  ```
- **Gateway node label**: `oc label node <node> k8s.ovn.org/egress-assignable=""`
- **kubernetes-nmstate operator**: installed for NNCP-based interface configuration
- **IP reachability**: between worker and gateway nodes

## Configuration

All configuration lives in `egress-multinic.conf` (deployed to `/etc/egress-multinic/egress-multinic.conf`).

### Egress gateway

| Variable | Default | Description |
|----------|---------|-------------|
| `POD_CIDRS` | `10.132.0.0/14` | Pod IPs/CIDRs to route (nftables set syntax) |
| `EXCLUDE_CIDRS` | Pod, Service, Machine, link-local CIDRs | Destinations excluded from routing |
| `POD_CIDRS_V6` | *(empty)* | IPv6 Pod CIDRs (optional) |
| `EXCLUDE_CIDRS_V6` | *(empty)* | IPv6 exclusions (required if `POD_CIDRS_V6` is set) |
| `FWMARK` | `0x2000` | Packet mark for policy routing |
| `RT_TABLE` | `100` | Routing table number |
| `RT_PRIO` | `1000` | ip rule priority |
| `RECONCILE_INTERVAL` | `10` | Seconds between reconciliation cycles |
| `PING_TIMEOUT` | `2` | Health probe timeout |
| `FIB_MULTIPATH_HASH_POLICY` | `1` | ECMP hash policy (0=L3, 1=L4) |

### EgressIP multi-NIC SNAT

| Variable | Default | Description |
|----------|---------|-------------|
| `EGRESSIP_SNAT` | `()` | Array of `"INTERFACE:SNAT_IP"` pairs for per-interface SNAT |
| `OVN_MGMT_PORT` | `ovn-k8s-mp0` | OVN management port name (used to identify EgressIP traffic) |

### API access

| Variable | Default | Description |
|----------|---------|-------------|
| `API_SERVER` | *(empty)* | API server URL (auto-populated by `setup-serviceaccount.sh`) |
| `CA_FILE` | `/etc/egress-multinic/ca.crt` | Path to API server CA certificate |
| `TOKEN_FILE` | `/etc/egress-multinic/token` | Path to ServiceAccount token |

## Deployment

### Step 1: Label gateway nodes

```bash
oc label node <node-name> k8s.ovn.org/egress-assignable=""
```

### Step 2: Create ServiceAccount and extract credentials

```bash
./setup-serviceaccount.sh create -o /tmp/egress-multinic-creds
```

### Step 3: Edit the configuration

Edit `egress-multinic.conf`:
- Set `POD_CIDRS` and `EXCLUDE_CIDRS` for your cluster
- Set `EGRESSIP_SNAT` with `"INTERFACE:SNAT_IP"` pairs for each alternate interface on the gateway nodes

### Step 4: Generate the MachineConfig

```bash
./generate-machineconfig.sh \
  -a /tmp/egress-multinic-creds/ca.crt \
  -k /tmp/egress-multinic-creds/token
```

### Step 5: Apply the node disruption policy (optional, recommended)

```bash
oc apply -f machineconfiguration-patch.yaml
```

Restarts the service instead of rebooting when script/config/credentials change.

### Step 6: Apply the MachineConfig

```bash
oc apply -f machineconfig-egress-multinic-final.yaml
```

### Step 7: Configure alternate interfaces (NNCP)

Create a NNCP per gateway node using `nncp-template.yaml` as a starting point. Each NNCP configures:
- Interface IPs (/24) and SNAT IPs (/32)
- Static routes for destination-based routing
- IP routing policy rules at priority 5550

### Step 8: Create EgressIP resources

Create EgressIP CRs using `egressip-template.yaml`. Each EgressIP address must be in the subnet of an interface on the gateway node.

### Step 9: Verify

```bash
# Check reconciler logs:
oc debug node/<node> -- chroot /host journalctl -u egress-multinic -f

# Check nftables on gateway node:
oc debug node/<gateway> -- chroot /host nft list table inet egress-snat
```

## Files

| File | Description |
|------|-------------|
| `egress-multinic-reconciler.sh` | Reconciler script deployed to gateway and worker nodes |
| `egress-multinic.conf` | Configuration file (edit for your environment) |
| `machineconfig-egress-multinic.yaml` | MachineConfig template |
| `generate-machineconfig.sh` | Generates final MachineConfig with encoded credentials |
| `setup-serviceaccount.sh` | Creates/deletes ServiceAccount and RBAC resources |
| `machineconfiguration-patch.yaml` | Node disruption policy (restart instead of reboot) |
| `network-operator-patch.yaml` | Network operator prerequisites |
| `nncp-template.yaml` | NNCP template for alternate interfaces |
| `egressip-template.yaml` | EgressIP CR template |

## Limitations

- Each alternate (non-OVN) interface supports exactly **one SNAT IP** for all EgressIP traffic. Per-pod EgressIP source address differentiation is only available on the OVN interface (`br-ex`).
- The `iifname` differentiation between EgressIP and egress-gateway traffic requires both capabilities to be deployed together. Without egress-gateway active on worker nodes, all pod traffic enters gateway nodes via `ovn-k8s-mp0` and receives the /32 SNAT.
- Pods must be scheduled on **non-gateway worker nodes** (not on nodes labeled `k8s.ovn.org/egress-assignable`). Pods on gateway nodes send traffic through OVN locally via `ovn-k8s-mp0`, bypassing the egress-gateway worker-mode routing. This means all traffic from pods on gateway nodes -- whether EgressIP-associated or not -- gets /32 SNAT on alternate interfaces. The `iifname` differentiation only works when traffic traverses the physical network from a worker to the gateway. Use node affinity with `k8s.ovn.org/egress-assignable DoesNotExist` to avoid scheduling on gateway nodes.
- The per-interface SNAT rules match on the **outgoing interface**, not on EgressIP association. Any traffic exiting an alternate interface (due to destination-based routing via NNCP) is SNAT'd to the /32 IP, regardless of whether an EgressIP CR exists. The NNCP ip rules and routes determine which traffic reaches the alternate interfaces; the SNAT rules apply unconditionally to traffic that does.
- EgressIP multi-NIC SNAT IPs (`EGRESSIP_SNAT`) are configured in the reconciler config file and apply to all gateway nodes. If different gateway nodes need different SNAT IPs, see [Per-Node SNAT IPs](#per-node-snat-ips) below.
- Requires `routingViaHost: true` and `ipForwarding: Global`.
- Double SNAT for egress-gateway traffic: Pod IP -> Worker IP (OVN-K) -> Gateway IP (masquerade).
- ECMP failover breaks existing connections through the failed gateway node.

## Per-Node SNAT IPs

When gateway nodes require different SNAT IPs on the same interfaces (e.g., `ens1f0` has IP `192.168.10.200` on gateway-1 and `192.168.10.201` on gateway-2), you need per-node config files and MachineConfigs.

The approach uses a custom MachineConfigPool per gateway node group. The base MachineConfig (role: `worker`) deploys the script, systemd unit, CA, and token -- these are the same for all nodes. A separate MachineConfig per node (or node group) deploys only the config file with the node-specific `EGRESSIP_SNAT` array.

### Step 1: Create per-node config files

Copy `egress-multinic.conf` for each gateway node and set the `EGRESSIP_SNAT` array:

```bash
cp egress-multinic.conf egress-multinic-gateway1.conf
cp egress-multinic.conf egress-multinic-gateway2.conf
```

Edit each file to set the node-specific SNAT IPs:

```bash
# egress-multinic-gateway1.conf
EGRESSIP_SNAT=(
    "ens1f0:192.168.10.200"
    "ens1f1:192.168.20.200"
)

# egress-multinic-gateway2.conf
EGRESSIP_SNAT=(
    "ens1f0:192.168.10.201"
    "ens1f1:192.168.20.201"
)
```

### Step 2: Generate the base MachineConfig

Generate the base MachineConfig using any one of the config files (all non-SNAT settings are identical):

```bash
./generate-machineconfig.sh \
  -a /tmp/egress-multinic-creds/ca.crt \
  -k /tmp/egress-multinic-creds/token \
  -c egress-multinic-gateway1.conf
```

### Step 3: Create a MachineConfigPool per gateway node

```yaml
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: gateway-node1
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: ["worker", "gateway-node1"]
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: gateway-node1.example.com
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: gateway-node2
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: ["worker", "gateway-node2"]
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: gateway-node2.example.com
```

Each pool inherits all `worker` MachineConfigs (including the base `99-egress-multinic`) and adds node-specific ones.

### Step 4: Create per-node MachineConfigs for the config file

Each MachineConfig deploys only the config file with the node-specific `EGRESSIP_SNAT`:

```bash
# For gateway-node1:
CONFIG_B64=$(base64 -w0 < egress-multinic-gateway1.conf)
cat > machineconfig-egress-multinic-gateway1.yaml << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-egress-multinic-config-gateway1
  labels:
    machineconfiguration.openshift.io/role: gateway-node1
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/egress-multinic/egress-multinic.conf
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,${CONFIG_B64}
EOF

# Repeat for gateway-node2 with egress-multinic-gateway2.conf
```

### Step 5: Apply

```bash
# Apply MachineConfigPools
oc apply -f machineconfig-gateway-pools.yaml

# Apply per-node config MachineConfigs
oc apply -f machineconfig-egress-multinic-gateway1.yaml
oc apply -f machineconfig-egress-multinic-gateway2.yaml

# Wait for each pool to update
oc wait machineconfigpool gateway-node1 --for=condition=Updated=True --timeout=600s
oc wait machineconfigpool gateway-node2 --for=condition=Updated=True --timeout=600s
```

### Cleanup order

When removing per-node MachineConfigPools, delete the per-node config MachineConfigs first, wait for the pool to reconcile, then delete the pool:

```bash
oc delete machineconfig 99-egress-multinic-config-gateway1
oc wait machineconfigpool gateway-node1 --for=condition=Updated=True --timeout=600s
oc delete machineconfigpool gateway-node1
oc wait machineconfigpool worker --for=condition=Updated=True --timeout=600s
```

Reversing this order leaves nodes stuck referencing a deleted rendered config.

## Example

See [`examples/oam-signaling/`](examples/oam-signaling/) for a complete working example with OAM and signaling networks using Linux network namespaces.
