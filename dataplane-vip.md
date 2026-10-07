<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Data-plane VIPs for NICo site services

NICo's site/Core provisioning services must be reachable by the BlueField-3 DPU
and the host it provisions, on a dedicated provisioning VLAN, via **MetalLB
LoadBalancer services** on that VLAN. Each exposed service gets its **own** LB IP
(not one shared VIP):

| Service | LB IP (example) | Role |
|---|---|---|
| `nico-api` | `10.0.0.100` | Core gRPC API (agents dial by IP → cert carries an IP SAN) |
| `nico-pxe` | `10.0.0.101` | PXE boot |
| `unbound` | `10.0.0.102` | client-facing DNS — serves `.forge` records → the IPs above, forwards the rest |

`nico-dhcp` and the SSH console are not LB-exposed (DHCP is served via switch
relay / the DPU). Operators reach the REST/Core API through the normal OpenShift
Routes. `unbound` runs non-privileged — the existing `fix-unbound-port` kustomize
patch remaps it to `:5353`, and the external Service presents `:53`.

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

## Prerequisites — must be in place BEFORE `make deploy-dataplane-vip`

The make targets only configure software (the NIC's IP via NNCP, MetalLB, the
VIPs). They do **not** create the VLAN or attach a NIC — so the data-plane
network must already exist, in this order:

1. **The dedicated VLAN** on the switch/fabric, and **a node NIC on it**. This is
   the hard prerequisite — MetalLB/NNCP configure that NIC, they can't create it:
   - **New cluster:** the NIC is attached at VM-create time by `bootstrap.sh`
     (`NICO_EXTRA_BRIDGES=<br>` → the VM gets a NIC on the host bridge carrying the
     VLAN). So the host bridge + physical VLAN must exist **before bootstrap**.
   - **Existing cluster:** the node must **already** have a NIC on the data-plane
     VLAN. If it doesn't, attach one (VM NIC on the VLAN bridge) **before** running
     the target — otherwise the NNCP has no interface to configure.
2. **Local-gateway mode** (day-1 flag at bootstrap, or the day-2 patch above) —
   also before deploy, since the VIPs won't carry traffic without it.
3. **A small range of free IPs** on that VLAN (one per exposed service) + a free
   node IP — put these in the override files.
4. **DHCP relay** `ip helper-address <VIP>` on the DPU-BMC/OOB SVI — DHCP is
   broadcast and can't reach a unicast VIP without a relay. The **DPU serves the
   host in-band overlay DHCP itself**, so that part needs no relay; the relay is
   for the DPU-BMC/OOB and host-BMC networks `nico-dhcp` handles. (Needed for DHCP
   to serve, not for the deploy to succeed.)
5. **Real `siteConfig` networks/pools** in your `nico-core-<site>.yaml` (the
   shipped values are RFC-1918 placeholders — the API starts, but real machines
   won't onboard until these match the site).

Items 1–2 are **blocking** for the deploy; 4–5 are needed for actual provisioning.

## Configure a new site

Copy the three example override files and set your values:

| File | Sets |
|---|---|
| `helm/values/prereqs-<site>.yaml` | enable MetalLB + nmstate operators |
| `helm/values/infra-site-<site>.yaml` | MetalLB pool **range**, dataplane interface, node IP |
| `helm/values/nico-core-<site>.yaml` | per-service `externalService` LB IPs (api/pxe/unbound), `unbound` `.forge` `localData`, Kea hook params, API cert IP SAN, siteConfig |

See `helm/values/*-example.yaml` for the templates.

## Deploy

Name the override files `*-<SITE>.yaml` and set `SITE` — one command does all three
stages (each an idempotent helm upgrade, so it's safe on an existing install):

```bash
make deploy-dataplane-vip SITE=<site>
```

`SITE` can also live in a git-ignored `deploy.env` (`cp deploy.env.example deploy.env`),
then just `make deploy-dataplane-vip`. Or run the stages individually / point the
knobs at explicit files:

```bash
make deploy-prereqs     PREREQS_VALUES=helm/values/prereqs-<site>.yaml
make deploy-site-infra  SITE_INFRA_VALUES=helm/values/infra-site-<site>.yaml
make deploy-site        SITE_VALUES=helm/values/nico-core-<site>.yaml
```

With no `SITE` / no override files, MetalLB/nmstate stay off (neutral chart
defaults) — other profiles are unaffected.

## Verify

One command runs the in-cluster checks (VIPs assigned, NNCP configured, MetalLB
pods up, pool/advertisement present, OVN gateway mode):

```bash
make verify-dataplane-vip
```

Then the external reachability test — from a host **on the data-plane VLAN**
(no generic make target for this; it needs a host on the VLAN):

```bash
nc -vz <API_VIP> 443          # Core gRPC
nc -vz <PXE_VIP> 8080         # PXE
dig @<DNS_VIP> <some.name>    # DNS
```

Reading the result:
- **`<pending>`** EXTERNAL-IP → MetalLB pool/annotation mismatch (is the IP in the pool range?).
- VIP **answers ARP but ports time out** → the OVN gateway settings are missing (`routingViaHost` + `ipForwarding: Global`).
- VIP **reachable on the ports** → working.
