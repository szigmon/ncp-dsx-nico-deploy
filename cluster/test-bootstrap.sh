#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Offline bootstrap regression checks: all external commands are local stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'if [ "${TEST_DEBUG:-no}" = yes ]; then printf "Fixture: %s\n" "$TMP"; else rm -rf "$TMP"; fi' EXIT
mkdir -p "$TMP/cluster/manifests" "$TMP/bin" "$TMP/disks"
cp "$ROOT/cluster/bootstrap.sh" "$TMP/cluster/bootstrap.sh"
cp "$ROOT"/cluster/manifests/*.yaml "$TMP/cluster/manifests/"
export TEST_DIR="$TMP" PATH="$TMP/bin:$PATH"

cat > "$TMP/bin/aicli" <<'EOF'
#!/usr/bin/env bash
set -e
printf 'aicli %s\n' "$*" >> "$TEST_DIR/log"
if [ "$1" = -o ]; then
    [ "${TEST_EXISTS:-yes}" != no ] && printf '%s\n' "${TEST_NAME:-nico-lab}"
    exit 0
fi
case "$1 $2" in
    'list clusters') exit 0 ;;
    'info cluster')
        case "$*" in
            *' -f status -v')
                if { [ "${TEST_STATUS:-installed}" = ready ] && [ -f "$TEST_DIR/started" ]; } || { [ "${TEST_STATUS:-installed}" = installing ] && [ -f "$TEST_DIR/finished" ]; }; then
                    printf 'installed\n'
                else
                    printf '%s\n' "${TEST_STATUS:-installed}"
                fi ;;
            *' -f base_dns_domain -v') printf '%s\n' example.com ;;
        esac ;;
    'download kubeconfig')
        [ "${TEST_FAIL_DOWNLOAD:-no}" != yes ] || exit 1
        while [ "$#" -gt 0 ] && [ "$1" != --path ]; do shift; done
        printf 'apiVersion: v1\n' > "$2/kubeconfig.${TEST_NAME:-nico-lab}" ;;
    'download kubeadmin-password') exit 1 ;;
    'download iso') exit 0 ;;
    'delete cluster') [ "${TEST_FAIL_DELETE:-no}" != yes ] ;;
    'start cluster') touch "$TEST_DIR/started" ;;
    'create cluster') exit 0 ;;
    *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -e
printf 'oc %s\n' "$*" >> "$TEST_DIR/log"
case "$1" in
    --kubeconfig=*) printf '%s' "${TEST_SERVER:-https://api.${TEST_NAME:-nico-lab}.example.com:6443}" ;;
    apply)
        if [ "$2" = -f ]; then
            grep 'source: redhat-operators' "$3" >> "$TEST_DIR/subscriptions" || true
            if [ "${TEST_RETRY:-no}" = yes ] && grep -q 'source: redhat-operators' "$3" && [ ! -f "$TEST_DIR/failed-once" ]; then
                touch "$TEST_DIR/failed-once"
                exit 1
            fi
        fi ;;
    get)
        case "$2" in
            pod) printf 'lvms-operator 1/1 Running\n' ;;
            lvmcluster) [[ "$*" != *jsonpath=* ]] || printf 'Ready\n' ;;
            storageclass) printf 'lvms-vg1\n' ;;
            clusterversion) printf '%s' "${TEST_OCP_VERSION:-4.22.7}" ;;
        esac ;;
esac
EOF
cat > "$TMP/bin/virsh" <<'EOF'
#!/usr/bin/env bash
set -e
printf 'virsh %s\n' "$*" >> "$TEST_DIR/log"
[ "$1 $2" = '-c qemu:///system' ] || exit 2
shift 2
case "$1" in
    list) printf '%s\n' "${TEST_VMS:-}" ;;
    domstate) [ "${TEST_FAIL_VM:-no}" != yes ] || exit 1; printf '%s\n' "${TEST_VM_STATE:-running}" ;;
    net-info) printf 'Active: yes\n' ;;
    dumpxml)
        vm=$2
        mac=$(printf '%s' "${TEST_NAME:-nico-lab}" | md5sum | cut -c1-6)
        printf '<domain><devices><interface type="bridge"><source bridge="mgmt-br"/><mac address="52:54:00:%s:%s:%s"/></interface><disk device="disk"><source file="%s/%s-disk1.qcow2"/></disk><disk device="disk"><source file="%s/%s-disk2.qcow2"/></disk></devices></domain>\n' "${mac:0:2}" "${mac:2:2}" "${mac:4:2}" "$TEST_DIR/disks" "$vm" "$TEST_DIR/disks" "$vm" ;;
    destroy|undefine|start) exit 0 ;;
    *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/virt-install" <<'EOF'
#!/usr/bin/env bash
printf 'virt-install %s\n' "$*" >> "$TEST_DIR/log"
[ "${TEST_FAIL_VM:-no}" != yes ]
EOF
cat > "$TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = link ] && [ "$2" = show ] && [ "$3" = type ] && [ "$4" = bridge ]; then
    case " ${TEST_BRIDGES:-mgmt-br} " in
        *" $5 "*) printf '2: %s: <UP> state UP\n' "$5" ;;
        *) exit 1 ;;
    esac
elif [ "$1" = link ]; then
    printf '2: mgmt-br: <UP> state UP\n'
fi
exit 0
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
[ "${TEST_STATUS:-}" != installing ] || touch "$TEST_DIR/finished"
exit 0
EOF
chmod +x "$TMP/bin/"*

reset_case() { : > "$TMP/log"; rm -f "$TMP/failed-once" "$TMP/subscriptions" "$TMP/started" "$TMP/finished"; }
run_bootstrap() { bash "$TMP/cluster/bootstrap.sh" "$@" > "$TMP/output" 2>&1; }
assert_logged() { grep -Fq "$1" "$TMP/log" || { printf 'Missing log: %s\n' "$1" >&2; exit 1; }; }
assert_not_logged() { ! grep -Fq "$1" "$TMP/log" || { printf 'Unexpected log: %s\n' "$1" >&2; exit 1; }; }

reset_case
printf 'old-password\n' > "$TMP/cluster/kubeadmin-password.staging"
TEST_STATUS=installed TEST_NAME=staging run_bootstrap install NICO_CLUSTER_NAME=staging
! grep -q 'Admin password:' "$TMP/output"
assert_not_logged 'virt-install '
assert_logged 'download kubeconfig staging'

reset_case
TEST_STATUS=ready TEST_NAME=staging TEST_RETRY=yes run_bootstrap install NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_DISK_PATH="$TMP/disks"
assert_logged 'virt-install --connect qemu:///system --name vm-staging1'
assert_logged 'start cluster staging'
mac=$(grep -oE '52:54:00:([[:xdigit:]]{2}:){2}[[:xdigit:]]{2}' "$TMP/cluster/static_net.yaml")
assert_logged "mac=$mac"
[ "$(wc -l < "$TMP/subscriptions")" -eq 2 ]

reset_case
TEST_STATUS=installing TEST_OCP_VERSION=4.23.4 run_bootstrap install
assert_not_logged 'start cluster'
assert_not_logged 'virt-install '
assert_logged 'get clusterversion version'
grep -Fq 'source: redhat-operators-v4.22' "$TMP/subscriptions" || {
    printf 'Wrong catalog for installed OCP version\n' >&2; exit 1
}

reset_case
if TEST_STATUS=error run_bootstrap install; then printf 'Terminal error was accepted\n' >&2; exit 1; fi
assert_not_logged 'download kubeconfig'

reset_case
printf STALE > "$TMP/cluster/kubeconfig"
if TEST_STATUS=installed TEST_FAIL_DOWNLOAD=yes run_bootstrap install; then printf 'Failed download was accepted\n' >&2; exit 1; fi
[ "$(< "$TMP/cluster/kubeconfig")" = STALE ]
assert_not_logged 'oc annotate'

reset_case
if TEST_STATUS=installed TEST_SERVER=https://api.other.example.com:6443 run_bootstrap install; then
    printf 'Wrong-cluster kubeconfig was accepted\n' >&2; exit 1
fi
[ "$(< "$TMP/cluster/kubeconfig")" = STALE ]
assert_not_logged 'oc annotate'

reset_case
if TEST_STATUS=ready TEST_NAME=staging TEST_FAIL_VM=yes run_bootstrap install NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_DISK_PATH="$TMP/disks"; then
    printf 'Failed VM was accepted\n' >&2; exit 1
fi
assert_not_logged 'start cluster'

reset_case
if TEST_STATUS=ready TEST_NAME=staging TEST_VMS=vm-staging1 TEST_VM_STATE='shut off' run_bootstrap install NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_DISK_PATH="$TMP/disks"; then
    printf 'Stopped VM was accepted as running\n' >&2; exit 1
fi
assert_logged 'virsh -c qemu:///system start vm-staging1'
assert_not_logged 'start cluster'

reset_case
printf 'disk\n' > "$TMP/disks/vm-staging1-disk1.qcow2"
if TEST_NAME=staging TEST_FAIL_DELETE=yes TEST_VMS=$'vm-staging1\nvm-staging-backup1' run_bootstrap clean NICO_CLUSTER_NAME=staging NICO_DISK_PATH="$TMP/disks"; then
    printf 'Failed delete removed local resources\n' >&2; exit 1
fi
[ -f "$TMP/disks/vm-staging1-disk1.qcow2" ]
assert_not_logged 'virsh -c qemu:///system destroy'

reset_case
TEST_NAME=staging TEST_VMS=$'vm-staging1\nvm-staging-backup1' run_bootstrap clean NICO_CLUSTER_NAME=staging NICO_DISK_PATH="$TMP/disks"
assert_logged 'virsh -c qemu:///system destroy vm-staging1'
assert_logged 'virsh -c qemu:///system undefine vm-staging1 --nvram'
assert_not_logged 'vm-staging-backup1 --nvram'
[ ! -f "$TMP/disks/vm-staging1-disk1.qcow2" ]

reset_case
printf '{}\n' > "$TMP/pull.json"
printf 'ssh-ed25519 test\n' > "$TMP/key.pub"
TEST_BRIDGES='mgmt-br br1' TEST_NAME=staging TEST_EXISTS=no TEST_VMS='' TEST_STATUS=ready run_bootstrap install NICO_PULL_SECRET="$TMP/pull.json" NICO_SSH_PUB_KEY="$TMP/key.pub" NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_EXTRA_NETWORKS=default NICO_EXTRA_BRIDGES=br1 NICO_DISK_PATH="$TMP/disks"
assert_logged 'create cluster'
assert_logged 'network=default,model=virtio,mac='
assert_logged 'bridge=br1,model=virtio,mac='
[ "$(grep -c 'mac-address:' "$TMP/cluster/static_net.yaml")" -eq 3 ]
[ "$(grep -c 'enabled: false' "$TMP/cluster/static_net.yaml")" -eq 4 ]
grep -Fq 'ip: 192.168.1.10' "$TMP/cluster/static_net.yaml"
[ "$(grep "mac-address:" "$TMP/cluster/static_net.yaml" | sort -u | wc -l)" -eq 3 ]

reset_case
if TEST_BRIDGES=mgmt-br TEST_NAME=staging TEST_EXISTS=no TEST_VMS='' TEST_STATUS=ready run_bootstrap install NICO_PULL_SECRET="$TMP/pull.json" NICO_SSH_PUB_KEY="$TMP/key.pub" NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_EXTRA_BRIDGES=missing-br NICO_DISK_PATH="$TMP/disks"; then
    printf 'Missing bridge was accepted\n' >&2; exit 1
fi
assert_not_logged 'virt-install '

reset_case
if TEST_NAME=staging TEST_VMS=vm-staging1 TEST_STATUS=ready run_bootstrap install NICO_CLUSTER_NAME=staging NICO_BASE_DOMAIN=example.com NICO_API_IP=192.168.1.10 NICO_GW=192.168.1.1 NICO_DNS=192.168.1.2 NICO_BRIDGE=mgmt-br NICO_EXTRA_NETWORKS=default,vlan712 NICO_DISK_PATH="$TMP/disks"; then
    printf 'Mismatched VM was accepted\n' >&2; exit 1
fi
assert_logged 'virsh -c qemu:///system dumpxml vm-staging1'
assert_not_logged 'start cluster'
printf 'bootstrap dry tests passed\n'
