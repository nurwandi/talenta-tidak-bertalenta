#!/usr/bin/env bash
# Manual kill switch for the Talenta attendance automation.
# Disables/enables BOTH EventBridge schedules (clock-in + clock-out) at once.
#
#   ./toggle.sh off   # before a holiday / leave — nothing will fire
#   ./toggle.sh on    # back to work — schedules resume
#
# Reads the live schedule, flips its State, writes it back. Needs `aws` + `jq`.
# Terraform ignore_changes=[state] keeps this toggle from being reverted on apply.
set -euo pipefail

case "${1:-}" in
  on)  STATE=ENABLED ;;
  off) STATE=DISABLED ;;
  *)   echo "usage: $0 on|off" >&2; exit 1 ;;
esac

REGION="ap-southeast-3"
GROUP="talenta-tidak-bertalenta"
export AWS_PROFILE="${AWS_PROFILE:-obi-sandbox}"

for N in talenta-tidak-bertalenta-sched-in talenta-tidak-bertalenta-sched-out; do
  json=$(aws scheduler get-schedule --name "$N" --group-name "$GROUP" --region "$REGION" \
    | jq --arg s "$STATE" '.State=$s | del(.Arn,.CreationDate,.LastModificationDate)')
  aws scheduler update-schedule --region "$REGION" --cli-input-json "$json" >/dev/null
  echo "$N → $STATE"
done
