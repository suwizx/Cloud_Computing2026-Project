#!/usr/bin/env bash
# What this account was actually billed, from Cost Explorer: one row per day, service and usage type, with the usage
# quantity and the effective unit rate (cost / quantity). Usage only: the lab's credits are a separate record type
# that would net everything to ~$0. This is the reconciliation side of docs/COST-REPORT.md: every estimated line there
# names the usage type it bills under, so the two can be matched row by row.
#
#   bash scripts/cost-actual.sh                       # this month so far
#   bash scripts/cost-actual.sh 2026-10-27 2026-10-28 # one day (end is exclusive)
#   TOTAL=1 bash scripts/cost-actual.sh 2026-08-01 2026-11-01   # just the total, e.g. what is left of the $50
#
# Cost Explorer lags up to ~24 h, so run it the day after a session for the full picture. Each call bills $0.01
# (USE1-APIRequest); this script makes one per 100 rows of output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib.sh"
load_aws_env

START="${1:-$(date +%Y-%m-01)}"
END="${2:-$(date -v+1d +%F 2>/dev/null || date -d tomorrow +%F)}"
USAGE='{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'

if [ -n "${TOTAL:-}" ]; then
  # captured first: a failed call must fail the script, not print $0.00
  AMOUNTS="$(aws ce get-cost-and-usage --time-period "Start=$START,End=$END" --granularity MONTHLY --metrics UnblendedCost \
    --filter "$USAGE" --query 'ResultsByTime[].Total.UnblendedCost.Amount' --output text)"
  tr '\t' '\n' <<<"$AMOUNTS" | awk -v s="$START" -v e="$END" '{ t += $1 } END { printf "usage cost %s .. %s: $%.2f\n", s, e, t }'
  exit 0
fi

printf 'day\tservice\tusage_type\tquantity\tunit\tcost_usd\tunit_rate\n'
TOKEN=""
while :; do
  OUT="$(aws ce get-cost-and-usage --time-period "Start=$START,End=$END" --granularity DAILY \
    --metrics UnblendedCost UsageQuantity --filter "$USAGE" \
    --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=USAGE_TYPE \
    ${TOKEN:+--next-page-token "$TOKEN"} --output json)"
  jq -r '.ResultsByTime[] | .TimePeriod.Start as $d | .Groups[]
    | (.Metrics.UnblendedCost.Amount | tonumber) as $c | (.Metrics.UsageQuantity.Amount | tonumber) as $q
    | select($c > 0.00005)
    | [$d, .Keys[0], .Keys[1], ($q * 10000 | round / 10000), .Metrics.UsageQuantity.Unit, ($c * 10000 | round / 10000),
       (if $q > 0 then ($c / $q * 1000000 | round / 1000000) else "" end)] | @tsv' <<<"$OUT"
  TOKEN="$(jq -r '.NextPageToken // empty' <<<"$OUT")"
  [ -n "$TOKEN" ] || break
done
