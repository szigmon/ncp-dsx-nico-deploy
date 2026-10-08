<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# MetalLB LoadBalancer VIPs for the Site Profile

NICo Core's provisioning services (DHCP, DNS, PXE, SSH console) and the Core
gRPC API must be reachable from the physical network that managed machines
boot on. OpenShift Routes cannot carry UDP/67, DNS, or TFTP, so a real
bare-metal site needs LoadBalancer VIPs — which on OpenShift means MetalLB.

This guide covers taking a VIP allocated by network IT and wiring it through
to the Core services.

## Current State of This Repo

**Nothing MetalLB-related is deployed today.** There is no operator
subscription, no address pool, and no `externalService` override anywhere in
`helm/values/`, `helm/infra-cloud/`, `helm/infra-site/`,
`helm/nvidia-infra-controller-prereqs/`, or `helm/kustomize/`. Every upstream
chart ships `externalService.enabled: false`, so `make deploy-site` produces
zero LoadBalancer services.

Everything described below is additive. The only existing MetalLB material is
in the read-only upstream submodule, as reference:

| Path (under `helm/vendor/infra-controller/`) | Contents |
|---|---|
| `helm-prereqs/values/metallb-config.yaml` | Site template: blank `IPAddressPool`s plus commented BGP and L2 blocks |
| `helm-prereqs/operators/values/metallb.yaml` | Community Helm chart values (FRR, `ignoreExcludeLB`, `crds.enabled: false`) |
| `helm-prereqs/helmfile.yaml` | Installs `metallb/metallb` 0.14.5 into `metallb-system` |
| `helm-prereqs/values/nico-core.yaml` | Per-service `metallb.universe.tf/loadBalancerIPs` annotations |
| `docs/manuals/networking/bgp_peering.md` | BGP peering walkthrough |
| `docs/getting-started/prerequisites/network.md` | IP pool sizing, switch config, topology options |

Upstream installs the **community Helm chart** via `helm-prereqs/setup.sh`.
Do not use that path here — it conflicts with this repo's deploy model. On
OpenShift, use the MetalLB Operator from OLM instead. The CRDs are identical
(`metallb.io/v1beta1`), so upstream's `metallb-config.yaml` can be lifted
verbatim once the operator is installed.

## Before You Start: Questions for Network IT

1. **Is the VIP in the same L2 subnet as the node NICs, or routed from
   elsewhere?** This decides L2 vs BGP mode. Nothing works until it is right.
2. **Which NIC on the nodes is on that VLAN?** Needed for interface pinning.
3. **Can they add a DHCP relay (`ip helper-address <VIP>`) on the BMC/OOB
   VLAN SVI?** See [DHCP Relay](#1-dhcp-relay-the-silent-failure) — this is
   mandatory, not optional.
4. **Can they exclude the VIP from any DHCP scope on that VLAN?**
5. **Can they add a DNS A record for the VIP?** See
   [No IP SANs](#no-ip-sans-on-the-api-certificate).

## Step 1 — Install the MetalLB Operator

Package `metallb-operator` from `redhat-operators`, into `metallb-system`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  targetNamespaces: [metallb-system]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

This matches the Subscription pattern already used in
`helm/nvidia-infra-controller-prereqs/templates/certmanager.yaml`.

Then create the `MetalLB` CR. The operator deploys no controller or speaker
pods until this exists:

```yaml
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
```

## Step 2 — Address Pool

A single allocated VIP is a `/32`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-dataplane-vip
  namespace: metallb-system
spec:
  addresses:
    - 10.20.30.40/32          # the IP from network IT
  autoAssign: false           # hand out only when explicitly requested
  avoidBuggyIPs: true
```

`autoAssign: false` matters when you have exactly one address — otherwise the
first LoadBalancer service to appear claims it. The tradeoff is that services
stay `<pending>` until annotated (Step 4).

For a larger allocation, use CIDR or range form and consider upstream's
two-pool split — `vip-pool-internal` for provisioning services,
`vip-pool-external` for the API:

```yaml
spec:
  addresses:
    - 10.20.30.160/28          # 16 addresses, .160 – .175
    - 10.20.30.10-10.20.30.20  # range form also accepted
```

## Step 3 — Advertisement

Pick exactly one mode. Configuring both is a preflight failure upstream and a
routing mess in practice.

### L2 — VIP shares a subnet with the node NICs

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-dataplane-l2
  namespace: metallb-system
spec:
  ipAddressPools: [nico-dataplane-vip]
  interfaces:
    - ens2f0                   # the dataplane NIC, NOT the admin NIC
  nodeSelectors:
    - matchLabels:
        nico.redhat.com/dataplane: "true"
```

**`interfaces` is mandatory on multi-NIC nodes.** Without it the speaker picks
its egress interface from the routing table, which on a dual-homed node will
be the admin NIC — the VIP gets ARP'd into the wrong broadcast domain and
nothing on the dataplane VLAN reaches it. `nodeSelectors` exists for the same
reason: a speaker election won by a node with no path to the clients is a
blackhole.

### BGP — VIP routed from elsewhere

```yaml
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: nico-dataplane-bgp
  namespace: metallb-system
spec:
  ipAddressPools: [nico-dataplane-vip]
```

Plus one `BGPPeer` per (node, TOR) pair. Template and field-by-field notes are
in `helm/vendor/infra-controller/helm-prereqs/values/metallb-config.yaml`; the
walkthrough is in
`helm/vendor/infra-controller/docs/manuals/networking/bgp_peering.md`. The TOR
side must be configured by network IT.

BGP is upstream's reference architecture — `network.md:122` describes MetalLB
advertising L3 VIPs to the site controller's DPU uplinks, or directly to the
ToR switches when the site controller has no DPUs.

## Step 4 — Enable `externalService` on the Core Charts

This repo enables five services that need VIPs. `nico-ntp` and `unbound` are
`enabled: false`, so they need none.

| Service | External ports | Default `externalTrafficPolicy` |
|---|---|---|
| `nico-api` | 443/TCP → gRPC 1079 | `Local` |
| `nico-dhcp` | 67/UDP | (unset) |
| `nico-dns` | 53/UDP + 53/TCP, per pod | (unset) |
| `nico-pxe` | 8080/TCP + 80/TCP | `Local` |
| `nico-ssh-console-rs` | 22/TCP | (unset) |

**All five belong on the dataplane VIP, including `nico-api`.** It is tempting
to leave the API on the admin plane, but DPU and host agents dial it directly.
`network.md:122` requires the API be routable to and from DPU BMCs, the admin
network, and tenant VPCs. Operators still reach the REST layer through the
cloud-side OpenShift Route, so nothing is lost.

### Sharing one VIP across all five

The port sets do not overlap, so a single shared VIP works. MetalLB requires
three conditions:

1. Identical `metallb.universe.tf/allow-shared-ip` value on every service.
2. No port collisions — satisfied, see the table above.
3. **Every service on `externalTrafficPolicy: Cluster`.** `nico-api` and
   `nico-pxe` default to `Local`. If even one stays `Local`, MetalLB refuses
   the share and the rest go `<pending>`.

Set `externalTrafficPolicy: null` to omit the field; the templates emit it only
when truthy, and Kubernetes defaults to `Cluster`.

Add to your site values overlay:

```yaml
nico-api:
  externalService:
    enabled: true
    externalTrafficPolicy: null
    annotations:
      metallb.universe.tf/loadBalancerIPs: "10.20.30.40"
      metallb.universe.tf/allow-shared-ip: "nico-site-vip"

nico-dhcp:
  externalService:
    enabled: true
    annotations:
      metallb.universe.tf/loadBalancerIPs: "10.20.30.40"
      metallb.universe.tf/allow-shared-ip: "nico-site-vip"

nico-pxe:
  externalService:
    enabled: true
    externalTrafficPolicy: null
    annotations:
      metallb.universe.tf/loadBalancerIPs: "10.20.30.40"
      metallb.universe.tf/allow-shared-ip: "nico-site-vip"

nico-ssh-console-rs:
  externalService:
    enabled: true
    annotations:
      metallb.universe.tf/loadBalancerIPs: "10.20.30.40"
      metallb.universe.tf/allow-shared-ip: "nico-site-vip"

nico-dns:
  externalService:
    enabled: true
    perPodAnnotations:                      # one entry per replica
      - metallb.universe.tf/loadBalancerIPs: "10.20.30.40"
        metallb.universe.tf/allow-shared-ip: "nico-site-vip"
```

Prefer the `loadBalancerIPs` annotation over the deprecated
`spec.loadBalancerIP` field. `metallb.universe.tf/address-pool: <pool-name>`
is the alternative when you want any address from a pool rather than a
specific one.

Note: the `nico-pxe` and `nico-dns` templates hardcode their own
`allow-shared-ip` keys before injecting yours, producing a duplicate YAML key.
The post-renderer's Python round-trip deduplicates last-wins so yours survives
(`helm/plugins/kustomize-post-renderer/render.sh:27`). It works, but by
accident — a kustomize patch is the durable version.

### Deploying

`SITE_VALUES` **replaces** the site overlay rather than adding to it
(`Makefile:44-45`). Pointing it at a VIP-only file drops the network segments
and resource pools from `nico-core-site.yaml`, and Core refuses to start
without pools (`crates/api-core/src/setup.rs`). Copy the overlay and append:

```bash
cp helm/values/nico-core-site.yaml helm/values/nico-core-<site>.yaml
# append the externalService blocks above, adjust pools/networks to the real site
make deploy-site SITE_VALUES=helm/values/nico-core-<site>.yaml
```

## Prerequisites on the Nodes

MetalLB can only ARP from an interface that is up with an address in the VIP's
subnet. **Nothing in this repo configures node networking** — no NMState, no
`NodeNetworkConfigurationPolicy`, no Multus.

- **Access port / untagged VLAN** — the NIC needs an IP in that subnet from
  the OS install. Usually already done.
- **Tagged VLAN** — you need the NMState operator
  (`kubernetes-nmstate-operator`) and an NNCP creating the VLAN
  sub-interface. That is a separate operator install, not in the prereqs
  chart.

Verify before touching MetalLB:

```bash
oc debug node/<node> -- ip -br addr
```

## Network Requirements

### 1. DHCP Relay — the silent failure

A MetalLB L2 VIP answers ARP for a unicast address. It does **not** capture
subnet broadcast. A DHCP DISCOVER from a BMC is broadcast, so it will never
reach the VIP on its own — even on the same VLAN.

The BMC/OOB VLAN SVI must have `ip helper-address <VIP>`. Upstream states this
as a hard requirement (`network.md:42`), and the protocol flow
(`docs/nico-provisioning-protocol-flow.md:42`) shows NICo matching on `giaddr`,
which only exists when a relay sets it.

### 2. Return routing on dual-NIC nodes

Traffic to the VIP arrives on the dataplane NIC, but the pod's reply is routed
by the node's routing table. If the default route is the admin NIC and there is
no specific route to the BMC/host subnets via the dataplane NIC, replies leave
the wrong interface and get dropped by RPF filtering or the ToR.

Nodes need static routes for every subnet they serve, pointed at the dataplane
NIC.

### 3. VIP excluded from DHCP scope

Standard, but easy to forget on a VLAN that also runs DHCP.

## Known Blockers in This Repo

### Hardcoded `targetPort` on DNS and SSH console

Both templates hardcode a `targetPort` that values cannot override, and both
disagree with this repo's port overrides:

| Service | Template emits | This repo listens on |
|---|---|---|
| `nico-dns` | `port: 53 → targetPort: 53` | 5353 (`helm/values/nico-core.yaml:134`) |
| `nico-ssh-console-rs` | `port: 22 → targetPort: 22` | 2222 (`helm/values/nico-core.yaml:169`) |

Both ports were moved off privileged values because this cluster's runtime does
not propagate `CAP_NET_BIND_SERVICE` to the effective set for non-root exec.
The VIP would forward to a dead port in both cases.

Fix: a patch under `helm/kustomize/nico-core/patches/` rewriting `targetPort`,
following the existing one-patch-per-upstream-PR convention.

### No IP SANs on the API certificate

`nico-api` exposes `certificate.dnsNames` and `certificate.extraDnsNames` but
has no IP SAN field (`helm/vendor/infra-controller/helm/charts/nico-api/values.yaml:129-145`).
Agents cannot validate the serving cert when dialing the VIP by raw IP.

You need a DNS name that resolves to the VIP from the dataplane VLAN — either
served by `nico-dns` or an A record from network IT — and that name must be in
the SAN list. Upstream carries a scar from exactly this failure mode: the
`carbide-api.forge` entry at line 144 exists because DPU agents stuck at
`WaitingForNetworkConfig` on a TLS `BadCertificate` (upstream issue #2823).

### Kea hook parameters still point at ClusterIPs

`helm/values/nico-core.yaml:112-117` hardcodes `172.30.57.9` and
`172.30.103.117`. DHCP advertises these to clients as the DNS, NTP, and
provisioning server. Once VIPs exist they must be updated, or DPUs receive
unreachable endpoints at boot.

### machine-a-tron is unaffected

`MAT=1` simulates the entire physical network
(`docs/machine-a-tron-testing-guide.md:60`). MetalLB adds nothing there.

## Verification

```bash
# VIP assigned?
oc get svc -n nico-system | grep LoadBalancer

# which node won the election, and why
oc describe svc nico-api-external -n nico-system   # look for the nodeAssigned event
oc logs -n metallb-system -l component=speaker --tail=50

# pool state
oc get ipaddresspool,l2advertisement,bgppeer -n metallb-system
oc describe ipaddresspool nico-dataplane-vip -n metallb-system
```

`EXTERNAL-IP` stuck at `<pending>` means MetalLB declined the allocation.
Most common causes, in order:

1. One service left on `externalTrafficPolicy: Local` while sharing an IP.
2. `allow-shared-ip` value differs between services (typo, or one missing).
3. `autoAssign: false` with no `loadBalancerIPs` annotation on the service.
4. Pool exhausted, or the requested IP is outside every pool.

VIP assigned but unreachable from the dataplane VLAN:

1. `interfaces` not pinned, so the speaker is ARPing on the admin NIC.
2. The VLAN interface does not exist or has no IP on the elected node.
3. Missing DHCP relay (DHCP only).
4. Asymmetric return path — see [Return routing](#2-return-routing-on-dual-nic-nodes).

## Integrating Into the Repo

The manual steps above are fine for a first bring-up, but do not survive
`make undeploy`. The durable form follows this repo's existing layering:

| Concern | Where it goes |
|---|---|
| Operator subscription | `helm/nvidia-infra-controller-prereqs/templates/metallb.yaml` + a `metallb:` block in `values.yaml` |
| `MetalLB` CR, pool, advertisement | `helm/infra-site/templates/metallb-config.yaml` |
| `targetPort` fixes | `helm/kustomize/nico-core/patches/` |
| Service VIP annotations | `helm/values/nico-core-<site>.yaml` |

That keeps the whole thing inside `make deploy-prereqs` →
`make deploy-site-infra` → `make deploy-site`, with no manual `oc apply`.

Ship the pool with `addresses: []` the way upstream does if the repo is shared
across sites — it fails loudly at deploy time rather than silently advertising
someone else's subnet.
