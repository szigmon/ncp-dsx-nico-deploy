#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Self-contained cluster bootstrap for NICo test beds.
#
# Installs a single-node OpenShift (SNO) on a local libvirt VM with a static
# IP via the Assisted Installer (aicli), then deploys LVM Storage so the
# cluster has a default StorageClass (required by NICo's PG/Vault/NATS/
# Temporal PVCs). Logic is a trimmed, standalone extraction of the
# openshift-dpf automation's cluster chain (rh-ecosystem-edge/openshift-dpf,
# scripts/cluster.sh + vm.sh), reduced to the SNO path only.
#
# Usage:
#   bootstrap.sh install NICO_BASE_DOMAIN=example.com NICO_API_IP=10.0.0.5 \
#       NICO_GW=10.0.0.1 NICO_DNS=10.0.0.2 [NICO_...=...]
#   bootstrap.sh clean  [NICO_CLUSTER_NAME=...]
#
# All configuration is NICO_* env vars (or KEY=VALUE args); defaults below.
# An installed cluster skips VM creation and refreshes its credentials and LVMS.

set -euo pipefail

# KEY=VALUE arguments must be parsed before deriving cluster-specific paths.
for arg in "$@"; do
    [[ "$arg" == NICO_*=* ]] || continue
    key="${arg%%=*}"
    val="${arg#*=}"
    case "$key" in
        NICO_CLUSTER_NAME|NICO_OPENSHIFT_VERSION|NICO_PULL_SECRET|NICO_SSH_PUB_KEY|NICO_VM_PREFIX|NICO_RAM|NICO_VCPUS|NICO_DISK1|NICO_DISK2|NICO_DISK_PATH|NICO_BRIDGE|NICO_PRIMARY_IFACE|NICO_EXTRA_NETWORKS|NICO_EXTRA_BRIDGES|NICO_NETMASK|NICO_OLM_WORKAROUND|NICO_BASE_DOMAIN|NICO_API_IP|NICO_GW|NICO_DNS|NICO_LOCAL_GATEWAY)
            [ -z "$val" ] || export "$key=$val" ;;
    esac
done

# --- Defaults ----------------------------------------------------------------
NICO_CLUSTER_NAME="${NICO_CLUSTER_NAME:-nico-lab}"
NICO_OPENSHIFT_VERSION="${NICO_OPENSHIFT_VERSION:-4.22.7-multi}"
NICO_PULL_SECRET="${NICO_PULL_SECRET:-openshift_pull.json}"
NICO_SSH_PUB_KEY="${NICO_SSH_PUB_KEY:-}"          # default: first of ~/.ssh/{id_ed25519,id_rsa}.pub
NICO_VM_PREFIX="${NICO_VM_PREFIX:-vm-${NICO_CLUSTER_NAME}}"
NICO_RAM="${NICO_RAM:-41984}"                      # MiB
NICO_VCPUS="${NICO_VCPUS:-14}"
NICO_DISK1="${NICO_DISK1:-120}"                    # GiB (root + platform)
NICO_DISK2="${NICO_DISK2:-80}"                     # GiB (spare disk -> LVMS)
NICO_DISK_PATH="${NICO_DISK_PATH:-/var/lib/libvirt/images}"
NICO_BRIDGE="${NICO_BRIDGE:-}"                     # default: auto-detect first UP bridge
NICO_PRIMARY_IFACE="${NICO_PRIMARY_IFACE:-enp1s0}" # guest NIC carrying the static API IP
NICO_EXTRA_NETWORKS="${NICO_EXTRA_NETWORKS:-}"       # optional comma-separated libvirt networks
NICO_EXTRA_BRIDGES="${NICO_EXTRA_BRIDGES:-}"         # optional comma-separated host Linux bridges
NICO_NETMASK="${NICO_NETMASK:-24}"
NICO_OLM_WORKAROUND="${NICO_OLM_WORKAROUND:-true}" # LVMS via previous-minor catalog
NICO_LOCAL_GATEWAY="${NICO_LOCAL_GATEWAY:-false}"  # day-1 OVN local-gateway mode (MetalLB on a dedicated VLAN NIC)
# Required (no default): NICO_BASE_DOMAIN, NICO_API_IP, NICO_GW, NICO_DNS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_NET_FILE="${SCRIPT_DIR}/static_net.yaml"
KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig"
ADMIN_PASS_FILE="${SCRIPT_DIR}/kubeadmin-password.${NICO_CLUSTER_NAME}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
retry() { local n=$1 d=$2; shift 2; for ((i=1;i<=n;i++)); do "$@" && return 0; [ $i -eq $n ] && return 1; sleep "$d"; done; return 1; }

cluster_status() { aicli info cluster "$NICO_CLUSTER_NAME" -f status -v 2>/dev/null; }

check_preflight() {
    local missing=()
    for bin in aicli oc; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"
    aicli list clusters >/dev/null 2>&1 \
        || die "aicli is not authenticated (set up ~/.aicli/offlinetoken.txt and check connectivity)"
}

check_vm_preflight() {
    local missing=()
    for bin in virt-install virsh md5sum ip python3; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing required VM tools: ${missing[*]}"
    resolve_bridge
    local network seen=,
    if [ -n "$NICO_EXTRA_NETWORKS" ]; then
        [[ "$NICO_EXTRA_NETWORKS" =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]] \
            || die "invalid extra network list: $NICO_EXTRA_NETWORKS"
        local -a networks
        IFS=, read -ra networks <<< "$NICO_EXTRA_NETWORKS"
        for network in "${networks[@]}"; do
            [[ "$seen" != *",$network,"* ]] || die "duplicate extra network: $network"
            seen+="$network,"
            local netinfo
            netinfo=$(virsh -c qemu:///system net-info "$network") \
                || die "cannot query libvirt network $network"
            grep -Eq '^Active:[[:space:]]+yes$' <<< "$netinfo" \
                || die "libvirt network $network is not active"
        done
    fi
    if [ -n "$NICO_EXTRA_BRIDGES" ]; then
        [[ "$NICO_EXTRA_BRIDGES" =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]] \
            || die "invalid extra bridge list: $NICO_EXTRA_BRIDGES"
        local -a bridges
        IFS=, read -ra bridges <<< "$NICO_EXTRA_BRIDGES"
        for bridge in "${bridges[@]}"; do
            [ "$bridge" != "$NICO_BRIDGE" ] || die "extra bridge $bridge is the primary bridge"
            ip link show type bridge "$bridge" >/dev/null 2>&1 \
                || die "host linux bridge $bridge does not exist"
        done
    fi
    [[ "$NICO_DISK_PATH" = /* ]] || die "NICO_DISK_PATH must be absolute"
}

# Bridge for the VM: explicit NICO_BRIDGE wins; otherwise auto-detect the
# first UP non-virtual bridge. The caller must verify it reaches NICO_API_IP.
resolve_bridge() {
    if [ -n "$NICO_BRIDGE" ]; then
        ip link show type bridge "$NICO_BRIDGE" >/dev/null 2>&1 \
            || die "bridge $NICO_BRIDGE does not exist. Create it first, e.g.:
  nmcli connection add type bridge con-name $NICO_BRIDGE ifname $NICO_BRIDGE
  nmcli connection up $NICO_BRIDGE
  nmcli connection modify $NICO_BRIDGE +ipv4.address <host-ip>/<pl>
  nmcli connection modify $NICO_BRIDGE +ipv4.gateway $NICO_GW
  nmcli connection modify $NICO_BRIDGE ipv4.method manual && nmcli connection up $NICO_BRIDGE"
        return 0
    fi
    local b
    for b in $(ip -o link show type bridge 2>/dev/null | awk '{print $2}' | cut -d@ -f1 | tr -d ':'); do
        case "$b" in virbr*|docker*|kube*|cali*|flannel*) continue ;; esac
        if ip link show "$b" 2>/dev/null | grep -q "state UP"; then
            NICO_BRIDGE="$b"
            log "Auto-detected bridge: $b (override with NICO_BRIDGE)"
            return 0
        fi
    done
    die "no usable bridge found on this host. Create one, e.g.:
  nmcli connection add type bridge con-name mgmt-br ifname mgmt-br
  nmcli connection up mgmt-br
  nmcli connection modify mgmt-br +ipv4.address <host-ip>/<pl>
  nmcli connection modify mgmt-br +ipv4.gateway $NICO_GW
  nmcli connection modify mgmt-br ipv4.method manual && nmcli connection up mgmt-br"
}

# Deterministic local MAC from the cluster name (stable across re-runs).
vm_mac() {
    local hex
    hex=$(printf '%s' "$NICO_CLUSTER_NAME" | md5sum | cut -c1-6)
    echo "52:54:00:${hex:0:2}:${hex:2:2}:${hex:4:2}"
}

extra_mac() {
    local hex
    hex=$(printf '%s:%s' "$NICO_CLUSTER_NAME" "$1" | md5sum | cut -c1-6)
    echo "52:54:00:${hex:0:2}:${hex:2:2}:${hex:4:2}"
}

write_static_net() {
    local mac extra_interfaces='' network index=2
    mac=$(vm_mac)
    if [ -n "$NICO_EXTRA_NETWORKS" ]; then
        local -a networks
        IFS=, read -ra networks <<< "$NICO_EXTRA_NETWORKS"
        for network in "${networks[@]}"; do
            extra_interfaces+="   - name: enp${index}s0
     type: ethernet
     state: up
     mac-address: '$(extra_mac "$network")'
     ipv4:
       enabled: false
     ipv6:
       enabled: false
"
            ((index+=1))
        done
    fi
    if [ -n "$NICO_EXTRA_BRIDGES" ]; then
        local -a bridges
        IFS=, read -ra bridges <<< "$NICO_EXTRA_BRIDGES"
        for bridge in "${bridges[@]}"; do
            extra_interfaces+="   - name: enp${index}s0
     type: ethernet
     state: up
     mac-address: '$(extra_mac "$bridge")'
     ipv4:
       enabled: false
     ipv6:
       enabled: false
"
            ((index+=1))
        done
    fi
    log "Static IP config: ${NICO_API_IP}/${NICO_NETMASK}, GW ${NICO_GW}, DNS ${NICO_DNS}, iface ${NICO_PRIMARY_IFACE}, MAC ${mac}"
    cat > "$STATIC_NET_FILE" <<EOF
static_network_config:
- interfaces:
   - name: ${NICO_PRIMARY_IFACE}
     type: ethernet
     state: up
     mtu: 1500
     mac-address: '${mac}'
     ipv4:
       enabled: true
       dhcp: false
       address:
         - ip: ${NICO_API_IP}
           prefix-length: ${NICO_NETMASK}
${extra_interfaces}  dns-resolver:
    config:
      server:
        - ${NICO_DNS}
  routes:
    config:
      - destination: 0.0.0.0/0
        next-hop-address: ${NICO_GW}
        next-hop-interface: ${NICO_PRIMARY_IFACE}
EOF
}

create_cluster() {
    local ssh_key="${NICO_SSH_PUB_KEY:-$(ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -1)}"
    [ -n "$ssh_key" ] || die "no SSH public key found (set NICO_SSH_PUB_KEY)"
    [ -f "$ssh_key" ] || die "SSH public key not found: $ssh_key"
    [ -f "$NICO_PULL_SECRET" ] || die "pull secret not found: $NICO_PULL_SECRET"

    log "Creating cluster ${NICO_CLUSTER_NAME} (${NICO_OPENSHIFT_VERSION}, SNO)..."
    aicli create cluster \
        -P openshift_version="${NICO_OPENSHIFT_VERSION}" \
        -P base_dns_domain="${NICO_BASE_DOMAIN}" \
        -P pull_secret="${NICO_PULL_SECRET}" \
        -P high_availability_mode=None \
        -P public_key="${ssh_key}" \
        -P user_managed_networking=True \
        --paramfile "${STATIC_NET_FILE}" \
        "${NICO_CLUSTER_NAME}"

    # Day-1 OVN local-gateway mode so MetalLB LoadBalancer VIPs work on a
    # dedicated secondary VLAN NIC (see manifests-day1/cluster-network-03-config.yaml).
    # Opt-in: only labs that expose services on a dedicated VLAN need it.
    if [ "${NICO_LOCAL_GATEWAY}" = "true" ]; then
        log "Uploading day-1 local-gateway manifest (routingViaHost: true)..."
        aicli create manifest --dir "${SCRIPT_DIR}/manifests-day1" --openshift "${NICO_CLUSTER_NAME}"
    fi
}

wait_status() {
    local status=$1 max_retries=$2 current
    log "Waiting for cluster ${NICO_CLUSTER_NAME} to reach status: ${status} (up to ${max_retries} min)"
    for ((i=1;i<=max_retries;i++)); do
        current=$(cluster_status) || die "cannot query status of cluster ${NICO_CLUSTER_NAME}"
        case "$current" in
            error|cancelled) die "cluster ${NICO_CLUSTER_NAME} entered terminal status: ${current}" ;;
            '') die "cannot query status of cluster ${NICO_CLUSTER_NAME}" ;;
        esac
        if [ "$status" = "ready" ]; then
            case "$current" in
                installed|preparing-for-installation|installing|finalizing)
                    log "Cluster has advanced to ${current}; skipping wait for 'ready'."
                    return 0 ;;
            esac
        fi
        if [ "$current" = "$status" ]; then
            log "Cluster status: ${status}"
            return 0
        fi
        log "status=${current} (attempt ${i}/${max_retries})"
        sleep 60
    done
    die "timeout waiting for cluster status ${status}"
}

validate_vm() {
    local vm=$1 xml
    xml=$(virsh -c qemu:///system dumpxml "$vm") || die "cannot inspect VM ${vm}"
    python3 -c '
import sys
import xml.etree.ElementTree as ET

import hashlib

root = ET.fromstring(sys.stdin.read())
bridge, networks, bridges, mac, disk_path, vm, cluster = sys.argv[1:]
def extra_mac(name):
    digest = hashlib.md5((cluster + ":" + name).encode()).hexdigest()[:6]
    return "52:54:00:" + ":".join(digest[i:i+2] for i in (0, 2, 4))
expected = [("bridge", bridge, mac)]
for name in filter(None, networks.split(",")):
    expected.append(("network", name, extra_mac(name)))
for name in filter(None, bridges.split(",")):
    expected.append(("bridge", name, extra_mac(name)))
actual = []
for iface in root.findall("./devices/interface"):
    source = iface.find("source")
    address = iface.find("mac")
    actual.append((iface.get("type"), source.get(iface.get("type")) if source is not None else None,
                   address.get("address") if address is not None else None))
disks = [disk.find("source").get("file") for disk in root.findall("./devices/disk")
         if disk.get("device") == "disk" and disk.find("source") is not None]
expected_disks = [f"{disk_path}/{vm}-disk{i}.qcow2" for i in (1, 2)]
if actual != expected or disks != expected_disks:
    sys.exit("VM network or disks do not match requested bootstrap configuration")
' "$NICO_BRIDGE" "$NICO_EXTRA_NETWORKS" "$NICO_EXTRA_BRIDGES" "$(vm_mac)" "$NICO_DISK_PATH" "$vm" "$NICO_CLUSTER_NAME" <<< "$xml" \
        || die "refusing to reuse mismatched VM ${vm}"
}

create_vm() {
    local vm="${NICO_VM_PREFIX}1" pid='' state existing_vms network
    local -a extra_network_args=()
    if [ -n "$NICO_EXTRA_NETWORKS" ]; then
        local -a networks
        IFS=, read -ra networks <<< "$NICO_EXTRA_NETWORKS"
        for network in "${networks[@]}"; do
            extra_network_args+=(--network "network=${network},model=virtio,mac=$(extra_mac "$network")")
        done
    fi
    if [ -n "$NICO_EXTRA_BRIDGES" ]; then
        local -a bridges
        IFS=, read -ra bridges <<< "$NICO_EXTRA_BRIDGES"
        for bridge in "${bridges[@]}"; do
            extra_network_args+=(--network "bridge=${bridge},model=virtio,mac=$(extra_mac "$bridge")")
        done
    fi
    existing_vms=$(virsh -c qemu:///system list --all --name) || die "cannot list system VMs"
    if grep -Fxq "$vm" <<< "$existing_vms"; then
        validate_vm "$vm"
        log "VM ${vm} already exists"
        state=$(virsh -c qemu:///system domstate "$vm") || die "cannot inspect VM ${vm}"
        [ "$state" = "running" ] || virsh -c qemu:///system start "$vm" || die "cannot start VM ${vm}"
    else
        mkdir -p "$NICO_DISK_PATH"
        for disk in "${NICO_DISK_PATH}/${vm}-disk1.qcow2" "${NICO_DISK_PATH}/${vm}-disk2.qcow2"; do
            [ ! -e "$disk" ] || die "refusing to overwrite existing disk: $disk"
        done
        log "Creating VM ${vm} (${NICO_VCPUS} vCPU, ${NICO_RAM} MiB, ${NICO_DISK1}+${NICO_DISK2} GiB)..."
        local -a vm_args=(--connect qemu:///system --name "$vm"
            --memory "$NICO_RAM" --vcpus "$NICO_VCPUS"
            --os-variant=rhel9.4
            --disk "path=${NICO_DISK_PATH}/${vm}-disk1.qcow2,size=${NICO_DISK1}"
            --disk "path=${NICO_DISK_PATH}/${vm}-disk2.qcow2,size=${NICO_DISK2}"
            --network "bridge=${NICO_BRIDGE},model=virtio,mac=$(vm_mac)")
        if [ ${#extra_network_args[@]} -gt 0 ]; then
            vm_args+=("${extra_network_args[@]}")
        fi
        vm_args+=(--graphics=vnc --events on_reboot=restart
            --cdrom "${NICO_DISK_PATH}/${NICO_CLUSTER_NAME}.iso"
            --cpu host-passthrough --boot uefi --noautoconsole --wait=-1)
        nohup virt-install "${vm_args[@]}" >"${SCRIPT_DIR}/virt-install.log" 2>&1 &
        pid=$!
    fi
    for ((i=1;i<=30;i++)); do
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || die "virt-install failed; see ${SCRIPT_DIR}/virt-install.log"
        fi
        if state=$(virsh -c qemu:///system domstate "$vm" 2>/dev/null) && [ "$state" = "running" ]; then
            return 0
        fi
        sleep 2
    done
    die "VM ${vm} did not start; see ${SCRIPT_DIR}/virt-install.log"
}

deploy_lvm() {
    local catalog="redhat-operators"
    if [ "$NICO_OLM_WORKAROUND" = "true" ]; then
        # LVMS subscription targets the previous-minor Red Hat catalog
        # (e.g. 4.22 -> 4.21), created by the dpf automation for this
        # deployment. Derive it from the actual OCP version on every run.
        local ocp_version minor olm_version
        ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') \
            || die "cannot determine installed OpenShift version"
        [[ "$ocp_version" =~ ^([0-9]+)\.([0-9]+)(\.|$) ]] \
            || die "invalid installed OpenShift version: ${ocp_version}"
        minor="${BASH_REMATCH[2]}"
        [ "$minor" -gt 0 ] || die "cannot derive previous-minor catalog from ${ocp_version}"
        olm_version="${BASH_REMATCH[1]}.$((minor - 1))"
        catalog="redhat-operators-v${olm_version}"
        log "Creating workaround CatalogSource ${catalog}..."
        sed -e "s/<OLM_VERSION>/${olm_version}/g" \
            "${SCRIPT_DIR}/manifests/lvm-catalogsource.yaml" | oc apply -f -
    fi

    log "Subscribing to LVMS operator (catalog: ${catalog})..."
    local subscription
    subscription=$(mktemp -d)/subscription.yaml
    sed -e "s/<CATALOG_SOURCE_NAME>/${catalog}/g" \
        "${SCRIPT_DIR}/manifests/lvm-subscription.yaml" > "$subscription"
    retry 12 15 oc apply -f "$subscription" || { rm -rf "${subscription%/*}"; die "LVMS subscription failed"; }
    rm -rf "${subscription%/*}"

    log "Waiting for LVMS operator pod..."
    retry 60 10 bash -c "oc get pod -n openshift-storage -l app.kubernetes.io/name=lvms-operator --no-headers | grep -q '1/1.*Running'"

    if ! oc get lvmcluster -n openshift-storage my-lvmcluster >/dev/null 2>&1; then
        log "Creating LVMCluster (auto-selects free disks; ${NICO_DISK2} GiB spare expected)..."
        retry 30 10 oc apply -f "${SCRIPT_DIR}/manifests/lvmcluster.yaml"
    fi

    log "Waiting for LVMS to report ready and create its StorageClass..."
    retry 60 10 bash -c 'oc get lvmcluster my-lvmcluster -n openshift-storage -o jsonpath="{.status.state}" | grep -qx Ready' \
        || die "LVMCluster did not become Ready; check the spare disk and LVMS operator"
    retry 30 10 oc get storageclass lvms-vg1 >/dev/null \
        || die "LVMS StorageClass lvms-vg1 was not created"
    oc annotate storageclass lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
    log "Default StorageClass ready:"
    oc get storageclass
}

cluster_exists() {
    local clusters
    clusters=$(aicli -o name list clusters) || die "cannot list Assisted Installer clusters"
    grep -Fxq "$NICO_CLUSTER_NAME" <<< "$clusters"
}

refresh_credentials() {
    local download_dir server expected
    download_dir=$(mktemp -d "$SCRIPT_DIR/.credentials.XXXXXX")
    if ! aicli download kubeconfig "$NICO_CLUSTER_NAME" --path "$download_dir"; then
        rm -rf "$download_dir"
        die "failed to download kubeconfig for ${NICO_CLUSTER_NAME}"
    fi
    local downloaded="$download_dir/kubeconfig.${NICO_CLUSTER_NAME}"
    if [ ! -s "$downloaded" ]; then
        rm -rf "$download_dir"
        die "downloaded kubeconfig is empty or missing"
    fi
    server=$(oc --kubeconfig="$downloaded" config view --raw -o jsonpath='{.clusters[0].cluster.server}') || {
        rm -rf "$download_dir"
        die "downloaded kubeconfig cannot be parsed"
    }
    expected="https://api.${NICO_CLUSTER_NAME}.${NICO_BASE_DOMAIN}:6443"
    if [ "$server" != "$expected" ]; then
        rm -rf "$download_dir"
        die "downloaded kubeconfig points to ${server}, expected ${expected}"
    fi
    chmod 600 "$downloaded"
    mv -f "$downloaded" "$KUBECONFIG_FILE"
    if aicli download kubeadmin-password "$NICO_CLUSTER_NAME" --path "$download_dir"; then
        local password="$download_dir/kubeadmin-password.${NICO_CLUSTER_NAME}"
        if [ -s "$password" ]; then
            chmod 600 "$password"
            mv -f "$password" "$ADMIN_PASS_FILE"
            log "Admin password: ${ADMIN_PASS_FILE}"
        else
            log "Warning: kubeadmin password download returned an empty file"
        fi
    else
        log "Warning: could not download kubeadmin password"
    fi
    rm -rf "$download_dir"
}

install() {
    local status
    check_preflight
    if cluster_exists; then
        status=$(cluster_status) || die "cannot query status of cluster ${NICO_CLUSTER_NAME}"
    else
        status=absent
    fi
    case "$status" in
        installed) log "Cluster ${NICO_CLUSTER_NAME} is already installed." ;;
        error|cancelled) die "cluster ${NICO_CLUSTER_NAME} entered terminal status: ${status}" ;;
        preparing-for-installation|installing|finalizing) wait_status installed 120 ;;
        *)
            [[ -n "${NICO_BASE_DOMAIN:-}" && -n "${NICO_API_IP:-}" && -n "${NICO_GW:-}" && -n "${NICO_DNS:-}" ]] \
                || die "NICO_BASE_DOMAIN, NICO_API_IP, NICO_GW and NICO_DNS are required to create or resume a VM"
            check_vm_preflight
            write_static_net
            if [ "$status" = absent ]; then
                create_cluster
            else
                log "Cluster ${NICO_CLUSTER_NAME} already exists in aicli (status: ${status})"
            fi
            mkdir -p "$NICO_DISK_PATH"
            log "Downloading installer ISO..."
            aicli download iso "$NICO_CLUSTER_NAME" -p "$NICO_DISK_PATH"
            create_vm
            wait_status ready 90
            status=$(cluster_status) || die "cannot query status of cluster ${NICO_CLUSTER_NAME}"
            case "$status" in
                ready)
                    log "Starting installation..."
                    aicli start cluster "$NICO_CLUSTER_NAME"
                    wait_status installed 120 ;;
                installed) : ;;
                preparing-for-installation|installing|finalizing) wait_status installed 120 ;;
                *) die "cannot start cluster ${NICO_CLUSTER_NAME} from status: ${status}" ;;
            esac
            ;;
    esac

    NICO_BASE_DOMAIN="${NICO_BASE_DOMAIN:-$(aicli info cluster "$NICO_CLUSTER_NAME" -f base_dns_domain -v)}"
    [ -n "$NICO_BASE_DOMAIN" ] || die "cannot determine cluster base domain"
    log "Downloading kubeconfig and admin password..."
    refresh_credentials
    export KUBECONFIG="$KUBECONFIG_FILE"
    deploy_lvm

    log "=== Bootstrap complete ==="
    log "  export KUBECONFIG=${KUBECONFIG_FILE}"
    log "Console: https://console-openshift-console.apps.${NICO_CLUSTER_NAME}.${NICO_BASE_DOMAIN}"
}

clean() {
    local vm="${NICO_VM_PREFIX}1" vms state
    command -v aicli >/dev/null && command -v virsh >/dev/null \
        || die "aicli and virsh are required for cleanup"
    if cluster_exists; then
        log "Deleting cluster ${NICO_CLUSTER_NAME}..."
        aicli delete cluster "$NICO_CLUSTER_NAME" -y || die "Assisted Installer cluster deletion failed; local VM was not removed"
    fi
    vms=$(virsh -c qemu:///system list --all --name) || die "cannot list system VMs"
    if grep -Fxq "$vm" <<< "$vms"; then
        state=$(virsh -c qemu:///system domstate "$vm") || die "cannot inspect VM ${vm}"
        if [ "$state" = running ]; then
            virsh -c qemu:///system destroy "$vm" || die "could not stop VM ${vm}; disks preserved"
        elif [ "$state" != 'shut off' ]; then
            die "VM ${vm} is ${state}; stop it manually before cleanup"
        fi
        virsh -c qemu:///system undefine "$vm" --nvram || die "could not undefine VM ${vm}; disks preserved"
        rm -f "${NICO_DISK_PATH}/${vm}-disk1.qcow2" "${NICO_DISK_PATH}/${vm}-disk2.qcow2"
    fi
    rm -f "${NICO_DISK_PATH}/${NICO_CLUSTER_NAME}.iso" "$STATIC_NET_FILE"
    log "Clean complete."
}

cmd="${1:-install}"; shift || true
case "$cmd" in
    install) install "$@" ;;
    clean)   clean "$@" ;;
    *) die "unknown command: $cmd (use 'install' or 'clean')" ;;
esac
