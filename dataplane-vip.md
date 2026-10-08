<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Data-plane VIPs for NICo site services

> This is the **deploy/operate** guide for the implemented MetalLB flow (make
> targets, overrides, verification). For the **design rationale** — L2 vs BGP,
> the DHCP-relay silent failure, API IP-SAN handling, shared vs per-service VIPs,
> and per-field troubleshooting — see
> [metallb-loadbalancer-setup.md](metallb-loadbalancer-setup.md).

NICo's site/Core provisioning services must be reachable by the BlueField-3 DPU
and the host it provisions, on a dedicated provisioning VLAN, via **MetalLB
LoadBalancer services** on that VLAN. Each exposed service gets its **own** LB IP
(not one shared VIP):

| Service | Port | Role |
|---|---|---|
| `nico-api` | 443 | Core gRPC API (agents dial by IP → cert carries an IP SAN) |
| `nico-pxe` | 8080 | PXE boot |
| `unbound` | 53 | client-facing DNS — serves `.forge` records → VIP on ports 443 & 8080, forwards the rest |
| `nico-dhcp` | 67 | DHCP for the DPU-BMC/OOB + host-BMC networks (reached via switch relay) |

All services share a **single VIP** on different ports via MetalLB's
`allow-shared-ip` annotation. The VIP comes from **env var only** — the example
overlay has an empty placeholder. Set the real VIP in `deploy.env` (`DATAPLANE_VIP`),
along with pool/NIC/node-IP (`DATAPLANE_POOL`, `DATAPLANE_NIC`, `DATAPLANE_NODE_IP`),
and the make targets override the overlay via `helm --set`. This keeps operational
IPs out of committed YAML.

The SSH console is not LB-exposed. Operators reach the REST/Core API through the
normal OpenShift Routes. `unbound` runs non-privileged — the existing
`fix-unbound-port` kustomize patch remaps it to `:5353`, and the external Service
presents `:53`.

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
4. **DHCP relay** `ip helper-address <nico-dhcp VIP>` (e.g. `192.0.2.103`) on the
   DPU-BMC/OOB and host-BMC SVIs — DHCP is broadcast and can't reach a unicast VIP
   without a relay, so point the relay at the `nico-dhcp` VIP specifically (not the
   api/pxe/dns VIPs). The **DPU serves the host in-band overlay DHCP itself**, so
   that network needs no relay. (Needed for DHCP to serve, not for the deploy to
   succeed.)
5. **Real `siteConfig` networks/pools** in your `nico-core-<site>.yaml` (the
   shipped values are RFC-1918 placeholders — the API starts, but real machines
   won't onboard until these match the site).

Items 1–2 are **blocking** for the deploy; 4–5 are needed for actual provisioning.

## Configure a new site

1. Copy the single per-site override file (site config only):

```bash
cp helm/values/nico-core-example.yaml helm/values/nico-core-<site>.yaml
```

   Edit `nico-core-<site>.yaml` for site-specific values only:
   - `unbound.localConfig.forwarders.conf` — your site's upstream recursive DNS
   - `siteConfig` — networks and resource pools for hardware discovery

2. Copy and edit `deploy.env`:

```bash
cp deploy.env.example deploy.env
```

   Set the MetalLB and network values:

```bash
SITE=<site>                     # must match the override file above
DATAPLANE_VIP=10.6.145.100      # shared VIP for all services
DATAPLANE_POOL=10.6.145.100-10.6.145.110  # MetalLB pool/range
DATAPLANE_NIC=ens1f0            # node NIC on the VLAN
DATAPLANE_NODE_IP=10.6.145.2    # static IP for the node NIC
```

**IP configuration is in `deploy.env` only** — the example overlay has empty
placeholders. When `DATAPLANE_VIP` is set, the make targets automatically enable
MetalLB and NMState operators. (No separate prereqs or infra-site override files needed.)

## Deploy

One command deploys all three stages (each an idempotent helm upgrade, so it's safe
on an existing install):

```bash
make deploy-dataplane-vip
```

(All `SITE` and `DATAPLANE_*` vars are read from `deploy.env`; no CLI args needed.)

With no `deploy.env`, the deploy fails fast with clear errors. With `DATAPLANE_VIP`
unset or empty, MetalLB/NMState stay disabled and the cluster runs without LoadBalancer VIPs.

## Verify

One command runs the in-cluster checks (VIPs assigned, NNCP configured, MetalLB
pods up, pool/advertisement present, OVN gateway mode):

```bash
make verify-dataplane-vip
```

Then the external reachability test — from a host **on the data-plane VLAN**
(no generic make target for this; it needs a host on the VLAN):

```bash
VIP=10.6.145.100  # your DATAPLANE_VIP from deploy.env
nc -vz $VIP 443          # Core gRPC (nico-api)
nc -vz $VIP 8080         # PXE (nico-pxe)
nc -vz $VIP 67           # DHCP (nico-dhcp)
dig @$VIP <some.name>    # DNS (unbound)
```

Reading the result:
- **`<pending>`** EXTERNAL-IP → MetalLB pool/annotation mismatch (is the IP in the pool range?).
- VIP **answers ARP but ports time out** → the OVN gateway settings are missing (`routingViaHost` + `ipForwarding: Global`).
- VIP **reachable on the ports** → working.

## Testing: From Scratch (Day-1 Proof)

To fully validate the flow on a fresh cluster:

```bash
# 1. Bootstrap a cluster with local-gateway enabled
make bootstrap-cluster \
  NICO_BASE_DOMAIN=example.com \
  NICO_API_IP=192.168.110.10 \
  NICO_GW=192.168.110.1 \
  NICO_DNS=192.168.110.2 \
  NICO_LOCAL_GATEWAY=true

export KUBECONFIG=$PWD/cluster/kubeconfig

# 2. Set up data-plane config
cp deploy.env.example deploy.env
# edit deploy.env with your lab IPs (VLAN, VIP, pool, NIC, node IP)

# 3. Create and configure the site
make new-site SITE=lab01
# edit helm/values/nico-core-lab01.yaml: upstream DNS + siteConfig

# 4. Deploy everything
make deploy-dataplane-vip

# 5. Verify in-cluster
make verify-dataplane-vip

# 6. Verify external reachability (from a host on the data-plane VLAN)
VIP=$(grep DATAPLANE_VIP deploy.env | cut -d= -f2)
nc -vz $VIP 443   # Core API
dig @$VIP example.com  # DNS
```

This proves the entire path: day-1 cluster with local-gateway → MetalLB operators → VIP services → all working.
