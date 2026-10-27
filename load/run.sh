#!/usr/bin/env bash
# One load-test run with everything the report needs, into load/results/<date>/<profile>/:
#   meta.env           the window (UTC), the target, the k6 exit code
#   before.txt/after.txt  nodes, HPAs, deployments and pods before and after
#   timeline.csv       load/collect.sh every 10 s: HPA CPU and desired replicas, Ready/Pending pods, nodes per tier, node CPU
#   k6.log, summary.json, dashboard.html   k6's console output, end-of-test summary and HTML report (time series)
#   events.txt         HPA rescales, scheduling failures, Cluster Autoscaler scale-ups and scale-downs
#   autoscaler.log     the Cluster Autoscaler's scale decisions (filtered)
#   cloudwatch.json / cloudwatch-summary.tsv   load/cloudwatch.sh for the window
#
#   bash load/run.sh idle|normal|extreme          (COOLDOWN=<s> keeps sampling after k6 ends; extreme defaults to 720)
# The demo attendee (demo/.credentials) signs in once for the "my tickets" requests.
set -uo pipefail
PROFILE="${1:?usage: run.sh idle|normal|extreme}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib.sh"
load_aws_env

BASE_URL="${BASE_URL:-$(tfout public_url || true)}"
[ -n "$BASE_URL" ] || { echo "no public_url in the Terraform outputs: pass BASE_URL"; exit 1; }
[ -f demo/.credentials ] && { set -a; . demo/.credentials; set +a; }
case "$PROFILE" in extreme) COOLDOWN="${COOLDOWN:-720}" ;; *) COOLDOWN="${COOLDOWN:-120}" ;; esac

DIR="load/results/$(date +%F)/$PROFILE"
[ -e "$DIR" ] && DIR="$DIR-$(date +%H%M)"
mkdir -p "$DIR"

snapshot() {
  { echo "## nodes"; kubectl get nodes -L eventide/tier,node.kubernetes.io/instance-type
    echo; echo "## hpa"; kubectl -n eventide get hpa
    echo; echo "## deployments"; kubectl -n eventide get deploy
    echo; echo "## pods"; kubectl get pods -A -o wide --sort-by=.spec.nodeName
    echo; echo "## top nodes"; kubectl top nodes; } > "$DIR/$1" 2>&1
}

snapshot before.txt
bash load/collect.sh "$DIR/timeline.csv" &
COLLECT=$!
START="$(date -u +%FT%TZ)"
echo "== $PROFILE against $BASE_URL from $START (results: $DIR) =="

K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT="$DIR/dashboard.html" K6_WEB_DASHBOARD_PERIOD=10s \
  k6 run --summary-export "$DIR/summary.json" \
    -e BASE_URL="$BASE_URL" -e PROFILE="$PROFILE" -e SCALE="${SCALE:-1}" \
    -e DEMO_EMAIL="${DEMO_ATTENDEE_EMAIL:-}" -e DEMO_PASSWORD="${DEMO_PASSWORD:-}" \
    load/k6/profiles.js 2>&1 | tee "$DIR/k6.log"
K6_EXIT="${PIPESTATUS[0]}"
K6_END="$(date -u +%FT%TZ)"

echo "== k6 finished ($K6_EXIT); sampling ${COOLDOWN}s more for the scale-in =="
sleep "$COOLDOWN"
END="$(date -u +%FT%TZ)"
kill "$COLLECT" 2>/dev/null; wait "$COLLECT" 2>/dev/null
snapshot after.txt

cat > "$DIR/meta.env" <<EOF
PROFILE=$PROFILE
BASE_URL=$BASE_URL
START=$START
K6_END=$K6_END
END=$END
K6_EXIT=$K6_EXIT
SCALE=${SCALE:-1}
GIT=$(git rev-parse --short HEAD)
K6=$(k6 version | head -1)
EOF

kubectl get events -A --sort-by=.lastTimestamp \
  -o custom-columns=TIME:.lastTimestamp,NS:.metadata.namespace,KIND:.involvedObject.kind,NAME:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>/dev/null \
  | awk -v s="$START" 'NR==1 || $1 >= s' \
  | grep -E 'TIME|HorizontalPodAutoscaler|SuccessfulRescale|TriggeredScaleUp|NotTriggerScaleUp|ScaleDown|FailedScheduling|RegisteredNode|RemovingNode|NodeNotReady' \
  > "$DIR/events.txt" || true
kubectl -n kube-system logs deployment/cluster-autoscaler --since-time="$START" 2>/dev/null \
  | grep -iE 'scale-up|scale up|scale-down|scale down|scaleup|removing|unneeded|final|setting asg|error|denied|failed' \
  > "$DIR/autoscaler.log" || true

bash load/cloudwatch.sh "$START" "$END" "$DIR" || echo "cloudwatch pull failed; rerun: bash load/cloudwatch.sh $START $END $DIR"
echo "== done: $DIR =="
