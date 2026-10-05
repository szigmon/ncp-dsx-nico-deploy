# nico-lab on nvd-srv-44 — configuration snapshot (taken 2026-09-29, before removal)

Recorded to allow exact re-creation on nvd-srv-04 via `make bootstrap-cluster`.
No credentials included.

## Assisted Installer cluster

| Field | Value |
|---|---|
| Cluster name | `nico-lab` |
| Base domain | `szigmon.okoyl.xyz` |
| API host | `api.nico-lab.szigmon.okoyl.xyz` |
| Ingress | `*.apps.nico-lab.szigmon.okoyl.xyz` |
| OpenShift version | `4.22.7` (installed from `4.22.7-multi`) |
| HA mode | SNO (`high_availability_mode=None`) |
| Networking | user-managed, static IP |
| API VIP / ingress VIP | `10.6.135.50` |
| Network | `10.6.135.0/24`, GW `10.6.135.254`, DNS `10.11.5.160` |
| Primary guest iface | `enp1s0`, MTU 9000 on the 44 deployment (bootstrap default 1500) |

DNS: `api.nico-lab.szigmon.okoyl.xyz` and `*.apps.nico-lab.szigmon.okoyl.xyz`
point to `10.6.135.50`. The 04 install reuses the same name, domain and IP,
so the existing records stay valid; no DNS changes are required.

## libvirt VM (vm-nico-lab1, host nvd-srv-44)

| Setting | Value |
|---|---|
| vCPUs | 14, static, `host-passthrough` |
| Memory | 42,991,616 KiB (40 GiB / 41984 MiB) |
| Firmware | UEFI secure boot (`OVMF_CODE.secboot.fd`) |
| disk1 | `/var/lib/libvirt/images/vm-nico-lab1-disk1.qcow2` — 120 GiB, `discard=unmap` |
| disk2 | `/var/lib/libvirt/images/vm-nico-lab1-disk2.qcow2` — 80 GiB, `discard=unmap` |
| NIC | single bridge NIC on `br0` (10.6.135.44/24 host side) |
| Install ISO | `/var/lib/libvirt/images/nico-lab.iso` (~1.4G) |
| SSH key injected | `/root/.ssh/id_rsa.pub` (of 44 root) |

## `.env` (from /root/nico-lab-install/.env on 44)

Values relevant to re-creation on 04 (rest of the file covered DPF/Hypershift
hosted-cluster options, not used by the NICo path):

```ini
CLUSTER_NAME=nico-lab
BASE_DOMAIN=szigmon.okoyl.xyz
OPENSHIFT_VERSION=4.22.7
OLM_WORKAROUND=true
BRIDGE_NAME=br0
API_VIP=10.6.135.50
INGRESS_VIP=10.6.135.50
DPU_HOST_CIDR=10.6.135.0/24
NODES_MTU=9000
PRIMARY_IFACE=enp1s0
VM_PREFIX=vm-nico-lab
VM_COUNT=1
RAM=41984
VCPUS=14
DISK_SIZE1=120
DISK_SIZE2=80
VM_STATIC_IP=true
STORAGE_TYPE=lvm
BFB_STORAGE_CLASS=lvms-vg1
TARGETCLUSTER_API_SERVER_HOST=api.nico-lab.szigmon.okoyl.xyz
VM_EXT_IPS=10.6.135.50
VM_EXT_PL=24
VM_GW=10.6.135.254
VM_DNS=10.11.5.160
SSH_KEY=/root/.ssh/id_rsa.pub
```

## Credentials location on 44 (copied to 04 on 2026-09-29)

- Assisted Installer token: `~/.aicli/offlinetoken.txt` (plus `token.txt`)
- Pull secret: `/root/nico-lab-install/openshift_pull.json`
- aicli: `/usr/local/bin/aicli` (Python wrapper) + `ailib` in
  `/usr/local/lib/python3.9/site-packages/` (repo upstream: karmab/aicli)

On 04 these land at `/root/.aicli/`, `/root/openshift_pull.json` and
`/usr/local/bin/aicli` respectively.

## 04 target configuration (deltas vs 44)

- Host bridge: `mgmt-br` (10.6.135.54/24) instead of `br0` — guest IP stays
  `10.6.135.50`.
- Extra NICs: libvirt network `default` (192.168.122.x NAT) + Linux bridge
  `br1` (L2 to physical VLAN 712, 10.6.145.0/24) for NICo DHCP/DNS/PXE day-2.
  The 44 VM had no extra NICs.
- Disk path: `/home/libvirt/images` (root fs has ~63 GiB free; /home has ~1.1 TiB).
- Fresh install: old NICo/DPF application state on 44 is intentionally NOT
  migrated. The 44 cluster also ran a HyperShift hosted `doca` DPF cluster —
  that goes away with it; the 04 cluster runs NICo (this repo) instead.
