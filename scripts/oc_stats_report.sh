#!/usr/bin/env bash
# oc_stats_report.sh — a one-line daily summary of what the executor cost.
#
# Usage: oc_stats_report.sh [DAYS] [--dry-run]
#   DAYS       window in days (default 1)
#   --dry-run  print the message instead of sending it
#
# With no sessions in the window it exits silently: a cost report that pings you to say
# nothing happened is a report you will mute, and then you will miss the one that matters.
#
# DELIVERY IS YOURS TO CHOOSE. Set OC_STATS_NOTIFY to a command that takes the message as
# its last argument, and it will be exec'd with it:
#
#   export OC_STATS_NOTIFY="/path/to/notify send --category system_update"
#   export OC_STATS_NOTIFY="curl -s -X POST -d @- https://hooks.example/…"   # see note below
#
# Unset, the message goes to stdout — which is all a cron job needs to mail it, and is the
# only default that cannot fail on a machine that has never heard of your chat tooling.

set -uo pipefail

OC="${OC_BIN:-$HOME/.npm-global/bin/opencode}"
NOTIFY="${OC_STATS_NOTIFY:-}"

DAYS="${1:-1}"
DRY=""
[ "${2:-}" = "--dry-run" ] && DRY=1

[ -x "$OC" ] || exit 0

RAW=$("$OC" stats --days "$DAYS" 2>/dev/null) || exit 0

get() { # get <exact-label> -> last field of that row
  printf '%s\n' "$RAW" | grep -m1 -F "│$1" | sed 's/[│]//g' | awk '{print $NF}'
}

SESS=$(get "Sessions ")
COST=$(get "Total Cost")
IN=$(get "Input ")
OUT=$(get "Output ")
CACHE=$(get "Cache Read")

# No activity in the window -> no message.
case "${SESS:-0}" in ""|0) exit 0;; esac

MSG="opencode offload (${DAYS}d): ${SESS} sessions · cost ${COST:-?} · in ${IN:-?} / out ${OUT:-?} tok · cache ${CACHE:-?}"

if [ -n "$DRY" ] || [ -z "$NOTIFY" ]; then
  printf '%s\n' "$MSG"
  exit 0
fi

# Deliberately unquoted: OC_STATS_NOTIFY is a command plus its flags, set by the person
# running this on their own machine. It is not attacker-controlled input.
# shellcheck disable=SC2086
exec $NOTIFY "$MSG"
