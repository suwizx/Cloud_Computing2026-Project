# Load testing

Three profiles through the public host, with the cluster's and AWS's view recorded beside k6's. The latest results and
what they mean: [LOADTEST-REPORT.md](LOADTEST-REPORT.md). The cost side of the same runs: [docs/COST-REPORT.md](../docs/COST-REPORT.md).

| Profile | Offered load | What it answers |
|---|---|---|
| `idle` | 1 request every 5 s, 15 min | the platform up with nobody on it: baseline CPU, memory, pods, nodes and cost |
| `normal` | 40 req/s for 12 min (~300 people browsing, ~7.5 s between clicks) | everyday traffic: latency per endpoint, whether anything scales |
| `extreme` | 150 → 400 → 800 req/s over 15 min, then 12 min without load | every HPA to its ceiling, the edge nodes past their pod slots (Cluster Autoscaler), then scale-in |

All three send the same read-only mix (`k6/profiles.js`): event list and detail, seat availability, the web pages, the
signed-in "my tickets", categories, Open Graph images and health checks. Nothing enrolls or pays: those paths send real
mail and touch Stripe.

## Prerequisites

- `brew install k6`, and `kubectl` pointed at the cluster (`make deploy` does that).
- The demo seeded (`make deploy` does it; `make demo` by hand): the run signs in as the demo attendee from
  `demo/.credentials`.
- For `normal` and `extreme`, the WAF's per-IP rate rule raised: one laptop is one IP, and the default 10,000 requests per
  5 minutes is about 33 req/s.

  ```sh
  set -a; . infra/aws.env 2>/dev/null; set +a
  terraform -chdir=infra/terraform apply -var waf_rate_limit=2000000   # before
  terraform -chdir=infra/terraform apply                               # after: back to the default
  ```

## Run

```sh
bash load/run.sh idle
bash load/run.sh normal
bash load/run.sh extreme          # COOLDOWN=<s> to sample longer after k6 ends; SCALE=0.5 halves every rate
```

Each run writes `load/results/<date>/<profile>/`:

| File | Content |
|---|---|
| `meta.env` | the window in UTC, the target, k6's exit code |
| `timeline.csv` | every 10 s (`collect.sh`): each HPA's CPU and desired replicas, Ready and Pending pods, Ready nodes per tier, node CPU and memory |
| `summary.json`, `k6.log`, `dashboard.html` | k6's end-of-test summary (per-endpoint thresholds give per-endpoint numbers) and its HTML report |
| `events.txt`, `autoscaler.log` | HPA rescales, scheduling failures, the Cluster Autoscaler's scale-ups and scale-downs |
| `before.txt`, `after.txt` | nodes, HPAs, deployments, pods and `kubectl top nodes` |
| `cloudwatch.json`, `cloudwatch-summary.tsv` | `cloudwatch.sh`: ALB, WAF, RDS, RDS Proxy, ElastiCache, node CPU and CPU credits, NAT |

CloudWatch lags a few minutes, and EC2's basic monitoring is 5-minute data: rerun
`bash load/cloudwatch.sh <START> <END> <dir>` (the times are in `meta.env`) later for the last points.

To watch live, in other panes:

```sh
kubectl -n eventide get hpa -w
kubectl get nodes -L eventide/tier -w
kubectl -n kube-system logs -f deployment/cluster-autoscaler | grep -iE 'scale|unneeded'
```

## Older scripts

- `k6/events.js` (`make load BASE_URL=…`): the original HPA demo, `GET /api/events` only.
- `k6/all.js`: every endpoint at a constant 30 VUs each. Results: `RESULTS.md`, `RESULTS-production-layout.md`.
- `k6/redis-compare.js`: Redis on vs off, run from inside the cluster.
- `seed.sh`: an admin and one event for those scripts (the demo seed replaces it for `profiles.js`).
