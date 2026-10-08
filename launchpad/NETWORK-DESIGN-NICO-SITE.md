<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# NICo Site Network Design — control-plane-3 + tray-6 + tray-7

## Scope

- **NICo site controller**: SNO OpenShift on `control-plane-3`
- **Targets**: `compute-tray-6` and `compute-tray-7` (bare-metal provisioned by NICo)
- **Goal**: Isolated provisioning network for tray-6/7 boot; after provisioning the ports are moved back to the existing north-south fabric (172.16.3.x)

---

## New VLANs

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| **210** | NICo Provisioning | `172.16.10.0/24` | DHCP, PXE, DNS — tray-6/7 boot |

After provisioning completes, tray switch ports move back to the existing north-south VLAN (172.16.3.x) — no new workload VLAN is created.

Existing networks are **not modified**:

| Existing | Subnet | Shared by |
|----------|--------|-----------|
| OOB/Management | `172.16.0.x/24` | All BMCs, switches |
| Host Management | `172.16.2.x/24` | All 13 control-plane nodes, all 18 tray OOBs, tray-6/7 BMCs |
| North-South | `172.16.3.x/24` | All hosts data plane |
| Storage LACP | `172.16.5.x/24` | All storage traffic |
| NVLink Management | VLAN 200 | NVLink switches |

---

## IP Address Assignments

### VLAN 210 — NICo Provisioning (`172.16.10.0/24`)

| IP | Role |
|----|------|
| `172.16.10.1` | L3 virtual gateway — VRR address on sn5600-csl-01/02 (shared VRR MAC `00:00:5e:00:01:0a`) |
| `172.16.10.252` | Physical SVI — sn5600-csl-01 |
| `172.16.10.253` | Physical SVI — sn5600-csl-02 |
| `172.16.10.2` | control-plane-3 subinterface (`bond-ns.210`) |
| **`172.16.10.10`** | **MetalLB VIP** — all NICo site services |
| `172.16.10.101` | DHCP reservation — tray-6 boot (MAC `e0:9d:73:87:03:70`) |
| `172.16.10.102` | DHCP reservation — tray-7 boot (MAC `e0:9d:73:86:d4:52`) |
| `172.16.10.128–254` | DHCP pool (dynamic, for iPXE stages) |

---

## DNS and Subdomains

NICo's DNS service runs at the MetalLB VIP `172.16.10.10:53` and is authoritative for the site domain. Upstream queries forward to `172.16.0.1` (LaunchPad DNS).

> Adjust `nico-site` below to match the actual SNO cluster name used at install time.

| Record | Type | Value | Notes |
|--------|------|-------|-------|
| `api.nico-site.launchpad.local` | A | `172.16.2.123` | SNO Kubernetes API (control-plane-3 Host Management IP) |
| `*.apps.nico-site.launchpad.local` | A | `172.16.2.123` | SNO Ingress / OpenShift Routes |
| `nico-api.nico-site.launchpad.local` | A | `172.16.10.10` | NICo gRPC API (MetalLB VIP) |
| `compute-tray-6.nico-site.launchpad.local` | A | `172.16.10.101` | Tray-6 during provisioning |
| `compute-tray-7.nico-site.launchpad.local` | A | `172.16.10.102` | Tray-7 during provisioning |
| `compute-tray-6.nico-site.launchpad.local` | A | assigned via 172.16.3.x | Tray-6 post-provision (north-south fabric) |
| `compute-tray-7.nico-site.launchpad.local` | A | assigned via 172.16.3.x | Tray-7 post-provision (north-south fabric) |

---

## MetalLB VIP — `172.16.10.10`

Single L2 VIP on VLAN 210, announced from `bond-ns.210` on control-plane-3. NICo Core services share this VIP:

| Service | External Port | Internal Port | Protocol |
|---------|--------------|---------------|----------|
| DHCP | 67, 68 | 67, 68 | UDP |
| DNS | 53 | 5353 | UDP + TCP |
| PXE / TFTP | 69 | 69 | UDP |
| SSH Console | 22 | 2222 | TCP |
| gRPC API | 443 | 50051 | TCP |

> **Known issues** (from metallb-loadbalancer-setup.md): DNS targetPort 53→5353 and SSH 22→2222
> require upstream kustomize patches before they work correctly. Apply those patches before testing.

---

## Switch Configuration

### sn5600-csl-01 and sn5600-csl-02 — Cumulus Linux (NVUE)

> OOB management IPs: `sn5600-csl-01` → `172.16.0.10`, `sn5600-csl-02` → `172.16.0.11`

These are the collapsed spine-leaf switches. All three nodes (SNO, tray-6, tray-7) connect here.

```bash
# Add VLAN 210 to the bridge
nv set bridge domain br_default vlan 210

# Trunk VLAN 210 on control-plane-3 uplink
# csl-01: swp16s1 (ens3f0np0, MAC 8c:91:3a:c8:1b:7a)
# csl-02: swp16s1 (ens3f1np1, MAC 8c:91:3a:c8:1b:7b)
nv set interface swp16s1 bridge domain br_default vlan 210

# Access VLAN 210 on tray-6 provisioning uplink
# csl-01: swp3s1 (DPU B3420 p0, MAC e0:9d:73:87:03:70)
# csl-02: swp3s1 (DPU B3420 p1, MAC e0:9d:73:87:03:71)
nv set interface swp3s1 bridge domain br_default access 210

# Access VLAN 210 on tray-7 provisioning uplink
# csl-01: swp4s0 (DPU B3420 p0, MAC e0:9d:73:86:d4:52)
# csl-02: swp4s0 (DPU B3420 p1, MAC e0:9d:73:86:d4:53)
nv set interface swp4s0 bridge domain br_default access 210

# L3 SVI for provisioning — VRR (Virtual Router Redundancy) for HA
# Each switch gets a unique physical address; 172.16.10.1 is the shared virtual gateway.
# The VRR MAC (00:00:5e:00:01:0a) is identical on both switches so ARP is consistent.

# --- on sn5600-csl-01 only ---
nv set interface vlan210 ip address 172.16.10.252/24
nv set interface vlan210 ip vrr address 172.16.10.1/24
nv set interface vlan210 ip vrr mac-address 00:00:5e:00:01:0a
nv set interface vlan210 ip vrr state up

# --- on sn5600-csl-02 only ---
nv set interface vlan210 ip address 172.16.10.253/24
nv set interface vlan210 ip vrr address 172.16.10.1/24
nv set interface vlan210 ip vrr mac-address 00:00:5e:00:01:0a
nv set interface vlan210 ip vrr state up

nv config apply --timeout 120
```

> **After provisioning**: Remove VLAN 210 access from swp3s1 and swp4s0, then set them to the
> existing north-south VLAN (172.16.3.x). The trays join the shared fabric alongside all other hosts.
> NICo's workflow should automate this transition.

---

## SNO (control-plane-3) — Network Interfaces

The north-south bond (`bond-ns`) is the LACP bond of `ens3f0np0` + `ens3f1np1`, already carrying `172.16.3.x` traffic. Add tagged subinterfaces for the new VLANs.

For OpenShift/SNO, apply a `NodeNetworkConfigurationPolicy` (NNCP) targeting `control-plane-3` by hostname:

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: nico-provisioning-vlan210
spec:
  nodeSelector:
    kubernetes.io/hostname: control-plane-3
  desiredState:
    interfaces:
      - name: bond-ns.210
        type: vlan
        state: up
        vlan:
          base-iface: bond-ns
          id: 210
        ipv4:
          enabled: true
          address:
            - ip: 172.16.10.2
              prefix-length: 24
          dhcp: false
```

Apply and verify:

```bash
oc apply -f nico-provisioning-vlan210-nncp.yaml
oc get nncp nico-provisioning-vlan210 -w
# Wait for: Available
oc get nncpe -l nmstate.io/policy=nico-provisioning-vlan210
```

---

## OVN-Kubernetes Prerequisite — Local Gateway Mode

MetalLB L2 mode requires the host network stack to handle ARP for the VIP. OVN-Kubernetes' default **shared-gateway** mode intercepts that traffic through the logical router before it reaches the host, so MetalLB VIPs will be unreachable without this change.

**Apply before installing MetalLB.** This is a cluster-wide change that causes a brief (~30–60s) network disruption — plan a maintenance window.

```yaml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        routingViaHost: true
```

Wait for all OVN pods to restart and the node to return `Ready` before proceeding:

```bash
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'
oc get nodes
```

> On SNO the disruption risk is lower than multi-node (single node, no inter-node traffic), but SSH sessions and `oc` commands will drop briefly.

---

## MetalLB IPAddressPool

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-site-vip
  namespace: metallb-system
spec:
  addresses:
    - 172.16.10.10/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-site-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - nico-site-vip
  interfaces:
    - bond-ns.210
```

---

## Topology Diagram

```
                        ┌──────────────────────────────────────────┐
                        │   sn5600-csl-01 / sn5600-csl-02         │
                        │   (collapsed spine-leaf, Cumulus Linux)  │
                        │                                          │
                        │  swp16s1 ── control-plane-3              │
                        │            trunk: existing + VLAN 210    │
                        │                                          │
                        │  swp3s1  ── compute-tray-6 DPU p0/p1    │
                        │            access: VLAN 210 (→N-S later) │
                        │                                          │
                        │  swp4s0  ── compute-tray-7 DPU p0/p1    │
                        │            access: VLAN 210 (→N-S later) │
                        │                                          │
                        │  VRR vlan210: 172.16.10.1/24 (virtual)  │
                        │  csl-01 SVI:  172.16.10.252/24          │
                        │  csl-02 SVI:  172.16.10.253/24          │
                        └──────────────────────────────────────────┘

   ┌────────────────────────────────────┐
   │  control-plane-3 (SNO OpenShift)   │
   │                                    │
   │  bond-ns       → 172.16.2.123     │  (Host Management — actual node IP)
   │  bond-ns.210   → 172.16.10.2/24   │  NICo provisioning
   │                                    │
   │  MetalLB L2 VIP: 172.16.10.10     │
   │  ├─ DHCP     :67/68               │
   │  ├─ DNS      :53 → :5353          │
   │  ├─ PXE      :69                  │
   │  ├─ SSH      :22 → :2222          │
   │  └─ gRPC API :443                 │
   └────────────────────────────────────┘

   ┌─────────────────────────┐    ┌─────────────────────────┐
   │  compute-tray-6          │    │  compute-tray-7          │
   │                         │    │                         │
   │  DPU B3420 p0           │    │  DPU B3420 p0           │
   │  MAC e0:9d:73:87:03:70  │    │  MAC e0:9d:73:86:d4:52  │
   │  VLAN 210               │    │  VLAN 210               │
   │  DHCP → 172.16.10.101   │    │  DHCP → 172.16.10.102   │
   └─────────────────────────┘    └─────────────────────────┘

                        ┌──────────────────────────────────────────┐
                        │   sn2201dc-mgmt-sw-01/02 (unchanged)     │
                        │   tray-6/7 BMCs remain on 172.16.2.x     │
                        │   NICo accesses via bond-ns (172.16.2.123)│
                        └──────────────────────────────────────────┘
```

---

## Switch Change Best Practices (Cumulus Linux / NVUE)

### Before every change

```bash
# 1. Open a BMC console session to the switch as a safety net
#    (so you retain access if SSH drops)
ssh admin@<switch-oob-ip>

# 2. Checkpoint the current config
nv config save
nv config checkpoint
```

### Apply with auto-rollback

Always use `--timeout` so the switch reverts automatically if you lose connectivity:

```bash
nv config apply --timeout 120
```

If the change looks good and SSH/connectivity is still alive, confirm to keep it:

```bash
nv config apply confirm
```

If you do not confirm within the timeout, Cumulus reverts automatically — no manual action needed.

### Manual rollback (if you still have access)

```bash
# List available checkpoints
nv config history

# Revert to a specific checkpoint
nv config revert <checkpoint-id>
```

### Persist after confirming

```bash
# Write confirmed config to disk so it survives a reboot
nv config save
```

### Summary: safe change sequence

| Step | Command |
|------|---------|
| 1. Open BMC console | (before SSH changes) |
| 2. Checkpoint | `nv config save && nv config checkpoint` |
| 3. Stage changes | `nv set ...` |
| 4. Apply with timer | `nv config apply --timeout 120` |
| 5. Verify | ping, SSH, check MACs |
| 6. Confirm | `nv config apply confirm` |
| 7. Persist | `nv config save` |

---

## Action Checklist

### Switch changes

- [ ] Add VLAN 210 + SVI on `sn5600-csl-01`
- [ ] Add VLAN 210 + SVI on `sn5600-csl-02`
- [ ] Trunk VLAN 210 on swp16s1 (both CSL switches)
- [ ] Access VLAN 210 on swp3s1 (tray-6 uplink on both CSL switches)
- [ ] Access VLAN 210 on swp4s0 (tray-7 uplink on both CSL switches)

> sn2201dc-mgmt-sw-01/02 require no changes — tray-6/7 BMCs stay on their existing `172.16.2.x` addresses.

### SNO / OpenShift

- [ ] Apply `NodeNetworkConfigurationPolicy` `nico-provisioning-vlan210` for bond-ns.210 on control-plane-3
- [ ] **Patch OVN to local-gateway mode** (`routingViaHost: true`) — brief network blip; apply before MetalLB
- [ ] Wait for OVN pods to restart and node to return `Ready`
- [ ] Install MetalLB operator via OLM
- [ ] Apply `IPAddressPool` + `L2Advertisement` for `172.16.10.10` on `bond-ns.210`
- [ ] Apply upstream kustomize patches (DNS targetPort 5353, SSH targetPort 2222)
- [ ] Deploy NICo Core chart (`nico-system` namespace) with `externalService` enabled

### NICo configuration

- [ ] Register site with NICo REST cloud (site agent)
- [ ] Configure DHCP reservations for tray-6 (MAC `e0:9d:73:87:03:70` → `172.16.10.101`)
- [ ] Configure DHCP reservations for tray-7 (MAC `e0:9d:73:86:d4:52` → `172.16.10.102`)
- [ ] Set BMC credentials for tray-6 (`172.16.2.66`) and tray-7 (`172.16.2.67`)
- [ ] Trigger provisioning workflow for tray-6 and tray-7
- [ ] After provisioning: move swp3s1/swp4s0 from VLAN 210 access to north-south VLAN (172.16.3.x)
