#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Helm post-renderer plugin that applies Kustomize patches to rendered manifests.
# Usage: helm install ... --post-renderer kustomize-post-renderer --post-renderer-args <kustomize-dir>

set -euo pipefail

KUSTOMIZE_DIR="${1:?Usage: --post-renderer-args <path-to-kustomize-dir>}"

# Use $HOME as the base for the temp dir: snap-confined kustomize cannot
# access /tmp (it gets mapped to /var/lib/snapd/void), but can access $HOME.
WORK_DIR=$(mktemp -d "$HOME/kustomize-post-renderer-XXXXXX")
trap "rm -rf $WORK_DIR" EXIT

cat > "$WORK_DIR/all.yaml.raw"

# Some upstream charts emit duplicate YAML mapping keys (e.g. nico-flow's
# labels + selectorLabels both output app.kubernetes.io/name). kubectl
# tolerates this but kustomize v5's strict YAML parser rejects it.
# Round-trip through Python's yaml parser which silently deduplicates keys.
#
# Also auto-numbers subnet4[].id in any kea_config.json ConfigMap: the
# nico-dhcp chart's template never emits one, and Kea 3.0+ requires it
# (see nico-core.yaml's nico-dhcp comment). Lets structured config.kea.*
# values work without a hand-written keaConfigJsonRaw blob.
python3 -c "
import json, yaml

# Kubernetes integer fields that Helm templates sometimes emit as quoted strings.
# PyYAML round-trips them as str; coerce back to int so the API server accepts them.
K8S_INT_KEYS = {
    'terminationGracePeriodSeconds', 'replicas', 'port', 'containerPort',
    'hostPort', 'successThreshold', 'failureThreshold', 'periodSeconds',
    'timeoutSeconds', 'initialDelaySeconds', 'startupSeconds',
    'revisionHistoryLimit', 'minReadySeconds', 'activeDeadlineSeconds',
    'backoffLimit', 'completions', 'parallelism', 'ttlSecondsAfterFinished',
}

def coerce_ints(obj, parent_key=None):
    if isinstance(obj, dict):
        return {k: coerce_ints(v, k) for k, v in obj.items()}
    if isinstance(obj, list):
        return [coerce_ints(v, parent_key) for v in obj]
    if isinstance(obj, str) and parent_key in K8S_INT_KEYS:
        try:
            return int(obj)
        except ValueError:
            pass
    return obj

content = open('$WORK_DIR/all.yaml.raw').read()
# ConfigMap .data is map[string]string — skip coercion to avoid turning
# string values like '8080' into bare ints the API server rejects.
docs = [
    doc if doc.get('kind') == 'ConfigMap' else coerce_ints(doc)
    for doc in yaml.safe_load_all(content) if doc is not None
]
for doc in docs:
    if doc.get('kind') != 'ConfigMap':
        continue
    data = doc.get('data') or {}
    raw = data.get('kea_config.json')
    if not raw:
        continue
    try:
        kea = json.loads(raw)
    except ValueError:
        continue
    subnets = kea.get('Dhcp4', {}).get('subnet4', [])
    changed = False
    # Allocate IDs from values not already taken by explicitly-numbered subnets,
    # so a mix of explicit and missing IDs never produces duplicates.
    used_ids = {subnet['id'] for subnet in subnets if 'id' in subnet}
    next_id = 1
    for subnet in subnets:
        if 'id' in subnet:
            continue
        while next_id in used_ids:
            next_id += 1
        subnet['id'] = next_id
        used_ids.add(next_id)
        next_id += 1
        changed = True
    if changed:
        data['kea_config.json'] = json.dumps(kea, indent=2)
for doc in docs:
    print('---')
    print(yaml.dump(doc, default_flow_style=False, width=200), end='')
" > "$WORK_DIR/all.yaml"

cp -rL "$KUSTOMIZE_DIR/." "$WORK_DIR/"

# kustomize's strategic-merge patch serializes null *int64 fields as the
# YAML string "null" instead of true YAML null, which the API server rejects.
kustomize build "$WORK_DIR" | \
  sed 's/^\( *[a-zA-Z]*: \)"null"$/\1null/g'
