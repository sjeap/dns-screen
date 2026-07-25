#!/usr/bin/env bash
# check.sh — resolve a fixed set of names against every detected resolver IP.
#
# Server IPs come from the DoT source config in tool/ (see extract-servers.py);
# target names come from targets.txt. Each name is queried per server with `dig @ip name A`
# (A records only, 2 attempts against UDP packet loss). A server is FAIL if any
# name does not resolve. Cause is split: OFFLINE (no reply at all, dig rc 9) vs
# RESOLUTION BROKEN (server replies but some names have no A answer).
#
# Servers that fail the direct check are re-checked through an optional
# DataImpulse residential SOCKS5 proxy (secrets DATAIMPULSE_USER/PASS,
# DNS-over-TCP); a server only counts as FAIL if it fails via the proxy too.
# Without the secrets this step is skipped (warning) and behaviour is unchanged.
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
  echo "::error::No resolver IPs extracted from tool/ source config"; exit 1
fi
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "::error::No target names in targets.txt"; exit 1
fi

TOTAL_T=${#TARGETS[@]}

# --- optional residential proxy (DataImpulse, SOCKS5) ----------------------
# Gleicher Account/gleiche Credentials wie im web-feed-Repo. Zwei Secrets,
# nie im Code: DATAIMPULSE_USER, DATAIMPULSE_PASS (getrennt, weil der Username
# pro Lauf um eine Session ergänzt wird). Host/Port stehen hier und sind per
# Env überschreibbar. Port 824 = SOCKS5 (nötig, weil DNS über TCP durch den
# Tunnel läuft; 823 wäre HTTP). Fehlen die Secrets -> Warnung, direkte Prüfung.
DATAIMPULSE_HOST="${DATAIMPULSE_HOST:-gw.dataimpulse.com}"
DATAIMPULSE_PORT="${DATAIMPULSE_PORT:-824}"
PROXY_CONF=""
USE_PROXY=0
setup_proxy() {
  if [ -z "${DATAIMPULSE_USER:-}" ] || [ -z "${DATAIMPULSE_PASS:-}" ]; then
    echo "::warning::DATAIMPULSE_USER/PASS nicht gesetzt — Proxy-Fallback übersprungen, es bleibt bei der direkten Prüfung"
    return 1
  fi
  command -v proxychains4 >/dev/null 2>&1 || {
    echo "::warning::proxychains4 nicht installiert — Proxy-Fallback übersprungen"; return 1; }
  # Sticky-Session pro Lauf: alle Queries eines Laufs teilen sich eine Exit-IP.
  local session="${GITHUB_RUN_ID:-$(date +%s)}"
  local puser="${DATAIMPULSE_USER}__sessid.${session}"
  PROXY_CONF="$(mktemp)"
  {
    echo "strict_chain"
    echo "quiet_mode"
    echo "tcp_connect_time_out 8000"
    echo "tcp_read_time_out 8000"
    echo "[ProxyList]"
    echo "socks5 $DATAIMPULSE_HOST $DATAIMPULSE_PORT $puser $DATAIMPULSE_PASS"
  } > "$PROXY_CONF"
  return 0
}

# --- per-target probe: echoes ok|noanswer|noreply --------------------------
probe() { # $1=server ip  $2=name  (honours USE_PROXY)
  local ip="$1" name="$2" out rc got_reply=0
  for _ in 1 2; do
    if [ "$USE_PROXY" = "1" ]; then
      out="$(proxychains4 -f "$PROXY_CONF" -q dig +tcp @"$ip" "$name" A +short +time=4 +tries=1 2>/dev/null)"; rc=$?
    else
      out="$(dig @"$ip" "$name" A +short +time=2 +tries=1 2>/dev/null)"; rc=$?
    fi
    [ "$rc" -ne 9 ] && got_reply=1
    if printf '%s\n' "$out" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      echo ok; return
    fi
    sleep 0.5
  done
  [ "$got_reply" -eq 1 ] && echo noanswer || echo noreply
}

# --- run checks (parallel: one background job per server IP) ---------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Probes all TARGETS against one server and writes a single result record to
# $WORKDIR/<ip>:  "<OK|OFFLINE|BROKEN>\t<ok_count>\t<space-separated bad names>"
# Bounded: bricht früh ab, wenn der Server auf die ersten Namen gar nicht
# antwortet (offline), und hart nach SERVER_DEADLINE Sekunden.
SERVER_DEADLINE=20

check_server() {
  local ip="$1" ok=0 noreply=0 noanswer=0
  local -a bad=()
  local name start=$SECONDS
  for name in "${TARGETS[@]}"; do
    [ $((SECONDS - start)) -ge "$SERVER_DEADLINE" ] && break   # hard cap
    case "$(probe "$ip" "$name")" in
      ok)       ok=$((ok+1)) ;;
      noreply)  noreply=$((noreply+1)); bad+=("$name") ;;
      noanswer) noanswer=$((noanswer+1)); bad+=("$name") ;;
    esac
    # Early-Exit: bisher nur Nicht-Antworten -> Server ist offline, Rest sparen.
    if [ "$ok" -eq 0 ] && [ "$noanswer" -eq 0 ] && [ "$noreply" -ge 2 ]; then
      break
    fi
  done
  local status
  if   [ "$ok" -eq "$TOTAL_T" ];                 then status="OK"
  elif [ "$ok" -eq 0 ] && [ "$noanswer" -eq 0 ]; then status="OFFLINE"
  else                                                status="BROKEN"
  fi
  printf '%s\t%s\t%s\n' "$status" "$ok" "${bad[*]}" > "$WORKDIR/$ip"
}

for ip in "${SERVERS[@]}"; do
  check_server "$ip" &
done
wait   # dauert nur so lange wie der langsamste einzelne Server

# --- aggregate (in original server order for stable output) ----------------
declare -a FAIL_LINES=()   # human-readable, one per failing server
declare -a FAIL_IPS=()     # ip list for state
any_fail=0

for ip in "${SERVERS[@]}"; do
  IFS=$'\t' read -r status ok bad < "$WORKDIR/$ip"
  [ "$status" = "OK" ] && continue
  any_fail=1
  FAIL_IPS+=("$ip")
  if [ "$status" = "OFFLINE" ]; then
    FAIL_LINES+=("$ip  OFFLINE — Server antwortet nicht (dig rc 9)")
  else
    FAIL_LINES+=("$ip  AUFLÖSUNG DEFEKT — ${ok}/${TOTAL_T} ok; kein A-Record für: ${bad}")
  fi
done

# --- proxy fallback: re-check failing servers via the residential proxy ----
declare -a PROXY_RECOVERED=()
PROXY_USED=0
if [ "$any_fail" -eq 1 ] && setup_proxy; then
  PROXY_USED=1
  RETRY_IPS=("${FAIL_IPS[@]}")
  USE_PROXY=1
  for ip in "${RETRY_IPS[@]}"; do
    check_server "$ip" &            # overwrites the pass-1 record in $WORKDIR/$ip
  done
  wait
  USE_PROXY=0

  # re-aggregate only over the previously-failing servers
  declare -a NEW_FAIL_LINES=() NEW_FAIL_IPS=()
  for ip in "${RETRY_IPS[@]}"; do
    IFS=$'\t' read -r status ok bad < "$WORKDIR/$ip"
    if [ "$status" = "OK" ]; then
      PROXY_RECOVERED+=("$ip")      # blocked directly, but resolves via proxy
      continue
    fi
    NEW_FAIL_IPS+=("$ip")
    if [ "$status" = "OFFLINE" ]; then
      NEW_FAIL_LINES+=("$ip  OFFLINE — auch via Proxy keine Antwort")
    else
      NEW_FAIL_LINES+=("$ip  AUFLÖSUNG DEFEKT (auch via Proxy) — ${ok}/${TOTAL_T} ok; kein A-Record für: ${bad}")
    fi
  done
  FAIL_IPS=("${NEW_FAIL_IPS[@]}")
  FAIL_LINES=("${NEW_FAIL_LINES[@]}")
  [ "${#FAIL_IPS[@]}" -eq 0 ] && any_fail=0
fi

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

if [ "${#PROXY_RECOVERED[@]}" -gt 0 ]; then
  summary ""
  summary "_Nur über Proxy erreichbar (direkt vom Runner geblockt, nicht als FAIL gewertet):_ ${PROXY_RECOVERED[*]}"
fi
if [ "$any_fail" -eq 1 ] && [ "$PROXY_USED" -eq 0 ] && [ -z "${DATAIMPULSE_USER:-}" ]; then
  summary ""
  summary "_Hinweis: Proxy-Fallback inaktiv — Secrets \`DATAIMPULSE_USER\`/\`DATAIMPULSE_PASS\` nicht gesetzt._"
fi

# --- transition-only failure signal ---------------------------------------
# OK -> FAIL: fail the job once so GitHub sends its native failure mail.
# FAIL -> FAIL: stay green (no repeat mail). FAIL -> OK / OK -> OK: green.
if [ "$PREV_STATUS" = "OK" ] && [ "$CUR_STATUS" = "FAIL" ]; then
  echo "::error::DNS-Monitor: Zustandswechsel OK -> FAIL um $NOW"
  exit 1
fi
exit 0
