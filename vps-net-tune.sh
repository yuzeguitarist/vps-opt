#!/usr/bin/env bash
# vps-net-tune.sh
# Network diagnostics + safe tuning with audit logs, idempotency, and rollback.
#
# Target: Ubuntu 18.04/20.04/22.04/24.04 (systemd), run as root.
#
# Safety principles:
# - Default: no changes until user chooses apply mode.
# - Any file modification is backed up first.
# - All changes are reversible with an auto-generated rollback script.
# - Avoid dangerous NIC params (MTU, ethtool offload toggles) by default; only diagnose.

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------
# Constants / Paths
# ----------------------------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

RUN_UTC="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_LOCAL="$(date +"%Y-%m-%d %H:%M:%S")"

LOG_ROOT="/var/log/vps-net-tune"
BACKUP_ROOT="/var/backups/vps-net-tune"

RUN_DIR="$BACKUP_ROOT/$RUN_UTC"
LOG_FILE="$LOG_ROOT/vps-net-tune-$RUN_UTC.log"

REPORT_FILE="$RUN_DIR/diagnostic-report-$RUN_UTC.txt"
PLAN_FILE="$RUN_DIR/change-plan-$RUN_UTC.txt"
APPLY_SUMMARY_FILE="$RUN_DIR/apply-summary-$RUN_UTC.txt"

ROLLBACK_SCRIPT="$RUN_DIR/rollback-$RUN_UTC.sh"

SYSCTL_CONF="/etc/sysctl.d/99-vps-net-tune.conf"
MODULES_CONF="/etc/modules-load.d/vps-net-tune.conf"

SYSCTL_CONF_BAK="$RUN_DIR/99-vps-net-tune.conf.bak"
MODULES_CONF_BAK="$RUN_DIR/vps-net-tune.conf.modules-load.bak"

RPSXPS_UNIT_NAME="vps-net-tune-rpsxps.service"
RPSXPS_UNIT_PATH="/etc/systemd/system/$RPSXPS_UNIT_NAME"
RPSXPS_SCRIPT="/usr/local/sbin/vps-net-tune-rpsxps-apply.sh"

RPSXPS_UNIT_BAK="$RUN_DIR/$RPSXPS_UNIT_NAME.bak"
RPSXPS_SCRIPT_BAK="$RUN_DIR/vps-net-tune-rpsxps-apply.sh.bak"
SYSTEMD_STATE="$RUN_DIR/systemd-state-$RUN_UTC.tsv"

SYSCTL_BEFORE="$RUN_DIR/sysctl-before-$RUN_UTC.tsv"
SYSFS_BEFORE="$RUN_DIR/sysfs-before-$RUN_UTC.tsv"
FILE_BEFORE_META="$RUN_DIR/file-before-meta-$RUN_UTC.tsv"  # label \t existed(0/1) \t path \t bak

# ----------------------------
# Globals collected at runtime
# ----------------------------
NODE_PROTO=""        # tcp|udp|both
VPN_NAME=""          # user-facing label from VPN/代理 menu
APPLY_MODE=""        # dry-run|confirm|apply|exit

OS_PRETTY="unknown"
KERNEL_REL="unknown"
VIRT_TYPE="unknown"

DEFAULT_IFACE="unknown"
IFACE_MTU="unknown"
IFACE_SPEED="unknown"
IFACE_DRIVER="unknown"
IFACE_BUSINFO="unknown"
IFACE_QUEUES_RX="unknown"
IFACE_QUEUES_TX="unknown"
IFACE_QUEUES_COMBINED="unknown"

TCP_CC_CUR="unknown"
TCP_CC_AVAIL="unknown"
QDISC_CUR="unknown"
QDISC_DEFAULT="unknown"
QDISC_FQ_SUPPORTED="unknown"

PMTU_TARGET="unknown"
PMTU_EST="unknown"
PMTU_RISK_NOTE="unknown"
PMTU_METHOD="unknown"

PMTU6_TARGET="unknown"
PMTU6_EST="unknown"
PMTU6_RISK_NOTE="unknown"
PMTU6_METHOD="unknown"

# Buffers
SYS_RMEM_MAX="unknown"
SYS_WMEM_MAX="unknown"
SYS_RMEM_DEF="unknown"
SYS_WMEM_DEF="unknown"
SYS_TCP_RMEM="unknown"
SYS_TCP_WMEM="unknown"
SYS_NETDEV_BACKLOG="unknown"
SYS_SOMAXCONN="unknown"
SYS_TCP_MAX_SYN_BACKLOG="unknown"
SYS_TCP_MTU_PROBING="unknown"
SYS_RPS_SOCK_FLOW_ENTRIES="unknown"
SYS_UDP_RMEM_MIN="unknown"

# Offloads
OFF_TSO="unknown"
OFF_GSO="unknown"
OFF_GRO="unknown"
OFF_LRO="unknown"

CPU_COUNT=1
MEM_TOTAL_MB=0

# Driver-specific notes
declare -a DRIVER_NOTES=()

# Sysfs persistence
PERSIST_SYSFS="no"
declare -a PERSIST_SYSFS_PATH=()
declare -a PERSIST_SYSFS_VAL=()

# Change plan arrays
declare -a PLAN_TYPE=()     # sysctl|sysfs|modules
declare -a PLAN_ID=()
declare -a PLAN_DESC=()
declare -a PLAN_RISK=()     # LOW|MED|HIGH
declare -a PLAN_KEY=()      # sysctl key OR sysfs path OR module name
declare -a PLAN_TARGET=()   # desired value OR empty for modules

# Selected flags during apply
declare -a PLAN_SELECTED=() # 0/1
declare -a PLAN_STATUS=()   # SKIP/OK/FAIL/NO

# ----------------------------
# Utility: logging
# ----------------------------
_ts() { date +"%Y-%m-%d %H:%M:%S"; }

_log() {
  local ts msg
  ts="$(_ts)"
  msg="[$ts] $*"
  printf "%s\n" "$msg"
  printf "%s\n" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
_warn() {
  local ts msg
  ts="$(_ts)"
  msg="[$ts] [WARN] $*"
  printf "%s\n" "$msg" >&2
  printf "%s\n" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
_err() {
  local ts msg
  ts="$(_ts)"
  msg="[$ts] [ERR ] $*"
  printf "%s\n" "$msg" >&2
  printf "%s\n" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

_die() {
  _err "$*"
  _err "Run log: $LOG_FILE"
  if [[ -f "$ROLLBACK_SCRIPT" ]]; then
    _err "If changes were applied, rollback script: $ROLLBACK_SCRIPT"
  fi
  exit 1
}

# ----------------------------
# Error trap (don't claim rollback always needed)
# ----------------------------
_on_err() {
  local code=$?
  _err "Unexpected failure (exit=$code) at: ${BASH_COMMAND}"
  _err "Log: $LOG_FILE"
  if [[ -f "$ROLLBACK_SCRIPT" ]]; then
    _err "Rollback (if you chose apply/confirm and changes happened): $ROLLBACK_SCRIPT"
  fi
  exit "$code"
}
trap _on_err ERR

# ----------------------------
# Small helpers
# ----------------------------
_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

_has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Read first line of a command output safely
_cmd1() { "$@" 2>/dev/null | head -n1 || true; }

# Read full output safely
_cmd() { "$@" 2>/dev/null || true; }

# Trim spaces
_trim() { awk '{$1=$1; print}' <<<"${1:-}"; }

_ping_cmd_help() {
  local cmd="$1"
  local out
  out="$("$cmd" -h 2>&1 || true)"
  if [[ -z "$out" ]]; then
    out="$("$cmd" --help 2>&1 || true)"
  fi
  printf "%s" "$out"
}

_ping_cmd_supports_opt() {
  local cmd="$1"
  local opt="$2"
  local help
  help="$(_ping_cmd_help "$cmd")"
  [[ -n "$help" ]] || return 1
  grep -qE "(^|[[:space:]])${opt}([[:space:],]|$)" <<<"$help"
}

_ping_supports_opt() { _ping_cmd_supports_opt ping "$1"; }

_tracepath_cmd_help() {
  local cmd="$1"
  local out
  out="$("$cmd" -h 2>&1 || true)"
  if [[ -z "$out" ]]; then
    out="$("$cmd" --help 2>&1 || true)"
  fi
  printf "%s" "$out"
}

_tracepath_cmd_supports_opt() {
  local cmd="$1"
  local opt="$2"
  local help
  help="$(_tracepath_cmd_help "$cmd")"
  [[ -n "$help" ]] || return 1
  grep -qE "(^|[[:space:]])${opt}([[:space:],]|$)" <<<"$help"
}

_tracepath_pmtu() {
  local cmd="$1"; shift
  local out
  out="$("$cmd" "$@" 2>/dev/null || true)"
  local pmtu
  pmtu="$(grep -oE 'pmtu[[:space:]]+[0-9]+' <<<"$out" | head -n1 | awk '{print $2}' || true)"
  printf "%s" "$pmtu"
}

# ----------------------------
# Interactive menu (up/down/enter)
# ----------------------------
_is_tty() { [[ -t 0 && -t 1 ]]; }

_menu_select() {
  # Usage: _menu_select "prompt" "opt1" "opt2" ...
  # Returns: selected index in $MENU_RET
  # TTY: redraw with CUU(N)+EL per line (avoids tput sc/rc issues on SSH/IDE terminals).
  local prompt="$1"; shift
  local -a options=("$@")
  local selected=0
  local key="" k2=""

  if ! _is_tty; then
    printf "%s\n" "$prompt"
    local i=0
    for i in "${!options[@]}"; do
      printf "  [%d] %s\n" "$i" "${options[$i]}"
    done
    printf "Choose index: "
    read -r selected
    if [[ ! "$selected" =~ ^[0-9]+$ ]] || (( selected < 0 || selected >= ${#options[@]} )); then
      selected=0
    fi
    MENU_RET="$selected"
    return 0
  fi

  local n="${#options[@]}"
  if (( n == 0 )); then
    MENU_RET=0
    return 0
  fi

  printf "%s\n" "$prompt"
  local first=1
  while true; do
    if (( first == 0 )); then
      printf '\033[%dA' "$n"
    fi
    first=0
    local i
    for i in "${!options[@]}"; do
      printf '\033[2K\r'
      if (( i == selected )); then
        printf "→ %s\n" "${options[$i]}"
      else
        printf "  %s\n" "${options[$i]}"
      fi
    done

    IFS= read -rsn1 key || true
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 k2 || true
      key+="$k2"
      case "$key" in
        $'\x1b[A') selected=$((selected - 1)) ;; # up
        $'\x1b[B') selected=$((selected + 1)) ;; # down
      esac
      if (( selected < 0 )); then selected=$((${#options[@]} - 1)); fi
      if (( selected >= ${#options[@]} )); then selected=0; fi
    elif [[ "$key" == "" || "$key" == $'\n' || "$key" == $'\r' ]]; then
      MENU_RET="$selected"
      printf "\n"
      return 0
    fi
  done
}

_prompt_yn() {
  # Usage: _prompt_yn "Question" "default" (default: y|n)
  local q="$1"
  local def="${2:-n}"
  local ans=""
  local hint="[y/N]"
  [[ "$def" == "y" ]] && hint="[Y/n]"

  while true; do
    printf "%s %s " "$q" "$hint"
    read -r ans || true
    ans="$(_trim "$ans")"
    if [[ -z "$ans" ]]; then
      ans="$def"
    fi
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) printf "Please answer y or n.\n" ;;
    esac
  done
}

# ----------------------------
# Sysctl helpers (safe + idempotent)
# ----------------------------
_sysctl_exists() {
  local key="$1"
  sysctl -n "$key" >/dev/null 2>&1
}

_sysctl_get() {
  local key="$1"
  sysctl -n "$key" 2>/dev/null || true
}

_sysctl_set_runtime() {
  local key="$1"
  local val="$2"
  # Return 0 if applied or already set, 1 if failed
  if ! _sysctl_exists "$key"; then
    _warn "sysctl key not found: $key (skip)"
    return 1
  fi
  local cur
  cur="$(_sysctl_get "$key")"
  if [[ "$cur" == "$val" ]]; then
    _log "sysctl runtime already: $key = $val (skip)"
    return 0
  fi
  if sysctl -w "$key=$val" >/dev/null 2>&1; then
    _log "sysctl runtime set: $key = $val (was: $cur)"
    return 0
  fi
  _warn "failed to set sysctl runtime: $key = $val"
  return 1
}

_backup_file_once() {
  # label, path, bakpath
  local label="$1"
  local path="$2"
  local bak="$3"

  # Avoid double-backup
  if grep -qE "^${label}\t" "$FILE_BEFORE_META" 2>/dev/null; then
    return 0
  fi

  local existed=0
  if [[ -e "$path" ]]; then
    existed=1
    cp -a "$path" "$bak"
  else
    existed=0
    : >"$bak"
  fi
  printf "%s\t%d\t%s\t%s\n" "$label" "$existed" "$path" "$bak" >>"$FILE_BEFORE_META"
  _log "backup: $path -> $bak (existed=$existed, label=$label)"
}

_sysctl_conf_ensure_header() {
  # Ensure SYSCTL_CONF exists and has header
  if [[ ! -f "$SYSCTL_CONF" ]]; then
    cat >"$SYSCTL_CONF" <<'EOF'
# Managed by vps-net-tune.sh
# Safe, idempotent sysctl overrides for VPS networking.
# You can rollback using the generated rollback script for each run.
EOF
  else
    # If file exists but no header, we won't rewrite; just append keys safely.
    true
  fi
}

_sysctl_conf_upsert() {
  # Insert or update "key = value" in SYSCTL_CONF idempotently.
  # Backup is assumed to have been done already.
  local key="$1"
  local val="$2"

  _sysctl_conf_ensure_header

  # If key not exists on this kernel, don't persist it.
  if ! _sysctl_exists "$key"; then
    _warn "sysctl key not found (won't persist): $key"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"
  local found=0

  awk -v k="$key" -v v="$val" '
    BEGIN {
      found=0
      ek=k
      gsub(/[][\\.^$*+?()|{}]/, "\\\\&", ek)
    }
    {
      line=$0
      if (line ~ /^[[:space:]]*#/) { print line; next }
      # Match lines like "net.ipv4.xxx = yyy" or "net.ipv4.xxx=yyy"
      if (match(line, "^[[:space:]]*" ek "[[:space:]]*=")) {
        print k " = " v
        found=1
      } else {
        print line
      }
    }
    END {
      if (found==0) {
        print k " = " v
      }
    }
  ' "$SYSCTL_CONF" >"$tmp"

  # Only replace if changed (auditable + reduces writes)
  if cmp -s "$SYSCTL_CONF" "$tmp"; then
    rm -f "$tmp"
    _log "sysctl conf already contains: $key = $val (skip)"
    return 0
  fi

  # Atomic replace
  chmod --reference="$SYSCTL_CONF" "$tmp" 2>/dev/null || true
  chown --reference="$SYSCTL_CONF" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SYSCTL_CONF"
  _log "sysctl conf upsert: $key = $val -> $SYSCTL_CONF"
  return 0
}

# ----------------------------
# modules-load.d helper
# ----------------------------
_modules_conf_ensure_header() {
  if [[ ! -f "$MODULES_CONF" ]]; then
    cat >"$MODULES_CONF" <<'EOF'
# Managed by vps-net-tune.sh
# Kernel modules to load at boot (for BBR / fq where applicable).
EOF
  fi
}

_modules_conf_add() {
  local mod="$1"
  _modules_conf_ensure_header

  if grep -qE "^[[:space:]]*${mod}([[:space:]]*(#.*)?)?$" "$MODULES_CONF" 2>/dev/null; then
    _log "modules-load already contains: $mod (skip)"
    return 0
  fi
  printf "%s\n" "$mod" >>"$MODULES_CONF"
  _log "modules-load add: $mod -> $MODULES_CONF"
  return 0
}

# ----------------------------
# Sysfs helpers for RPS/XPS
# ----------------------------
_sysfs_get() {
  local path="$1"
  if [[ -r "$path" ]]; then
    cat "$path" 2>/dev/null || true
  else
    echo ""
  fi
}

_sysfs_set() {
  local path="$1"
  local val="$2"
  if [[ ! -e "$path" ]]; then
    _warn "sysfs path not found: $path"
    return 1
  fi
  if [[ ! -w "$path" ]]; then
    _warn "sysfs path not writable: $path"
    return 1
  fi
  local cur
  cur="$(_sysfs_get "$path")"
  if [[ "$cur" == "$val" ]]; then
    _log "sysfs already: $path = $val (skip)"
    return 0
  fi
  printf "%s" "$val" >"$path" 2>/dev/null || { _warn "failed to write sysfs: $path"; return 1; }
  _log "sysfs set: $path = $val (was: $cur)"
  return 0
}

_cpumask_all() {
  # Build cpumask string with all CPUs [0..n-1] set.
  # Format: comma-separated 32-bit hex groups, most significant first.
  local n="$1"
  if (( n <= 0 )); then echo "0"; return 0; fi

  local -a groups=()
  local remaining="$n"
  while (( remaining > 0 )); do
    local bits=$(( remaining > 32 ? 32 : remaining ))
    local val=""
    if (( bits == 32 )); then
      val="ffffffff"
    else
      # bits 1..31
      val=$(printf "%x" $(( (1 << bits) - 1 )) )
    fi
    # prepend group (most significant first)
    groups=("$val" "${groups[@]}")
    remaining=$(( remaining - bits ))
  done

  local out=""
  local IFS=,
  out="${groups[*]}"
  echo "$out"
}

_is_rps_xps_path() {
  case "$1" in
    */rps_cpus|*/rps_flow_cnt|*/xps_cpus) return 0 ;;
    *) return 1 ;;
  esac
}

_record_systemd_state() {
  : >"$SYSTEMD_STATE"
  local state="not-found"
  local unit_state=""
  local fragment=""
  local source=""
  local active=""
  local sub=""
  if _has_cmd systemctl; then
    state="$(systemctl is-enabled "$RPSXPS_UNIT_NAME" 2>/dev/null || echo "not-found")"
    local show_out
    show_out="$(systemctl show "$RPSXPS_UNIT_NAME" \
      -p UnitFileState -p FragmentPath -p SourcePath -p ActiveState -p SubState 2>/dev/null || true)"
    unit_state="$(awk -F= '/^UnitFileState=/{print $2}' <<<"$show_out" || true)"
    fragment="$(awk -F= '/^FragmentPath=/{print $2}' <<<"$show_out" || true)"
    source="$(awk -F= '/^SourcePath=/{print $2}' <<<"$show_out" || true)"
    active="$(awk -F= '/^ActiveState=/{print $2}' <<<"$show_out" || true)"
    sub="$(awk -F= '/^SubState=/{print $2}' <<<"$show_out" || true)"
    if [[ -n "$unit_state" ]]; then
      state="$unit_state"
    fi
  fi
  local existed=0
  [[ -e "$RPSXPS_UNIT_PATH" ]] && existed=1
  printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\n" \
    "$RPSXPS_UNIT_NAME" "$state" "$existed" "$fragment" "$source" "$active" "$sub" >>"$SYSTEMD_STATE"
  _log "Recorded systemd state: $SYSTEMD_STATE"
}

_persist_sysfs_to_systemd() {
  if [[ "$PERSIST_SYSFS" != "yes" ]]; then
    return 0
  fi
  if (( ${#PERSIST_SYSFS_PATH[@]} == 0 )); then
    _log "No sysfs items to persist via systemd."
    return 0
  fi
  if ! _has_cmd systemctl; then
    _warn "systemctl not found; cannot persist RPS/XPS settings."
    return 1
  fi

  _backup_file_once "rpsxps_unit" "$RPSXPS_UNIT_PATH" "$RPSXPS_UNIT_BAK"
  _backup_file_once "rpsxps_script" "$RPSXPS_SCRIPT" "$RPSXPS_SCRIPT_BAK"

  {
    printf "#!/usr/bin/env bash\n"
    printf "# Generated by vps-net-tune.sh at %s\n" "$RUN_UTC"
    printf "apply_one() {\n"
    printf "  local path=\"\\$1\"\n"
    printf "  local val=\"\\$2\"\n"
    printf "  if [[ -w \"\\$path\" ]]; then\n"
    printf "    printf \"%%s\" \"\\$val\" >\"\\$path\" 2>/dev/null || true\n"
    printf "  fi\n"
    printf "}\n"
    local i
    for i in "${!PERSIST_SYSFS_PATH[@]}"; do
      printf "apply_one \"%s\" \"%s\"\n" "${PERSIST_SYSFS_PATH[$i]}" "${PERSIST_SYSFS_VAL[$i]}"
    done
  } >"$RPSXPS_SCRIPT"
  chmod 755 "$RPSXPS_SCRIPT" 2>/dev/null || true

  cat >"$RPSXPS_UNIT_PATH" <<EOF
[Unit]
Description=Apply RPS/XPS settings generated by vps-net-tune.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RPSXPS_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  if systemctl enable --now "$RPSXPS_UNIT_NAME" >/dev/null 2>&1; then
    _log "RPS/XPS persistence enabled: $RPSXPS_UNIT_NAME"
  else
    _warn "failed to enable systemd unit: $RPSXPS_UNIT_NAME"
    return 1
  fi
  return 0
}

# ----------------------------
# Diagnostics collectors
# ----------------------------
_detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$NAME $VERSION}"
  fi
  KERNEL_REL="$(uname -r 2>/dev/null || echo "unknown")"

  if _has_cmd systemd-detect-virt; then
    VIRT_TYPE="$(_cmd1 systemd-detect-virt || true)"
    VIRT_TYPE="${VIRT_TYPE:-none}"
  else
    VIRT_TYPE="unknown"
  fi

  CPU_COUNT="$(nproc 2>/dev/null || echo 1)"
  if [[ -r /proc/meminfo ]]; then
    local kb
    kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    MEM_TOTAL_MB=$(( kb / 1024 ))
  fi
}

_detect_default_iface() {
  local iface=""
  if _has_cmd ip; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    if [[ -z "$iface" ]]; then
      iface="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    fi
    if [[ -z "$iface" ]]; then
      iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
    fi
  else
    _warn "ip command not found; falling back to /sys/class/net for default iface detection."
  fi
  if [[ -z "$iface" && -d /sys/class/net ]]; then
    local cand=""
    local fallback=""
    for cand in /sys/class/net/*; do
      cand="${cand##*/}"
      [[ "$cand" == "lo" ]] && continue
      [[ -z "$fallback" ]] && fallback="$cand"
      if [[ -r "/sys/class/net/$cand/operstate" ]]; then
        local st
        st="$(cat "/sys/class/net/$cand/operstate" 2>/dev/null || true)"
        if [[ "$st" == "up" ]]; then
          iface="$cand"
          break
        fi
      fi
    done
    if [[ -z "$iface" ]]; then
      iface="$fallback"
    fi
  fi
  if [[ -z "$iface" ]]; then
    _warn "Default iface detection failed; using 'unknown'."
  fi
  DEFAULT_IFACE="${iface:-unknown}"
}

_get_iface_mtu() {
  local iface="$1"
  IFACE_MTU="$(ip link show dev "$iface" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}' || true)"
  IFACE_MTU="${IFACE_MTU:-unknown}"
}

_get_iface_speed_driver_queues() {
  local iface="$1"

  IFACE_SPEED="unknown"
  IFACE_DRIVER="unknown"
  IFACE_BUSINFO="unknown"
  IFACE_QUEUES_RX="unknown"
  IFACE_QUEUES_TX="unknown"
  IFACE_QUEUES_COMBINED="unknown"

  # Speed
  if _has_cmd ethtool; then
    local s
    s="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/{print $2; exit}' || true)"
    IFACE_SPEED="${s:-unknown}"
  fi
  if [[ "$IFACE_SPEED" == "unknown" && -r "/sys/class/net/$iface/speed" ]]; then
    local sp
    sp="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
    if [[ -n "$sp" && "$sp" != "-1" ]]; then
      IFACE_SPEED="${sp}Mb/s"
    fi
  fi

  # Driver
  if _has_cmd ethtool; then
    IFACE_DRIVER="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/driver:/{print $2; exit}' || true)"
    IFACE_BUSINFO="$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/bus-info:/{print $2; exit}' || true)"
    IFACE_DRIVER="${IFACE_DRIVER:-unknown}"
    IFACE_BUSINFO="${IFACE_BUSINFO:-unknown}"
  fi

  # Queues from sysfs count
  if [[ -d "/sys/class/net/$iface/queues" ]]; then
    local rx tx
    rx="$(ls -1 "/sys/class/net/$iface/queues" 2>/dev/null | grep -cE '^rx-' || true)"
    tx="$(ls -1 "/sys/class/net/$iface/queues" 2>/dev/null | grep -cE '^tx-' || true)"
    IFACE_QUEUES_RX="${rx:-unknown}"
    IFACE_QUEUES_TX="${tx:-unknown}"
  fi

  # Combined channels (ethtool -l)
  if _has_cmd ethtool; then
    local comb
    comb="$(ethtool -l "$iface" 2>/dev/null | awk '
      /Current hardware settings:/ {in_hw=1; next}
      /Pre-set maximums:/ {in_hw=0}
      in_hw && $1=="Combined:" {print $2; exit}
    ' || true)"
    IFACE_QUEUES_COMBINED="${comb:-unknown}"
  fi
}

_get_tcp_cc_and_qdisc() {
  TCP_CC_CUR="$(_sysctl_get net.ipv4.tcp_congestion_control)"
  TCP_CC_CUR="${TCP_CC_CUR:-unknown}"

  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    TCP_CC_AVAIL="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    TCP_CC_AVAIL="${TCP_CC_AVAIL:-unknown}"
  else
    TCP_CC_AVAIL="unknown"
  fi

  QDISC_DEFAULT="$(_sysctl_get net.core.default_qdisc)"
  QDISC_DEFAULT="${QDISC_DEFAULT:-unknown}"

  if _has_cmd tc && [[ "$DEFAULT_IFACE" != "unknown" ]]; then
    local line
    line="$(tc qdisc show dev "$DEFAULT_IFACE" 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      QDISC_CUR="$(awk '{for(i=1;i<=NF;i++) if($i=="qdisc"){print $(i+1); exit}}' <<<"$line")"
      QDISC_CUR="${QDISC_CUR:-unknown}"
    else
      QDISC_CUR="unknown"
    fi

    # Detect fq support without modifying system state
    QDISC_FQ_SUPPORTED="unknown"
    if [[ -e /sys/module/sch_fq ]]; then
      QDISC_FQ_SUPPORTED="yes"
    elif _has_cmd modprobe && modprobe -n sch_fq >/dev/null 2>&1; then
      QDISC_FQ_SUPPORTED="yes"
    else
      local moddir="/lib/modules/$(uname -r)/kernel/net/sched"
      if [[ -d "$moddir" ]]; then
        if compgen -G "$moddir/sch_fq.ko*" >/dev/null; then
          QDISC_FQ_SUPPORTED="yes"
        else
          QDISC_FQ_SUPPORTED="no"
        fi
      fi
    fi
  else
    QDISC_CUR="unknown"
    QDISC_FQ_SUPPORTED="unknown"
  fi
}

_get_buffers_and_mtu_flags() {
  SYS_RMEM_MAX="$(_sysctl_get net.core.rmem_max)"; SYS_RMEM_MAX="${SYS_RMEM_MAX:-unknown}"
  SYS_WMEM_MAX="$(_sysctl_get net.core.wmem_max)"; SYS_WMEM_MAX="${SYS_WMEM_MAX:-unknown}"
  SYS_RMEM_DEF="$(_sysctl_get net.core.rmem_default)"; SYS_RMEM_DEF="${SYS_RMEM_DEF:-unknown}"
  SYS_WMEM_DEF="$(_sysctl_get net.core.wmem_default)"; SYS_WMEM_DEF="${SYS_WMEM_DEF:-unknown}"
  SYS_TCP_RMEM="$(_sysctl_get net.ipv4.tcp_rmem)"; SYS_TCP_RMEM="${SYS_TCP_RMEM:-unknown}"
  SYS_TCP_WMEM="$(_sysctl_get net.ipv4.tcp_wmem)"; SYS_TCP_WMEM="${SYS_TCP_WMEM:-unknown}"
  SYS_NETDEV_BACKLOG="$(_sysctl_get net.core.netdev_max_backlog)"; SYS_NETDEV_BACKLOG="${SYS_NETDEV_BACKLOG:-unknown}"
  SYS_SOMAXCONN="$(_sysctl_get net.core.somaxconn)"; SYS_SOMAXCONN="${SYS_SOMAXCONN:-unknown}"
  SYS_TCP_MAX_SYN_BACKLOG="$(_sysctl_get net.ipv4.tcp_max_syn_backlog)"; SYS_TCP_MAX_SYN_BACKLOG="${SYS_TCP_MAX_SYN_BACKLOG:-unknown}"
  SYS_TCP_MTU_PROBING="$(_sysctl_get net.ipv4.tcp_mtu_probing)"; SYS_TCP_MTU_PROBING="${SYS_TCP_MTU_PROBING:-unknown}"
  SYS_RPS_SOCK_FLOW_ENTRIES="$(_sysctl_get net.core.rps_sock_flow_entries)"; SYS_RPS_SOCK_FLOW_ENTRIES="${SYS_RPS_SOCK_FLOW_ENTRIES:-unknown}"
  SYS_UDP_RMEM_MIN="$(_sysctl_get net.ipv4.udp_rmem_min)"; SYS_UDP_RMEM_MIN="${SYS_UDP_RMEM_MIN:-unknown}"
}

_get_offload_states() {
  OFF_TSO="unknown"; OFF_GSO="unknown"; OFF_GRO="unknown"; OFF_LRO="unknown"
  if _has_cmd ethtool && [[ "$DEFAULT_IFACE" != "unknown" ]]; then
    local out
    out="$(ethtool -k "$DEFAULT_IFACE" 2>/dev/null || true)"
    OFF_TSO="$(awk -F': ' '/tcp-segmentation-offload:/{print $2; exit}' <<<"$out" || true)"
    OFF_GSO="$(awk -F': ' '/generic-segmentation-offload:/{print $2; exit}' <<<"$out" || true)"
    OFF_GRO="$(awk -F': ' '/generic-receive-offload:/{print $2; exit}' <<<"$out" || true)"
    OFF_LRO="$(awk -F': ' '/large-receive-offload:/{print $2; exit}' <<<"$out" || true)"
    OFF_TSO="${OFF_TSO:-unknown}"
    OFF_GSO="${OFF_GSO:-unknown}"
    OFF_GRO="${OFF_GRO:-unknown}"
    OFF_LRO="${OFF_LRO:-unknown}"
  fi
}

_add_driver_note() {
  local note="$1"
  DRIVER_NOTES+=("$note")
}

_driver_specific_notes() {
  DRIVER_NOTES=()
  local drv="${IFACE_DRIVER,,}"
  local qinfo=""
  if [[ "$IFACE_QUEUES_COMBINED" =~ ^[0-9]+$ && "$CPU_COUNT" =~ ^[0-9]+$ ]]; then
    qinfo=" (combined=${IFACE_QUEUES_COMBINED}, cpu=${CPU_COUNT})"
  fi

  case "$drv" in
    virtio_net|virtio-net|virtio)
      _add_driver_note "KVM/virtio-net: 建议确认多队列已启用，队列数接近 vCPU$qinfo；如支持可用 ethtool -L 调整。"
      _add_driver_note "KVM/virtio-net: 单队列场景下 RPS/XPS 通常更有收益，已支持持久化。"
      _add_driver_note "KVM/virtio-net: 若吞吐异常，可让云商确认宿主机 vhost-net 与多队列配置。"
      ;;
    ena)
      _add_driver_note "ENA (AWS): 建议将 combined 队列数设为接近 vCPU$qinfo；用 ethtool -l 查看上限，支持时用 -L 调整。"
      _add_driver_note "ENA (AWS): 默认开启 TSO/GSO/GRO 通常更优，低延迟业务再评估关闭。"
      ;;
    vmxnet3)
      _add_driver_note "vmxnet3 (VMware): 建议启用多队列/RSS，队列数接近 vCPU$qinfo；支持时用 ethtool -L 调整。"
      _add_driver_note "vmxnet3 (VMware): GRO/LRO 常提升吞吐，但可能影响延迟/包检查，按业务取舍。"
      _add_driver_note "vmxnet3 (VMware): PPS 高时结合 RPS/XPS 分散到多核通常有效。"
      ;;
  esac
}

_pmtu_probe_v4() {
  # Best-effort PMTU test (IPv4). No system changes.
  PMTU_TARGET="unknown"
  PMTU_EST="unknown"
  PMTU_RISK_NOTE="unknown"
  PMTU_METHOD="unknown"

  if _has_cmd ip; then
    if ! ip -4 route show default 2>/dev/null | head -n1 | grep -q .; then
      PMTU_RISK_NOTE="no IPv4 default route; skip PMTU probe"
      return 0
    fi
  fi

  local -a targets=("1.1.1.1" "8.8.8.8" "9.9.9.9")

  if _has_cmd tracepath; then
    local -a tp_args=(-n -m 10)
    if _tracepath_cmd_supports_opt tracepath "-q"; then
      tp_args+=(-q 1)
    fi
    local t
    for t in "${targets[@]}"; do
      local pmtu
      pmtu="$(_tracepath_pmtu tracepath "${tp_args[@]}" "$t")"
      if [[ "$pmtu" =~ ^[0-9]+$ ]]; then
        PMTU_TARGET="$t"
        PMTU_EST="$pmtu"
        PMTU_METHOD="tracepath"
        if [[ "$IFACE_MTU" =~ ^[0-9]+$ ]] && (( pmtu < IFACE_MTU )); then
          PMTU_RISK_NOTE="tracepath pmtu=$pmtu < iface MTU=$IFACE_MTU: possible fragmentation / PMTU blackhole risk"
        else
          PMTU_RISK_NOTE="tracepath pmtu=$pmtu"
        fi
        return 0
      fi
    done
  fi

  if ! _has_cmd ping; then
    PMTU_RISK_NOTE="ping not found; cannot probe PMTU"
    return 0
  fi

  local -a ping_timeout=()
  if _ping_supports_opt "-W"; then
    ping_timeout=(-W 1)
  elif _ping_supports_opt "-w"; then
    ping_timeout=(-w 1)
  else
    PMTU_RISK_NOTE="ping lacks -W/-w option; cannot probe PMTU"
    return 0
  fi

  if ! _ping_supports_opt "-M"; then
    PMTU_RISK_NOTE="ping lacks -M option; cannot probe PMTU"
    return 0
  fi

  local t=""
  for t in "${targets[@]}"; do
    if ping -c1 "${ping_timeout[@]}" "$t" >/dev/null 2>&1; then
      PMTU_TARGET="$t"
      break
    fi
  done
  if [[ "$PMTU_TARGET" == "unknown" ]]; then
    PMTU_RISK_NOTE="no ICMP reply from common targets; PMTU probe unavailable (may be blocked)"
    return 0
  fi

  if [[ "$IFACE_MTU" == "unknown" || ! "$IFACE_MTU" =~ ^[0-9]+$ ]]; then
    PMTU_RISK_NOTE="iface MTU unknown; PMTU probe limited"
    return 0
  fi

  local mtu="$IFACE_MTU"
  local payload=$(( mtu - 28 )) # IPv4 header 20 + ICMP 8
  if (( payload < 0 )); then payload=0; fi

  local out
  out="$(ping -c1 "${ping_timeout[@]}" -M do -s "$payload" "$PMTU_TARGET" 2>&1 || true)"

  PMTU_METHOD="ping"
  if grep -qiE '1 received|bytes from' <<<"$out"; then
    PMTU_EST="$mtu"
    PMTU_RISK_NOTE="DF ping at iface MTU succeeded; path MTU likely >= $mtu"
    return 0
  fi

  local reported
  reported="$(grep -oE 'mtu[[:space:]]*=[[:space:]]*[0-9]+' <<<"$out" | head -n1 | awk -F'=' '{print $2}' | awk '{$1=$1; print}' || true)"
  if [[ -n "$reported" && "$reported" =~ ^[0-9]+$ ]]; then
    PMTU_EST="$reported"
    if (( reported < mtu )); then
      PMTU_RISK_NOTE="path MTU appears lower than iface MTU (iface=$mtu, path≈$reported): possible fragmentation / PMTU blackhole risk"
    else
      PMTU_RISK_NOTE="reported path MTU≈$reported"
    fi
    return 0
  fi

  local lo=0 hi="$payload" best=0
  while (( lo <= hi )); do
    local mid=$(( (lo + hi) / 2 ))
    local o
    o="$(ping -c1 "${ping_timeout[@]}" -M do -s "$mid" "$PMTU_TARGET" 2>&1 || true)"
    if grep -qiE '1 received|bytes from' <<<"$o"; then
      best="$mid"
      lo=$(( mid + 1 ))
    else
      hi=$(( mid - 1 ))
    fi
  done

  local est=$(( best + 28 ))
  PMTU_EST="$est"
  if (( est < mtu )); then
    PMTU_RISK_NOTE="estimated path MTU≈$est < iface MTU=$mtu: possible fragmentation / PMTU blackhole risk"
  else
    PMTU_RISK_NOTE="estimated path MTU≈$est"
  fi
}

_pmtu_probe_v6() {
  # Best-effort PMTU test (IPv6). No system changes.
  PMTU6_TARGET="unknown"
  PMTU6_EST="unknown"
  PMTU6_RISK_NOTE="unknown"
  PMTU6_METHOD="unknown"

  if _has_cmd ip; then
    if ! ip -6 route show default 2>/dev/null | head -n1 | grep -q .; then
      PMTU6_RISK_NOTE="no IPv6 default route; skip PMTU probe"
      return 0
    fi
  fi

  local -a ping_cmd=()
  local -a ping6_opt=()
  if _has_cmd ping6; then
    ping_cmd=(ping6)
  elif _has_cmd ping && _ping_cmd_supports_opt ping "-6"; then
    ping_cmd=(ping)
    ping6_opt=(-6)
  else
    PMTU6_RISK_NOTE="ping6 not available; cannot probe IPv6 PMTU"
    return 0
  fi

  local -a tp_cmd=()
  local tp_cmd_name=""
  if _has_cmd tracepath6; then
    tp_cmd=(tracepath6)
    tp_cmd_name="tracepath6"
  elif _has_cmd tracepath && _tracepath_cmd_supports_opt tracepath "-6"; then
    tp_cmd=(tracepath -6)
    tp_cmd_name="tracepath"
  fi

  local -a targets=("2606:4700:4700::1111" "2001:4860:4860::8888" "2620:fe::fe")

  if (( ${#tp_cmd[@]} > 0 )); then
    local -a tp_args=(-n -m 10)
    if [[ -n "$tp_cmd_name" ]] && _tracepath_cmd_supports_opt "$tp_cmd_name" "-q"; then
      tp_args+=(-q 1)
    fi
    local t
    for t in "${targets[@]}"; do
      local pmtu
      pmtu="$(_tracepath_pmtu "${tp_cmd[@]}" "${tp_args[@]}" "$t")"
      if [[ "$pmtu" =~ ^[0-9]+$ ]]; then
        PMTU6_TARGET="$t"
        PMTU6_EST="$pmtu"
        PMTU6_METHOD="tracepath"
        if [[ "$IFACE_MTU" =~ ^[0-9]+$ ]] && (( pmtu < IFACE_MTU )); then
          PMTU6_RISK_NOTE="tracepath pmtu=$pmtu < iface MTU=$IFACE_MTU: possible fragmentation / PMTU blackhole risk"
        else
          PMTU6_RISK_NOTE="tracepath pmtu=$pmtu"
        fi
        return 0
      fi
    done
  fi

  local ping_cmd_name="${ping_cmd[0]}"
  local -a ping_timeout=()
  if _ping_cmd_supports_opt "$ping_cmd_name" "-W"; then
    ping_timeout=(-W 1)
  elif _ping_cmd_supports_opt "$ping_cmd_name" "-w"; then
    ping_timeout=(-w 1)
  else
    PMTU6_RISK_NOTE="ping6 lacks -W/-w option; cannot probe IPv6 PMTU"
    return 0
  fi

  if ! _ping_cmd_supports_opt "$ping_cmd_name" "-M"; then
    PMTU6_RISK_NOTE="ping6 lacks -M option; cannot probe IPv6 PMTU"
    return 0
  fi

  local t=""
  for t in "${targets[@]}"; do
    if "${ping_cmd[@]}" "${ping6_opt[@]}" -c1 "${ping_timeout[@]}" "$t" >/dev/null 2>&1; then
      PMTU6_TARGET="$t"
      break
    fi
  done
  if [[ "$PMTU6_TARGET" == "unknown" ]]; then
    PMTU6_RISK_NOTE="no ICMPv6 reply from common targets; IPv6 PMTU probe unavailable (may be blocked)"
    return 0
  fi

  if [[ "$IFACE_MTU" == "unknown" || ! "$IFACE_MTU" =~ ^[0-9]+$ ]]; then
    PMTU6_RISK_NOTE="iface MTU unknown; IPv6 PMTU probe limited"
    return 0
  fi

  local mtu="$IFACE_MTU"
  local payload=$(( mtu - 48 )) # IPv6 header 40 + ICMPv6 8
  if (( payload < 0 )); then payload=0; fi

  local out
  out="$("${ping_cmd[@]}" "${ping6_opt[@]}" -c1 "${ping_timeout[@]}" -M do -s "$payload" "$PMTU6_TARGET" 2>&1 || true)"

  PMTU6_METHOD="ping"
  if grep -qiE '1 received|bytes from' <<<"$out"; then
    PMTU6_EST="$mtu"
    PMTU6_RISK_NOTE="PMTU ping at iface MTU succeeded; IPv6 path MTU likely >= $mtu"
    return 0
  fi

  local reported
  reported="$(grep -oE 'mtu[[:space:]]*=[[:space:]]*[0-9]+' <<<"$out" | head -n1 | awk -F'=' '{print $2}' | awk '{$1=$1; print}' || true)"
  if [[ -n "$reported" && "$reported" =~ ^[0-9]+$ ]]; then
    PMTU6_EST="$reported"
    if (( reported < mtu )); then
      PMTU6_RISK_NOTE="path MTU appears lower than iface MTU (iface=$mtu, path≈$reported): possible fragmentation / PMTU blackhole risk"
    else
      PMTU6_RISK_NOTE="reported path MTU≈$reported"
    fi
    return 0
  fi

  local lo=0 hi="$payload" best=0
  while (( lo <= hi )); do
    local mid=$(( (lo + hi) / 2 ))
    local o
    o="$("${ping_cmd[@]}" "${ping6_opt[@]}" -c1 "${ping_timeout[@]}" -M do -s "$mid" "$PMTU6_TARGET" 2>&1 || true)"
    if grep -qiE '1 received|bytes from' <<<"$o"; then
      best="$mid"
      lo=$(( mid + 1 ))
    else
      hi=$(( mid - 1 ))
    fi
  done

  local est=$(( best + 48 ))
  PMTU6_EST="$est"
  if (( est < mtu )); then
    PMTU6_RISK_NOTE="estimated path MTU≈$est < iface MTU=$mtu: possible fragmentation / PMTU blackhole risk"
  else
    PMTU6_RISK_NOTE="estimated path MTU≈$est"
  fi
}

_pmtu_probe() {
  _pmtu_probe_v4
  _pmtu_probe_v6
}

# ----------------------------
# Report generation
# ----------------------------
_write_report() {
  mkdir -p "$RUN_DIR"
  : >"$REPORT_FILE"
  local n

  {
    printf "vps-net-tune diagnostic report\n"
    printf "Run time (local): %s\n" "$RUN_LOCAL"
    printf "Run id (UTC): %s\n" "$RUN_UTC"
    printf "Script: %s v%s\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf "\n"

    printf "[1] System\n"
    printf "  OS: %s\n" "$OS_PRETTY"
    printf "  Kernel: %s\n" "$KERNEL_REL"
    printf "  Virtualization: %s\n" "$VIRT_TYPE"
    printf "  CPU: %s cores\n" "$CPU_COUNT"
    printf "  Memory: %s MB\n" "$MEM_TOTAL_MB"
    printf "\n"

    printf "[2] Network Interface\n"
    printf "  Default iface: %s\n" "$DEFAULT_IFACE"
    printf "  MTU: %s\n" "$IFACE_MTU"
    printf "  Link speed: %s\n" "$IFACE_SPEED"
    printf "  Driver: %s\n" "$IFACE_DRIVER"
    printf "  Bus-info: %s\n" "$IFACE_BUSINFO"
    printf "  Queues (rx/tx/combined): %s / %s / %s\n" "$IFACE_QUEUES_RX" "$IFACE_QUEUES_TX" "$IFACE_QUEUES_COMBINED"
    printf "\n"

    printf "[3] TCP / Qdisc\n"
    printf "  tcp_congestion_control (current): %s\n" "$TCP_CC_CUR"
    printf "  tcp_available_congestion_control: %s\n" "$TCP_CC_AVAIL"
    printf "  qdisc (current on iface): %s\n" "$QDISC_CUR"
    printf "  net.core.default_qdisc: %s\n" "$QDISC_DEFAULT"
    printf "  fq qdisc supported: %s\n" "$QDISC_FQ_SUPPORTED"
    printf "\n"

    printf "[4] MTU / PMTU Probe (best-effort)\n"
    printf "  IPv4 target: %s\n" "$PMTU_TARGET"
    printf "  IPv4 method: %s\n" "$PMTU_METHOD"
    printf "  IPv4 estimated path MTU: %s\n" "$PMTU_EST"
    printf "  IPv4 note: %s\n" "$PMTU_RISK_NOTE"
    printf "  IPv6 target: %s\n" "$PMTU6_TARGET"
    printf "  IPv6 method: %s\n" "$PMTU6_METHOD"
    printf "  IPv6 estimated path MTU: %s\n" "$PMTU6_EST"
    printf "  IPv6 note: %s\n" "$PMTU6_RISK_NOTE"
    printf "\n"

    printf "[5] Buffer / backlog related sysctls\n"
    printf "  net.core.rmem_max: %s\n" "$SYS_RMEM_MAX"
    printf "  net.core.wmem_max: %s\n" "$SYS_WMEM_MAX"
    printf "  net.core.rmem_default: %s\n" "$SYS_RMEM_DEF"
    printf "  net.core.wmem_default: %s\n" "$SYS_WMEM_DEF"
    printf "  net.ipv4.tcp_rmem: %s\n" "$SYS_TCP_RMEM"
    printf "  net.ipv4.tcp_wmem: %s\n" "$SYS_TCP_WMEM"
    printf "  net.core.netdev_max_backlog: %s\n" "$SYS_NETDEV_BACKLOG"
    printf "  net.core.somaxconn: %s\n" "$SYS_SOMAXCONN"
    printf "  net.ipv4.tcp_max_syn_backlog: %s\n" "$SYS_TCP_MAX_SYN_BACKLOG"
    printf "  net.ipv4.tcp_mtu_probing: %s\n" "$SYS_TCP_MTU_PROBING"
    printf "  net.core.rps_sock_flow_entries: %s\n" "$SYS_RPS_SOCK_FLOW_ENTRIES"
    printf "  net.ipv4.udp_rmem_min: %s\n" "$SYS_UDP_RMEM_MIN"
    printf "\n"

    printf "[6] Offload (read-only)\n"
    printf "  TSO: %s\n" "$OFF_TSO"
    printf "  GSO: %s\n" "$OFF_GSO"
    printf "  GRO: %s\n" "$OFF_GRO"
    printf "  LRO: %s\n" "$OFF_LRO"
    printf "\n"

    printf "[7] Driver-specific suggestions\n"
    if (( ${#DRIVER_NOTES[@]} == 0 )); then
      printf "  (none)\n"
    else
      for n in "${DRIVER_NOTES[@]}"; do
        printf "  - %s\n" "$n"
      done
    fi
    printf "\n"

    printf "[8] Notes / Safety\n"
    printf "  - This tool does NOT change MTU, NIC ring sizes, or offload flags by default (risk control).\n"
    printf "  - Apply stage supports dry-run / per-item confirmation / one-click apply.\n"
    printf "  - All applied changes generate a rollback script.\n"
  } | tee -a "$REPORT_FILE" >/dev/null

  _log "Diagnostic report written: $REPORT_FILE"
}

# ----------------------------
# Plan builder
# ----------------------------
_plan_reset() {
  PLAN_TYPE=()
  PLAN_ID=()
  PLAN_DESC=()
  PLAN_RISK=()
  PLAN_KEY=()
  PLAN_TARGET=()
  PLAN_SELECTED=()
  PLAN_STATUS=()
}

_plan_add_sysctl() {
  local id="$1" desc="$2" risk="$3" key="$4" target="$5"
  PLAN_TYPE+=("sysctl")
  PLAN_ID+=("$id")
  PLAN_DESC+=("$desc")
  PLAN_RISK+=("$risk")
  PLAN_KEY+=("$key")
  PLAN_TARGET+=("$target")
}

_plan_add_sysfs() {
  local id="$1" desc="$2" risk="$3" path="$4" target="$5"
  PLAN_TYPE+=("sysfs")
  PLAN_ID+=("$id")
  PLAN_DESC+=("$desc")
  PLAN_RISK+=("$risk")
  PLAN_KEY+=("$path")
  PLAN_TARGET+=("$target")
}

_plan_add_module() {
  local id="$1" desc="$2" risk="$3" mod="$4"
  PLAN_TYPE+=("modules")
  PLAN_ID+=("$id")
  PLAN_DESC+=("$desc")
  PLAN_RISK+=("$risk")
  PLAN_KEY+=("$mod")
  PLAN_TARGET+=("")
}

_is_tcp_related() {
  [[ "$NODE_PROTO" == "tcp" || "$NODE_PROTO" == "both" ]]
}

_is_udp_related() {
  [[ "$NODE_PROTO" == "udp" || "$NODE_PROTO" == "both" ]]
}

# Decide recommended buffer/backlog values by memory size (conservative & safe)
_calc_recommended_values() {
  # outputs globals:
  # REC_RMEM_MAX REC_WMEM_MAX REC_TCP_RMEM REC_TCP_WMEM REC_NETDEV_BACKLOG REC_SOMAXCONN REC_SYN_BACKLOG
  # REC_MTU_PROBING REC_RPS_SOCK_FLOW_ENTRIES

  local mem="$MEM_TOTAL_MB"
  local rmax wmax backlog somax synb

  if (( mem <= 1024 )); then
    rmax=$(( 8 * 1024 * 1024 ))
    wmax=$(( 8 * 1024 * 1024 ))
    backlog=10000
    somax=2048
    synb=4096
  elif (( mem <= 2048 )); then
    rmax=$(( 16 * 1024 * 1024 ))
    wmax=$(( 16 * 1024 * 1024 ))
    backlog=50000
    somax=4096
    synb=8192
  elif (( mem <= 4096 )); then
    rmax=$(( 32 * 1024 * 1024 ))
    wmax=$(( 32 * 1024 * 1024 ))
    backlog=100000
    somax=4096
    synb=8192
  else
    rmax=$(( 32 * 1024 * 1024 ))
    wmax=$(( 32 * 1024 * 1024 ))
    backlog=250000
    somax=4096
    synb=8192
  fi

  REC_RMEM_MAX="$rmax"
  REC_WMEM_MAX="$wmax"
  REC_TCP_RMEM="4096 87380 $rmax"
  REC_TCP_WMEM="4096 65536 $wmax"
  REC_NETDEV_BACKLOG="$backlog"
  REC_SOMAXCONN="$somax"
  REC_SYN_BACKLOG="$synb"

  # MTU probing: enable if we suspect PMTU mismatch OR if currently disabled and node is TCP-ish
  REC_MTU_PROBING="1"

  # RPS flows: only useful with multiple CPUs
  if (( CPU_COUNT > 1 )); then
    REC_RPS_SOCK_FLOW_ENTRIES="32768"
  else
    REC_RPS_SOCK_FLOW_ENTRIES="0"
  fi
}

_build_plan() {
  _plan_reset
  _calc_recommended_values

  # 1) Congestion control -> bbr (TCP only)
  if _is_tcp_related; then
    if [[ "$TCP_CC_AVAIL" != "unknown" ]] && grep -qw "bbr" <<<"$TCP_CC_AVAIL"; then
      if [[ "$TCP_CC_CUR" != "bbr" ]]; then
        _plan_add_sysctl "tcp_cc_bbr" "将 net.ipv4.tcp_congestion_control 调整为 bbr（若可用）" "LOW" "net.ipv4.tcp_congestion_control" "bbr"
        _plan_add_module "mod_tcp_bbr" "确保 tcp_bbr 模块可加载（开机可用）" "LOW" "tcp_bbr"
      fi
    fi
  fi

  # 2) default_qdisc -> fq (if supported)
  if [[ "$QDISC_FQ_SUPPORTED" == "yes" || "$QDISC_FQ_SUPPORTED" == "maybe" ]]; then
    if [[ "$QDISC_DEFAULT" != "fq" ]]; then
      _plan_add_sysctl "default_qdisc_fq" "将 net.core.default_qdisc 调整为 fq（若可用）" "LOW" "net.core.default_qdisc" "fq"
      _plan_add_module "mod_sch_fq" "确保 sch_fq 模块可加载（开机可用）" "LOW" "sch_fq"
    fi
  fi

  # 3) Buffers/backlog: only increase (safe)
  # rmem_max / wmem_max
  if [[ "$SYS_RMEM_MAX" =~ ^[0-9]+$ ]] && (( SYS_RMEM_MAX < REC_RMEM_MAX )); then
    _plan_add_sysctl "rmem_max" "提高 net.core.rmem_max（上限）" "LOW" "net.core.rmem_max" "$REC_RMEM_MAX"
  fi
  if [[ "$SYS_WMEM_MAX" =~ ^[0-9]+$ ]] && (( SYS_WMEM_MAX < REC_WMEM_MAX )); then
    _plan_add_sysctl "wmem_max" "提高 net.core.wmem_max（上限）" "LOW" "net.core.wmem_max" "$REC_WMEM_MAX"
  fi

  # Defaults (moderate, not too aggressive)
  if [[ "$SYS_RMEM_DEF" =~ ^[0-9]+$ ]] && (( SYS_RMEM_DEF < 262144 )); then
    _plan_add_sysctl "rmem_default" "提高 net.core.rmem_default（默认接收缓冲）" "LOW" "net.core.rmem_default" "262144"
  fi
  if [[ "$SYS_WMEM_DEF" =~ ^[0-9]+$ ]] && (( SYS_WMEM_DEF < 262144 )); then
    _plan_add_sysctl "wmem_default" "提高 net.core.wmem_default（默认发送缓冲）" "LOW" "net.core.wmem_default" "262144"
  fi

  # tcp_rmem / tcp_wmem (set full triplet)
  if _is_tcp_related; then
    if [[ "$SYS_TCP_RMEM" != "unknown" && "$SYS_TCP_RMEM" != "$REC_TCP_RMEM" ]]; then
      # Only apply if current max < recommended max (heuristic)
      local cur_max
      cur_max="$(awk '{print $3}' <<<"$SYS_TCP_RMEM" 2>/dev/null || echo "")"
      if [[ "$cur_max" =~ ^[0-9]+$ ]] && (( cur_max < REC_RMEM_MAX )); then
        _plan_add_sysctl "tcp_rmem" "调整 net.ipv4.tcp_rmem（读缓冲三元组）" "LOW" "net.ipv4.tcp_rmem" "$REC_TCP_RMEM"
      fi
    fi
    if [[ "$SYS_TCP_WMEM" != "unknown" && "$SYS_TCP_WMEM" != "$REC_TCP_WMEM" ]]; then
      local cur_max
      cur_max="$(awk '{print $3}' <<<"$SYS_TCP_WMEM" 2>/dev/null || echo "")"
      if [[ "$cur_max" =~ ^[0-9]+$ ]] && (( cur_max < REC_WMEM_MAX )); then
        _plan_add_sysctl "tcp_wmem" "调整 net.ipv4.tcp_wmem（写缓冲三元组）" "LOW" "net.ipv4.tcp_wmem" "$REC_TCP_WMEM"
      fi
    fi
  fi

  # netdev backlog
  if [[ "$SYS_NETDEV_BACKLOG" =~ ^[0-9]+$ ]] && [[ "$REC_NETDEV_BACKLOG" =~ ^[0-9]+$ ]] && (( SYS_NETDEV_BACKLOG < REC_NETDEV_BACKLOG )); then
    _plan_add_sysctl "netdev_backlog" "提高 net.core.netdev_max_backlog（网卡接收队列拥塞缓冲）" "MED" "net.core.netdev_max_backlog" "$REC_NETDEV_BACKLOG"
  fi

  # somaxconn
  if [[ "$SYS_SOMAXCONN" =~ ^[0-9]+$ ]] && (( SYS_SOMAXCONN < REC_SOMAXCONN )); then
    _plan_add_sysctl "somaxconn" "提高 net.core.somaxconn（listen backlog 上限）" "LOW" "net.core.somaxconn" "$REC_SOMAXCONN"
  fi

  # syn backlog
  if _is_tcp_related; then
    if [[ "$SYS_TCP_MAX_SYN_BACKLOG" =~ ^[0-9]+$ ]] && (( SYS_TCP_MAX_SYN_BACKLOG < REC_SYN_BACKLOG )); then
      _plan_add_sysctl "syn_backlog" "提高 net.ipv4.tcp_max_syn_backlog（半连接队列上限）" "LOW" "net.ipv4.tcp_max_syn_backlog" "$REC_SYN_BACKLOG"
    fi
  fi

  # 3b) UDP receive floor (when profile includes UDP)
  if _is_udp_related; then
    if _sysctl_exists net.ipv4.udp_rmem_min; then
      if [[ "$SYS_UDP_RMEM_MIN" =~ ^[0-9]+$ ]] && (( SYS_UDP_RMEM_MIN < 8192 )); then
        _plan_add_sysctl "udp_rmem_min" "提高 net.ipv4.udp_rmem_min（UDP 接收下限，代理/QUIC 场景）" "LOW" "net.ipv4.udp_rmem_min" "8192"
      fi
    fi
  fi

  # 4) Enable tcp_mtu_probing if TCP-ish and currently disabled and/or PMTU mismatch suspected
  if _is_tcp_related; then
    local need=0
    if [[ "$SYS_TCP_MTU_PROBING" =~ ^[0-9]+$ ]] && (( SYS_TCP_MTU_PROBING == 0 )); then
      need=1
    fi
    if [[ "$PMTU_EST" =~ ^[0-9]+$ && "$IFACE_MTU" =~ ^[0-9]+$ ]] && (( PMTU_EST < IFACE_MTU )); then
      need=1
    fi
    if (( need == 1 )); then
      _plan_add_sysctl "mtu_probing" "启用 net.ipv4.tcp_mtu_probing（改善 PMTU 黑洞场景）" "LOW" "net.ipv4.tcp_mtu_probing" "$REC_MTU_PROBING"
    fi
  fi

  # 5) RPS suggestions (optional apply via sysfs)
  # We include only if multiple CPUs and queues exist.
  if [[ "$DEFAULT_IFACE" != "unknown" && -d "/sys/class/net/$DEFAULT_IFACE/queues" ]] && (( CPU_COUNT > 1 )); then
    local rxq
    rxq="$(ls -1 "/sys/class/net/$DEFAULT_IFACE/queues" 2>/dev/null | grep -cE '^rx-' || true)"
    if (( rxq > 0 )); then
      local mask
      mask="$(_cpumask_all "$CPU_COUNT")"

      # Global flow entries if below recommended
      if [[ "$SYS_RPS_SOCK_FLOW_ENTRIES" =~ ^[0-9]+$ ]] && [[ "$REC_RPS_SOCK_FLOW_ENTRIES" =~ ^[0-9]+$ ]] && (( SYS_RPS_SOCK_FLOW_ENTRIES < REC_RPS_SOCK_FLOW_ENTRIES )); then
        _plan_add_sysctl "rps_flow_entries" "提高 net.core.rps_sock_flow_entries（RPS 连接流表）" "MED" "net.core.rps_sock_flow_entries" "$REC_RPS_SOCK_FLOW_ENTRIES"
      fi

      # Per-queue sysfs (RPS)
      local per_queue
      per_queue=$(( 32768 / rxq ))
      if (( per_queue < 1024 )); then per_queue=1024; fi

      local q
      for q in /sys/class/net/"$DEFAULT_IFACE"/queues/rx-*; do
        [[ -d "$q" ]] || continue
        local idx
        idx="$(basename "$q")"
        _plan_add_sysfs "rps_cpus_${idx}" "设置 ${idx} 的 rps_cpus（分散到多核）" "MED" "$q/rps_cpus" "$mask"
        if [[ -e "$q/rps_flow_cnt" ]]; then
          _plan_add_sysfs "rps_flow_${idx}" "设置 ${idx} 的 rps_flow_cnt（启用 RPS 流散列）" "MED" "$q/rps_flow_cnt" "$per_queue"
        fi
      done

      # XPS (optional)
      local txq
      txq="$(ls -1 "/sys/class/net/$DEFAULT_IFACE/queues" 2>/dev/null | grep -cE '^tx-' || true)"
      if (( txq > 0 )); then
        for q in /sys/class/net/"$DEFAULT_IFACE"/queues/tx-*; do
          [[ -d "$q" ]] || continue
          local idx
          idx="$(basename "$q")"
          if [[ -e "$q/xps_cpus" ]]; then
            _plan_add_sysfs "xps_cpus_${idx}" "设置 ${idx} 的 xps_cpus（发送侧多核亲和）" "MED" "$q/xps_cpus" "$mask"
          fi
        done
      fi
    fi
  fi
}

_write_plan() {
  : >"$PLAN_FILE"
  local n
  {
    printf "Change plan (proposed)\n"
    printf "Run id (UTC): %s\n" "$RUN_UTC"
    printf "Protocol selection: VPN=%s | kernel_profile=%s\n" "$VPN_NAME" "$NODE_PROTO"
    printf "\n"

    if (( ${#PLAN_ID[@]} == 0 )); then
      printf "No changes recommended (or all already optimal / not supported).\n"
    else
      local i
      for i in "${!PLAN_ID[@]}"; do
        printf -- "- [%s] (%s) %s\n" "${PLAN_RISK[$i]}" "${PLAN_TYPE[$i]}" "${PLAN_DESC[$i]}"
        case "${PLAN_TYPE[$i]}" in
          sysctl)
            printf "    key: %s\n" "${PLAN_KEY[$i]}"
            printf "    target: %s\n" "${PLAN_TARGET[$i]}"
            ;;
          sysfs)
            printf "    path: %s\n" "${PLAN_KEY[$i]}"
            printf "    target: %s\n" "${PLAN_TARGET[$i]}"
            ;;
          modules)
            printf "    module: %s\n" "${PLAN_KEY[$i]}"
            ;;
        esac
      done
    fi

    printf "\nNotes:\n"
    printf "  - MTU/Offload changes are NOT included by default (risk control).\n"
    printf "  - MSS clamp is NOT auto-applied (iptables/nft persistence differs across setups); consider manual if needed.\n"
    printf "  - RPS/XPS sysfs changes are runtime-only by default; you can opt-in to persist via systemd during apply.\n"

    if (( ${#DRIVER_NOTES[@]} > 0 )); then
      printf "\nDriver-specific suggestions (non-applied):\n"
      for n in "${DRIVER_NOTES[@]}"; do
        printf "  - %s\n" "$n"
      done
    fi
  } | tee -a "$PLAN_FILE" >/dev/null

  _log "Change plan written: $PLAN_FILE"
}

# ----------------------------
# Apply stage: selection + rollback preparation + execution
# ----------------------------
_prepare_dirs_and_logs() {
  mkdir -p "$LOG_ROOT" "$RUN_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

_record_sysctl_before() {
  : >"$SYSCTL_BEFORE"
  # Record only relevant keys (those in plan, type=sysctl)
  local -A seen=()
  local i
  for i in "${!PLAN_ID[@]}"; do
    if [[ "${PLAN_TYPE[$i]}" == "sysctl" ]]; then
      local k="${PLAN_KEY[$i]}"
      if [[ -n "${seen[$k]:-}" ]]; then
        continue
      fi
      seen["$k"]=1
      local v
      v="$(_sysctl_get "$k")"
      printf "%s\t%s\n" "$k" "$v" >>"$SYSCTL_BEFORE"
    fi
  done
  _log "Recorded sysctl before-state: $SYSCTL_BEFORE"
}

_record_sysfs_before() {
  : >"$SYSFS_BEFORE"
  local i
  for i in "${!PLAN_ID[@]}"; do
    if [[ "${PLAN_TYPE[$i]}" == "sysfs" ]]; then
      local p="${PLAN_KEY[$i]}"
      local v=""
      if [[ -r "$p" ]]; then
        v="$(cat "$p" 2>/dev/null || true)"
      fi
      # Keep as one line (avoid newlines in v)
      v="${v//$'\n'/}"
      printf "%s\t%s\n" "$p" "$v" >>"$SYSFS_BEFORE"
    fi
  done
  _log "Recorded sysfs before-state: $SYSFS_BEFORE"
}

_generate_rollback_script() {
  cat >"$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\\n\\t'

_ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ printf "[%s] %s\\n" "\$(_ts)" "\$*"; }
warn(){ printf "[%s] [WARN] %s\\n" "\$(_ts)" "\$*" >&2; }

[[ \${EUID:-\$(id -u)} -eq 0 ]] || { echo "Please run rollback as root: sudo $ROLLBACK_SCRIPT" >&2; exit 1; }

log "Rollback for run: $RUN_UTC"
log "Backup dir: $RUN_DIR"

# Restore files (sysctl + modules-load), based on meta:
if [[ -f "$FILE_BEFORE_META" ]]; then
  while IFS=\$'\\t' read -r label existed path bak; do
    [[ -n "\$label" ]] || continue
    if [[ "\$existed" == "1" ]]; then
      if [[ -e "\$bak" ]]; then
        cp -a "\$bak" "\$path" || warn "failed to restore file: \$path"
        log "restored file: \$path (label=\$label)"
      else
        warn "backup missing for \$path (label=\$label)"
      fi
    else
      # file didn't exist originally
      if [[ -e "\$path" ]]; then
        rm -f "\$path" || warn "failed to remove file: \$path"
        log "removed file (was created by tune): \$path (label=\$label)"
      fi
    fi
  done <"$FILE_BEFORE_META"
else
  warn "file meta not found: $FILE_BEFORE_META"
fi

# Restore systemd unit state if recorded
if [[ -f "$SYSTEMD_STATE" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    # Stop if it was active before rollback (best effort)
    while IFS=\$'\\t' read -r unit state existed fragment source active sub; do
      [[ -n "\$unit" ]] || continue
      if [[ "\$active" == "active" ]]; then
        systemctl stop "\$unit" >/dev/null 2>&1 || warn "failed to stop unit: \$unit"
      fi
    done <"$SYSTEMD_STATE"

    # Restore linked/linked-runtime sources before reload
    while IFS=\$'\\t' read -r unit state existed fragment source active sub; do
      [[ -n "\$unit" ]] || continue
      case "\$state" in
        linked|linked-runtime)
          link_src="\$fragment"
          if [[ -z "\$link_src" ]]; then
            link_src="\$source"
          fi
          if [[ -n "\$link_src" ]]; then
            if [[ "\$state" == "linked-runtime" ]]; then
              systemctl link --runtime "\$link_src" >/dev/null 2>&1 || warn "failed to runtime-link unit: \$unit (\$link_src)"
            else
              systemctl link "\$link_src" >/dev/null 2>&1 || warn "failed to link unit: \$unit (\$link_src)"
            fi
          else
            warn "prior unit state was \$state but no FragmentPath/SourcePath; cannot restore link: \$unit"
          fi
          ;;
      esac
    done <"$SYSTEMD_STATE"

    systemctl daemon-reload >/dev/null 2>&1 || true

    # Restore enable/mask/disable state
    while IFS=\$'\\t' read -r unit state existed fragment source active sub; do
      [[ -n "\$unit" ]] || continue
      if [[ "\$existed" == "1" ]]; then
        case "\$state" in
          enabled)
            systemctl enable "\$unit" >/dev/null 2>&1 || warn "failed to enable unit: \$unit"
            ;;
          enabled-runtime)
            systemctl enable --runtime "\$unit" >/dev/null 2>&1 || warn "failed to runtime-enable unit: \$unit"
            ;;
          masked)
            systemctl mask "\$unit" >/dev/null 2>&1 || warn "failed to mask unit: \$unit"
            ;;
          masked-runtime)
            systemctl mask --runtime "\$unit" >/dev/null 2>&1 || warn "failed to runtime-mask unit: \$unit"
            ;;
          disabled)
            systemctl disable "\$unit" >/dev/null 2>&1 || warn "failed to disable unit: \$unit"
            ;;
          static|indirect|generated|transient|alias|linked|linked-runtime)
            log "unit state was \$state; no enable/disable action: \$unit"
            ;;
          *)
            warn "unknown prior unit state (\$state); skip enable/disable: \$unit"
            ;;
        esac
      else
        case "\$state" in
          linked|linked-runtime)
            log "unit state was \$state with no /etc unit file; skip disable: \$unit"
            ;;
          not-found|"")
            log "unit not found before; skip disable: \$unit"
            ;;
          *)
            systemctl disable "\$unit" >/dev/null 2>&1 || true
            ;;
        esac
      fi
    done <"$SYSTEMD_STATE"

    # Restore active state if it was active before
    while IFS=\$'\\t' read -r unit state existed fragment source active sub; do
      [[ -n "\$unit" ]] || continue
      if [[ "\$active" == "active" ]]; then
        case "\$state" in
          masked|masked-runtime)
            warn "unit was active but masked state recorded; skip start: \$unit"
            ;;
          *)
            systemctl start "\$unit" >/dev/null 2>&1 || warn "failed to start unit: \$unit"
            ;;
        esac
      fi
    done <"$SYSTEMD_STATE"
  else
    warn "systemctl not found; cannot restore systemd unit state"
  fi
else
  warn "systemd-state not found: $SYSTEMD_STATE"
fi

# Restore sysctl runtime values
if [[ -f "$SYSCTL_BEFORE" ]]; then
  while IFS=\$'\\t' read -r key val; do
    [[ -n "\$key" ]] || continue
    # skip if key not present now
    if sysctl -n "\$key" >/dev/null 2>&1; then
      sysctl -w "\$key=\$val" >/dev/null 2>&1 || warn "failed to restore sysctl: \$key"
      log "restored sysctl: \$key=\$val"
    else
      warn "sysctl key not present now (skip): \$key"
    fi
  done <"$SYSCTL_BEFORE"
else
  warn "sysctl-before not found: $SYSCTL_BEFORE"
fi

# Restore sysfs values
if [[ -f "$SYSFS_BEFORE" ]]; then
  while IFS=\$'\\t' read -r path val; do
    [[ -n "\$path" ]] || continue
    if [[ -e "\$path" && -w "\$path" ]]; then
      printf "%s" "\$val" >"\$path" 2>/dev/null || warn "failed to restore sysfs: \$path"
      log "restored sysfs: \$path=\$val"
    fi
  done <"$SYSFS_BEFORE"
else
  warn "sysfs-before not found: $SYSFS_BEFORE"
fi

log "Rollback complete."
EOF

  chmod +x "$ROLLBACK_SCRIPT"
  _log "Rollback script generated: $ROLLBACK_SCRIPT"
}

_apply_modules_item() {
  local mod="$1"
  local ok=0

  # Best-effort modprobe (no fail-hard)
  if _has_cmd modprobe; then
    if modprobe "$mod" >/dev/null 2>&1; then
      _log "modprobe ok: $mod"
      ok=1
    else
      _warn "modprobe failed (maybe built-in or not available): $mod"
      # still can persist it; but if not available it won't load anyway. Keep conservative: persist only if modprobe -n succeeds.
      if modprobe -n "$mod" >/dev/null 2>&1; then
        ok=1
      else
        ok=0
      fi
    fi
  else
    _warn "modprobe not found; cannot load module now: $mod"
    ok=0
  fi

  # Persist in modules-load.d if plausible
  if (( ok == 1 )); then
    _backup_file_once "modules_conf" "$MODULES_CONF" "$MODULES_CONF_BAK"
    _modules_conf_add "$mod" || true
    return 0
  fi
  return 1
}

_apply_sysctl_item() {
  local key="$1" target="$2"
  local ok=0
  if _sysctl_set_runtime "$key" "$target"; then
    ok=1
  else
    ok=0
  fi

  if (( ok == 1 )); then
    _backup_file_once "sysctl_conf" "$SYSCTL_CONF" "$SYSCTL_CONF_BAK"
    _sysctl_conf_upsert "$key" "$target" || true
    return 0
  fi
  return 1
}

_apply_sysfs_item() {
  local path="$1" target="$2"
  _sysfs_set "$path" "$target"
}

_plan_print_to_screen() {
  printf "\n将要应用的改动清单（基于当前诊断）：\n"
  if (( ${#PLAN_ID[@]} == 0 )); then
    printf "  （无）\n"
    return 0
  fi
  local i
  for i in "${!PLAN_ID[@]}"; do
    printf "  - [%s] %s\n" "${PLAN_RISK[$i]}" "${PLAN_DESC[$i]}"
  done
}

_choose_apply_mode() {
  _menu_select "请选择应用模式：" \
    "Dry-run（仅预览，不做任何更改）" \
    "逐项确认（每条改动都问你一次）" \
    "一键应用（应用所有建议项）" \
    "退出（不做任何更改）"
  local idx="$MENU_RET"
  case "$idx" in
    0) APPLY_MODE="dry-run" ;;
    1) APPLY_MODE="confirm" ;;
    2) APPLY_MODE="apply" ;;
    3) APPLY_MODE="exit" ;;
    *) APPLY_MODE="dry-run" ;;
  esac
  _log "Apply mode selected: $APPLY_MODE"
}

_select_items() {
  # Sets PLAN_SELECTED[i]=1 if chosen
  PLAN_SELECTED=()
  local i
  for i in "${!PLAN_ID[@]}"; do
    PLAN_SELECTED+=(0)
    PLAN_STATUS+=("NO")
  done

  if [[ "$APPLY_MODE" == "dry-run" ]]; then
    for i in "${!PLAN_ID[@]}"; do
      PLAN_SELECTED[$i]=1
    done
    return 0
  fi

  if [[ "$APPLY_MODE" == "apply" ]]; then
    # Safety: require explicit confirmation
    printf "\n你选择了【一键应用】。为安全起见，请输入 APPLY 再继续："
    local token=""
    read -r token || true
    if [[ "$token" != "APPLY" ]]; then
      _warn "Token mismatch. Abort apply."
      APPLY_MODE="exit"
      return 0
    fi
    for i in "${!PLAN_ID[@]}"; do
      PLAN_SELECTED[$i]=1
    done
    return 0
  fi

  if [[ "$APPLY_MODE" == "confirm" ]]; then
    local i
    for i in "${!PLAN_ID[@]}"; do
      printf "\n[%s] %s\n" "${PLAN_RISK[$i]}" "${PLAN_DESC[$i]}"
      case "${PLAN_TYPE[$i]}" in
        sysctl)
          printf "  sysctl: %s => %s\n" "${PLAN_KEY[$i]}" "${PLAN_TARGET[$i]}"
          ;;
        sysfs)
          printf "  sysfs: %s => %s\n" "${PLAN_KEY[$i]}" "${PLAN_TARGET[$i]}"
          ;;
        modules)
          printf "  module: %s\n" "${PLAN_KEY[$i]}"
          ;;
      esac
      if _prompt_yn "  应用这个改动吗？" "n"; then
        PLAN_SELECTED[$i]=1
      else
        PLAN_SELECTED[$i]=0
      fi
    done
    return 0
  fi
}

_select_persist_sysfs() {
  PERSIST_SYSFS="no"
  if [[ "$APPLY_MODE" == "dry-run" || "$APPLY_MODE" == "exit" ]]; then
    return 0
  fi

  local any=0
  local i
  for i in "${!PLAN_ID[@]}"; do
    if [[ "${PLAN_SELECTED[$i]}" -eq 1 && "${PLAN_TYPE[$i]}" == "sysfs" ]]; then
      if _is_rps_xps_path "${PLAN_KEY[$i]}"; then
        any=1
        break
      fi
    fi
  done

  if (( any == 1 )); then
    if _prompt_yn "检测到 RPS/XPS 调整，是否写入 systemd 持久化？" "y"; then
      PERSIST_SYSFS="yes"
    fi
  fi
}

_apply_selected_items() {
  PERSIST_SYSFS_PATH=()
  PERSIST_SYSFS_VAL=()
  : >"$APPLY_SUMMARY_FILE"
  {
    printf "Apply summary\n"
    printf "Run id (UTC): %s\n" "$RUN_UTC"
    printf "Mode: %s\n" "$APPLY_MODE"
    printf "Persist RPS/XPS: %s\n" "$PERSIST_SYSFS"
    if [[ "$PERSIST_SYSFS" == "yes" ]]; then
      printf "Systemd unit: %s\n" "$RPSXPS_UNIT_NAME"
    fi
    printf "\n"
  } >>"$APPLY_SUMMARY_FILE"

  if [[ "$APPLY_MODE" == "dry-run" ]]; then
    _log "Dry-run: no changes will be made."
  fi

  local any_change=0
  local any_fail=0

  local i
  for i in "${!PLAN_ID[@]}"; do
    if [[ "${PLAN_SELECTED[$i]}" -ne 1 ]]; then
      PLAN_STATUS[$i]="SKIP"
      continue
    fi

    local t="${PLAN_TYPE[$i]}"
    local desc="${PLAN_DESC[$i]}"
    local key="${PLAN_KEY[$i]}"
    local target="${PLAN_TARGET[$i]}"

    if [[ "$APPLY_MODE" == "dry-run" ]]; then
      PLAN_STATUS[$i]="OK"
      {
        printf -- "- DRYRUN OK: %s\n" "$desc"
        case "$t" in
          sysctl)  printf "    would: sysctl -w %s=%s ; persist in %s\n" "$key" "$target" "$SYSCTL_CONF" ;;
          sysfs)   printf "    would: echo %s > %s\n" "$target" "$key" ;;
          modules) printf "    would: modprobe %s ; persist in %s\n" "$key" "$MODULES_CONF" ;;
        esac
      } >>"$APPLY_SUMMARY_FILE"
      continue
    fi

    any_change=1

    # Apply with best-effort; do not crash whole script on one failure
    local ok=0
    case "$t" in
      sysctl)
        if _apply_sysctl_item "$key" "$target"; then ok=1; else ok=0; fi
        ;;
      sysfs)
        if _apply_sysfs_item "$key" "$target"; then ok=1; else ok=0; fi
        ;;
      modules)
        if _apply_modules_item "$key"; then ok=1; else ok=0; fi
        ;;
      *)
        ok=0
        ;;
    esac

    if (( ok == 1 )); then
      PLAN_STATUS[$i]="OK"
      _log "APPLY OK: $desc"
      if [[ "$t" == "sysfs" && "$PERSIST_SYSFS" == "yes" ]] && _is_rps_xps_path "$key"; then
        PERSIST_SYSFS_PATH+=("$key")
        PERSIST_SYSFS_VAL+=("$target")
      fi
      {
        printf -- "- OK: %s\n" "$desc"
        case "$t" in
          sysctl)  printf "    applied: %s=%s\n" "$key" "$target" ;;
          sysfs)   printf "    applied: %s=%s\n" "$key" "$target" ;;
          modules) printf "    applied: module %s\n" "$key" ;;
        esac
      } >>"$APPLY_SUMMARY_FILE"
    else
      PLAN_STATUS[$i]="FAIL"
      any_fail=1
      _warn "APPLY FAIL: $desc"
      {
        printf -- "- FAIL: %s\n" "$desc"
        case "$t" in
          sysctl)  printf "    tried: %s=%s\n" "$key" "$target" ;;
          sysfs)   printf "    tried: %s=%s\n" "$key" "$target" ;;
          modules) printf "    tried: module %s\n" "$key" ;;
        esac
      } >>"$APPLY_SUMMARY_FILE"
    fi
  done

  # Reload sysctl file if exists and we changed it
  if [[ -f "$SYSCTL_CONF" && "$any_change" -eq 1 ]]; then
    # Best-effort apply (avoid fail-hard if some keys missing)
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
  fi

  _log "Apply summary written: $APPLY_SUMMARY_FILE"

  if (( any_change == 0 )); then
    _log "No changes were applied."
  fi
  if (( any_fail == 1 )); then
    _warn "Some items failed. You can rollback with: $ROLLBACK_SCRIPT"
  fi
}

_apply_flow() {
  if [[ "$APPLY_MODE" == "exit" ]]; then
    _log "User chose exit. No changes will be applied."
    return 0
  fi

  # Prepare rollback artifacts only if not dry-run and at least one item selected
  local sel_any=0
  local i
  for i in "${!PLAN_ID[@]}"; do
    if [[ "${PLAN_SELECTED[$i]}" -eq 1 ]]; then sel_any=1; break; fi
  done
  if (( sel_any == 0 )); then
    _log "No items selected. Nothing to apply."
    return 0
  fi

  if [[ "$APPLY_MODE" == "dry-run" ]]; then
    _apply_selected_items
    return 0
  fi

  # Backup files (only when needed, but we do once-per-label on first modification)
  : >"$FILE_BEFORE_META"

  _record_sysctl_before
  _record_sysfs_before
  if [[ "$PERSIST_SYSFS" == "yes" ]]; then
    _record_systemd_state
  fi
  _generate_rollback_script

  _apply_selected_items

  if [[ "$PERSIST_SYSFS" == "yes" ]]; then
    if (( ${#PERSIST_SYSFS_PATH[@]} == 0 )); then
      {
        printf "\nRPS/XPS persistence: SKIP (no sysfs items)\n"
      } >>"$APPLY_SUMMARY_FILE"
    elif _persist_sysfs_to_systemd; then
      {
        printf "\nRPS/XPS persistence: OK (%s)\n" "$RPSXPS_UNIT_NAME"
      } >>"$APPLY_SUMMARY_FILE"
    else
      {
        printf "\nRPS/XPS persistence: FAIL (%s)\n" "$RPSXPS_UNIT_NAME"
      } >>"$APPLY_SUMMARY_FILE"
    fi
  fi
}

# ----------------------------
# Main
# ----------------------------
_usage() {
  cat <<EOF
Usage: sudo ./$SCRIPT_NAME

This script starts an interactive menu:
  1) Choose VPN/proxy type (maps to kernel tcp/udp/both tuning profile)
  2) Collect diagnostics (no changes)
  3) Show report + change plan
  4) Apply stage: dry-run / confirm each / one-click apply
  5) Generate rollback script + logs

Notes:
  - Default behavior is safe: no changes until you select apply mode.
  - It avoids MTU/offload modification by default.
  - RPS/XPS sysfs changes can be persisted via systemd if you choose.
EOF
}

_main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    _usage
    exit 0
  fi

  _is_root || _die "Please run as root: sudo ./$SCRIPT_NAME"

  _prepare_dirs_and_logs
  _log "=== vps-net-tune start (v$SCRIPT_VERSION) ==="
  _log "Run local time: $RUN_LOCAL"
  _log "Run id (UTC): $RUN_UTC"

  # VPN/proxy selection -> NODE_PROTO (tcp|udp|both) for sysctl plan
  declare -a VPN_OPTIONS=(
    "Hysteria2（QUIC/UDP）"
    "TUIC（QUIC/UDP）"
    "WireGuard（UDP）"
    "VMess"
    "Vless"
    "Trojan（通常 TCP/TLS）"
    "Shadowsocks"
    "Socks5"
    "ShadowsocksR"
    "Relay（中转）"
    "通用/不确定（按 TCP+UDP）"
  )
  _menu_select "请选择节点使用的 VPN/代理协议（将自动匹配内核侧调优策略）：" "${VPN_OPTIONS[@]}"
  VPN_NAME="${VPN_OPTIONS[$MENU_RET]}"
  case "$MENU_RET" in
    0|1|2) NODE_PROTO="udp" ;;
    5|8) NODE_PROTO="tcp" ;;
    3|4|6|7|9|10) NODE_PROTO="both" ;;
    *) NODE_PROTO="both" ;;
  esac
  _log "VPN/协议: $VPN_NAME | kernel profile: $NODE_PROTO"

  # Collect info (no changes)
  _detect_os
  _detect_default_iface
  if [[ "$DEFAULT_IFACE" != "unknown" ]]; then
    _get_iface_mtu "$DEFAULT_IFACE"
    _get_iface_speed_driver_queues "$DEFAULT_IFACE"
  fi
  _get_tcp_cc_and_qdisc
  _get_buffers_and_mtu_flags
  _get_offload_states
  _driver_specific_notes
  _pmtu_probe

  # Report + plan
  _write_report
  _build_plan
  _write_plan

  # Print key outputs to screen (user-visible conclusions)
  printf "\n==================== 诊断报告（摘要）====================\n"
  printf "默认网卡: %s | 速率: %s | 驱动: %s | 队列(rx/tx/combined): %s/%s/%s\n" \
    "$DEFAULT_IFACE" "$IFACE_SPEED" "$IFACE_DRIVER" "$IFACE_QUEUES_RX" "$IFACE_QUEUES_TX" "$IFACE_QUEUES_COMBINED"
  printf "拥塞控制: 当前=%s | 可用=%s\n" "$TCP_CC_CUR" "$TCP_CC_AVAIL"
  printf "qdisc: 当前=%s | default_qdisc=%s | fq支持=%s\n" "$QDISC_CUR" "$QDISC_DEFAULT" "$QDISC_FQ_SUPPORTED"
  printf "IPv4 PMTU: target=%s | method=%s | est=%s | note=%s\n" "$PMTU_TARGET" "$PMTU_METHOD" "$PMTU_EST" "$PMTU_RISK_NOTE"
  printf "IPv6 PMTU: target=%s | method=%s | est=%s | note=%s\n" "$PMTU6_TARGET" "$PMTU6_METHOD" "$PMTU6_EST" "$PMTU6_RISK_NOTE"
  printf "offload: TSO=%s GSO=%s GRO=%s LRO=%s\n" "$OFF_TSO" "$OFF_GSO" "$OFF_GRO" "$OFF_LRO"
  printf "虚拟化: %s | OS: %s | Kernel: %s\n" "$VIRT_TYPE" "$OS_PRETTY" "$KERNEL_REL"
  case "$NODE_PROTO" in
    tcp)  printf "VPN/协议: %s | 内核侧策略: TCP\n" "$VPN_NAME" ;;
    udp)  printf "VPN/协议: %s | 内核侧策略: UDP\n" "$VPN_NAME" ;;
    both) printf "VPN/协议: %s | 内核侧策略: TCP+UDP\n" "$VPN_NAME" ;;
    *)    printf "VPN/协议: %s | 内核侧策略: %s\n" "$VPN_NAME" "$NODE_PROTO" ;;
  esac

  printf "\n报告文件:\n  %s\n" "$REPORT_FILE"
  printf "改动清单文件:\n  %s\n" "$PLAN_FILE"

  _plan_print_to_screen

  # Apply stage
  _choose_apply_mode
  if [[ "$APPLY_MODE" == "exit" ]]; then
    printf "\n已退出：未做任何更改。\n"
    _log "Exit without changes."
    _log "=== vps-net-tune end ==="
    exit 0
  fi

  _select_items
  _select_persist_sysfs
  _apply_flow

  printf "\n==================== 完成 ====================\n"
  printf "日志:\n  %s\n" "$LOG_FILE"
  printf "报告:\n  %s\n" "$REPORT_FILE"
  printf "改动清单:\n  %s\n" "$PLAN_FILE"
  printf "应用摘要:\n  %s\n" "$APPLY_SUMMARY_FILE"
  if [[ -f "$ROLLBACK_SCRIPT" ]]; then
    printf "回滚脚本:\n  %s\n" "$ROLLBACK_SCRIPT"
  else
    printf "回滚脚本: （dry-run 或未应用变更时不生成/或无需）\n"
  fi

  _log "=== vps-net-tune end ==="
}

_main "$@"
