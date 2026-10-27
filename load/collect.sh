#!/usr/bin/env bash
# Samples the cluster about every 10 s (the kubectl calls take ~6 s, then INTERVAL=5 s of sleep) into <out.csv> until it is stopped (load/run.sh starts and
# stops it). One row per sample: what the HPAs see and decide, how many pods are Ready or Pending, how many nodes each
# tier has, and how busy those nodes are. Needs kubectl pointed at the cluster and metrics-server (kubectl top).
#   bash load/collect.sh load/results/<date>/<profile>/timeline.csv
set -uo pipefail
OUT="${1:?usage: collect.sh <out.csv>}"
INTERVAL="${INTERVAL:-5}"
NS=eventide
HPAS="event registration web"
DEPLOYS="event registration web auth payment"

header="ts"
for h in $HPAS; do header="$header,${h}_cpu_pct,${h}_desired"; done
for d in $DEPLOYS; do header="$header,${d}_ready"; done
header="$header,pending_pods,edge_nodes,egress_nodes,edge_cpu_pct,egress_cpu_pct,edge_mem_pct,egress_mem_pct"
for h in $HPAS; do header="$header,${h}_cpu_m"; done
echo "$header" > "$OUT"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; exit 0' TERM INT
while :; do
  ts="$(date -u +%FT%TZ)"
  # in parallel: each kubectl call mints its own EKS token, and one after another they took ~30 s per sample
  kubectl -n $NS get hpa -o json > "$TMP/hpa" 2>/dev/null &
  kubectl -n $NS get deploy -o json > "$TMP/dep" 2>/dev/null &
  kubectl get nodes -o json > "$TMP/nodes" 2>/dev/null &
  kubectl top nodes --no-headers > "$TMP/top_nodes" 2>/dev/null &
  kubectl -n $NS top pods --no-headers > "$TMP/top_pods" 2>/dev/null &
  kubectl -n $NS get pods --field-selector=status.phase=Pending --no-headers > "$TMP/pending" 2>/dev/null &
  wait
  hpa="$(cat "$TMP/hpa")"; [ -n "$hpa" ] || hpa='{"items":[]}'
  dep="$(cat "$TMP/dep")"; [ -n "$dep" ] || dep='{"items":[]}'
  nodes="$(cat "$TMP/nodes")"; [ -n "$nodes" ] || nodes='{"items":[]}'
  top_nodes="$(cat "$TMP/top_nodes")"
  top_pods="$(cat "$TMP/top_pods")"
  pending="$(wc -l < "$TMP/pending" | tr -d ' ')"

  row="$ts"
  for h in $HPAS; do
    row="$row,$(jq -r --arg n "$h" '[.items[] | select(.metadata.name==$n)
      | "\(.status.currentMetrics[0].resource.current.averageUtilization // ""),\(.status.desiredReplicas // "")"] | first // ","' <<<"$hpa")"
  done
  for d in $DEPLOYS; do
    row="$row,$(jq -r --arg n "$d" '[.items[] | select(.metadata.name==$n) | .status.readyReplicas // 0] | first // ""' <<<"$dep")"
  done
  # node name -> tier, Ready nodes per tier
  tiers="$(jq -r '.items[] | "\(.metadata.name) \(.metadata.labels["eventide/tier"] // "none") \([.status.conditions[] | select(.type=="Ready") | .status][0])"' <<<"$nodes")"
  ready() { awk -v t="$1" '$2==t && $3=="True"' <<<"$tiers" | wc -l | tr -d ' '; }
  # `kubectl top nodes`: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%; average the % over the tier's nodes
  avg() { awk -v t="$1" -v col="$2" 'NR==FNR { tier[$1]=$2; next } tier[$1]==t { gsub("%","",$col); s+=$col; n++ } END { if (n) printf "%.0f", s/n }' \
            <(echo "$tiers") <(echo "$top_nodes"); }
  row="$row,$pending,$(ready edge),$(ready egress),$(avg edge 3),$(avg egress 3),$(avg edge 5),$(avg egress 5)"
  # summed CPU (millicores) of each scaled deployment's pods
  for h in $HPAS; do
    row="$row,$(awk -v p="^$h-" '$1 ~ p { gsub("m","",$2); s+=$2 } END { print s+0 }' <<<"$top_pods")"
  done
  echo "$row" >> "$OUT"
  sleep "$INTERVAL" & wait $!
done
