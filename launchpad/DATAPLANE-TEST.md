# Data Plane Test — VLAN 212 (tray-6 + tray-7)

Validates that the workload network is end-to-end functional after provisioning and tenant assignment.

## Prerequisites

- tray-6 and tray-7 provisioned (OS installed, VLAN 212 IPs configured)
- Switch ports swp3s1 / swp4s0 moved from VLAN 210 → VLAN 212 on sn5600-csl-01/02
- NICo API accessible at `172.16.10.10` (MetalLB VIP)
- `iperf3` installed on both trays
- `TOKEN` and `API_URL` set (see bootstrap steps in CLAUDE.md)

## Variables

```bash
CP3=172.16.2.123          # control-plane-3 (Host Management network)
TRAY6=172.16.12.6
TRAY7=172.16.12.7
GW=172.16.12.1
```

---

## Step 1 — Gateway and tray reachability from control-plane-3

Control-plane-3 has `bond-ns.212 → 172.16.12.2` and is the closest L3 hop into VLAN 212.

```bash
ssh core@$CP3 "
  echo '=== Gateway ===' && ping -c 3 $GW
  echo '=== tray-6 ===' && ping -c 3 $TRAY6
  echo '=== tray-7 ===' && ping -c 3 $TRAY7
"
```

**Pass**: all three ping targets respond, RTT < 1 ms.

---

## Step 2 — East-west L3 (tray-6 → tray-7)

```bash
# Jump through control-plane-3 into tray-6, ping tray-7 directly
ssh -J core@$CP3 user@$TRAY6 "ping -c 10 -i 0.2 $TRAY7"
```

**Pass**: 10/10 packets received, RTT < 1 ms, 0% loss.

---

## Step 3 — East-west bandwidth (iperf3)

Run both commands concurrently — start the server first.

```bash
# Terminal 1: server on tray-7
ssh -J core@$CP3 user@$TRAY7 "iperf3 -s --one-off"

# Terminal 2: client on tray-6 (4 parallel streams, 30 s)
ssh -J core@$CP3 user@$TRAY6 "iperf3 -c $TRAY7 -t 30 -P 4"
```

**Pass**: aggregate throughput ≥ 25 Gbps (BlueField B3420 DPU, single port).  
**Investigate** if result is ~1 Gbps — likely MTU mismatch or wrong NIC selected.

---

## Step 4 — No bleed-back to VLAN 210

While iperf3 is running, capture on the provisioning interface from control-plane-3:

```bash
ssh core@$CP3 "sudo tcpdump -i bond-ns.210 -c 20 -n not port 67 and not port 68"
```

**Pass**: no iperf traffic appears on VLAN 210 during the test.

---

## Step 5 — NICo API: instances visible under tenant

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/tenant/current/instances" | jq '.'
```

**Pass**:
- Both `compute-tray-6` and `compute-tray-7` appear in the response
- Status is `provisioned` (or equivalent terminal state)
- Reported IPs match `172.16.12.6` and `172.16.12.7`

---

## Pass / Fail Summary

| Test | Pass Criteria |
|------|---------------|
| Gateway ping | RTT < 1 ms, 0% loss |
| Tray reachability from CP3 | Both `172.16.12.6` and `.7` respond |
| East-west ping | 10/10 packets, 0% loss, RTT < 1 ms |
| iperf3 throughput | ≥ 25 Gbps aggregate |
| VLAN 210 bleed-back | Zero iperf packets on `bond-ns.210` |
| NICo API tenant view | Both trays `provisioned` with correct IPs |
