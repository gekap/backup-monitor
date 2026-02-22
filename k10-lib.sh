#!/bin/bash
#
# k10-lib.sh
# Copyright (c) 2026 Georgios Kapellakis
# Licensed under AGPL-3.0 — see LICENSE for details.
#
# Shared compliance library for K10-tool.
# Provides cluster fingerprinting, enterprise detection, license key
# validation, and optional anonymous telemetry.
#
# Sourced by k10-cancel-stuck-actions.sh.
# All detection failures produce defaults — this library never crashes the caller.
#
# License enforcement:
#   - Non-enterprise clusters (score < 3): banner can be suppressed with K10TOOL_NO_BANNER=true
#   - Enterprise clusters (score >= 3): only a valid K10TOOL_LICENSE_KEY suppresses the banner
#   - License keys are HMAC-SHA256 based, tied to the cluster fingerprint

K10TOOL_VERSION="1.0.0"
K10TOOL_LICENSE_SECRET="k10tool-agpl3-commercial-2026"

# --- Cluster Fingerprint ---
# Generates a deterministic, anonymous fingerprint from the kube-system namespace UID.
# Appends to a local log file for the operator's own audit trail.
k10_cluster_fingerprint() {
    local fp_file="${K10TOOL_FINGERPRINT_FILE:-${HOME}/.k10tool-fingerprint}"
    local ks_uid
    ks_uid=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null) || true

    if [[ -z "$ks_uid" ]]; then
        K10_FINGERPRINT="unknown"
        return
    fi

    K10_FINGERPRINT=$(printf '%s' "$ks_uid" | sha256sum | cut -c1-16)

    # Append fingerprint with timestamp (idempotent per cluster)
    if [[ -n "$fp_file" ]]; then
        local entry
        entry="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${K10_FINGERPRINT}"
        # Only append if this fingerprint isn't already the last entry
        if ! tail -1 "$fp_file" 2>/dev/null | grep -q "$K10_FINGERPRINT"; then
            echo "$entry" >> "$fp_file" 2>/dev/null || true
        fi
    fi
}

# --- Enterprise Detection ---
# Scoring system (0-5 points). Threshold >= 3 triggers enterprise detection.
# Each signal is collected independently; failures default to 0 points.
k10_detect_enterprise() {
    K10_ENTERPRISE_SCORE=0
    K10_NODE_COUNT=0
    K10_NAMESPACE_COUNT=0
    K10_PROVIDER="unknown"
    K10_K10_VERSION=""
    K10_CP_NODES=0
    K10_HAS_PAID_LICENSE=false

    # Signal 1: Node count > 3
    K10_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l) || K10_NODE_COUNT=0
    K10_NODE_COUNT=$(( K10_NODE_COUNT + 0 ))  # ensure numeric
    if [[ $K10_NODE_COUNT -gt 3 ]]; then
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    fi

    # Signal 2: Managed Kubernetes (EKS/AKS/GKE/OpenShift)
    local node_labels server_version
    node_labels=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null) || node_labels=""
    server_version=$(kubectl version --short 2>/dev/null || kubectl version 2>/dev/null) || server_version=""

    if echo "$node_labels" | grep -qi "eks.amazonaws.com" 2>/dev/null; then
        K10_PROVIDER="EKS"
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    elif echo "$node_labels" | grep -qi "kubernetes.azure.com" 2>/dev/null; then
        K10_PROVIDER="AKS"
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    elif echo "$node_labels" | grep -qi "cloud.google.com/gke" 2>/dev/null; then
        K10_PROVIDER="GKE"
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    elif echo "$server_version" | grep -qi "openshift" 2>/dev/null; then
        K10_PROVIDER="OpenShift"
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    fi

    # Signal 3: Namespace count > 10
    K10_NAMESPACE_COUNT=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l) || K10_NAMESPACE_COUNT=0
    K10_NAMESPACE_COUNT=$(( K10_NAMESPACE_COUNT + 0 ))
    if [[ $K10_NAMESPACE_COUNT -gt 10 ]]; then
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    fi

    # Signal 4: HA control plane (>1 control-plane node)
    K10_CP_NODES=$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | wc -l) || K10_CP_NODES=0
    K10_CP_NODES=$(( K10_CP_NODES + 0 ))
    if [[ $K10_CP_NODES -le 0 ]]; then
        # Fallback: check for master label (older clusters)
        K10_CP_NODES=$(kubectl get nodes -l 'node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l) || K10_CP_NODES=0
        K10_CP_NODES=$(( K10_CP_NODES + 0 ))
    fi
    # Also count apiserver pods as HA signal
    local apiserver_pods
    apiserver_pods=$(kubectl get pods -n kube-system -l 'component=kube-apiserver' --no-headers 2>/dev/null | wc -l) || apiserver_pods=0
    apiserver_pods=$(( apiserver_pods + 0 ))
    if [[ $K10_CP_NODES -gt 1 ]] || [[ $apiserver_pods -gt 1 ]]; then
        K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
    fi

    # Signal 5: Paid K10 license (>5 nodes + license secret/configmap present)
    if [[ $K10_NODE_COUNT -gt 5 ]]; then
        local has_license=false
        # Check for K10 license configmap or secret in kasten-io namespace
        if kubectl get configmap -n kasten-io -l 'app=k10,component=license' --no-headers 2>/dev/null | grep -q .; then
            has_license=true
        elif kubectl get secret -n kasten-io -l 'app=k10,component=license' --no-headers 2>/dev/null | grep -q .; then
            has_license=true
        elif kubectl get configmap k10-license -n kasten-io --no-headers 2>/dev/null | grep -q .; then
            has_license=true
        elif kubectl get secret k10-license -n kasten-io --no-headers 2>/dev/null | grep -q .; then
            has_license=true
        fi
        if $has_license; then
            K10_HAS_PAID_LICENSE=true
            K10_ENTERPRISE_SCORE=$(( K10_ENTERPRISE_SCORE + 1 ))
        fi
    fi

    # Detect K10 version from the catalog deployment
    K10_K10_VERSION=$(kubectl get deployment catalog-svc -n kasten-io -o jsonpath='{.metadata.labels.version}' 2>/dev/null) || K10_K10_VERSION=""
    if [[ -z "$K10_K10_VERSION" ]]; then
        K10_K10_VERSION=$(kubectl get deployment catalog-svc -n kasten-io -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://' 2>/dev/null) || K10_K10_VERSION="unknown"
    fi

    # Result
    if [[ $K10_ENTERPRISE_SCORE -ge 3 ]]; then
        K10_IS_ENTERPRISE=true
    else
        K10_IS_ENTERPRISE=false
    fi
}

# --- License Key Validation ---
# Generates a valid license key for a given fingerprint.
# Key = HMAC-SHA256(secret, fingerprint), truncated to 32 hex chars.
# This function is used internally for validation and by the maintainer to issue keys.
k10_generate_key() {
    local fingerprint="$1"
    printf '%s' "$fingerprint" \
        | openssl dgst -sha256 -hmac "$K10TOOL_LICENSE_SECRET" 2>/dev/null \
        | awk '{print $NF}' \
        | cut -c1-32
}

# Validates K10TOOL_LICENSE_KEY against the current cluster fingerprint.
# Returns 0 (valid) or 1 (invalid/missing).
k10_validate_license() {
    local user_key="${K10TOOL_LICENSE_KEY:-}"
    if [[ -z "$user_key" ]]; then
        return 1
    fi
    if [[ -z "${K10_FINGERPRINT:-}" || "$K10_FINGERPRINT" == "unknown" ]]; then
        return 1
    fi

    local expected_key
    expected_key=$(k10_generate_key "$K10_FINGERPRINT")

    if [[ "$user_key" == "$expected_key" ]]; then
        return 0
    fi
    return 1
}

# --- License Banner ---
# Enterprise clusters (score >= 3): only a valid K10TOOL_LICENSE_KEY suppresses the banner.
# Non-enterprise clusters: K10TOOL_NO_BANNER=true suppresses the banner.
# Always goes to stderr so stdout remains clean for piping.
k10_show_banner() {
    if ! ${K10_IS_ENTERPRISE:-false}; then
        # Non-enterprise: allow simple suppression
        if [[ "${K10TOOL_NO_BANNER:-}" == "true" ]]; then
            return
        fi
        # Non-enterprise clusters don't get the banner at all
        return
    fi

    # Enterprise cluster: only a valid license key suppresses the banner
    if k10_validate_license; then
        K10_LICENSED=true
        return
    fi
    K10_LICENSED=false

    cat >&2 <<BANNER
================================================================================
  K10-TOOL  —  Enterprise Environment Detected (Unlicensed)
================================================================================
  Provider:     ${K10_PROVIDER}
  Nodes:        ${K10_NODE_COUNT} (${K10_CP_NODES} control-plane)
  Namespaces:   ${K10_NAMESPACE_COUNT}
  K10 version:  ${K10_K10_VERSION:-unknown}
  Cluster ID:   ${K10_FINGERPRINT:-unknown}
  Score:        ${K10_ENTERPRISE_SCORE}/5
--------------------------------------------------------------------------------
  This tool is licensed under AGPL-3.0. Enterprise use without source
  disclosure requires a commercial license.

  To obtain a license key for this cluster, contact:
    georgios.kapellakis@yandex.com

  Include your Cluster ID in the request. Once received:
    export K10TOOL_LICENSE_KEY=<your-key>

  Details: COMMERCIAL_LICENSE.md
================================================================================
BANNER
}

# --- Optional Phone-Home ---
# Strictly opt-in. Only fires when BOTH K10TOOL_REPORT=true AND
# K10TOOL_REPORT_ENDPOINT=<url> are set. Backgrounded with 5s timeout.
k10_optional_report() {
    if [[ "${K10TOOL_REPORT:-}" != "true" ]]; then
        return
    fi
    if [[ -z "${K10TOOL_REPORT_ENDPOINT:-}" ]]; then
        return
    fi

    # Validate endpoint is HTTPS
    if [[ "${K10TOOL_REPORT_ENDPOINT}" != https://* ]]; then
        return
    fi

    local payload
    payload=$(cat <<JSON
{
  "fingerprint": "${K10_FINGERPRINT:-unknown}",
  "node_count": ${K10_NODE_COUNT:-0},
  "namespace_count": ${K10_NAMESPACE_COUNT:-0},
  "provider": "${K10_PROVIDER:-unknown}",
  "k10_version": "${K10_K10_VERSION:-unknown}",
  "tool_version": "${K10TOOL_VERSION}",
  "enterprise_score": ${K10_ENTERPRISE_SCORE:-0},
  "licensed": ${K10_LICENSED:-false},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
)

    # Background curl with 5s timeout — zero latency impact on caller
    curl -s -m 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${K10TOOL_REPORT_ENDPOINT}" >/dev/null 2>&1 &
}

# --- Main Entry Point ---
# Call this from each script after namespace resolution.
# Runs fingerprint, detection, banner, and optional report in sequence.
k10_license_check() {
    k10_cluster_fingerprint
    k10_detect_enterprise
    k10_show_banner
    k10_optional_report
}
