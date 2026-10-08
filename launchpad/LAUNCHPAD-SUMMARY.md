# NVIDIA LaunchPad — GB300 NVL72 Bring-Up Lab Summary

> Extracted from saved documentation pages in `launchpad/docs/`.

## What This Is

A hands-on lab environment giving NCP/Red Hat partners access to a real **GB300 NVL72 AI supercomputer** for bring-up, configuration, validation, and purchase decisions.

---

## Hardware Overview

- **72** Blackwell Ultra GPUs + **36** Grace CPUs
- **37 TB** fast memory
- **130 TB/s** NVLink scale-up fabric
- ConnectX-8 + Quantum-X800 InfiniBand / Spectrum-X Ethernet for scale-out networking
- Target workloads: reasoning, long-context inference, multimodal AI, AI factory

---

## Access

| Method | Description |
|---|---|
| Bastion Desktop | GUI desktop via browser |
| Code Server | VS Code IDE in browser |
| SSH | Direct terminal access |
| System Console | OOB/serial console |

**Credentials** — uniform password `Buynvidia2026!` across all components; username varies:

| Component | Username |
|---|---|
| Ethernet switches (Cumulus) | `cumulus` |
| Lenovo BMC | `USERID` |
| NVLink switches (management) | `admin` |
| NVLink/Power BMC | `root` |

---

## Network Segmentation

| Subnet | Role |
|---|---|
| `172.16.0.x` | OOB / management (BMC, switches) |
| `172.16.2.x` | Host management / OOB |
| `172.16.3.x` | North-south (data plane) |
| `172.16.5.x` | Storage (LACP bonds) |

---

## Architecture

- **Bastion host** — entry point; provides docs, desktop, SSH, and OOB management
- **Control-plane nodes (13)** — operational hub for all environment work (OS install, DHCP, bring-up)
- Compute trays and NVLink switches are **only reachable from control-plane nodes**, not directly from the bastion

### Control-Plane Nodes (13)
Each node has:
- BMC (OOB), accessible at `https://<IP>` with username `USERID`
- 1G management links (north-south, `172.16.2.x`)
- CX7 storage LACP (`172.16.5.x`)
- CX7 north-south LACP (`172.16.3.x`)

### Compute Trays (18)
Each tray has:
- Tray BMC + DPU BMC (BlueField B24)
- DPU host OOB + host OOB
- Storage and east-west fabric interfaces
- BMC browser access via SSH port-forward tunnels: bastion → control-plane node → tray
- ARP flux mitigation may be needed for the east-west VLAN (see DGX OS 7 guide)

---

## Switches

### Ethernet Switches (Cumulus Linux — NVUE CLI)

| Hostname (LLDP) | OOB IP | Role |
|---|---|---|
| `gb300-01-sn5600-csl-01` | `172.16.0.10` | Collapsed spine-leaf |
| `gb300-01-sn5600-csl-02` | `172.16.0.11` | Collapsed spine-leaf |
| `gb300-01-sn2201-mg-01` | `172.16.0.12` | OOB management |
| `gb300-01-sn2201-mg-02` | `172.16.0.13` | OOB management |
| `gb300-01-sn2201dc-mgmt-sw-01` | `172.16.0.14` | DC management (tray BMC ports) |
| `gb300-01-sn2201dc-mgmt-sw-02` | `172.16.0.15` | DC management (tray DPU BMC + host OOB ports) |

**sn2201dc uplinks to fabric (confirmed via LLDP):**

| DC switch | Local port | → CSL switch | CSL port |
|---|---|---|---|
| `sn2201dc-mgmt-sw-01` | `swp49` | `sn5600-csl-01` | `swp61s0` |
| `sn2201dc-mgmt-sw-01` | `swp51` | `sn5600-csl-02` | `swp61s0` |
| `sn2201dc-mgmt-sw-02` | `swp49` | `sn5600-csl-01` | `swp61s1` |
| `sn2201dc-mgmt-sw-02` | `swp51` | `sn5600-csl-02` | `swp61s1` |

> **Warning:** switch changes can break full environment access. Do not mix NVUE and Linux config methods on the same switch.

### NVLink Switches (NVIDIA NVOS — different CLI from Cumulus)

- 9 NVLink switches, management VLAN 200
- Credentials: `admin/Buynvidia2026!` (management), `root/Buynvidia2026!` (BMC)
- May span Rack-1 and Rack-2; reached from control-plane nodes

---

## Power Shelves

- 6 shelves across 2 racks
- Connected to `sn2201-mg-01/02` switches (swp36-38)
- Credentials: `root/Buynvidia2026!`
- Reached from control-plane nodes via management VLAN 200

---

## WEKA Storage

High-performance shared storage — native WEKA client or NFS v4 only (no SMB).

| Access Method | Target |
|---|---|
| Native WEKA client | `172.16.5.11,172.16.5.12/gb300-weka_fs` |
| NFS v4 | `weka-nfs.nvidialaunchpad.internal:/gb300-weka_fs` → `172.16.5.31–40` |

- Storage traffic **must** use dedicated storage interfaces (`172.16.5.x`), not north-south or management interfaces
