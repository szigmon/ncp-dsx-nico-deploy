<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Data-plane VIP for NICo site services

NICo's site/Core provisioning services must be reachable by the BlueField-3 DPU
and the host it provisions, on a dedicated provisioning VLAN, via **MetalLB
LoadBalancer services** on that VLAN. Each exposed service gets its **own** LB IP
(not one shared VIP):

| Service | LB IP (nico-lab) | Role |
|---|---|---|
| `nico-api` | `10.6.145.100` | Core gRPC API (agents dial by IP → cert carries an IP SAN) |
| `nico-pxe` | `10.6.145.101` | PXE boot |
| `nico-dns` | `10.6.145.102` | DNS (non-privileged: `:5353` behind a 53→5353 Service remap) |

`nico-dhcp` and the SSH console are not LB-exposed (DHCP is served via switch
relay / the DPU). Operators reach the REST/Core API through the normal OpenShift
Routes.

> **unbound (the alosadagrande/hub0 `.forge` DNS pattern) is intentionally off here.**
> It binds `:53` and uses `ip-transparent`, which this cluster's **restricted
> runtime won't permit even as root** (needs `CAP_NET_ADMIN`). Enabling it needs a
> custom SCC — a follow-up. `nico-dns` provides DNS non-privileged in the meantime,
> and the API cert uses an IP SAN instead of a `.forge` name.

## The one non-obvious constraint

MetalLB L2 advertises the VIP on the node's **secondary** VLAN NIC. With
OpenShift's default **shared-gateway** OVN mode, OVN only services LoadBalancer
VIPs on the primary bridge (`br-ex`) and **silently drops** VIP traffic arriving
on a secondary NIC — the DNAT rule fires but IP forwarding is `Restricted`, so
the packet dies. You need **both** OVN gateway settings:

```yaml
gatewayConfig:
  routingViaHost: true     # adds the VIP DNAT rules on the node
  ipForwarding: Global     # lets the DNAT'd packet forward into OVN
```

- **Day-1 (recommended, no disruption):** set `NICO_LOCAL_GATEWAY=true` so
  `cluster/bootstrap.sh` uploads `cluster/manifests-day1/cluster-network-03-config.yaml`
  as an Assisted-Installer manifest — the cluster boots in local-gateway mode.
- **Day-2 (existing cluster, brief OVN rollout):**
  ```bash
  oc patch network.operator cluster --type merge \
    -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
  oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes
  ```

## Per-lab external inputs (NOT code)

These are physical/site facts you provide; no manifest can create them:

1. **A dedicated VLAN** and a **node NIC on it** (via a host bridge for VMs).
2. **A small range of free IPs** on that VLAN (one per exposed service — api/pxe/
   nico-dns) plus a **free node IP**.
3. **Local-gateway mode** (day-1 flag or day-2 patch, above).
4. **DHCP relay** `ip helper-address <VIP>` on the DPU/BMC network SVI — DHCP is
   broadcast and cannot reach a unicast VIP without a relay. Note the **DPU
   serves the host in-band overlay DHCP itself**, so that part needs no relay;
   the relay is for the DPU-BMC/OOB and host-BMC networks `nico-dhcp` handles.
5. **Real `siteConfig` networks/pools** in your `nico-core-<lab>.yaml` (the
   shipped values are RFC-1918 placeholders — the API starts, but real machines
   won't onboard until these match the site).

## Configure a new lab

Copy the three per-site override files and set your values:

| File | Sets |
|---|---|
| `helm/values/prereqs-<lab>.yaml` | enable MetalLB + nmstate operators |
| `helm/values/infra-site-<lab>.yaml` | MetalLB pool **range**, dataplane interface, node IP |
| `helm/values/nico-core-<lab>.yaml` | per-service `externalService` LB IPs (api/pxe/nico-dns), Kea hook params, API cert IP SAN, siteConfig |

Use the `*-nico-lab.yaml` files as the worked example (VLAN 712, pool
`10.6.145.100-110`, NIC `enp3s0`, node IP `10.6.145.2`; api `.100` / pxe `.101`
/ nico-dns `.102`).

## Deploy

```bash
make deploy-prereqs     PREREQS_VALUES=helm/values/prereqs-<lab>.yaml
make deploy-site-infra  SITE_INFRA_VALUES=helm/values/infra-site-<lab>.yaml
make deploy-site        SITE_VALUES=helm/values/nico-core-<lab>.yaml
```

Without the override files, MetalLB/nmstate stay off (chart defaults) — other
lab profiles are unaffected.

## Verify

```bash
oc get svc -n nico-system | grep LoadBalancer   # each service has its own EXTERNAL-IP
oc get nncp                                      # dataplane NIC configured
# from a host on the VLAN:
nc -vz 10.6.145.100 443    # API; pxe -> .101:8080; nico-dns -> .102:53
dig @10.6.145.102 nico.local          # nico-dns answers on the VIP
```

`EXTERNAL-IP` stuck at `<pending>` → MetalLB pool/annotation mismatch (is the IP
in the pool range?). IP answers ARP but ports time out → the OVN gateway settings
above are missing.
