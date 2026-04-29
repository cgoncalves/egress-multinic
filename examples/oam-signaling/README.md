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
| 07a | `07-pod.yaml` | `oc apply` -- EgressIP and non-EgressIP pods on workers |
| 07b | `07b-egressservice.yaml` | `oc apply` -- EgressService pod, LB service, MetalLB config |
| 07c | `07c-gateway-pods.yaml` | `oc apply` -- EgressIP, non-EgressIP, EgressService pods on gateway |
| 08 | `08-verify.sh` | Verify SNAT behavior for all pods |
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
oc apply -f examples/oam-signaling/07b-egressservice.yaml   # requires MetalLB
oc apply -f examples/oam-signaling/07c-gateway-pods.yaml

# Wait for pods
oc wait -n demo-egressip pod/egressip-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/non-egressip-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/egressservice-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/gw-egressip-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/gw-non-egressip-pod --for=condition=Ready --timeout=120s
oc wait -n demo-egressip pod/gw-egressservice-pod --for=condition=Ready --timeout=120s

# Verify
bash examples/oam-signaling/08-verify.sh

# Cleanup
bash examples/oam-signaling/09-cleanup.sh
```

## Expected Results

| Test | Pod | Location | Destination | Expected Source IP | Why |
|------|-----|----------|-------------|-------------------|-----|
| 1 | egressip-pod | worker | OAM | 192.168.150.200 | EgressIP, source in `egressip-pods` set, /32 SNAT |
| 2 | egressip-pod | worker | signaling | 192.168.200.200 | EgressIP, source in `egressip-pods` set, /32 SNAT |
| 3 | non-egressip-pod | worker | OAM | 192.168.150.10 | Egress-gateway traffic via br-ex, masquerade |
| 4 | non-egressip-pod | worker | signaling | 192.168.200.10 | Egress-gateway traffic via br-ex, masquerade |
| 5 | egressservice-pod | worker | OAM | 10.6.105.240 | EgressService, source in `egresssvc-pods` set, LB IP SNAT by OVN |
| 6 | egressservice-pod | worker | signaling | 10.6.105.240 | EgressService, source in `egresssvc-pods` set, LB IP SNAT by OVN |
| 7 | gw-egressip-pod | gateway | OAM | 192.168.150.200 | EgressIP on gateway, source in `egressip-pods` set, /32 SNAT |
| 8 | gw-non-egressip-pod | gateway | OAM | 192.168.150.10 | Not in any set, masquerade fallback |
| 9 | gw-egressservice-pod | gateway | OAM | 10.6.105.241 | EgressService on gateway, source in `egresssvc-pods` set, LB IP SNAT by OVN |
| 10 | non-egressip-pod | worker | 1.1.1.1 (external) | HTTP response | Traffic via br-ex default route, not alternate interfaces |
| 11 | egressip-pod | worker | cluster DNS | resolved | DNS not affected by steering/SNAT |
| 12 | egressip-pod | worker | gateway node:10250 | HTTP response | Machine network excluded from steering |

Tests 5-6, 8, and 9 require the set-based reconciler from the `experimental` branch to produce correct results. On `main`, these tests show /32 SNAT instead.

## Notes

- Worker pods (tests 1-6) use node affinity (`k8s.ovn.org/egress-assignable DoesNotExist`) to schedule on non-gateway workers. Gateway pods (tests 7-9) use the inverse (`Exists`).
- The EgressIP CR uses `podSelector` (`app: demo`) to match only `egressip-pod` and `gw-egressip-pod`. Other pods are not associated with any EgressIP.
- EgressService CRs include `nodeSelector` matching `k8s.ovn.org/egress-assignable` to ensure the EgressService host is a gateway node. Requires MetalLB installed.
- The reconciler maintains two nftables sets (`egressip-pods` and `egresssvc-pods`) updated each cycle. There is a window of up to `RECONCILE_INTERVAL` seconds after assignment changes where SNAT may be incorrect.
- EgressIP pods can only reach destinations routable from the EgressIP-bound interface. In this example, the EgressIP is bound to `oam-host` which only has routes to the simulated OAM/signaling networks. Traffic to external destinations (e.g., 1.1.1.1) from EgressIP pods fails because `oam-host` has no default route to the internet. To reach external destinations, the EgressIP address should be on a routable interface (e.g., `br-ex`). Test 10 uses `non-egressip-pod` for this reason.
- The simulated infrastructure (netns, veth pairs, HTTP servers) is ephemeral and does not survive node reboots. Re-run `03-setup-infra.sh` after a gateway node reboot.
- The NNCP uses `type: veth` for the interfaces since they are veth pairs created by the setup script. For physical NICs, use `type: ethernet`.
