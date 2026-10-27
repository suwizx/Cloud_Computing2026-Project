# Load test report: production, 2026-10-27

**English** · [ภาษาไทย](LOADTEST-REPORT.th.md)

Three load profiles against the production deployment at **https://eventide.creasy.club**. Each run records the
autoscaling (HPAs, Pending pods, nodes per tier) and the AWS side (ALB, WAF, RDS, RDS Proxy, ElastiCache, node CPU
credits). The cost side of the same runs: [docs/COST-REPORT.md](../docs/COST-REPORT.md). Raw data:
[`load/results/2026-10-27/`](results/2026-10-27/).

## Short answers

- **Does pod autoscaling (HPA) work?** Yes. At 150–400 req/s `event` went **2 → 8** (its ceiling) in 75 s and
  `registration` **2 → 8** in 2.5 min; `web` went **1 → 3** at 800 req/s. Two minutes after the load stopped all three
  were back at their minimum.
- **Do nodes scale?** Yes, on both tiers. When the HPAs outgrew the edge nodes' pod slots (`t3.small` holds 11 pods),
  the Cluster Autoscaler added an edge node (**2 → 3**) 10–20 s after the first pod went Pending, and the node was
  serving pods 23–40 s later. The in-cluster load generator needed room on the egress tier and got its own node
  (**1 → 2**). After the load stopped, the autoscaler decided to remove the extra edge node within 3–4 minutes and the
  node was gone within 4–6.
- **How far did it scale?** Peak: **`event` 8/8, `registration` 8/8, `web` 3/4 pods; 3/4 edge + 2/2 egress = 5 nodes**
  (from 3).
- **Did it hold?** At **800 req/s** (48,000 requests in the busiest minute) the ALB → target response time stayed at
  **≤ 112 ms p95** in the worst minute, RDS CPU peaked at **44 %**, and the nodes at ~40 % CPU. 99.93 % of 393,524
  requests succeeded. **The 269 failures (0.07 %) all came from one event:** the Cluster Autoscaler removed a node in the
  middle of the load and took both `auth` replicas and the single `payment` pod with it, ~16–20 s of 503s (§7, finding 1).
- **Where would it break?** Not reached at 800 req/s. The HPAs were at their ceiling with CPU to spare on the nodes; by
  extrapolation the database comes first, at around 1,800 req/s (§5).

## 1. Setup

| | |
|---|---|
| Cluster | EKS **1.35**, node groups `edge` (2–4) and `egress` (1–2), all `t3.small` (2 vCPU, 2 GiB, **11 pods per node**), T3 unlimited |
| Pod autoscaling | HPAs at 60 % of the CPU request: `event` 2–8 (request 50m), `registration` 2–8 (50m), `web` 1–4 (50m). Scale-up: no stabilisation, +100 % or +4 pods per 15 s; scale-down: 60 s window, −2 pods per 30 s |
| Node autoscaling | Cluster Autoscaler 1.35.0 (chart 9.59.0), auto-discovery by ASG tags, expander `least-waste`, scale-down after 2 min unneeded and 2 min after a scale-up (demo timings; the defaults are 10 min) |
| Fixed replicas | `auth` 2, `payment` 1, `mail-worker` 1 (egress); ingress-nginx 2 (edge) |
| Data | RDS PostgreSQL `db.t3.micro` behind RDS Proxy, ElastiCache `cache.t3.micro` (TLS + AUTH), `DB_POOL_MAX=4` per pod |
| Edge | ALB + WAF (5 rules). The per-IP rate rule was raised from 10,000 to 2,000,000 requests per 5 min for normal and extreme (one source IP sends all the load) and put back afterwards |
| Data set | the prepared demo: 8 events (5 public), 6 categories, 3 accounts |
| Tools | k6 2.3.0 (`load/k6/profiles.js`), `load/run.sh`, `load/collect.sh` (cluster every ~10 s), `load/cloudwatch.sh` |

**Request mix** (every profile, weights out of 100), all reads: nothing enrolls or pays, because those paths send real
mail and touch Stripe.

| Weight | Request | Path through the system |
|---:|---|---|
| 25 | `GET /api/events` | event → RDS Proxy → Postgres |
| 25 | `GET /api/events/:slug` | event → Redis (event cache), Postgres on a miss |
| 15 | `GET /api/regis/events/:id/availability` | registration → Postgres |
| 12 | `GET /` and `/events/:slug` | web (Bun server, per-URL head) → event |
| 10 | `GET /api/regis/tickets/mine` (signed in) | registration → session cache in Redis (auth on a miss) → Postgres |
| 8 | `GET /api/events/categories` | event → Postgres |
| 2 | `GET /api/events/og/events/:id` | event renders a 1200×630 JPEG |
| 3 | `/api/*/health` | each service, touches nothing |

**Profiles:** `idle` one request every 5 s for 15 min; `normal` 40 req/s for 12 min (≈ 300 people browsing with
~7.5 s between clicks, an assumption); `extreme` 150 → 400 → 800 req/s over 15 min, then 12 min without load to watch
scale-in. Arrival-rate executors: the offered load does not drop when the system slows; when k6 cannot keep up it
counts `dropped_iterations`.

**Where the load came from.** idle and normal ran from a laptop in Bangkok (≈ 270 ms to us-east-1, which is most of
the client latency in their tables). The first extreme attempt from the same laptop showed that the **home network, not
the system, is the limit**: at ~300 req/s every new connection to an AWS address was refused (`Couldn't connect to
server` to the ALB, Cost Explorer and the EKS API alike, while other sites still loaded) and recovered the moment k6
stopped. The full extreme run therefore ran **inside AWS**: k6 as a Kubernetes Job on the egress tier, still against
the public URL (out through the NAT, back in through the ALB and the WAF): `RUNNER=cluster bash load/run.sh extreme`.

## 2. Results at a glance

| | idle | normal | extreme (in AWS) |
|---|---:|---:|---:|
| Requests | 182 | 32,150 | 393,524 |
| Achieved rate | 0.2/s | 35.7/s (40 at plateau) | 437/s avg, **800/s at plateau** |
| Failed | 0.00 % | 0.06 % (client network) | 0.07 % (one node scale-down, §7) |
| Client latency med / p95 / p99 | 285 / 890 / 1,504 ms | 284 / 757 / 2,520 ms | **9 / 38 / 212 ms** |
| ALB → target response p95, worst minute | 220 ms | 47 ms | 112 ms |
| ALB 5xx / target 5xx | 0 / 0 | 0 / 0 | 0 / 269 |
| `event` pods (min → peak) | 2 → 2 | 2 → 3 | **2 → 8** |
| `registration` pods | 2 → 2 | 2 → 2 | **2 → 8** |
| `web` pods | 1 → 1 | 1 → 1 | **1 → 3** |
| Nodes edge / egress (peak) | 2 / 1 | 2 / 1 | **3 / 2** |
| Edge node CPU, peak (`kubectl top`) | 5 % | 8 % | 43 % |
| Edge node memory, peak | 52 % | 56 % | 71 % |
| RDS CPU, max | 6.6 % | 8.5 % | 43.7 % |
| RDS Proxy: client → DB connections, max | 11 → 6 | 15 → 8 | 38 → 33 |
| Redis hit rate | 76 % | 88 % | 88 % |
| CPU credits charged (nodes, RDS) | 0 | 0 | 0 |

The extreme client latencies are from inside AWS and are not comparable with the laptop runs; the ALB row is the
server-side number for all three.

## 3. idle

`results/2026-10-27/idle/`, 16:52–17:10 UTC.

- 182 requests, all 200. Nothing scaled: `event` 2, `registration` 2, `web` 1, nodes 2 + 1. Pods used 2–8 m of CPU
  each, nodes 2–5 %, edge node memory ~50 % (2 GiB nodes).
- The ALB counted **430** requests in the window although k6 sent 182: a new public load balancer is found by scanners
  within minutes, and the WAF **blocked 10** of them on its own.
- RDS started with almost no CPU credits (balance ≈ 4): a fresh `db.t3.micro` has to earn them. It did not matter here
  (no credit was charged in any run), but a long burst right after a deploy would be billed as surplus credits.
- The slowest request is the Open Graph image, rendered per request (median 1.2 s from the laptop).

## 4. normal (40 req/s)

`results/2026-10-27/normal/`, 17:11–17:28 UTC.

| Endpoint | Requests | Failed | med | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| `GET /api/events` | 8,091 | 0.05 % | 285 | 433 | 2,246 |
| `GET /api/events/:slug` | 7,941 | 0.06 % | 277 | 411 | 2,218 |
| availability | 4,839 | 0.12 % | 290 | 452 | 2,316 |
| web | 3,851 | 0.05 % | 282 | 616 | 2,562 |
| my tickets (signed in) | 3,247 | 0.03 % | 285 | 403 | 2,321 |
| categories | 2,549 | 0.04 % | 280 | 419 | 2,184 |
| health | 973 | 0 % | 276 | 471 | 2,392 |
| OG image | 657 | 0 % | 1,433 | 2,802 | 6,554 |

(milliseconds, measured at the laptop)

- **The servers were fast; the tail was the network.** The ALB's target response time stayed at or below **47 ms**
  p95 in every minute, with no 5xx at all. The 21 failed requests (0.06 %) and the 2.2–2.5 s p99 line up with a short
  loss of the laptop's connection at +3 min (the cluster sampler lost two samples at the same moment).
- **Autoscaling:** `event` reached 75 % of its CPU request at +2 min and the HPA scaled it **2 → 3**, back to 2 after
  ~7 min, and once more 2 → 3 → 2 later. `registration` peaked at 49 % and `web` at 14 %: no change. Nodes: no change.
  At 40 req/s the whole application used **≈ 0.2 vCPU** (`event` 140 m, `registration` 49 m, `web` 7 m).
- **Cache and database:** 23,610 Redis hits against 3,262 misses (88 %). RDS CPU ≤ 8.5 %; RDS Proxy turned 15 client
  connections into 8 database connections.
- **Bytes per request:** ALB `ProcessedBytes` ÷ requests = 2.9 KB (request + response), used by the cost report.

## 5. extreme (in AWS)

`results/2026-10-27/extreme/`, k6 17:48:02–18:03:33 UTC, sampled to 18:15:33.

| Endpoint | Requests | Failed | med | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| `GET /api/events` | 98,412 | 0 % | 10 | 35 | 287 |
| `GET /api/events/:slug` | 98,502 | 0 % | 4.3 | 12 | 74 |
| availability | 59,009 | 0 % | 16 | 47 | 281 |
| web | 47,184 | 0 % | 4.5 | 11 | 45 |
| my tickets (signed in) | 39,431 | **0.38 %** | 11 | 41 | 434 |
| categories | 31,348 | 0 % | 6.9 | 23 | 222 |
| health | 11,763 | **1.00 %** | 3.5 | 9.7 | 63 |
| OG image | 7,873 | 0 % | 45 | 146 | 693 |

(milliseconds, from a pod in the same region through the public URL; status codes: 393,253 × 200, 261 × 503,
4 × 502, 4 × 504; 977 dropped iterations, 0.25 %)

**Scaling timeline** (Kubernetes events, `events.txt`, and the autoscaler's log):

| UTC | Load | What happened |
|---|---|---|
| 17:47:17 | – | the k6 pod (asks 1.5 vCPU / 1 GiB) cannot fit on the egress node: *Insufficient memory* → Cluster Autoscaler **egress 1 → 2** |
| 17:48:02 | ramp to 150/s | the new egress node is Ready, k6 starts on it |
| 17:48:58 | ~60/s | HPA `event` 2 → 3 |
| 17:49:28 – 17:50:13 | 90–150/s | HPA `event` 3 → 4 → 5 → 6 → **8 (max)** in 75 s; `registration` 2 → 3 |
| 17:50:43 – 17:51:28 | ramp to 400/s | HPA `registration` 3 → 5 → 6; pods `Pending`: *"Too many pods"* (both edge nodes full) |
| **17:51:39** | ~300/s | **Cluster Autoscaler: edge 2 → 3** |
| 17:52:02 | | the new edge node registers (23 s later) and takes the Pending pods |
| 17:52:28 | 400/s | HPA `registration` → **8 (max)** |
| **17:54:20** | 400/s | **Cluster Autoscaler scales the old egress node down during the load** (utilisation 0.21 < 0.5): evicts both `auth` replicas, `payment` and `mail-worker` at once (finding 1) |
| 17:54:41 – 17:54:45 | 400/s | the replacements are Ready on the other egress node; **≈ 16–20 s of 503s** on signed-in requests and the auth/payment health checks |
| 17:57:59 – 17:58:44 | ramp to 800/s | HPA `web` 1 → 2 → **3** |
| 17:59 – 18:02 | **800/s** | steady: `event` 8, `registration` 8, `web` 3, 3 edge nodes at ~39 % CPU, RDS CPU up to 44 % |
| 18:03:33 | 0 | k6 done |
| 18:03:29 – 18:05:15 | 0 | HPAs back to 2 / 2 / 1 |
| 18:07:11 – 18:07:52 | 0 | Cluster Autoscaler drains and removes the third edge node |

**At the 800 req/s plateau:** `event` used ~1.15 vCPU over its 8 pods (≈ 145 m each, 290 % of its 50 m request and
still below its 500 m limit), `registration` ~0.5 vCPU, and the three edge nodes ~39 % of their 6 vCPU. Edge memory
peaked at 71 %. RDS CPU 44 %, Redis engine CPU 3.7 %, no CPU credit charged anywhere (the nodes' and RDS's earned
balances covered the 15 minutes).

**Where it would break.** Not at 800 req/s. The HPAs were capped at 8 with the nodes under half busy, so the next
limits, by extrapolation from these numbers (not measured):

1. **The database:** RDS CPU went from 8.5 % at 40 req/s to 44 % at 800 req/s; linearly it reaches 100 % near
   **~1,800 req/s**. Its CPU credit balance (≈ 5–8) would run out within minutes of sustained load above its 10 %
   baseline and be billed as surplus credits (§7 of the cost report).
2. **`event` pods:** 8 pods × 500 m limit = 4 vCPU against ~1.15 vCPU used: ≈ 3× headroom.
3. **Pod slots:** at the ceiling the edge tier holds 23 app and system pods; three `t3.small` nodes give 27 slots and the
   fourth (the node group's max) 36.

## 6. Node autoscaling seen twice: the first extreme attempt (from the laptop)

`results/2026-10-27/extreme-laptop/`. The load stopped at 17:33:32 when the laptop's network gave out at ~300 req/s,
but the cluster had already gone through a full scale-up, and the 12-minute watch afterwards caught the scale-in:

| UTC | What happened |
|---|---|
| 17:29:29 | load starts (ramp to 150 req/s, then toward 400) |
| 17:30:42 | HPA `event` 2 → 4 |
| 17:31:27 | HPA `event` 4 → 7, `registration` 2 → 3 |
| 17:32:12 | HPA `event` 7 → **8 (max)**, `registration` 3 → 4 |
| 17:32:57 | HPA `registration` 4 → 6: three pods `Pending`, *"0/3 nodes are available: … 2 Too many pods"* |
| **17:33:07** | **Cluster Autoscaler: "Final scale-up plan: edge 2 → 3 (max 4)"**, 10 s after the first Pending pod |
| 17:33:27 | HPA `registration` → **8 (max)** |
| 17:33:47 | the new node `ip-10-20-10-45` registers (40 s after the decision); all 8 + 8 pods Ready by 17:34:30 |
| 17:34:42 – 17:35:57 | load gone: both HPAs step down 8 → 6 → 4 → 2 |
| **17:37:59** | **Cluster Autoscaler scale-down**: node `ip-10-20-10-194` drained (2 min after the scale-up + 2 min unneeded) |
| 17:40:42 | the node is gone: edge back to 2 |

The server side stayed clean while the laptop failed: the ALB counted **0** target or ELB 5xx in that window. The
scale-down evicted one ingress-nginx controller (rescheduled at once; the other kept serving) and the `web` HPA logged
`FailedGetResourceMetric` for ~10 s while its pod moved; neither caused an error.

## 7. Findings

1. **The Cluster Autoscaler can take a whole service down while it scales in.** At 17:54:20, at 400 req/s, it removed
   the original egress node because its pods would fit on the new one. Nothing stopped it from evicting **both `auth`
   replicas and the only `payment` pod at the same moment**: the chart has no PodDisruptionBudget. Result: ~16–20 s
   without auth (signed-in requests answered 503 `AUTH_UNAVAILABLE`) and without payment. Fix, small and in the chart:
   a PodDisruptionBudget `minAvailable: 1` for `auth` (and for `event`/`registration`, which have ≥ 2 replicas), and
   the annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` on the single `payment` pod (it is
   `Recreate` by design and must not be moved mid-request). The 2-minute demo timings made this more likely, not
   possible: the defaults (10 min) only delay it.
2. **The pod slot limit, not CPU, is what adds nodes.** Every edge scale-up was triggered by *"Too many pods"*: a `t3.small`
   holds 11 pods (VPC CNI), and with 50 m CPU requests the scheduler never runs out of CPU first. The nodes were under
   half busy at 800 req/s. Pods ran at ~290 % of their CPU request, so the HPA percentages are mostly a signal of
   "busy", not of capacity. Right-sizing the requests (≈ 150 m for `event`, the measured use at load) would make the
   scheduler and the HPA see real capacity, at the price of fewer pods per node.
3. **The HPAs hit their ceiling of 8 well before the system was in trouble.** `event` was at 8 from 150 req/s on. With
   the Cluster Autoscaler in place, the "8 because a `t3.medium` only holds 17 pods" rule is no longer what limits it;
   raising the ceilings (and lowering `DB_POOL_MAX` accordingly, RDS Proxy absorbs the rest) is the next lever.
4. **New capacity is fast.** Pending → new node registered: 23–40 s; the scaling decision itself 10–20 s after the first
   Pending pod. The ECR images pull in a few seconds through the VPC endpoints.
5. **One laptop is not a load generator.** The home network refused all connections to AWS at ~300 req/s. Server-side
   numbers (ALB, CloudWatch) are the ones to trust for the laptop runs; anything heavier has to run in the region.
6. **A new public load balancer gets scanned immediately**: 248 unsolicited requests in the idle window, 10 blocked by the
   WAF. The per-IP rate rule (10,000 per 5 min ≈ 33 req/s) is low enough that one office behind a single NAT could trip
   it at peak; it was raised only for the test.
7. **The cache does its job.** 88 % Redis hit rate under load; RDS saw 33 connections through the proxy for 38 client
   connections (the 19 pods that use the database × `DB_POOL_MAX` 4 could open up to 76 without it).

## 8. Limitations

- One run per profile. Scaling events and orders of magnitude are far above run-to-run noise; small percentages are not.
- Reads only. Enrolling, holding seats and paying (writes that lock rows and send mail) are not in the mix.
- idle and normal ran from one laptop, one IP, ≈ 270 ms away: their client latencies are mostly the WAN.
- The in-cluster generator reaches the site through the NAT gateway and the ALB's public address; real users do not
  pass the NAT, so that cost is a test artefact (counted separately in the cost report). Its own node is not part of
  what production would need.
- The Cluster Autoscaler's scale-down timings were shortened for the demo (2 min instead of 10 min).
- The "where it breaks" numbers in §5 are extrapolations, not measurements.

## 9. Reproduce

```sh
bash load/run.sh idle
terraform -chdir=infra/terraform apply -var waf_rate_limit=2000000    # one source IP sends all the load
bash load/run.sh normal
RUNNER=cluster bash load/run.sh extreme                                 # k6 as a Job in the cluster
terraform -chdir=infra/terraform apply                                  # the WAF limit back to 10,000 per 5 min
```

Each run's folder holds `summary.json` (k6), `dashboard.html` (k6's HTML report with time series), `timeline.csv` (the
cluster every ~10 s), `events.txt` and `autoscaler.log` (scaling decisions), and `cloudwatch-summary.tsv`.
