#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  apache-status.sh — Full-screen TUI Apache monitor                         ║
# ║  Usage: ./apache-status.sh [--watch] [--url URL] [--top N] [--interval S]  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# ── Config ────────────────────────────────────────────────────────────────────
URL="http://127.0.0.1/server-status"
TOP_N=10
WATCH_INTERVAL=3
WATCH_MODE=false
IGNORE_IPS=('127.0.0.1' '::1' 'localhost')
WARN_IP_CONN=20
WARN_WORKER_PCT=85
WARN_LONG_REQ_SEC=30
WARN_URL_HIT=15
WARN_SUBNET_COUNT=3      # how many IPs from same /24 triggers a subnet warning

WARN_SCAN_PATTERNS=(
  '\.\.' 'etc/passwd' 'wp-login' 'wp-admin' 'xmlrpc'
  'phpmyadmin' 'pma' '\.env' '\.git' 'eval\(' 'base64'
  'union.*select' 'select.*from' '<script' '%3cscript'
  '/shell' '/cmd' '/exec' 'nikto' 'sqlmap' 'nmap'
)
WARN_METHODS=('CONNECT' 'TRACE' 'TRACK')

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch|-w)    WATCH_MODE=true ;;
    --url|-u)      URL="$2"; shift ;;
    --top|-n)      TOP_N="$2"; shift ;;
    --interval|-i) WATCH_INTERVAL="$2"; shift ;;
    --help|-h)
      echo "Usage: $0 [--watch] [--url URL] [--top N] [--interval SEC]"
      echo ""
      echo "  --watch,    -w        Full-screen TUI mode"
      echo "  --url,      -u URL    Status URL  (default: http://127.0.0.1/server-status)"
      echo "  --top,      -n N      Show top N rows (default: 10)"
      echo "  --interval, -i SEC    Refresh interval (default: 3)"
      echo ""
      echo "  Keybinds while running:"
      echo "    q   quit"
      echo "    p   pause / resume"
      echo "    r   force refresh"
      echo "    +   increase top-N"
      echo "    -   decrease top-N"
      exit 0 ;;
    *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
  esac
  shift
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED=$(tput setaf 1); YEL=$(tput setaf 3); GRN=$(tput setaf 2)
CYN=$(tput setaf 6); MAG=$(tput setaf 5); BLD=$(tput bold)
DIM=$(tput dim);     RST=$(tput sgr0);    BLU=$(tput setaf 4)

# ── Terminal size ─────────────────────────────────────────────────────────────
COLS=80; ROWS=24
update_size() { COLS=$(tput cols); ROWS=$(tput lines); }

# ── TUI primitives ────────────────────────────────────────────────────────────
at()     { tput cup "$1" "$2"; }
hline()  { local i; for (( i=0; i<$2; i++ )); do printf '%s' "$1"; done; }

# ── Dependency check ──────────────────────────────────────────────────────────
command -v links &>/dev/null || {
  echo "ERROR: 'links' not installed. Run: sudo apt install links" >&2; exit 1
}

# ── State colorizer ───────────────────────────────────────────────────────────
colorize_state() {
  case "$1" in
    W) printf '%s' "${BLD}${GRN}W${RST}" ;;
    R) printf '%s' "${YEL}R${RST}" ;;
    K) printf '%s' "${CYN}K${RST}" ;;
    D) printf '%s' "${MAG}D${RST}" ;;
    C) printf '%s' "${RED}C${RST}" ;;
    _) printf '%s' "${DIM}_${RST}" ;;
    .) printf '%s' "${DIM}.${RST}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── Global data ───────────────────────────────────────────────────────────────
WORKERS=""
declare -gA STATE_COUNTS
W_TOTAL=0
SERVER_TS="" SERVER_UPTIME="" SERVER_REQS=""
WARNINGS=()
SUGGESTIONS=()
FETCH_ERROR=""

# ── Warning / suggestion helpers ──────────────────────────────────────────────
warn()    { WARNINGS+=("$1"); }
suggest() { SUGGESTIONS+=("$1"); }

is_ignored_ip() {
  local ip="$1" ig
  for ig in "${IGNORE_IPS[@]}"; do [[ "$ip" == "$ig" ]] && return 0; done
  return 1
}

is_noise_url() {
  [[ "$1" =~ ^"OPTIONS \* HTTP" ]] && return 0
  [[ "$1" =~ ^"GET /server-status" ]] && return 0
  [[ -z "$1" || "$1" == "-" ]] && return 0
  return 1
}

# Returns 0 if the IP resolves to Hungary — skip blocking Hungarian IPs.
# Requires geoiplookup (geoip-bin); silently passes if not installed.
is_hu_ip() {
  local ip="$1"
  command -v geoiplookup &>/dev/null || return 1
  geoiplookup "$ip" 2>/dev/null | grep -qiE 'Hungary|: HU,' && return 0
  return 1
}

# ── Warning checks ────────────────────────────────────────────────────────────
check_worker_saturation() {
  local busy total pct
  busy=$(echo  "$WORKERS" | awk '$4!="."&&$4!="_"' | wc -l)
  total=$(echo "$WORKERS" | wc -l)
  [[ $total -eq 0 ]] && return
  pct=$(( busy * 100 / total ))
  [[ $pct -ge $WARN_WORKER_PCT ]] && \
    warn "${RED}🔴 SATURATION: ${pct}% busy (${busy}/${total}) — near capacity${RST}"
}

check_ip_flood() {
  while IFS= read -r line; do
    local cnt ip
    cnt=$(awk '{print $1}' <<< "$line")
    ip=$( awk '{print $2}' <<< "$line")
    is_ignored_ip "$ip" && continue
    if   [[ $cnt -ge $WARN_IP_CONN ]]; then
      warn "${RED}🔴 IP FLOOD: ${ip} — ${cnt} simultaneous connections${RST}"
    elif [[ $cnt -ge $(( WARN_IP_CONN / 2 )) ]]; then
      warn "${YEL}🟡 HIGH CONN: ${ip} — ${cnt} connections (threshold: ${WARN_IP_CONN})${RST}"
    fi
  done < <(echo "$WORKERS" | awk '{print $12}' | grep -v '^-$' | sort | uniq -c | sort -rn)
}

check_long_requests() {
  while IFS= read -r line; do
    local pid secs client req
    pid=$(    awk '{print $1}'                                    <<< "$line")
    secs=$(   awk '{print $6}'                                    <<< "$line")
    client=$( awk '{print $12}'                                   <<< "$line")
    req=$(    awk '{for(i=15;i<=NF;i++) printf $i" "; print ""}' <<< "$line" | sed 's/ $//')
    is_ignored_ip "$client" && continue
    is_noise_url  "$req"    && continue
    [[ "$secs" =~ ^[0-9]+$ ]] && [[ $secs -ge $WARN_LONG_REQ_SEC ]] && \
      warn "${YEL}🟡 LONG REQ: PID ${pid} — ${secs}s from ${client}${RST}"
  done <<< "$WORKERS"
}

check_url_hammering() {
  while IFS= read -r line; do
    local cnt url
    cnt=$(awk '{print $1}'                       <<< "$line")
    url=$(awk '{$1=""; sub(/^ /,""); print}' <<< "$line")
    is_noise_url "$url" && continue
    [[ $cnt -ge $WARN_URL_HIT ]] && \
      warn "${YEL}🟡 HAMMERED: ${cnt}× — ${url:0:50}${RST}"
  done < <(echo "$WORKERS" \
    | awk '{for(i=15;i<=NF;i++) printf $i" "; print ""}' \
    | sed 's/ $//' | grep -v '^\s*$' | grep -v '^-$' \
    | sort | uniq -c | sort -rn)
}

check_suspicious_urls() {
  local pattern
  for pattern in "${WARN_SCAN_PATTERNS[@]}"; do
    while IFS= read -r match; do
      local client req
      client=$(awk '{print $12}'                                   <<< "$match")
      req=$(   awk '{for(i=15;i<=NF;i++) printf $i" "; print ""}' <<< "$match" | sed 's/ $//')
      is_ignored_ip "$client" && continue
      warn "${RED}🔴 ATTACK [${pattern}] from ${client} — ${req:0:40}${RST}"
    done < <(echo "$WORKERS" | grep -iE "$pattern")
  done
}

check_bad_methods() {
  local method
  for method in "${WARN_METHODS[@]}"; do
    local hits cnt client
    hits=$(echo "$WORKERS" | awk -v m="$method" '$15==m')
    [[ -z "$hits" ]] && continue
    cnt=$(    wc -l                             <<< "$hits")
    client=$( awk '{print $12}' <<< "$hits" | sort -u | tr '\n' ' ')
    warn "${RED}🔴 DANGEROUS METHOD [${method}]: ${cnt} req from ${client}${RST}"
  done
}

check_ip_url_diversity() {
  while IFS= read -r ipline; do
    local conn ip uniq
    conn=$(awk '{print $1}' <<< "$ipline")
    ip=$(  awk '{print $2}' <<< "$ipline")
    is_ignored_ip "$ip" && continue
    [[ $conn -lt 5 ]] && continue
    uniq=$(echo "$WORKERS" \
      | awk -v ip="$ip" '$12==ip {for(i=15;i<=NF;i++) printf $i" "; print ""}' \
      | sed 's/ $//' | sort -u | wc -l)
    [[ $uniq -eq 1 ]] && \
      warn "${YEL}🟡 BOT PATTERN: ${ip} — ${conn} requests all to same URL${RST}"
  done < <(echo "$WORKERS" | awk '{print $12}' | grep -v '^-$' | sort | uniq -c | sort -rn)
}

# ── Subnet detection (/24 clustering) ────────────────────────────────────────
check_subnet_clusters() {
  declare -A subnet_count subnet_ips
  while IFS= read -r ip; do
    is_ignored_ip "$ip" && continue
    # Extract /24 prefix (first 3 octets)
    local prefix
    prefix=$(echo "$ip" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
    [[ -z "$prefix" ]] && continue
    subnet_count["$prefix"]=$(( ${subnet_count["$prefix"]:-0} + 1 ))
    # Collect unique IPs per subnet
    if [[ -z "${subnet_ips[$prefix]}" ]]; then
      subnet_ips["$prefix"]="$ip"
    else
      # Only add if not already listed
      echo "${subnet_ips[$prefix]}" | grep -qF "$ip" || \
        subnet_ips["$prefix"]="${subnet_ips[$prefix]}, $ip"
    fi
  done < <(echo "$WORKERS" | awk '{print $12}' | grep -v '^-$' | sort -u)

  for prefix in "${!subnet_count[@]}"; do
    local cnt=${subnet_count[$prefix]}
    if [[ $cnt -ge $WARN_SUBNET_COUNT ]]; then
      warn "${YEL}🟡 SUBNET CLUSTER: ${cnt} different IPs from ${prefix}.0/24${RST}"
      warn "   ${DIM}IPs: ${subnet_ips[$prefix]}${RST}"
    fi
  done
}

# ── Smart suggestions engine ─────────────────────────────────────────────────
build_suggestions() {
  SUGGESTIONS=()
  local has_flood=false has_attack=false has_saturation=false
  local has_long=false has_method=false has_subnet=false has_bot=false

  # Classify what was found
  for w in "${WARNINGS[@]}"; do
    [[ "$w" =~ "IP FLOOD" ]]         && has_flood=true
    [[ "$w" =~ "ATTACK" ]]           && has_attack=true
    [[ "$w" =~ "SATURATION" ]]       && has_saturation=true
    [[ "$w" =~ "LONG REQ" ]]         && has_long=true
    [[ "$w" =~ "DANGEROUS METHOD" ]] && has_method=true
    [[ "$w" =~ "SUBNET CLUSTER" ]]   && has_subnet=true
    [[ "$w" =~ "BOT PATTERN" ]]      && has_bot=true
  done

  # ── Suggestions based on what was detected ──────────────────────────────────

  if $has_flood || $has_bot; then
    suggest "${BLD}Rate limiting${RST} — Add a CrowdSec collection for Apache:"
    suggest "  ${DIM}cscli collections install crowdsecurity/apache2${RST}"
    suggest "  ${DIM}systemctl reload crowdsec${RST}"
    suggest ""
    suggest "${BLD}Block offending IPs via CrowdSec immediately:${RST}"
    # Extract offending IPs from warnings — skip own-server and Hungarian IPs
    local _own_ip; _own_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    for w in "${WARNINGS[@]}"; do
      if [[ "$w" =~ "IP FLOOD" || "$w" =~ "BOT PATTERN" ]]; then
        local ip; ip=$(echo "$w" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        [[ -z "$ip" ]] && continue
        [[ "$ip" == "$_own_ip" ]] && { suggest "  ${DIM}# Skipped ${ip} — looks like your own server IP${RST}"; continue; }
        if is_hu_ip "$ip"; then
          suggest "  ${DIM}# Skipped ${ip} — Hungarian IP (HU), review manually${RST}"
          continue
        fi
        suggest "  ${DIM}cscli decisions add --ip ${ip} --reason 'apache-flood' --duration 24h${RST}"
      fi
    done
  fi

  if $has_subnet; then
    suggest "${BLD}Subnet-level block${RST} — Multiple IPs from same /24 detected:"
    local _own_ip; _own_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    for w in "${WARNINGS[@]}"; do
      if [[ "$w" =~ "SUBNET CLUSTER" ]]; then
        local prefix; prefix=$(echo "$w" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.0/24' | head -1)
        [[ -z "$prefix" ]] && continue
        # Check if own IP falls in this /24
        local net3; net3=$(echo "$prefix" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
        if [[ "$_own_ip" == ${net3}.* ]]; then
          suggest "  ${DIM}# Skipped ${prefix} — contains your own server IP${RST}"
          continue
        fi
        # Check first IP of this subnet for HU geo
        if is_hu_ip "${net3}.1"; then
          suggest "  ${DIM}# Skipped ${prefix} — Hungarian subnet (HU), review manually${RST}"
          continue
        fi
        suggest "  ${DIM}cscli decisions add --range ${prefix} --reason 'apache-subnet-cluster' --duration 24h${RST}"
      fi
    done
    suggest "  ${DIM}# Or use Apache: Require not ip <prefix>${RST}"
  fi

  if $has_attack; then
    suggest "${BLD}Active exploit attempts detected${RST} — Immediate actions:"
    suggest "  ${DIM}tail -f /var/log/apache2/access.log | grep -E 'wp-login|xmlrpc|\.env'${RST}"
    suggest "  ${DIM}# ModSecurity is installed — verify it is in enforcement mode:${RST}"
    suggest "  ${DIM}grep -r 'SecRuleEngine' /etc/modsecurity/ /etc/apache2/mods-enabled/security2.conf 2>/dev/null${RST}"
    suggest "  ${DIM}# Should read 'SecRuleEngine On' (not DetectionOnly)${RST}"
    suggest "  ${DIM}# Check ModSec audit log: tail -f /var/log/apache2/modsec_audit.log${RST}"
    suggest ""
    suggest "${BLD}WordPress-specific hardening:${RST}"
    suggest "  ${DIM}# Block xmlrpc.php entirely in vhost config:${RST}"
    suggest "  ${DIM}<Files xmlrpc.php>  Require all denied  </Files>${RST}"
    suggest "  ${DIM}# Limit wp-login.php to known IPs only${RST}"
  fi

  if $has_method; then
    suggest "${BLD}Disable dangerous HTTP methods${RST} — Add to apache2.conf:"
    suggest "  ${DIM}TraceEnable Off${RST}"
    suggest "  ${DIM}<LimitExcept GET POST HEAD>${RST}"
    suggest "  ${DIM}  Require all denied${RST}"
    suggest "  ${DIM}</LimitExcept>${RST}"
    suggest "  ${DIM}systemctl reload apache2${RST}"
  fi

  if $has_saturation; then
    suggest "${BLD}Worker saturation${RST} — Check and tune mpm_prefork/mpm_event:"
    suggest "  ${DIM}apache2ctl -V | grep MPM${RST}"
    suggest "  ${DIM}# Increase MaxRequestWorkers in /etc/apache2/mpm_*.conf${RST}"
    suggest "  ${DIM}# Also check for slow upstream (PHP-FPM, DB, proxy)${RST}"
    suggest "  ${DIM}mysqladmin processlist   # DB bottleneck?${RST}"
    suggest "  ${DIM}php-fpm status           # FPM queue full?${RST}"
  fi

  if $has_long; then
    suggest "${BLD}Long-running requests${RST} — Possible slow queries or upstream timeouts:"
    suggest "  ${DIM}# Set aggressive timeouts in apache2.conf:${RST}"
    suggest "  ${DIM}Timeout 60${RST}"
    suggest "  ${DIM}ProxyTimeout 60${RST}"
    suggest "  ${DIM}# Check slow query log in MySQL:${RST}"
    suggest "  ${DIM}SET GLOBAL slow_query_log = 'ON';${RST}"
    suggest "  ${DIM}SET GLOBAL long_query_time = 2;${RST}"
  fi

  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    suggest "${GRN}✔  All clear — no immediate actions needed.${RST}"
    suggest ""
    suggest "${DIM}Proactive hardening tips:${RST}"
    suggest "  ${DIM}• Verify CrowdSec is running: systemctl status crowdsec${RST}"
    suggest "  ${DIM}• Check active decisions: cscli decisions list${RST}"
    suggest "  ${DIM}• Review /var/log/apache2/error.log regularly${RST}"
    suggest "  ${DIM}• Ensure ModSecurity is set to 'SecRuleEngine On' (not DetectionOnly)${RST}"
    suggest "  ${DIM}• Use Cloudflare or similar CDN to absorb volumetric attacks${RST}"
  fi
}

# ── Run all checks ─────────────────────────────────────────────────────────────
run_checks() {
  WARNINGS=()
  check_worker_saturation
  check_ip_flood
  check_long_requests
  check_url_hammering
  check_suspicious_urls
  check_bad_methods
  check_ip_url_diversity
  check_subnet_clusters
  build_suggestions
}

# ── Data fetch & parse ────────────────────────────────────────────────────────
fetch_data() {
  local raw
  raw=$(links -dump "$URL" 2>/dev/null)
  if [[ $? -ne 0 || -z "$raw" ]]; then
    FETCH_ERROR="Cannot reach $URL"
    return 1
  fi
  FETCH_ERROR=""
  SERVER_TS=$(    date '+%Y-%m-%d %H:%M:%S')
  SERVER_UPTIME=$(echo "$raw" | grep -i 'server uptime\|uptime'        | head -1 | sed 's/^[[:space:]]*//')
  SERVER_REQS=$(  echo "$raw" | grep -i 'requests/sec\|total accesses' | head -1 | sed 's/^[[:space:]]*//')
  WORKERS=$(      echo "$raw" | grep -E '^[0-9]')

  for k in "${!STATE_COUNTS[@]}"; do unset "STATE_COUNTS[$k]"; done
  W_TOTAL=0
  while IFS= read -r line; do
    local st; st=$(awk '{print $4}' <<< "$line")
    [[ -z "$st" ]] && continue
    STATE_COUNTS["$st"]=$(( ${STATE_COUNTS["$st"]:-0} + 1 ))
    (( W_TOTAL++ ))
  done <<< "$WORKERS"

  run_checks
  return 0
}

# ── Box drawing ───────────────────────────────────────────────────────────────
BD="${BLD}${BLU}"

box_top()  { at "$1" 0; printf "${BD}╔"; hline '═' $(( COLS-2 )); printf "╗${RST}"; }
box_bot()  { at "$1" 0; printf "${BD}╚"; hline '═' $(( COLS-2 )); printf "╝${RST}"; }
box_div()  { at "$1" 0; printf "${BD}╠"; hline '═' $(( COLS-2 )); printf "╣${RST}"; }

box_div2() {  # row split_col
  at "$1" 0; printf "${BD}╠"; hline '═' $(( $2-1 )); printf '╦'
  hline '═' $(( COLS-$2-2 )); printf "╣${RST}"
}
box_mid2() {  # row split_col  (│ continuation, no ╦╩)
  at "$1" 0; printf "${BD}╠"; hline '═' $(( $2-1 )); printf '╣'
  # right side stays open — used for mid-section dividers
  printf "${RST}"
}
box_close2() {  # row split_col  ╩ close
  at "$1" 0; printf "${BD}╠"; hline '═' $(( $2-1 )); printf '╩'
  hline '═' $(( COLS-$2-2 )); printf "╣${RST}"
}
box_div3() {  # row c1 c2
  at "$1" 0; printf "${BD}╠"; hline '═' $(( $2-1 )); printf '╦'
  hline '═' $(( $3-$2-1 )); printf '╦'
  hline '═' $(( COLS-$3-2 )); printf "╣${RST}"
}
box_close3() {  # row c1 c2
  at "$1" 0; printf "${BD}╠"; hline '═' $(( $2-1 )); printf '╩'
  hline '═' $(( $3-$2-1 )); printf '╩'
  hline '═' $(( COLS-$3-2 )); printf "╣${RST}"
}

# ── TUI renderer ─────────────────────────────────────────────────────────────
tui_draw() {
  update_size
  tput clear

  local SPC=$(( COLS / 2 ))
  local C1=$(( COLS / 3 ))
  local C2=$(( COLS * 2 / 3 ))
  local row=0

  # ── Header ─────────────────────────────────────────────────────────────────
  box_top $row; (( row++ ))

  local host; host=$(hostname 2>/dev/null || echo "localhost")
  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${BLD}🖥  Apache Monitor${RST}  ${DIM}│${RST}  ${BLD}${BLU}%s${RST}  ${DIM}│${RST}  %s" "$host" "$SERVER_TS"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${DIM}%s${RST}" "${SERVER_UPTIME:-Uptime: —}  │  ${SERVER_REQS:-Requests: —}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  # ── Worker States (left) + Warnings (right) ────────────────────────────────
  box_div2 $row $SPC; (( row++ ))

  local -a LP=()
  LP+=( "${BLD}  Worker States${RST}" )
  LP+=( "  ${DIM}$(hline '─' $(( SPC-4 )))${RST}" )
  for st in W R K _ D C G L I .; do
    local cnt=${STATE_COUNTS["$st"]:-0}
    [[ $cnt -eq 0 ]] && continue
    local blen=$(( cnt > 20 ? 20 : cnt ))
    local bar; bar=$(hline '█' $blen)
    LP+=( "  $(colorize_state $st)  ${GRN}${bar}${RST}  ${BLD}${cnt}${RST}" )
  done
  LP+=( "" )
  LP+=( "  Total workers: ${BLD}${W_TOTAL}${RST}" )

  local -a RP=()
  RP+=( "${BLD}  ⚠  Warnings${RST}" )
  RP+=( "  ${DIM}$(hline '─' $(( COLS-SPC-4 )))${RST}" )
  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    RP+=( "  ${GRN}✔  No anomalies detected${RST}" )
  else
    for w in "${WARNINGS[@]}"; do RP+=( "  $w" ); done
  fi

  local ph=$(( ${#LP[@]} > ${#RP[@]} ? ${#LP[@]} : ${#RP[@]} ))
  [[ $ph -lt 5 ]] && ph=5

  for (( i=0; i<ph; i++ )); do
    at $row 0;             printf "${BD}║${RST}"
    at $row 1;             printf '%s' "${LP[$i]:-}"
    at $row $SPC;          printf "${BD}│${RST}"
    at $row $(( SPC+1 ));  printf '%s' "${RP[$i]:-}"
    at $row $(( COLS-1 )); printf "${BD}║${RST}"
    (( row++ ))
  done

  # ── Active Connections ─────────────────────────────────────────────────────
  box_close2 $row $SPC; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${BLD}Active Connections${RST}  ${DIM}(top ${TOP_N}, sorted by duration)${RST}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${DIM}%-6s %-8s %-6s %-6s %-22s %s${RST}" "PID" "State" "CPU" "Secs" "Client" "Request"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  local conn_start=$row
  mapfile -t CONN_LINES < <(echo "$WORKERS" | awk '{
    pid=$1; state=$4; cpu=$5; secs=$6; client=$12; req=""
    for(i=15;i<=NF;i++) req=req" "$i; sub(/^ /,"",req)
    if (state!="."&&state!="_"&&
        client!="::1"&&client!="127.0.0.1"&&client!="localhost"&&
        req!~/^OPTIONS \* HTTP/&&req!~/^GET \/server-status/)
      printf "  %-6s %-8s %-6s %-6s %-22s %s\n", pid, state, cpu, secs, client, req
  }' | sort -t' ' -k5 -rn | head -"$TOP_N")

  local conn_disp=6
  for (( i=0; i<conn_disp; i++ )); do
    at $row 0;             printf "${BD}║${RST}"
    at $row 1;             printf '%s' "${CONN_LINES[$i]:0:$(( COLS-3 ))}"
    at $row $(( COLS-1 )); printf "${BD}║${RST}"
    (( row++ ))
  done

  # ── Stats: Top URLs / IPs / VHosts ────────────────────────────────────────
  box_div3 $row $C1 $C2; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${BLD}Top URLs${RST}"
  at $row $C1;           printf "${BD}│${RST}"
  at $row $(( C1+2 ));   printf "${BLD}Top Client IPs${RST}"
  at $row $C2;           printf "${BD}│${RST}"
  at $row $(( C2+2 ));   printf "${BLD}Top Virtual Hosts${RST}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 1;             printf "${DIM}"; hline '─' $(( C1-2  )); printf "${RST}"
  at $row $C1;           printf "${BD}│${RST}"
  at $row $(( C1+1 ));   printf "${DIM}"; hline '─' $(( C2-C1-2 )); printf "${RST}"
  at $row $C2;           printf "${BD}│${RST}"
  at $row $(( C2+1 ));   printf "${DIM}"; hline '─' $(( COLS-C2-3 )); printf "${RST}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  local stats_h=5
  local w1=$(( C1-3 )) w2=$(( C2-C1-3 )) w3=$(( COLS-C2-4 ))

  mapfile -t URL_LINES < <(echo "$WORKERS" \
    | awk '{for(i=15;i<=NF;i++) printf $i" "; print ""}' \
    | sed 's/ $//' \
    | grep -vE '^OPTIONS \* HTTP|^GET /server-status|-$|^\s*$' \
    | sort | uniq -c | sort -rn | head -$stats_h \
    | awk '{cnt=$1;$1="";sub(/^ /,"");printf "%4d  %s\n",cnt,$0}')

  mapfile -t IP_LINES < <(echo "$WORKERS" \
    | awk '{print $12}' \
    | grep -vE '^(-|::1|127\.0\.0\.1|localhost)$' \
    | sort | uniq -c | sort -rn | head -$stats_h \
    | awk '{printf "%4d  %s\n",$1,$2}')

  mapfile -t VH_LINES < <(echo "$WORKERS" \
    | awk '{print $14}' \
    | grep -vE '^(-|::1|127\.0\.0\.1|localhost|https?/.*)$' \
    | sort | uniq -c | sort -rn | head -$stats_h \
    | awk '{printf "%4d  %s\n",$1,$2}')

  for (( i=0; i<stats_h; i++ )); do
    at $row 0;             printf "${BD}║${RST}"
    at $row 2;             printf '%s' "${URL_LINES[$i]:0:$w1}"
    at $row $C1;           printf "${BD}│${RST}"
    at $row $(( C1+2 ));   printf '%s' "${IP_LINES[$i]:0:$w2}"
    at $row $C2;           printf "${BD}│${RST}"
    at $row $(( C2+2 ));   printf '%s' "${VH_LINES[$i]:0:$w3}"
    at $row $(( COLS-1 )); printf "${BD}║${RST}"
    (( row++ ))
  done

  # ── Suggestions ────────────────────────────────────────────────────────────
  box_close3 $row $C1 $C2; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 2;             printf "${BLD}💡 Suggested Next Steps${RST}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  at $row 0;             printf "${BD}║${RST}"
  at $row 1;             printf "${DIM}"; hline '─' $(( COLS-3 )); printf "${RST}"
  at $row $(( COLS-1 )); printf "${BD}║${RST}"; (( row++ ))

  local sug_disp=6
  for (( i=0; i<sug_disp; i++ )); do
    at $row 0;             printf "${BD}║${RST}"
    at $row 2;             printf '%s' "${SUGGESTIONS[$i]:0:$(( COLS-4 ))}"
    at $row $(( COLS-1 )); printf "${BD}║${RST}"
    (( row++ ))
  done

  # ── Bottom border + status bar ─────────────────────────────────────────────
  box_bot $row; (( row++ ))

  at $row 0
  if $PAUSED; then
    printf " ${BLD}${YEL}⏸  PAUSED${RST}   "
  else
    printf " ${BLD}${GRN}▶  LIVE${RST}  ${DIM}every ${WATCH_INTERVAL}s${RST}   "
  fi
  printf "${DIM}[q]${RST}quit  ${DIM}[p]${RST}pause  ${DIM}[r]${RST}refresh  ${DIM}[+]/[-]${RST}top-N=${BLD}${TOP_N}${RST}"
  if [[ -n "$FETCH_ERROR" ]]; then
    printf "   ${RED}⚠  %s${RST}" "$FETCH_ERROR"
  fi
}

# ── Simple (non-watch) render ─────────────────────────────────────────────────
simple_render() {
  local dhr; dhr=$(hline '─' 72)

  echo
  printf '%s%s Apache Server Status%s  —  %s\n' "$BLD" "$BLU" "$RST" "$SERVER_TS"
  [[ -n "$SERVER_UPTIME" ]] && echo "  $SERVER_UPTIME"
  [[ -n "$SERVER_REQS"   ]] && echo "  $SERVER_REQS"

  echo; printf '%s▶ Worker States%s\n' "$BLD$CYN" "$RST"; echo "$dhr"
  for st in W R K _ D C G L I .; do
    local cnt=${STATE_COUNTS["$st"]:-0}
    [[ $cnt -eq 0 ]] && continue
    local bar; bar=$(hline '█' $(( cnt > 30 ? 30 : cnt )))
    printf '  %-4s %-6s %s\n' "$(colorize_state "$st")" "$cnt" "${GRN}${bar}${RST}"
  done
  printf '  Total: %s%d%s\n' "$BLD" "$W_TOTAL" "$RST"

  echo; printf '%s▶ Active Connections (top %d)%s\n' "$BLD$CYN" "$TOP_N" "$RST"; echo "$dhr"
  printf '  %s%-6s %-8s %-6s %-6s %-22s %s%s\n' "$BLD" "PID" "State" "CPU" "Secs" "Client" "Request" "$RST"
  echo "$WORKERS" | awk '{
    pid=$1; state=$4; cpu=$5; secs=$6; client=$12; req=""
    for(i=15;i<=NF;i++) req=req" "$i; sub(/^ /,"",req)
    if (state!="."&&state!="_"&&
        client!="::1"&&client!="127.0.0.1"&&
        req!~/^OPTIONS \* HTTP/&&req!~/^GET \/server-status/)
      printf "  %-6s %-8s %-6s %-6s %-22s %s\n", pid, state, cpu, secs, client, req
  }' | sort -t' ' -k5 -rn | head -"$TOP_N"

  echo; printf '%s▶ Top %d Requested URLs%s\n' "$BLD$CYN" "$TOP_N" "$RST"; echo "$dhr"
  echo "$WORKERS" \
    | awk '{for(i=15;i<=NF;i++) printf $i" "; print ""}' \
    | sed 's/ $//' \
    | grep -vE '^OPTIONS \* HTTP|^GET /server-status|-$|^\s*$' \
    | sort | uniq -c | sort -rn | head -"$TOP_N" \
    | awk -v BLD="$BLD" -v RST="$RST" '{cnt=$1;$1="";sub(/^ /,"");printf "  %s%5d%s  %s\n",BLD,cnt,RST,$0}'

  echo; printf '%s▶ Top %d Client IPs%s\n' "$BLD$CYN" "$TOP_N" "$RST"; echo "$dhr"
  echo "$WORKERS" | awk '{print $12}' \
    | grep -vE '^(-|::1|127\.0\.0\.1|localhost)$' \
    | sort | uniq -c | sort -rn | head -"$TOP_N" \
    | awk -v BLD="$BLD" -v RST="$RST" -v YEL="$YEL" '{printf "  %s%5d%s  %s%s%s\n",BLD,$1,RST,YEL,$2,RST}'

  echo; printf '%s▶ Top %d Virtual Hosts%s\n' "$BLD$CYN" "$TOP_N" "$RST"; echo "$dhr"
  echo "$WORKERS" | awk '{print $14}' \
    | grep -vE '^(-|::1|127\.0\.0\.1|localhost|https?/.*)$' \
    | sort | uniq -c | sort -rn | head -"$TOP_N" \
    | awk -v BLD="$BLD" -v RST="$RST" -v MAG="$MAG" '{printf "  %s%5d%s  %s%s%s\n",BLD,$1,RST,MAG,$2,RST}'

  echo; printf '%s▶ ⚠  Warnings%s\n' "$BLD$CYN" "$RST"; echo "$dhr"
  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    echo "  ${GRN}✔  No anomalies detected.${RST}"
  else
    for w in "${WARNINGS[@]}"; do echo "  $w"; done
    echo; printf '  %s%d warning(s) total%s\n' "$BLD" "${#WARNINGS[@]}" "$RST"
  fi

  echo; printf '%s▶ 💡 Suggested Next Steps%s\n' "$BLD$CYN" "$RST"; echo "$dhr"
  for s in "${SUGGESTIONS[@]}"; do echo "  $s"; done
  echo "$dhr"
}

# ── Entry point ───────────────────────────────────────────────────────────────
if $WATCH_MODE; then

  tput smcup
  tput civis

  cleanup() {
    tput cnorm
    tput rmcup
    echo
    exit 0
  }
  trap cleanup INT TERM EXIT HUP
  trap 'update_size; tui_draw' WINCH

  PAUSED=false
  old_stty=$(stty -g)
  stty -echo -icanon min 0 time 0

  fetch_data
  tui_draw

  while true; do
    elapsed=0
    while [[ $elapsed -lt $WATCH_INTERVAL ]]; do
      key=$(dd bs=1 count=1 2>/dev/null)
      case "$key" in
        q|Q) stty "$old_stty"; cleanup ;;
        p|P)
          if $PAUSED; then
            PAUSED=false
            fetch_data; tui_draw
          else
            PAUSED=true
            update_size
            at $(( ROWS-1 )) 0
            printf " ${BLD}${YEL}⏸  PAUSED${RST}  $(hline ' ' 30)[p] resume  [q] quit$(hline ' ' 10)"
          fi
          ;;
        r|R) fetch_data; tui_draw; elapsed=0; continue ;;
        +)   (( TOP_N++ ));                    fetch_data; tui_draw; elapsed=0; continue ;;
        -)   [[ $TOP_N -gt 1 ]] && (( TOP_N-- )); fetch_data; tui_draw; elapsed=0; continue ;;
      esac
      $PAUSED || (( elapsed++ ))
      sleep 1
    done
    $PAUSED || { fetch_data; tui_draw; }
  done

else
  fetch_data || { echo "ERROR: $FETCH_ERROR" >&2; exit 1; }
  simple_render
fi
