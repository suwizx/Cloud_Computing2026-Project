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
#   RUNNER=cluster bash load/run.sh extreme      k6 as a Job inside the cluster (see run_in_cluster)
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

DIR="load/results/$(date -u +%F)/$PROFILE"   # UTC date, like the times in meta.env
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
# RUNNER=cluster: k6 runs as a Job on the egress tier instead of this machine, still against the public URL (out through
# the NAT, back in through the ALB and the WAF). For loads a home connection cannot carry: from a laptop in Bangkok the
# local network started refusing connections to AWS at ~300 req/s. The Job asks for 1.5 vCPU, more than the egress node
# has left, so the Cluster Autoscaler adds an egress node for it, and the generator does not share a node with auth.
run_in_cluster() {
  local job="k6-$PROFILE-$(date +%s)" pod
  kubectl -n eventide create configmap "$job" --from-file=profiles.js=load/k6/profiles.js >/dev/null
  kubectl -n eventide create secret generic "$job" \
    --from-literal=DEMO_EMAIL="${DEMO_ATTENDEE_EMAIL:-}" --from-literal=DEMO_PASSWORD="${DEMO_PASSWORD:-}" >/dev/null
  kubectl -n eventide apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $job, labels: { app: k6 } }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { app: k6 } }
    spec:
      restartPolicy: Never
      nodeSelector: { eventide/tier: egress }
      containers:
        - name: k6
          image: grafana/k6:2.3.0
          command: ["sh", "-c"]
          # stays up after k6 so the summary and the HTML report can be copied out
          args: ['k6 run --summary-export /tmp/summary.json -e DEMO_EMAIL="\$DEMO_EMAIL" -e DEMO_PASSWORD="\$DEMO_PASSWORD" /scripts/profiles.js; echo "K6_EXIT=\$?"; sleep 900']
          env:
            - { name: BASE_URL, value: "$BASE_URL" }
            - { name: PROFILE, value: "$PROFILE" }
            - { name: SCALE, value: "${SCALE:-1}" }
            - { name: K6_WEB_DASHBOARD, value: "true" }
            - { name: K6_WEB_DASHBOARD_EXPORT, value: /tmp/dashboard.html }
            - { name: K6_WEB_DASHBOARD_PERIOD, value: 10s }
          envFrom: [{ secretRef: { name: $job } }]
          resources:
            requests: { cpu: 1500m, memory: 1Gi }
            limits: { cpu: 2000m, memory: 1536Mi }
          volumeMounts: [{ name: scripts, mountPath: /scripts }]
      volumes: [{ name: scripts, configMap: { name: $job } }]
YAML
  echo "== k6 Job $job: waiting for a node (the Cluster Autoscaler) and the pod =="
  kubectl -n eventide wait --for=condition=Ready pod -l job-name="$job" --timeout=900s >/dev/null || { echo "the k6 pod never started"; return 1; }
  pod="$(kubectl -n eventide get pod -l job-name="$job" -o jsonpath='{.items[0].metadata.name}')"
  START="$(date -u +%FT%TZ)"
  echo "== $PROFILE from pod $pod (node $(kubectl -n eventide get pod "$pod" -o jsonpath='{.spec.nodeName}')) from $START =="
  until kubectl -n eventide logs "$pod" --tail=20 2>/dev/null | grep -q '^K6_EXIT='; do sleep 20; done
  kubectl -n eventide logs "$pod" > "$DIR/k6.log" 2>&1
  K6_EXIT="$(grep -o '^K6_EXIT=[0-9]*' "$DIR/k6.log" | cut -d= -f2)"
  kubectl -n eventide cp "$pod:/tmp/summary.json" "$DIR/summary.json" >/dev/null 2>&1
  kubectl -n eventide cp "$pod:/tmp/dashboard.html" "$DIR/dashboard.html" >/dev/null 2>&1
  kubectl -n eventide delete job "$job" --wait=false >/dev/null
  kubectl -n eventide delete configmap,secret "$job" >/dev/null
  echo "RUNNER=cluster ($pod)" > "$DIR/runner.txt"
}

START="$(date -u +%FT%TZ)"
if [ "${RUNNER:-local}" = cluster ]; then
  run_in_cluster || exit 1
else
  echo "== $PROFILE against $BASE_URL from $START (results: $DIR) =="
  K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT="$DIR/dashboard.html" K6_WEB_DASHBOARD_PERIOD=10s \
    k6 run --summary-export "$DIR/summary.json" \
      -e BASE_URL="$BASE_URL" -e PROFILE="$PROFILE" -e SCALE="${SCALE:-1}" \
      -e DEMO_EMAIL="${DEMO_ATTENDEE_EMAIL:-}" -e DEMO_PASSWORD="${DEMO_PASSWORD:-}" \
      load/k6/profiles.js 2>&1 | tee "$DIR/k6.log"
  K6_EXIT="${PIPESTATUS[0]}"
fi
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
