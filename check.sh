#!/usr/bin/env bash
# check.sh — resolve a fixed set of names against every detected resolver IP.
#
# Server IPs come from tool/*.mhtml (see extract-servers.py); target names come
# from targets.txt. Each name is queried per server with `dig @ip name A`
# (A records only, 2 attempts against UDP packet loss). A server is FAIL if any
# name does not resolve. Cause is split: OFFLINE (no reply at all, dig rc 9) vs
# RESOLUTION BROKEN (server replies but some names have no A answer).
#
# Alerting model: no SMTP. The job exits 1 ONLY on an OK -> FAIL transition, so
# GitHub sends its native failure e-mail exactly once. State is persisted in
# state/last-status.json and committed only when it changes (no per-run noise).
# The detailed cause/targets/timestamp report is written to the GitHub job
# summary and as ::error:: annotations (one click from the notification mail).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$REPO_ROOT/last-status.json"
TARGETS_FILE="$REPO_ROOT/targets.txt"

TZ_BERLIN='Europe/Berlin'
now_ts() { TZ="$TZ_BERLIN" date '+%Y-%m-%d %H:%M:%S %Z%z'; }
NOW="$(now_ts)"

summary() { printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }

# --- load inputs -----------------------------------------------------------
mapfile -t TARGETS < <(grep -vE '^\s*(#|$)' "$TARGETS_FILE" | tr -d '\r' | awk '{print $1}')
mapfile -t SERVERS < <(python3 "$REPO_ROOT/extract-servers.py")

if [ "${#SERVERS[@]}" -eq 0 ]; then
  echo "::error::No resolver IPs extracted from tool/*.mhtml"; exit 1
fi
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "::error::No target names in targets.txt"; exit 1
fi

TOTAL_T=${#TARGETS[@]}

# --- per-target probe: echoes ok|noanswer|noreply --------------------------
probe() { # $1=server ip  $2=name
  local ip="$1" name="$2" out rc got_reply=0
  for _ in 1 2; do
    out="$(dig @"$ip" "$name" A +short +time=3 +tries=1 2>/dev/null)"; rc=$?
    [ "$rc" -ne 9 ] && got_reply=1
    if printf '%s\n' "$out" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      echo ok; return
    fi
    sleep 1
  done
  [ "$got_reply" -eq 1 ] && echo noanswer || echo noreply
}

# --- run checks ------------------------------------------------------------
declare -a FAIL_LINES=()   # human-readable, one per failing server
declare -a FAIL_IPS=()     # ip list for state
any_fail=0

for ip in "${SERVERS[@]}"; do
  ok=0; noreply=0; declare -a bad=()
  for name in "${TARGETS[@]}"; do
    case "$(probe "$ip" "$name")" in
      ok)      ok=$((ok+1)) ;;
      noreply) noreply=$((noreply+1)); bad+=("$name") ;;
      noanswer) bad+=("$name") ;;
    esac
  done

  if [ "$ok" -eq "$TOTAL_T" ]; then
    continue                                   # server OK
  fi
  any_fail=1
  FAIL_IPS+=("$ip")
  if [ "$noreply" -eq "$TOTAL_T" ]; then
    FAIL_LINES+=("$ip  OFFLINE — keine Antwort auf alle $TOTAL_T Ziele (dig rc 9)")
  else
    FAIL_LINES+=("$ip  AUFLÖSUNG DEFEKT — ${ok}/${TOTAL_T} ok; kein A-Record für: ${bad[*]}")
  fi
done

# --- previous state --------------------------------------------------------
PREV_STATUS="OK"; PREV_SINCE="$NOW"
if [ -f "$STATE_FILE" ]; then
  PREV_STATUS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status","OK"))' "$STATE_FILE" 2>/dev/null || echo OK)"
  PREV_SINCE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("since",""))' "$STATE_FILE" 2>/dev/null || true)"
fi

if [ "$any_fail" -eq 1 ]; then CUR_STATUS="FAIL"; else CUR_STATUS="OK"; fi

# 'since' only advances on an actual status change (keeps the file stable
# across unchanged runs, so no spurious commits).
if [ "$CUR_STATUS" != "$PREV_STATUS" ]; then SINCE="$NOW"; else SINCE="${PREV_SINCE:-$NOW}"; fi

# --- write new state (sorted failing set, stable serialisation) ------------
mkdir -p "$(dirname "$STATE_FILE")"
FAILING_CSV="$(printf '%s\n' "${FAIL_IPS[@]}" | sed '/^$/d' | sort -V | paste -sd, -)"
STATUS="$CUR_STATUS" SINCE="$SINCE" FAILING="$FAILING_CSV" python3 - "$STATE_FILE" <<'PY'
import json, os, sys
failing = [x for x in os.environ.get("FAILING", "").split(",") if x]
state = {"status": os.environ["STATUS"], "since": os.environ["SINCE"], "failing": failing}
with open(sys.argv[1], "w") as fh:
    json.dump(state, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

# --- report ----------------------------------------------------------------
summary "# DNS-Monitor — $CUR_STATUS"
summary ""
summary "Zeitpunkt: **$NOW**"
summary "Server geprüft: ${#SERVERS[@]} · Ziele je Server: $TOTAL_T"
summary ""
if [ "$any_fail" -eq 1 ]; then
  summary "## Betroffene Server"
  for line in "${FAIL_LINES[@]}"; do
    summary "- $line"
    echo "::error::$line"
  done
else
  summary "Alle Resolver lösen alle Ziele sauber auf."
fi

# --- transition-only failure signal ---------------------------------------
# OK -> FAIL: fail the job once so GitHub sends its native failure mail.
# FAIL -> FAIL: stay green (no repeat mail). FAIL -> OK / OK -> OK: green.
if [ "$PREV_STATUS" = "OK" ] && [ "$CUR_STATUS" = "FAIL" ]; then
  echo "::error::DNS-Monitor: Zustandswechsel OK -> FAIL um $NOW"
  exit 1
fi
exit 0
