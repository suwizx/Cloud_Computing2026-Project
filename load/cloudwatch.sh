#!/usr/bin/env bash
# Pulls the AWS-side view of a load-test window from CloudWatch into <dir>/cloudwatch.json (raw GetMetricData) and
# <dir>/cloudwatch-summary.tsv (sum / avg / max per series): the ALB and the WAF in front, RDS, RDS Proxy and ElastiCache
# behind, the node groups' CPU and CPU credits, and the NAT gateway. These are also the usage figures the cost report
# turns into dollars (LCUs, WAF requests, bytes, surplus CPU credits). Read-only; GetMetricData bills $0.01 per 1,000
# metrics requested (this asks for about 30).
#   bash load/cloudwatch.sh 2026-10-27T16:00:00Z 2026-10-27T16:30:00Z load/results/<date>/<profile>
# CloudWatch lags a few minutes (EC2's basic monitoring is 5-minute data): run it again later for the last points.
set -euo pipefail
START="${1:?start (UTC ISO)}"; END="${2:?end (UTC ISO)}"; DIR="${3:?output dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
load_aws_env
P=eventide

ALB="$(aws elbv2 describe-load-balancers --names "$P-edge" --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*:loadbalancer/##')"
PROXY="$(aws rds describe-db-proxies --query 'DBProxies[0].DBProxyName' --output text)"
REDIS="$(aws elasticache describe-replication-groups --replication-group-id "$P" --query 'ReplicationGroups[0].MemberClusters[0]' --output text)"
NAT="$(aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[0].NatGatewayId' --output text)"
asg() { aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?Tags[?Key=='eks:nodegroup-name' && Value=='$1']].AutoScalingGroupName | [0]" --output text; }
EDGE="$(asg edge)"; EGRESS="$(asg egress)"

# id namespace metric stat period dimension-pairs...
q() {
  local id="$1" ns="$2" metric="$3" stat="$4" period="$5"; shift 5
  local dims="[]"
  while [ $# -gt 0 ]; do dims="$(jq -c --arg n "$1" --arg v "$2" '. + [{Name: $n, Value: $v}]' <<<"$dims")"; shift 2; done
  jq -cn --arg id "$id" --arg ns "$ns" --arg m "$metric" --arg s "$stat" --argjson p "$period" --argjson d "$dims" \
    '{Id: $id, MetricStat: {Metric: {Namespace: $ns, MetricName: $m, Dimensions: $d}, Period: $p, Stat: $s}, ReturnData: true}'
}
# Metrics Insights: one series per instance, so nodes the autoscaler added and removed are counted too
e() { jq -cn --arg id "$1" --arg x "$2" --argjson p "$3" '{Id: $id, Expression: $x, Period: $p, ReturnData: true}'; }

Q="$(jq -s -c . <<EOF
$(q alb_requests AWS/ApplicationELB RequestCount Sum 60 LoadBalancer "$ALB")
$(q alb_resp_avg AWS/ApplicationELB TargetResponseTime Average 60 LoadBalancer "$ALB")
$(q alb_resp_p95 AWS/ApplicationELB TargetResponseTime p95 60 LoadBalancer "$ALB")
$(q alb_target_5xx AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum 60 LoadBalancer "$ALB")
$(q alb_elb_5xx AWS/ApplicationELB HTTPCode_ELB_5XX_Count Sum 60 LoadBalancer "$ALB")
$(q alb_elb_4xx AWS/ApplicationELB HTTPCode_ELB_4XX_Count Sum 60 LoadBalancer "$ALB")
$(q alb_lcu AWS/ApplicationELB ConsumedLCUs Average 60 LoadBalancer "$ALB")
$(q alb_bytes AWS/ApplicationELB ProcessedBytes Sum 60 LoadBalancer "$ALB")
$(q alb_new_conn AWS/ApplicationELB NewConnectionCount Sum 60 LoadBalancer "$ALB")
$(q alb_active_conn AWS/ApplicationELB ActiveConnectionCount Sum 60 LoadBalancer "$ALB")
$(q waf_allowed AWS/WAFV2 AllowedRequests Sum 60 WebACL "$P-edge" Region "${AWS_DEFAULT_REGION}" Rule ALL)
$(q waf_blocked AWS/WAFV2 BlockedRequests Sum 60 WebACL "$P-edge" Region "${AWS_DEFAULT_REGION}" Rule ALL)
$(q rds_cpu AWS/RDS CPUUtilization Maximum 60 DBInstanceIdentifier "$P")
$(q rds_conn AWS/RDS DatabaseConnections Maximum 60 DBInstanceIdentifier "$P")
$(q rds_credit_balance AWS/RDS CPUCreditBalance Minimum 300 DBInstanceIdentifier "$P")
$(q rds_surplus_charged AWS/RDS CPUSurplusCreditsCharged Sum 300 DBInstanceIdentifier "$P")
$(q rds_read_iops AWS/RDS ReadIOPS Average 60 DBInstanceIdentifier "$P")
$(q proxy_client_conn AWS/RDS ClientConnections Maximum 60 ProxyName "$PROXY")
$(q proxy_db_conn AWS/RDS DatabaseConnections Maximum 60 ProxyName "$PROXY")
$(q proxy_query_latency AWS/RDS QueryDatabaseResponseLatency Average 60 ProxyName "$PROXY")
$(q redis_engine_cpu AWS/ElastiCache EngineCPUUtilization Maximum 60 CacheClusterId "$REDIS")
$(q redis_conn AWS/ElastiCache CurrConnections Maximum 60 CacheClusterId "$REDIS")
$(q redis_hits AWS/ElastiCache CacheHits Sum 60 CacheClusterId "$REDIS")
$(q redis_misses AWS/ElastiCache CacheMisses Sum 60 CacheClusterId "$REDIS")
$(q edge_cpu AWS/EC2 CPUUtilization Average 300 AutoScalingGroupName "$EDGE")
$(q egress_cpu AWS/EC2 CPUUtilization Average 300 AutoScalingGroupName "$EGRESS")
$(q nat_bytes_out AWS/NATGateway BytesOutToDestination Sum 60 NatGatewayId "$NAT")
$(q nat_bytes_in AWS/NATGateway BytesInFromDestination Sum 60 NatGatewayId "$NAT")
$(e node_cpu 'SELECT AVG(CPUUtilization) FROM SCHEMA("AWS/EC2", InstanceId) GROUP BY InstanceId' 300)
$(e node_surplus_charged 'SELECT SUM(CPUSurplusCreditsCharged) FROM SCHEMA("AWS/EC2", InstanceId) GROUP BY InstanceId' 300)
EOF
)"

aws cloudwatch get-metric-data --start-time "$START" --end-time "$END" --metric-data-queries "$Q" --output json > "$DIR/cloudwatch.json"
{
  printf 'series\tpoints\tsum\tavg\tmax\n'
  jq -r '.MetricDataResults[] | [ (.Label // .Id), (.Values | length), (.Values | add // 0),
      (if (.Values | length) > 0 then (.Values | add) / (.Values | length) else 0 end), (.Values | max // 0) ]
    | @tsv' "$DIR/cloudwatch.json"
} > "$DIR/cloudwatch-summary.tsv"
echo "cloudwatch: $(jq '.MetricDataResults | length' "$DIR/cloudwatch.json") series -> $DIR/cloudwatch-summary.tsv"
