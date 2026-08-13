#!/usr/bin/env bash
# oc_run.sh — invoca opencode non-interattivo e restituisce un output COMPATTO
# pensato per essere letto da un orchestratore LLM (economia di token).
#
# Usage:
#   oc_run.sh -d WORKDIR [-c] [-s SESSION_ID] [-T TIMEOUT_S] [-t TITLE] [-m MODEL] [-p PROMPT_FILE]
#   echo "prompt" | oc_run.sh -d ~/projects/foo -t my-task
#
#   -d  working directory (obbligatorio)
#   -c  continua l'ultima sessione (per iterazioni correttive)
#   -s  continua una sessione specifica
#   -T  timeout in secondi (default 600)
#   -t  titolo task (default oc-task) — usato per log e --title
#   -m  modello opencode (es. deepseek/deepseek-v4-flash); default: config opencode.jsonc
#   -p  file contenente il prompt (altrimenti letto da stdin)
#
# Output su stdout: EXIT_CODE, LOG path, ultime ~60 righe del run (no ANSI).
# Il log completo resta su disco: NON rileggerlo se il tail basta.

set -uo pipefail

# IMPORTANTE: usare il build npm. Il build snap (classic) fallisce con
# "snap-confine ... cap_dac_override" quando invocato da shell systemd-hardened
# (mcp-bridge.service, timer, ecc.).
OC="${OC_BIN:-$HOME/.npm-global/bin/opencode}"
LOGDIR="$HOME/.local/state/oc-orchestrate"
mkdir -p "$LOGDIR"

WORKDIR="" SESSION="" CONT=0 TIMEOUT=600 TITLE="oc-task" PROMPTFILE="" MODEL=""
while getopts "d:s:cT:t:p:m:" o; do
  case $o in
    d) WORKDIR=$OPTARG ;;
    s) SESSION=$OPTARG ;;
    c) CONT=1 ;;
    T) TIMEOUT=$OPTARG ;;
    t) TITLE=$OPTARG ;;
    p) PROMPTFILE=$OPTARG ;;
    m) MODEL=$OPTARG ;;
    *) echo "ERR: bad option"; exit 2 ;;
  esac
done

[ -z "$WORKDIR" ] && { echo "ERR: -d WORKDIR obbligatorio"; exit 2; }
[ -d "$WORKDIR" ] || { echo "ERR: WORKDIR '$WORKDIR' inesistente"; exit 2; }
[ -x "$OC" ] || { echo "ERR: opencode non trovato in $OC (npm i -g opencode-ai)"; exit 2; }

if [ -n "$PROMPTFILE" ]; then
  PROMPT="$(cat "$PROMPTFILE")"
else
  PROMPT="$(cat)"
fi
[ -z "$PROMPT" ] && { echo "ERR: prompt vuoto"; exit 2; }

TS=$(date +%Y%m%d-%H%M%S)
SAFE_TITLE=$(printf '%s' "$TITLE" | tr -cs 'a-zA-Z0-9_-' '-')
LOG="$LOGDIR/$TS-$SAFE_TITLE.log"

# ONE WORKER AT A TIME, PER USER (snaporca-i14). Concurrent opencode runs on this box do not
# merely contend — they CROSS-ATTRIBUTE: of three parallel runs, one did all the work, two
# exited 0 having changed nothing, and one worker's log contained another worker's complete
# transcript. An orchestrator that follows the skill's own token-economy rule (read the tail,
# trust it) would then review a diff belonging to a different task, or mark work done that
# never happened. The lock is per-USER and not per-repo on purpose: the suspected shared state
# is the opencode session store under ~/.local/share/opencode, which distinct -d does not
# isolate. Refuse rather than queue — a caller that blocks for 30 minutes with no output looks
# identical to a hang, and the orchestrator needs to know it must serialise.
LOCK="$LOGDIR/.run.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "ERR: another opencode run is already in progress (lock: $LOCK)."
  echo "     Concurrent runs cross-attribute their output and silently no-op — snaporca-i14."
  echo "     Wait for it to finish, then re-run. Set OC_ALLOW_CONCURRENT=1 only to reproduce"
  echo "     the bug deliberately."
  [ "${OC_ALLOW_CONCURRENT:-0}" = "1" ] || exit 3
  echo "     OC_ALLOW_CONCURRENT=1 set — proceeding anyway, results are NOT trustworthy."
fi

# opencode 1.17.x HANGS when stdout is not a TTY (produces zero output, then
# times out). Provide a pseudo-TTY via script(1) so non-interactive runs work.
# Prompt is passed via a temp file to survive multi-line/special chars.
PF="$LOGDIR/.prompt-$TS.txt"
printf '%s' "$PROMPT" > "$PF"
CONTFLAG=""; [ "$CONT" -eq 1 ] && CONTFLAG="--continue"
SESSFLAG=""; [ -n "$SESSION" ] && SESSFLAG="--session $SESSION"
MODELFLAG=""; [ -n "$MODEL" ] && MODELFLAG="--model $MODEL"
export OC WORKDIR TIMEOUT SAFE_TITLE PF CONTFLAG SESSFLAG MODELFLAG
script -qfec 'cd "$WORKDIR" && timeout "$TIMEOUT" "$OC" run --title "$SAFE_TITLE" $MODELFLAG $CONTFLAG $SESSFLAG "$(cat "$PF")"' "$LOG" >/dev/null 2>&1
RC=$?
rm -f "$PF"

echo "EXIT_CODE: $RC $( [ $RC -eq 124 ] && echo '(TIMEOUT)' )"
echo "LOG: $LOG ($(wc -l <"$LOG") righe)"
# Exit 0 is not evidence that anything happened (snaporca-i14): the two starved workers both
# exited 0 with an empty diff. Say so here, where the orchestrator is already looking, rather
# than leaving it to be noticed three steps later during review.
if git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$(git -C "$WORKDIR" status --porcelain)" ]; then
    echo "WARNING: exit $RC but the working tree is CLEAN — this run changed nothing."
    echo "         Read the tail before believing the task was done; a task that legitimately"
    echo "         only reads or reports will also land here, so this is a prompt to check,"
    echo "         not a verdict."
  fi
fi
echo "--- TAIL ---"
sed -e 's/\x1b\[[0-9;]*[mK]//g' -e 's/\x1b\][^\x07]*\x07//g' "$LOG" | grep -v '^\s*$' | tail -60
exit $RC
