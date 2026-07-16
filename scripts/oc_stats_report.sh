#!/usr/bin/env bash
# oc_stats_report.sh — report giornaliero del costo executor (opencode/DeepSeek)
# verso Telegram, passando dal budget arbiter di Athena (categoria system_update).
#
# Usage: oc_stats_report.sh [DAYS] [--dry-run]
#   DAYS      finestra in giorni (default 1)
#   --dry-run passa --dry-run a outbound.py (nessun invio, nessun consumo budget)
#
# Se nella finestra non ci sono sessioni opencode, esce in silenzio (zero rumore).

set -uo pipefail

OC="${OC_BIN:-$HOME/.npm-global/bin/opencode}"
OUTBOUND="$HOME/projects/athena/modules/comm-tg/scripts/outbound.py"

DAYS="${1:-1}"
DRY=""
[ "${2:-}" = "--dry-run" ] && DRY="--dry-run"

[ -x "$OC" ] || exit 0
[ -x "$OUTBOUND" ] || { echo "ERR: outbound.py non trovato"; exit 1; }

RAW=$("$OC" stats --days "$DAYS" 2>/dev/null) || exit 0

get() { # get <label-esatta> → ultimo campo della riga
  printf '%s\n' "$RAW" | grep -m1 -F "│$1" | sed 's/[│]//g' | awk '{print $NF}'
}

SESS=$(get "Sessions ")
COST=$(get "Total Cost")
IN=$(get "Input ")
OUT=$(get "Output ")
CACHE=$(get "Cache Read")

# Nessuna attivita` nella finestra → niente messaggio
case "${SESS:-0}" in ""|0) exit 0;; esac

MSG="📊 opencode offload (${DAYS}g): ${SESS} sessioni · costo ${COST:-?} · in ${IN:-?} / out ${OUT:-?} tok · cache ${CACHE:-?}"

exec "$OUTBOUND" send --category system_update --score 0.5 $DRY "$MSG"
