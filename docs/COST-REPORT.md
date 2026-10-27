# Cost report: Eventide on AWS (us-east-1)

What the production layout costs to run idle and under load. Every dollar below traces to an AWS service, a unit price
with its SKU, and a quantity taken from the Terraform code or measured on the running account during the load tests of
2026-10-27 ([load/LOADTEST-REPORT.md](../load/LOADTEST-REPORT.md)).

Account 735838417080 (AWS Academy Learner Lab, **$50 hard cap**), region us-east-1, EKS 1.35, nodes `t3.small`.

## 1. Summary

| Scenario | $/hour | 4-hour lab session | 30 days (730 h) |
|---|---:|---:|---:|
| **Idle**: platform up, nobody using it (3 nodes) | **0.403** | 1.61 | 294 |
| **Normal**: 40 req/s, measured mix (3 nodes) | **0.530** | 2.12 | 387 |
| **Full load**: 800 req/s sustained, 4 nodes (§5) | **3.07** | 12.27 | 2,240 |
| Same idle platform on EKS 1.33 (extended support) | 0.903 | 3.61 | 659 |
| **Platform down** (`make down`): 3 secrets, DNS zone, 3 GB in ECR | 0.0027 | 0.011 | 2.01 |

- At idle the money goes to **infrastructure, not usage**: the EKS control plane, six interface endpoints, three nodes
  and the NAT gateway are 66 % of the hourly bill.
- Under load the **per-request lines** take over: at 800 req/s the WAF's request charge alone is $1.73/h (56 %) and
  data out $0.75/h (24 %). The node the Cluster Autoscaler adds costs $0.023/h. Each extra million requests costs
  **≈ $0.93** (WAF $0.60, data out $0.26, the rest LCUs, the node and burst CPU credits).
- **Left running, the platform costs ≈ $9.7 a day**, which is about 2.9 days of the $28 left in the lab budget (§6).
- Running EKS 1.33 instead of 1.35 would more than double the idle bill: 1.33 left standard support on 2026-07-29 and
  bills **extended support at $0.50/h on top of $0.10/h**. This account was already billed for it in September (§7).

## 2. Method and sources

- **Unit prices:** the AWS Price List bulk files, us-east-1 on-demand, downloaded 2026-10-27 from
  `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<service>/current/us-east-1/index.json` (public, no
  credentials; the lab role is denied the Pricing API). Each price below names its **SKU** and the file's version.
  CloudWatch dashboards and the RDS Proxy 2-vCPU minimum are not in the files and come from the pricing pages.
- **Quantities:** the Terraform code (`infra/terraform`) and, where it matters, the running account: 3 public IPv4
  addresses (2 ALB + 1 NAT EIP), 3 × 20 GB **gp3** node volumes, nodes in T3 **unlimited** mode, WAF capacity 949 WCU with
  5 rules, 5 secrets, 15 alarms, 1 dashboard, 3.05 GB in ECR, 1.6 MB in S3, SQS long poll 10 s.
- **Usage under load:** CloudWatch for each load-test window (`load/cloudwatch.sh`): ALB `ProcessedBytes` and connections,
  WAF `AllowedRequests`, `CPUSurplusCreditsCharged` per node and for RDS, NAT bytes.
- **Cross-check against the bill:** this account's own Cost Explorer usage (`scripts/cost-actual.sh`). Every rate that
  the account has been billed for before matches the price list (§7).
- **No free tier.** Learner Lab usage is billed from the first unit: in September this account paid for 381 S3 PUTs and
  0.34 GB-month of ECR, both inside the normal free tier. So no line below subtracts a free tier.

## 3. Unit prices

| Service | Usage type (as billed) | Price | SKU | Price list version |
|---|---|---|---|---|
| EKS | `USE1-AmazonEKS-Hours:perCluster` | $0.10 / cluster-hour | ZYWMR684YSMFHWEU | AmazonEKS 20260928194255 |
| EKS | `USE1-AmazonEKS-Hours:extendedSupport` | $0.50 / cluster-hour | M7977BSVFGDUJZ67 | AmazonEKS 20260928194255 |
| EC2 | `BoxUsage:t3.small` (Linux) | $0.0208 / hour | QA3NBPZEQKZ2K9AR | AmazonEC2 20261023221355 |
| EC2 | `CPUCredits:t3` (Linux, unlimited surplus) | $0.05 / vCPU-hour | DHXM9J4FT38HQAQ6 | AmazonEC2 20261023221355 |
| EBS | `EBS:VolumeUsage.gp3` | $0.08 / GB-month | JG3KUJMBRGHV3N8G | AmazonEC2 20261023221355 |
| VPC | `NatGateway-Hours` / `NatGateway-Bytes` | $0.045 / hour, $0.045 / GB | M2YSHUBETB3JX4M4 / 59S5R83GFPUAGVR5 | AmazonEC2 20261023221355 |
| VPC | `USE1-PublicIPv4:InUseAddress` | $0.005 / address-hour | 4GQUNXTFWVSGPUZK | AmazonVPC 20261016224321 |
| VPC | `USE1-VpcEndpoint-Hours` / `-Bytes` | $0.01 / endpoint-AZ-hour, $0.01 / GB | EN2N5TATXE673A3B / DQYYEZBCWSW5XS2R | AmazonVPC 20261016224321 |
| ELB | `LoadBalancerUsage` (ALB) | $0.0225 / hour | 37CUWUT8GSNQEPUV | AWSELB 20260911124544 |
| ELB | `LCUUsage` (ALB) | $0.008 / LCU-hour | P2XGEJ8N3KU52WA8 | AWSELB 20260911124544 |
| WAF | `USE1-WebACLV2` / `USE1-RuleV2` | $5 / web ACL-month, $1 / rule-month (prorated hourly) | KF2QAJUBXF7XNYSM / JGH3VFMTQFNJUV5W | awswaf 20260914163921 |
| WAF | `USE1-RequestV2-Tier1` (≤ 1,500 WCU; ours is 949) | $0.60 / million requests | 94S3KGQ8C7XGQFSJ | awswaf 20260914163921 |
| RDS | `InstanceUsage:db.t3.micro` (PostgreSQL, Single-AZ) | $0.018 / hour | TGN7QDJF2AGFU9XA | AmazonRDS 20261026214716 |
| RDS | `RDS:GP3-Storage` (PostgreSQL) | $0.115 / GB-month | KYVYY29G957PKY3B | AmazonRDS 20261026214716 |
| RDS | `CPUCredits:db.t3` (PostgreSQL) | $0.075 / vCPU-hour | C4924V2PCZBUKDC6 | AmazonRDS 20261026214716 |
| RDS Proxy | `USE1-RDS:ProxyUsage` | $0.015 / vCPU-hour of the DB (minimum 2 vCPU) | AHVT2C6WP2BB5BXQ | AmazonRDS 20261026214716 |
| ElastiCache | `NodeUsage:cache.t3.micro` (Redis) | $0.017 / hour (Valkey: $0.0136) | YJHUKPU3DN6YKD58 | AmazonElastiCache 20261014221139 |
| CloudWatch | `CW:AlarmMonitorUsage` | $0.10 / alarm-month | EVETVUGEN3MUTMXM | AmazonCloudWatch 20261007115540 |
| CloudWatch | dashboard | $3 / dashboard-month | pricing page | aws.amazon.com/cloudwatch/pricing |
| CloudWatch | `CW:GMD-Metrics` (GetMetricData) | $0.01 / 1,000 metrics | ST83NCNZMVRKWEVJ | AmazonCloudWatch 20261007115540 |
| Secrets Manager | `USE1-AWSSecretsManager-Secrets` / API | $0.40 / secret-month, $0.05 / 10,000 calls | BJ3PQ9BYGU6P632F / 4MDZ5VNEJPMUTG9B | AWSSecretsManager 20260911124610 |
| Route 53 | `HostedZone` / `DNS-Queries` | $0.50 / zone-month, $0.40 / million (ALIAS to the ALB: free) | KVPGEJE88UW8S779 / JHRA6QBEDT9FZVT5 | AmazonRoute53 20260911124504 |
| ECR | `TimedStorage-ByteHrs` | $0.10 / GB-month | KJC988R4J65BDMTQ | AmazonECR 20260911124425 |
| S3 | `TimedStorage-ByteHrs`, `Requests-Tier1/2` | $0.023 / GB-month, $0.005 / 1,000 PUT, $0.0004 / 1,000 GET | WP9ANXZGBYYSGJEA / E9YHNFENF4XQBZR6 / ZWQ6Q48CRJXX4FXE | AmazonS3 |
| SQS | `Requests-RBP` | $0.40 / million | 8RN6B8U4MERHRXP3 | AWSQueueService |
| Data transfer | `DataTransfer-Out-Bytes` (to the internet) | $0.09 / GB (first 10 TB) | HQEH3ZWJVT46JHRG | AWSDataTransfer 20260916132208 |
| Data transfer | `DataTransfer-Regional-Bytes` (across AZs) | $0.01 / GB each way | PNUBVW4CPC8XA46W | AWSDataTransfer 20260916132208 |
| Cost Explorer | `USE1-APIRequest` | $0.01 / request | BX68HKNBJP73AFBV | AWSCostExplorer |

ACM public certificates, the VPC itself, subnets, route tables, the internet gateway, the S3 gateway endpoint, the SNS
topic without subscribers, EKS managed add-ons and the AWS-managed KMS keys that encrypt RDS and ElastiCache cost nothing.

## 4. Idle: the fixed hourly cost, line by line

The platform with nobody on it: 2 edge + 1 egress `t3.small`, every HPA at its minimum (measured: §5 and the idle run).

| Line | Terraform | Qty | Unit price | $/hour | 30 days |
|---|---|---:|---|---:|---:|
| EKS control plane (1.35) | `module.platform.aws_eks_cluster.this` | 1 | $0.10/h | 0.1000 | 73.00 |
| EC2 nodes | `aws_eks_node_group.edge` (2), `.egress` (1) | 3 | $0.0208/h | 0.0624 | 45.55 |
| EBS node volumes | node groups, `disk_size = 20`, gp3 | 60 GB | $0.08/GB-month | 0.0066 | 4.80 |
| VPC interface endpoints | `aws_vpc_endpoint.interface` (ecr.api, ecr.dkr, sts, ec2, sqs, secretsmanager) × 1 AZ | 6 | $0.01/h | 0.0600 | 43.80 |
| NAT gateway | `aws_nat_gateway.this` | 1 | $0.045/h | 0.0450 | 32.85 |
| RDS Proxy | `aws_db_proxy.main` (db.t3.micro = 2 vCPU) | 2 vCPU | $0.015/vCPU-h | 0.0300 | 21.90 |
| ALB | `aws_lb.edge` | 1 | $0.0225/h | 0.0225 | 16.43 |
| RDS instance | `aws_db_instance.main`, db.t3.micro Single-AZ | 1 | $0.018/h | 0.0180 | 13.14 |
| RDS storage | gp3 20 GB | 20 GB | $0.115/GB-month | 0.0032 | 2.30 |
| ElastiCache | `aws_elasticache_replication_group.main`, 1 × cache.t3.micro | 1 | $0.017/h | 0.0170 | 12.41 |
| Public IPv4 | ALB (2, one per subnet) + NAT EIP (1) | 3 | $0.005/h | 0.0150 | 10.95 |
| WAF web ACL | `aws_wafv2_web_acl.edge` | 1 | $5/month | 0.0068 | 5.00 |
| WAF rules | stripe allow, rate limit, Common, KnownBadInputs, IP reputation | 5 | $1/month | 0.0068 | 5.00 |
| CloudWatch alarms | `aws_cloudwatch_metric_alarm.this` (14) + `.waf_blocks` | 15 | $0.10/month | 0.0021 | 1.50 |
| CloudWatch dashboard | `aws_cloudwatch_dashboard.main` | 1 | $3/month | 0.0041 | 3.00 |
| Secrets Manager | google-oauth, gmail, stripe (permanent) + rds-master, endpoints (platform) | 5 | $0.40/month | 0.0027 | 2.00 |
| Route 53 hosted zone | `aws_route53_zone.app` | 1 | $0.50/month | 0.0007 | 0.50 |
| ECR storage | 9 repositories | 3.05 GB | $0.10/GB-month | 0.0004 | 0.31 |
| SQS | mail-worker long poll (10 s) ≈ 360 requests/h | 360/h | $0.40/million | 0.0001 | 0.11 |
| S3 | uploads + Terraform state | 1.6 MB | $0.023/GB-month | 0.0000 | 0.00 |
| **Total, idle** | | | | **0.4033** | **294.4** |

Measured during the idle run (15 min, one request every 5 s): the ALB still saw 430 requests (internet scanners find a
new public load balancer within minutes; the WAF blocked 10 of them), ALB capacity units stayed below 0.001, no node or
RDS CPU credit was charged, and the NAT moved under 1 MB. **Usage-driven cost at idle is below $0.001/h.**

## 5. Under load: what grows, measured

Measured during the load tests (`load/results/2026-10-27/`; CloudWatch per window) and turned into a cost per hour at
a steady rate. The idle lines of §4 stay as they are; these come on top.

| Line | Measured | Normal, 40 req/s | Full load, 800 req/s |
|---|---|---:|---:|
| Requests per hour | | 144,000 | 2,880,000 |
| WAF requests ($0.60 per million) | WAF `AllowedRequests` = ALB requests (every request is inspected) | 0.0864 | **1.7280** |
| Data out to the internet ($0.09/GB) | **3,089 bytes per response on the wire**: NAT `BytesInFromDestination` ÷ requests in the extreme run, where every response crossed the NAT | 0.0373 (0.41 GB) | **0.7457** (8.29 GB) |
| ALB capacity units ($0.008/LCU-h) | processed bytes is the dominant dimension: ALB `ProcessedBytes` = 2,843 bytes per request, 1 LCU per GB-hour; cross-check: `ConsumedLCUs` read 0.42 LCU-h per hour during normal | 0.0031 | 0.0610 |
| Extra nodes (Cluster Autoscaler) | normal: none. Full load: edge 2 → 3 (the k6 generator's own egress node is a test artefact, §6) | 0 | 0.0230 |
| EC2 CPU credits ($0.05/vCPU-h) | **none charged in the 15-minute run** (`CPUSurplusCreditsCharged` = 0 on every node: the balance earned at idle covered it). Sustained: 3 edge nodes at 39 % against the 20 % baseline = 1.14 vCPU-h/h | 0 | 0.0570 |
| RDS CPU credits ($0.075/vCPU-h) | **none charged** in the run (balance 5–8 credits). Sustained: 43.7 % of 2 vCPU against the 0.2 vCPU baseline = 0.67 vCPU-h/h | 0 | 0.0505 |
| NAT data processing ($0.045/GB) | real users do not pass the NAT; the services call nothing outside during these requests (NAT moved < 1 MB per run at idle and normal) | 0 | 0 |
| **Usage-driven, per hour** | | **0.1268** | **2.6652** |
| **Total with the idle base ($0.4033)** | | **0.530** | **3.069** |

- **Per million requests** at full load: $1.07 in total, **$0.93 of it marginal**: WAF $0.60, data out $0.26, LCUs $0.02,
  the extra node and CPU credits $0.045.
- The extra node the autoscaler adds for 800 req/s costs less than 1 % of the hour. The WAF, which inspects every
  request, is the largest single line under load; at this traffic it costs more than the whole idle platform.
- **Not in the totals, not measured:** traffic between the pods (us-east-1a) and the RDS Proxy endpoint in us-east-1b is
  billed at $0.01/GB in each direction. An upper bound, if every database-backed request (48 % of the mix) moved as many
  bytes to the database as to the client and half the connections landed on the 1b endpoint: ≈ $0.04/h at full load.
- The in-cluster load generator added its own costs that production traffic would not have: the k6 egress node
  (≈ 10 min, $0.004), NAT processing of 1.2 GB of responses ($0.054) and public-IP regional transfer ($0.024).

## 6. Today's session

From the creation time of each resource (UTC; EKS, NAT and the endpoints at 15:54, nodes and ElastiCache at 16:04,
RDS at 16:08, RDS Proxy at 16:09, the ALB at 16:16) to 18:20 UTC, when the load tests were over:

| Line | Hours | Qty | $ |
|---|---:|---:|---:|
| EKS control plane | 2.43 | 1 | 0.243 |
| VPC interface endpoints | 2.43 | 6 | 0.146 |
| EC2 base nodes (2 edge + 1 egress) + 60 GB gp3 | 2.27 | 3 | 0.156 |
| EC2 extra nodes added by the Cluster Autoscaler (edge 17:33–17:40 and 17:51–18:07, egress 17:47–17:57) | 0.56 | 1 | 0.013 |
| NAT gateway | 2.43 | 1 | 0.110 |
| RDS Proxy | 2.17 | 2 vCPU | 0.065 |
| RDS instance + storage | 2.20 | 1 | 0.046 |
| ALB | 2.06 | 1 | 0.046 |
| ElastiCache | 2.26 | 1 | 0.038 |
| Public IPv4 (NAT + 2 ALB) | 2.06–2.43 | 3 | 0.033 |
| WAF web ACL + rules, CloudWatch alarms + dashboard | 2.05 | | 0.041 |
| Secrets Manager, Route 53 zone | 2.55 | | 0.009 |
| **Fixed subtotal** | | | **0.946** |
| WAF requests: ≈ 460,000 (idle 431, normal 32,151, laptop extreme 31,168, extreme 393,531, plus the deploy, the demo seed and scanners) | | | 0.276 |
| Data out to the internet (the laptop runs, 0.17 GB) | | | 0.015 |
| In-cluster generator: NAT processing 1.2 GB + public-IP regional transfer | | | 0.078 |
| ALB capacity units (≈ 1.3 LCU-h) | | | 0.010 |
| CPU credits (nodes, RDS) | | | 0 |
| CloudWatch GetMetricData (≈ 250 metrics) and Cost Explorer API (≈ 10 requests) | | | 0.103 |
| **Session to 18:20 UTC** | | | **≈ 1.43** |

**The platform was left running afterwards** (the user's call), so from 18:20 UTC it keeps billing the idle rate of
§4: **$0.403/h, $9.68 per day**. With $20.56 billed before this session and ≈ $1.43 for it, about **$28.0 of the $50
remains, which lasts ≈ 69 hours (≈ 2.9 days) at idle**. Past $50 the account is locked and its resources deleted, so
`make down` well before then; it leaves $0.0027/h ($2.01 a month).

Two things also stop working when this lab session ends, without stopping the bill: the pods' AWS session credentials
(uploads to S3, mail through SQS) and the Cluster Autoscaler's credentials expire with it. After the next Start Lab,
`make redeploy` (or `make ci-creds DEPLOY=1`) refreshes them.

## 7. The bill so far, and how the estimate checks against it

Cost Explorer, usage only (the lab's credits are a separate record type that nets everything to ~$0):

| Period | Usage cost | Main lines |
|---|---:|---|
| 2026-08 | $0.00 | |
| 2026-09 | $19.17 | EKS $14.70 (of which **extended support $12.25**), Secrets $1.29, EC2 $1.23, ELB $0.66, public IPv4 $0.63, RDS $0.50 |
| 2026-10 (to the 26th) | $1.39 | four leftover secrets from September ($0.0516/day) and ECR |
| **Total to 2026-10-27** | **$20.56** | budget left: **$29.44** of $50 |

Effective rates on that bill (cost ÷ usage quantity) against the price list:

| Usage type (Sept 2026) | Billed | Quantity | Effective rate | Price list |
|---|---:|---:|---:|---:|
| `USE1-AmazonEKS-Hours:perCluster` | $2.45 | 24.5 h | $0.100/h | $0.10 |
| `USE1-AmazonEKS-Hours:extendedSupport` | $12.25 | 24.5 h | $0.500/h | $0.50 |
| `BoxUsage:t3.small` | $0.773 | 37.16 h | $0.0208/h | $0.0208 |
| `InstanceUsage:db.t3.micro` | $0.421 | 23.36 h | $0.0180/h | $0.018 |
| `LoadBalancerUsage` | $0.653 | 29 h | $0.0225/h | $0.0225 |
| `USE1-PublicIPv4:InUseAddress` | $0.628 | 125.6 h | $0.0050/h | $0.005 |
| `EBS:VolumeUsage.gp3` | $0.111 | 1.39 GB-month | $0.080 | $0.08 |
| `RDS:GP3-Storage` | $0.075 | 0.65 GB-month | $0.115 | $0.115 |
| `USE1-AWSSecretsManager-Secrets` | $1.291 | 3.23 secret-months | $0.400 | $0.40 |
| `DataTransfer-Regional-Bytes` | $0.022 | 2.21 GB | $0.010 | $0.01 |

The September cluster ran 24.5 hours and cost **$14.70, of which $12.25 was extended support**. That line alone is
why this session runs 1.35.

To reconcile tonight's session once Cost Explorer has caught up (it lags up to ~24 h):

```sh
bash scripts/cost-actual.sh 2026-10-27 2026-10-29     # per day, service and usage type, with the effective rate
TOTAL=1 bash scripts/cost-actual.sh 2026-08-01 2026-11-01
```

## 8. Findings

1. **Kubernetes version is the largest avoidable cost.** EKS 1.33 has been in extended support since 2026-07-29: $0.60/h
   instead of $0.10/h: the extended-support charge alone would be **55 % of the idle bill**. This account paid $12.25 for it in September. The
   platform now runs 1.35 (standard support until 2027-03-27); move on to 1.36 or later before then.
2. **Idle cost is infrastructure, not traffic.** EKS (25 %), six interface endpoints (15 %), three nodes (15 %), NAT
   (11 %) and RDS Proxy (7 %) are 73 % of $0.40/h; usage at idle is below $0.001/h. The six endpoints cost more than
   the ALB; they exist because the edge tier has no route out.
3. **Under load, the WAF is the biggest line.** $0.60 per million requests is 56 % of the full-load hour and 65 % of the
   marginal cost of a request. Data out is next (24 %, at a measured 3.1 KB per response). Nodes, LCUs and CPU credits
   together are under 7 %.
4. **Autoscaled capacity is cheap.** Each node the Cluster Autoscaler adds is $0.023/h; tonight's three extra nodes cost
   $0.013 in total. The bigger cost risk under load is the burstable CPU: a sustained 800 req/s would add ≈ $0.11/h of
   T3 surplus credits (nodes and RDS) once the earned balances run out. None were charged in the 15-minute test.
5. **Left up, the budget lasts ≈ 2.9 days.** $9.68/day against ≈ $28 remaining. `make down` ($0.0027/h when down) is
   the only switch that matters for the lab budget.
6. **Small savings available:** the Valkey engine on the same `cache.t3.micro` is $0.0136/h instead of $0.017/h (−20 %);
   the September leftovers (four per-service secrets, $1.35 billed in October with no platform up) were deleted by the
   first apply of this session.
7. **No free tier in the Learner Lab.** Every line above is billed from the first unit (§2).
