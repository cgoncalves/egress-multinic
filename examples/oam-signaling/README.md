# Example: OAM and Signaling Networks

This example demonstrates the egress-multinic solution using simulated OAM and signaling networks. Linux network namespaces on the gateway node create veth-pair interfaces with HTTP servers that report the client's source IP, allowing verification of the SNAT behavior.

## Network Topology

```
                        Worker Node                              Gateway Node (egress-assignable)
                   (dhcp-105-228)                                      (cnfdc6)
              +-----------------------+                    +----------------------------------+
              |                       |                    |                                  |
              |  +----------------+   |                    |                                  |
              |  | egressip-pod   |   |                    |    oam-host (veth)               |
              |  | 10.132.x.x     |   |                    |    192.168.150.10/24             |
              |  | label: app=demo|   |                    |    192.168.150.200/32  (SNAT IP) |
              |  +-------+--------+   |                    |    192.168.150.100/32  (EgressIP)|
              |          |            |                    |         |                        |
              |  +-------+--------+   |                    |    sig-host (veth)               |
              |  |non-egressip-pod|   |                    |    192.168.200.10/24             |
              |  | 10.132.x.x     |   |                    |    192.168.200.200/32  (SNAT IP) |
              |  | (no EgressIP)  |   |                    |         |                        |
              |  +-------+--------+   |                    |    br-ex                         |
              |          |            |                    |    10.6.105.51/24                |
              |    ovn-k8s-mp0        |                    |    ovn-k8s-mp0                   |
              |    br-ex              |                    |         |                        |
              |    10.6.105.228/24    |                    +---------|------------------------+
              +----------|------------ +                             |
                         |                                           |
                         +------ Physical Network (10.6.105.0/24) ---+
```

### Simulated External Networks (netns on gateway node)

```
  Gateway Node
  +----------------------------------+
  |                                  |
  |   oam-host  <--- veth pair --->  netns "oam"
  |   .10/24                         |  oam-ns: 192.168.150.1/24 (router)
  |                                  |  oam-ext: 192.168.250.1/32 (server)
  |                                  |  HTTP :8080
  |                                  |
  |   sig-host  <--- veth pair --->  netns "signaling"
  |   .10/24                         |  sig-ns: 192.168.200.1/24 (router)
  |                                  |  sig-ext: 192.168.251.1/32 (server)
  |                                  |  HTTP :8081
  |                                  |
  +----------------------------------+
```

## Traffic Flows

### Flow 1: EgressIP pod -> OAM server (192.168.250.1)

The EgressIP pod's traffic is handled by OVN and arrives at the gateway via
the Geneve tunnel. Destination-based routing sends it out oam-host, where it
is SNAT'd to the admin-configured /32 IP.

```
egressip-pod (10.132.x.x)
    |
    | OVN Geneve tunnel
    v
Gateway: ovn-k8s-mp0
    |
    | ip rule 5550: to 192.168.250.0/24 -> main table
    | main table: 192.168.250.0/24 via 192.168.150.1 dev oam-host
    v
Gateway: oam-host
    |
    | nftables postrouting:
    |   iifname "ovn-k8s-mp0" -> not marked (skipped in forward chain)
    |   oifname "oam-host" -> snat ip to 192.168.150.200
    v
netns "oam": HTTP server sees source: 192.168.150.200
```

### Flow 2: Non-EgressIP pod -> OAM server (192.168.250.1)

The non-EgressIP pod's traffic is routed by the egress-gateway on the worker
node. It arrives at the gateway via the physical network (br-ex) and is
masqueraded to the host IP.

```
non-egressip-pod (10.132.x.x)
    |
    | Worker nftables prerouting: mark 0x2000
    | Worker ip rule 1000: fwmark 0x2000 -> table 100
    | Worker OVN-K masquerade: src -> 10.6.105.228 (worker IP)
    v
Gateway: br-ex (arrives via physical network)
    |
    | nftables forward:
    |   iifname != "ovn-k8s-mp0" -> mark 0x3000
    |
    | ip rule 5550: to 192.168.250.0/24 -> main table
    | main table: 192.168.250.0/24 via 192.168.150.1 dev oam-host
    v
Gateway: oam-host
    |
    | nftables postrouting:
    |   meta mark 0x3000 -> masquerade (to 192.168.150.10)
    v
netns "oam": HTTP server sees source: 192.168.150.10
```

### Flow 3: EgressIP pod -> signaling server (192.168.251.1)

Same as Flow 1 but routed to sig-host via destination-based routing.

```
egressip-pod -> OVN Geneve -> Gateway: ovn-k8s-mp0
    -> ip rule 5550: to 192.168.251.0/24 -> main table -> sig-host
    -> nftables: oifname "sig-host" snat ip to 192.168.200.200

netns "signaling": HTTP server sees source: 192.168.200.200
```

## IP Addresses

| Component | Address | Description |
|-----------|---------|-------------|
| oam-host (gateway) | 192.168.150.10/24 | Host IP on OAM interface |
| oam-host (gateway) | 192.168.150.200/32 | SNAT IP for EgressIP traffic |
| oam-host (gateway) | 192.168.150.100/32 | EgressIP assigned by OVN |
| sig-host (gateway) | 192.168.200.10/24 | Host IP on signaling interface |
| sig-host (gateway) | 192.168.200.200/32 | SNAT IP for EgressIP traffic |
| oam-ns (netns router) | 192.168.150.1/24 | Next-hop for OAM traffic |
| oam-ext (netns server) | 192.168.250.1/32 | OAM HTTP server |
| sig-ns (netns router) | 192.168.200.1/24 | Next-hop for signaling traffic |
| sig-ext (netns server) | 192.168.251.1/32 | Signaling HTTP server |

## Deployment Steps

| Step | File | Action |
|------|------|--------|
| 00 | `00-setup-serviceaccount.sh` | Create ServiceAccount and extract credentials |
| 01 | `01-generate-machineconfig.sh` | Generate MachineConfig with encoded script and config |
| 02 | `02-machineconfig-final.yaml` | `oc apply` -- deploys reconciler to all worker nodes |
| 03 | `03-setup-infra.sh` | Create veth/netns infrastructure with HTTP servers |
| 04 | `04-nncp.yaml` | `oc apply` -- configure /32 IPs, routes, ip rules |
| 05 | `05-namespace.yaml` | `oc apply` -- create namespace with egress-group label |
| 06 | `06-egressip.yaml` | `oc apply` -- EgressIP CR (selects pods with `app: demo`) |
| 07 | `07-pod.yaml` | `oc apply` -- EgressIP pod and non-EgressIP pod |
| 08 | `08-verify.sh` | Verify SNAT behavior for both pods |
| 09 | `09-cleanup.sh` | Tear down all resources |

## Usage

```bash
export KUBECONFIG=/path/to/kubeconfig

# Deploy (steps 00-07)
bash examples/oam-signaling/00-setup-serviceaccount.sh
bash examples/oam-signaling/01-generate-machineconfig.sh
oc apply -f examples/oam-signaling/02-machineconfig-final.yaml
oc wait machineconfigpool worker --for=condition=Updated=True --timeout=600s
bash examples/oam-signaling/03-setup-infra.sh
oc apply -f examples/oam-signaling/04-nncp.yaml
oc apply -f examples/oam-signaling/05-namespace.yaml
oc apply -f examples/oam-signaling/06-egressip.yaml
oc apply -f examples/oam-signaling/07-pod.yaml

# Wait for pods
oc wait -n demo-egressip pod/egressip-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/non-egressip-pod --for=condition=Ready --timeout=120s

# Verify
bash examples/oam-signaling/08-verify.sh

# Cleanup
bash examples/oam-signaling/09-cleanup.sh
```

## Expected Results

| Test | Pod | Destination | Expected Source IP | Why |
|------|-----|-------------|-------------------|-----|
| 1 | egressip-pod | 192.168.250.1:8080 (OAM) | 192.168.150.200 | EgressIP traffic via ovn-k8s-mp0, /32 SNAT |
| 2 | egressip-pod | 192.168.251.1:8081 (signaling) | 192.168.200.200 | EgressIP traffic via ovn-k8s-mp0, /32 SNAT |
| 3 | non-egressip-pod | 192.168.250.1:8080 (OAM) | 192.168.150.10 | Egress-gateway traffic via br-ex, masquerade |
| 4 | non-egressip-pod | 192.168.251.1:8081 (signaling) | 192.168.200.10 | Egress-gateway traffic via br-ex, masquerade |

## Notes

- Both pods use node affinity (`k8s.ovn.org/egress-assignable DoesNotExist`) to schedule on non-gateway workers. This is required for the `iifname`-based traffic differentiation to work.
- The EgressIP CR uses `podSelector` (`app: demo`) to match only `egressip-pod`. The `non-egressip-pod` has no matching label and is not associated with any EgressIP.
- The simulated infrastructure (netns, veth pairs, HTTP servers) is ephemeral and does not survive node reboots. Re-run `03-setup-infra.sh` after a gateway node reboot.
- The NNCP uses `type: veth` for the interfaces since they are veth pairs created by the setup script. For physical NICs, use `type: ethernet`.
