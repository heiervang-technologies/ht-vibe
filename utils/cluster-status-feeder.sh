#!/bin/bash
# Feeds live Kubernetes cluster metrics into the cluster.wgsl shader constants.
# Vibe watches the shader file for changes and hot-reloads.
#
# Usage: cluster-status-feeder.sh [interval_seconds] [shader_path]
#
# The cluster.wgsl shader must contain markers:
#   // ── CLUSTER_STATUS_BEGIN ──
#   ...constants...
#   // ── CLUSTER_STATUS_END ──
#
# Environment:
#   KUBECONFIG - path to k8s config (default: /etc/rancher/rke2/rke2.yaml)

set -euo pipefail

INTERVAL="${1:-10}"
SHADER="${2:-$HOME/.config/vibe/shaders/cluster.wgsl}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export PATH="$PATH:/var/lib/rancher/rke2/bin"

SSH_OPTS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes"

RUNNING=true
trap 'RUNNING=false; echo "Shutting down..."; exit 0' SIGTERM SIGINT

# ── Metric helpers ────────────────────────────────────────────

get_node_ready() {
    local node="$1"
    local status
    status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || true
    if [[ "$status" == "True" ]]; then
        echo "1.0"
    else
        echo "0.0"
    fi
}

get_cpu_mem() {
    local node="$1"
    local line
    line=$(kubectl top node "$node" --no-headers 2>/dev/null) || { echo "0 0"; return; }
    local cpu_pct mem_pct
    cpu_pct=$(echo "$line" | awk '{gsub(/%/,""); print $3}')
    mem_pct=$(echo "$line" | awk '{gsub(/%/,""); print $5}')
    echo "${cpu_pct:-0} ${mem_pct:-0}"
}

get_gpu_local() {
    nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || true
}

get_gpu_remote() {
    local ip="$1"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$ip" \
        nvidia-smi --query-gpu=index,utilization.gpu,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || true
}

normalize_pct() {
    awk "BEGIN { printf \"%.3f\", ${1:-0} / 100.0 }"
}

normalize_temp() {
    awk "BEGIN { v = ${1:-0} / 90.0; if (v > 1.0) v = 1.0; printf \"%.3f\", v }"
}

# ── Collect metrics for a node ────────────────────────────────

collect_node() {
    local name="$1" ip="$2" gpu_count="${3:-0}" is_local="${4:-false}"
    local ready cpu mem
    ready=$(get_node_ready "$name")

    local reachable=true
    local gpu_data=""

    if [[ "$gpu_count" -gt 0 ]]; then
        if $is_local; then
            gpu_data=$(get_gpu_local)
        else
            gpu_data=$(get_gpu_remote "$ip")
        fi
        [[ -z "$gpu_data" ]] && reachable=false
    fi

    if $reachable; then
        read -r cpu_raw mem_raw <<< "$(get_cpu_mem "$name")"
        cpu=$(normalize_pct "$cpu_raw")
        mem=$(normalize_pct "$mem_raw")
    else
        ready="0.0"; cpu="0.000"; mem="0.000"
    fi

    echo "$ready $cpu $mem"

    # GPU lines
    for ((g=0; g<gpu_count; g++)); do
        if $reachable && [[ -n "$gpu_data" ]]; then
            local line
            line=$(echo "$gpu_data" | sed -n "$((g+1))p")
            if [[ -n "$line" ]]; then
                echo "$(normalize_pct "$(echo "$line" | cut -d, -f2)") $(normalize_temp "$(echo "$line" | cut -d, -f3)")"
            else
                echo "0.000 0.000"
            fi
        else
            echo "0.000 0.000"
        fi
    done
}

# ── Build and inject constants ────────────────────────────────

# ── Load node config ──────────────────────────────────────────

NODES_CONFIG="${VIBE_CLUSTER_NODES:-$HOME/.config/vibe/cluster-nodes.toml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

load_nodes() {
    if [[ ! -f "$NODES_CONFIG" ]]; then
        echo "Node config not found: $NODES_CONFIG" >&2
        echo "Copy the example and edit for your cluster:" >&2
        echo "  cp $SCRIPT_DIR/cluster-nodes.toml.example ~/.config/vibe/cluster-nodes.toml" >&2
        exit 1
    fi

    NODES=()
    local name="" ip="" gpus="0" local_node="false"
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue
        case "${line// /}" in
            "[[nodes]]")
                if [[ -n "$name" ]]; then
                    NODES+=("$name $ip $gpus $local_node")
                fi
                name="" ip="" gpus="0" local_node="false"
                ;;
            name=*) name="${line#*= }"; name="${name//\"/}" ;;
            ip=*)   ip="${line#*= }"; ip="${ip//\"/}" ;;
            gpus=*) gpus="${line#*= }" ;;
            local=*) local_node="${line#*= }" ;;
        esac
    done < "$NODES_CONFIG"
    if [[ -n "$name" ]]; then
        NODES+=("$name $ip $gpus $local_node")
    fi

    if [[ ${#NODES[@]} -eq 0 ]]; then
        echo "No nodes defined in $NODES_CONFIG" >&2
        exit 1
    fi
}

load_nodes

collect_and_inject() {
    local block="// ── CLUSTER_STATUS_BEGIN ──"

    for node_spec in "${NODES[@]}"; do
        read -r name ip gpu_count is_local <<< "$node_spec"
        local prefix="${name:0:1}"
        prefix=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')

        local metrics
        metrics=$(collect_node "$name" "$ip" "$gpu_count" "$is_local")

        local ready cpu mem
        read -r ready cpu mem <<< "$(echo "$metrics" | head -1)"
        block+=$'\n'"const ${prefix}_CPU: f32 = ${cpu};"
        block+=$'\n'"const ${prefix}_MEM: f32 = ${mem};"
        block+=$'\n'"const ${prefix}_READY: f32 = ${ready};"

        # GPU lines
        for ((g=0; g<gpu_count; g++)); do
            local gpu_line
            gpu_line=$(echo "$metrics" | sed -n "$((g+2))p")
            read -r gpu_util gpu_temp <<< "$gpu_line"
            local suffix=""
            [[ "$gpu_count" -gt 1 ]] && suffix="$g"
            block+=$'\n'"const ${prefix}_GPU${suffix}: f32 = ${gpu_util};"
            block+=$'\n'"const ${prefix}_TEMP${suffix}: f32 = ${gpu_temp};"
        done
    done

    block+=$'\n'"// ── CLUSTER_STATUS_END ──"

    if [[ ! -f "$SHADER" ]]; then
        echo "Shader not found: $SHADER" >&2
        return 1
    fi

    local tmpfile="${SHADER}.tmp.$$"
    awk -v block="$block" '
        /CLUSTER_STATUS_BEGIN/ { print block; skip=1; next }
        /CLUSTER_STATUS_END/   { skip=0; next }
        !skip { print }
    ' "$SHADER" > "$tmpfile"
    mv "$tmpfile" "$SHADER"
}

# ── Main loop ────────────────────────────────────────────────

echo "cluster-status-feeder: updating $SHADER every ${INTERVAL}s"

while $RUNNING; do
    if collect_and_inject; then
        printf "[%s] Updated cluster metrics\n" "$(date +%H:%M:%S)"
    else
        echo "inject failed" >&2
    fi
    sleep "$INTERVAL" &
    wait $! 2>/dev/null || true
done
