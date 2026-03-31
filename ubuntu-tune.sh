#!/usr/bin/env bash
# ubuntu-tune.sh
#
# 目标：Ubuntu/Debian 生态优先的“计划优先（plan-first）”系统维护/调优脚本。
# 特性：
#   - 默认只诊断 + 生成计划（不改系统）
#   - 可审计：日志（带时间戳）+ 报告（report.md）+ 计划（plan.md）
#   - 可回滚：apply 自动生成 rollback.sh，并支持内置 rollback 子命令
#   - 幂等：重复运行不会叠加污染；已达目标状态会跳过
#   - 交互 + 非交互：菜单 + CLI 参数（plan/diagnose/dry-run/apply/rollback/list-runs）
#   - 风险分级：safe/medium/high/all（默认只执行 safe）
#
# 重要原则：
#   - 不默认做不可逆操作：apt clean、journal vacuum、snap old revisions、docker prune 等仅建议
#   - systemd 相关动作在非 systemd 环境下自动跳过（优雅降级）
#
# 兼容性：
#   - 主要覆盖 Ubuntu/Debian（apt/dpkg），其它发行版做优雅降级：仍能输出诊断报告
#   - systemd 可用时启用 systemd 动作；否则跳过
#
# 版本：0.1.0（脚本版本）
#
# --------------------------------------------

set -Eeuo pipefail
shopt -s extglob

if [[ -z "${BASH_VERSINFO:-}" ]]; then
  echo "ERROR: This script must be run with bash, not sh." >&2
  exit 2
fi

PROG="ubuntu-tune"
SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="0.1.0"
NOW_ISO="$(date +'%Y-%m-%dT%H:%M:%S%z')"

MODE=""                    # diagnose|plan|dry-run|apply|rollback|list-runs|help
RISK_LEVEL="safe"          # safe|medium|high|all
ASSUME_YES=0
NON_INTERACTIVE=0
DEEP_SCAN=0
DU_TIMEOUT_SEC=3           # du 统计单个目录超时秒数，避免卡住
BASE_DIR_OVERRIDE=""
RUN_ID_OVERRIDE=""
DRY_RUN=0
QUIET=0
COLOR=1
SIMPLE_MENU=0

BASE_DIR=""
RUN_ID=""
RUN_DIR=""
STATE_DIR=""
BACKUP_DIR=""
ROLLBACK_DIR=""
DIFF_DIR=""
LOG_FILE=""
REPORT_FILE=""
PLAN_FILE=""
STDOUT_SUMMARY_FILE=""
LOCK_FILE=""
LOCK_FD=""
MENU_RET=""

APT_HEALTH_OK=1
APT_HEALTH_HELD_COUNT=0
APT_HEALTH_PARTIAL_COUNT=0
APT_HEALTH_AUDIT_COUNT=0
APT_HEALTH_DETAILS_FILE=""

c_reset="" c_red="" c_yellow="" c_green="" c_blue="" c_dim=""
init_colors() {
  if [[ "$COLOR" -eq 1 ]] && [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    c_reset=$'\033[0m'
    c_red=$'\033[31m'
    c_yellow=$'\033[33m'
    c_green=$'\033[32m'
    c_blue=$'\033[34m'
    c_dim=$'\033[2m'
  else
    c_reset="" c_red="" c_yellow="" c_green="" c_blue="" c_dim=""
  fi
}

ts() { date +'%Y-%m-%d %H:%M:%S%z'; }

log_raw() {
  local line="${1:-}"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s %s\n' "$(ts)" "$line" >>"$LOG_FILE" || true
  fi
  return 0
}

log() {
  local msg="$*"
  log_raw "[INFO] $msg"
  [[ "$QUIET" -eq 0 ]] && printf '%s%s%s\n' "$c_green" "$msg" "$c_reset" >&2
}

warn() {
  local msg="$*"
  log_raw "[WARN] $msg"
  printf '%s%s%s\n' "$c_yellow" "WARN: $msg" "$c_reset" >&2
}

err() {
  local msg="$*"
  log_raw "[ERROR] $msg"
  printf '%s%s%s\n' "$c_red" "ERROR: $msg" "$c_reset" >&2
}

die() {
  err "$*"
  err "Run directory: ${RUN_DIR:-"(not initialized)"}"
  exit 1
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
is_tty() { [[ -t 0 ]] && [[ -t 1 ]]; }

trim() { awk '{$1=$1; print}' <<<"${1:-}"; }

menu_select() {
  # Usage: menu_select "prompt" "opt1" "opt2" ...
  # Returns: selected index in $MENU_RET
  local prompt="$1"; shift
  local -a options=( "$@" )
  local selected=0
  local key="" k2=""
  local i=0

  local can_tput=0
  if is_tty && has_cmd tput; then
    if tput sc >/dev/null 2>&1 && tput rc >/dev/null 2>&1 && tput el >/dev/null 2>&1; then
      can_tput=1
    fi
  fi

  if (( can_tput == 0 )); then
    menu_select_simple "$prompt" "${options[@]}"
    return 0
  fi

  printf "%s\n" "$prompt"
  if ! tput sc 2>/dev/null; then
    menu_select_simple "$prompt" "${options[@]}"
    return 0
  fi
  while true; do
    if ! tput rc 2>/dev/null; then
      menu_select_simple "$prompt" "${options[@]}"
      return 0
    fi
    for i in "${!options[@]}"; do
      if ! tput el 2>/dev/null; then
        menu_select_simple "$prompt" "${options[@]}"
        return 0
      fi
      if (( i == selected )); then
        printf "> %s\n" "${options[$i]}"
      else
        printf "  %s\n" "${options[$i]}"
      fi
    done

    IFS= read -rsn1 key || true
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 k2 || true
      key+="$k2"
      case "$key" in
        $'\x1b[A') selected=$((selected - 1)) ;;
        $'\x1b[B') selected=$((selected + 1)) ;;
      esac
      if (( selected < 0 )); then selected=$((${#options[@]} - 1)); fi
      if (( selected >= ${#options[@]} )); then selected=0; fi
    elif [[ "$key" == "" || "$key" == $'\n' || "$key" == $'\r' ]]; then
      MENU_RET="$selected"
      printf "\n"
      return 0
    fi
  done
  return 0
}

menu_select_simple() {
  local prompt="$1"; shift
  local -a options=( "$@" )
  local selected=0
  local i=0
  printf "%s\n" "$prompt"
  for i in "${!options[@]}"; do
    printf "  [%d] %s\n" "$i" "${options[$i]}"
  done
  printf "Choose index: "
  read -r selected || true
  if [[ ! "$selected" =~ ^[0-9]+$ ]] || (( selected < 0 || selected >= ${#options[@]} )); then
    selected=0
  fi
  MENU_RET="$selected"
  return 0
}

prompt_yn() {
  # Usage: prompt_yn "Question" "default" (default: y|n)
  local q="$1"
  local def="${2:-n}"
  local ans=""
  local hint="[y/N]"
  [[ "$def" == "y" ]] && hint="[Y/n]"

  while true; do
    printf "%s %s " "$q" "$hint"
    read -r ans || true
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      ans="$def"
    fi
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf "Please answer y or n.\n" ;;
    esac
  done
}

detect_container() {
  if [[ -f /.dockerenv ]]; then echo "docker"; return 0; fi
  if has_cmd systemd-detect-virt; then
    local out
    out="$(systemd-detect-virt -c 2>/dev/null || true)"
    if [[ -n "$out" ]] && [[ "$out" != "none" ]]; then echo "$out"; return 0; fi
  fi
  if [[ -f /proc/1/cgroup ]] && grep -qiE '(docker|kubepods|containerd|lxc)' /proc/1/cgroup; then
    echo "cgroup-container"; return 0
  fi
  echo "none"
}

detect_init() {
  local comm=""
  comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"
  case "$comm" in
    systemd) echo "systemd" ;;
    init)
      if [[ -f /sbin/openrc ]] || has_cmd rc-service; then echo "openrc"; else echo "sysvinit"; fi ;;
    *)
      if [[ -d /run/systemd/system ]] && has_cmd systemctl; then echo "systemd"; else echo "unknown"; fi ;;
  esac
}

OS_ID="unknown"
OS_NAME="unknown"
OS_PRETTY="unknown"
OS_VERSION_ID="unknown"
OS_VERSION_CODENAME=""
load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_NAME}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  elif has_cmd lsb_release; then
    OS_ID="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
    OS_PRETTY="$(lsb_release -sd 2>/dev/null || echo unknown)"
    OS_VERSION_ID="$(lsb_release -sr 2>/dev/null || echo unknown)"
  fi
}

detect_pkg_mgr() {
  if has_cmd apt-get && has_cmd dpkg; then echo "apt"; return 0; fi
  if has_cmd dnf; then echo "dnf"; return 0; fi
  if has_cmd yum; then echo "yum"; return 0; fi
  if has_cmd zypper; then echo "zypper"; return 0; fi
  if has_cmd pacman; then echo "pacman"; return 0; fi
  if has_cmd apk; then echo "apk"; return 0; fi
  echo "unknown"
}

PKG_MGR="unknown"
SYSTEMD_AVAILABLE=0
init_systemd_flag() {
  if [[ "$(detect_init)" == "systemd" ]] && has_cmd systemctl && [[ -d /run/systemd/system ]]; then
    SYSTEMD_AVAILABLE=1
  else
    SYSTEMD_AVAILABLE=0
  fi
}

mkdir_p() {
  local d
  for d in "$@"; do
    [[ -n "$d" ]] || continue
    if [[ -d "$d" ]]; then
      continue
    fi
    if ! mkdir -p "$d"; then
      err "Failed to create directory: $d"
      return 1
    fi
  done
}

ensure_writable_dir() {
  local dir="$1"
  [[ -n "$dir" ]] || return 1
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 1
  fi
  local probe="$dir/.writetest.$$"
  if ! : >"$probe" 2>/dev/null; then
    return 1
  fi
  rm -f "$probe" 2>/dev/null || true
  return 0
}

acquire_lock() {
  local mode="$1"
  local lock_file="$2"

  [[ -n "$lock_file" ]] || die "Lock file path missing."
  LOCK_FILE="$lock_file"

  mkdir_p "$(dirname "$LOCK_FILE")"
  if ! has_cmd flock; then
    warn "flock not found; cannot enforce concurrency lock."
    return 0
  fi

  if ! exec {LOCK_FD}>"$LOCK_FILE"; then
    die "Failed to open lock file: $LOCK_FILE (check permissions or bash version)."
  fi
  if ! flock -n "$LOCK_FD"; then
    die "Another $PROG $mode is in progress (lock: $LOCK_FILE)."
  fi
  log "Acquired lock: $LOCK_FILE"
}

release_lock() {
  if [[ -n "${LOCK_FD:-}" ]] && has_cmd flock; then
    flock -u "$LOCK_FD" || true
    eval "exec ${LOCK_FD}>&-"
  fi
}

is_managed_path() {
  # dry-run 允许写入 RUN_DIR（用于生成计划/报告/rollback），禁止写系统路径
  local p="$1"
  [[ -n "${RUN_DIR:-}" ]] || return 1
  case "$p" in
    "$RUN_DIR"/*|"$RUN_DIR") return 0 ;;
    *) return 1 ;;
  esac
}

write_file() {
  local path="$1"
  local content="$2"

  if [[ "$DRY_RUN" -eq 1 ]] && ! is_managed_path "$path"; then
    log "[DRY-RUN] Would write file: $path"
    return 0
  fi

  mkdir_p "$(dirname "$path")"
  printf '%b' "$content" >"$path"
}

append_file() {
  local path="$1"
  local content="$2"

  if [[ "$DRY_RUN" -eq 1 ]] && ! is_managed_path "$path"; then
    log "[DRY-RUN] Would append file: $path"
    return 0
  fi

  mkdir_p "$(dirname "$path")"
  printf '%b' "$content" >>"$path"
}

capture_file_snapshot() {
  local src="$1"
  local label="$2"
  [[ -n "${STATE_DIR:-}" ]] || die "capture_file_snapshot called before init_run"
  local snap="$STATE_DIR/${label}.before"
  if [[ -e "$src" || -L "$src" ]]; then
    cp -a "$src" "$snap" 2>>"${LOG_FILE:-/dev/null}" || true
  else
    : >"$snap"
  fi
  printf '%s' "$snap"
}

record_diff_file() {
  local label="$1"
  local before="$2"
  local after="$3"
  [[ -n "${DIFF_DIR:-}" ]] || return 0
  if ! has_cmd diff; then
    warn "diff not found; skip diff for $label"
    return 0
  fi
  mkdir_p "$DIFF_DIR"
  diff -u "$before" "$after" >"$DIFF_DIR/${label}.diff" || true
}

write_file_with_diff() {
  local target="$1"
  local desired="$2"
  local label="$3"
  local before
  before="$(capture_file_snapshot "$target" "$label")"
  local after="$STATE_DIR/${label}.after"
  write_file "$after" "$desired"
  write_file "$target" "$desired"
  record_diff_file "$label" "$before" "$after"
}

backup_file() {
  # 备份单个文件到 BACKUP_DIR，保持绝对路径结构：/etc/foo -> $BACKUP_DIR/etc/foo
  # 重要：即使备份失败（权限/不存在），也不应让 plan/diagnose 直接退出。
  local src="$1"
  [[ -n "${BACKUP_DIR:-}" ]] || die "backup_file called before init_run"
  if [[ -e "$src" || -L "$src" ]]; then
    local dst="$BACKUP_DIR${src}"
    mkdir_p "$(dirname "$dst")"
    if cp -a "$src" "$dst" 2>>"${LOG_FILE:-/dev/null}"; then
      log "Backed up: $src -> $dst"
      return 0
    else
      warn "Backup failed (permission/IO?): $src -> $dst"
      return 1
    fi
  fi
  return 1
}

run_cmd() {
  local -a cmd=( "$@" )
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] ${cmd[*]}"
    return 0
  fi
  log "RUN: ${cmd[*]}"
  local rc=0
  if [[ -n "${LOG_FILE:-}" ]]; then
    set +e
    "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    set -e
  else
    "${cmd[@]}"
    rc=$?
  fi
  return "$rc"
}

run_cmd_c() {
  local -a cmd=( "$@" )
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN][C] ${cmd[*]}"
    return 0
  fi
  log "RUN[C]: ${cmd[*]}"
  local rc=0
  if [[ -n "${LOG_FILE:-}" ]]; then
    set +e
    LC_ALL=C LANG=C "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
    set -e
  else
    LC_ALL=C LANG=C "${cmd[@]}"
    rc=$?
  fi
  return "$rc"
}

on_err() {
  local line="$1"
  local cmd="${BASH_COMMAND:-unknown}"
  set +e
  err "Unhandled error at line $line: $cmd. See log: ${LOG_FILE:-"(no log)"}"
  set -e
}
trap 'on_err $LINENO' ERR
trap 'release_lock' EXIT

usage() {
  cat <<'USAGE'
用法：
  sudo ./ubuntu-tune.sh [子命令] [选项]

子命令：
  plan            诊断 + 生成计划（默认、安全、只读）
  diagnose        只做诊断（只读）
  dry-run         生成计划 + 演练 apply（不改系统）
  apply           生成计划并应用（默认仅 safe 风险项；可 --risk-level 调整）
  rollback        回滚到某次 apply 之前（默认回滚最近一次成功 apply）
  list-runs       列出历史运行记录（run directories）
  help            显示帮助

常用选项：
  --risk-level <safe|medium|high|all>     apply 时选择风险等级（默认 safe）
  -y, --yes                                apply 时无需二次确认
  --non-interactive                        禁用交互菜单/提示（适合自动化）
  --deep-scan                              更深/更慢的空间扫描（du）
  --base-dir <path>                        覆盖默认运行目录
  --run-id <id>                            rollback 指定某次运行 ID
  --dry-run                                apply 的演练模式（不改系统）
  --no-color                               关闭彩色输出
  -q, --quiet                              控制台少输出（日志仍完整）
  --simple-menu                            使用数字菜单（不使用方向键）

环境变量：
  UBUNTU_TUNE_ACTIONS_DIR=<dir[:dir]>      额外动作模块目录（*.sh）

示例：
  ./ubuntu-tune.sh                         # 交互菜单；默认计划模式
  ./ubuntu-tune.sh plan --deep-scan
  sudo ./ubuntu-tune.sh apply --risk-level safe -y
  sudo ./ubuntu-tune.sh rollback
  sudo ./ubuntu-tune.sh rollback --run-id 20260109-123000-12345
USAGE
}

parse_args() {
  local -a positional=()
  while (($#)); do
    case "$1" in
      plan|diagnose|dry-run|apply|rollback|list-runs|help) MODE="$1"; shift ;;
      --risk-level) RISK_LEVEL="${2:-}"; shift 2 ;;
      --risk-level=*) RISK_LEVEL="${1#*=}"; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --deep-scan) DEEP_SCAN=1; shift ;;
      --base-dir) BASE_DIR_OVERRIDE="${2:-}"; shift 2 ;;
      --base-dir=*) BASE_DIR_OVERRIDE="${1#*=}"; shift ;;
      --run-id) RUN_ID_OVERRIDE="${2:-}"; shift 2 ;;
      --run-id=*) RUN_ID_OVERRIDE="${1#*=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-color) COLOR=0; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      --simple-menu) SIMPLE_MENU=1; shift ;;
      -h|--help) MODE="help"; shift ;;
      --) shift; positional+=( "$@" ); break ;;
      -*) die "Unknown option: $1 (use --help)" ;;
      *) positional+=( "$1" ); shift ;;
    esac
  done

  if [[ -z "$MODE" ]] && ((${#positional[@]})); then
    case "${positional[0]}" in
      plan|diagnose|dry-run|apply|rollback|list-runs|help) MODE="${positional[0]}"; positional=( "${positional[@]:1}" ) ;;
    esac
  fi

  [[ -n "$MODE" ]] || MODE="plan"

  case "$RISK_LEVEL" in safe|medium|high|all) ;; *) die "--risk-level must be one of: safe|medium|high|all (got: $RISK_LEVEL)" ;; esac
}

default_base_dir() {
  if is_root; then
    echo "/var/lib/${PROG}"
  else
    local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
    echo "${state_home}/${PROG}"
  fi
}

init_base_dir() {
  BASE_DIR="${BASE_DIR_OVERRIDE:-"$(default_base_dir)"}"
  if ensure_writable_dir "$BASE_DIR"; then
    return 0
  fi

  if [[ -n "$BASE_DIR_OVERRIDE" ]]; then
    die "Base dir not writable: $BASE_DIR (from --base-dir)."
  fi

  local alt="/var/tmp/${PROG}"
  local fallback=""
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    fallback="${XDG_STATE_HOME}/${PROG}"
  else
    fallback="${HOME:-/root}/.local/state/${PROG}"
  fi

  if ensure_writable_dir "$alt"; then
    warn "Base dir not writable: $BASE_DIR; using fallback: $alt"
    BASE_DIR="$alt"
    return 0
  fi
  if ensure_writable_dir "$fallback"; then
    warn "Base dir not writable: $BASE_DIR; using fallback: $fallback"
    BASE_DIR="$fallback"
    return 0
  fi

  die "Base dir not writable: $BASE_DIR (also tried $alt and $fallback). Use --base-dir."
}

init_run() {
  init_colors
  load_os_release
  PKG_MGR="$(detect_pkg_mgr)"
  init_systemd_flag

  [[ -n "${BASE_DIR:-}" ]] || init_base_dir
  mkdir_p "$BASE_DIR/runs"

  local ts
  ts="$(date +'%Y%m%d-%H%M%S')"
  RUN_ID="${ts}-$$-$RANDOM"
  RUN_DIR="$BASE_DIR/runs/$RUN_ID"
  STATE_DIR="$RUN_DIR/state"
  BACKUP_DIR="$RUN_DIR/backup"
  ROLLBACK_DIR="$RUN_DIR/rollback.d"
  DIFF_DIR="$RUN_DIR/diff"
  LOG_FILE="$RUN_DIR/${PROG}.log"
  REPORT_FILE="$RUN_DIR/report.md"
  PLAN_FILE="$RUN_DIR/plan.md"
  STDOUT_SUMMARY_FILE="$RUN_DIR/summary.txt"

  mkdir_p "$RUN_DIR" "$STATE_DIR" "$BACKUP_DIR" "$ROLLBACK_DIR" "$DIFF_DIR"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true

  log "=== $PROG $SCRIPT_VERSION ==="
  log "Mode: $MODE (risk-level=$RISK_LEVEL dry-run=$DRY_RUN)"
  log "Run ID: $RUN_ID"
  log "OS: $OS_PRETTY (id=$OS_ID version=$OS_VERSION_ID codename=$OS_VERSION_CODENAME)"
  log "PkgMgr: $PKG_MGR, init=$(detect_init), container=$(detect_container)"

  write_file "$STATE_DIR/meta.env" "RUN_ID=$RUN_ID\nSTART_TIME=$NOW_ISO\nMODE=$MODE\nRISK_LEVEL=$RISK_LEVEL\n"
  init_actions
}

report_h1() { append_file "$REPORT_FILE" "\n# $*\n"; }
report_h2() { append_file "$REPORT_FILE" "\n## $*\n"; }
report_p()  { append_file "$REPORT_FILE" "\n$*\n"; }
report_code_block() {
  local lang="$1"; shift
  append_file "$REPORT_FILE" "\n\`\`\`${lang}\n"
  append_file "$REPORT_FILE" "$*\n"
  append_file "$REPORT_FILE" "\`\`\`\n"
}

human_bytes() {
  local b="${1:-0}"
  if has_cmd numfmt; then
    numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b}B"
  else
    if (( b > 1024*1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.2fGiB", b/1024/1024/1024}'
    elif (( b > 1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.2fMiB", b/1024/1024}'
    elif (( b > 1024 )); then awk -v b="$b" 'BEGIN{printf "%.2fKiB", b/1024}'
    else echo "${b}B"; fi
  fi
}

du_bytes() {
  local path="$1"
  [[ -e "$path" ]] || { echo "0"; return 0; }

  local out="" rc=0
  if has_cmd timeout; then
    set +e
    out="$(timeout "${DU_TIMEOUT_SEC}s" du -B1 -s -x "$path" 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then awk '{print $1}' <<<"$out"; return 0; fi
    [[ $rc -eq 124 ]] && return 124
  else
    out="$(du -B1 -s -x "$path" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]] && [[ -n "$out" ]]; then awk '{print $1}' <<<"$out"; return 0; fi
  fi

  if has_cmd timeout; then
    set +e
    out="$(timeout "${DU_TIMEOUT_SEC}s" du -sk "$path" 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then awk '{print $1*1024}' <<<"$out"; return 0; fi
    [[ $rc -eq 124 ]] && return 124
  else
    out="$(du -sk "$path" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]] && [[ -n "$out" ]]; then awk '{print $1*1024}' <<<"$out"; return 0; fi
  fi

  return 1
}

collect_system_summary() {
  report_h1 "ubuntu-tune 报告"
  report_p "- Run ID: \`$RUN_ID\`"
  report_p "- 时间: \`$NOW_ISO\`"
  report_p "- 模式: \`$MODE\`（risk-level=\`$RISK_LEVEL\`，dry-run=\`$DRY_RUN\`）"
  report_p "- 系统: \`$OS_PRETTY\`（id=\`$OS_ID\` version=\`$OS_VERSION_ID\` codename=\`$OS_VERSION_CODENAME\`）"
  report_p "- 内核: \`$(uname -r 2>/dev/null || echo unknown)\`  架构: \`$(uname -m 2>/dev/null || echo unknown)\`"
  report_p "- init: \`$(detect_init)\`  systemd可用: \`$SYSTEMD_AVAILABLE\`"
  report_p "- 容器/虚拟化: \`$(detect_container)\`"
  report_p "- 包管理器: \`$PKG_MGR\`"
  if has_cmd uptime; then report_p "- Uptime: \`$(uptime -p 2>/dev/null || true)\`"; fi
}

collect_storage_summary() {
  report_h2 "存储概览"
  if has_cmd df; then report_code_block "text" "$(df -hT 2>/dev/null || true)"; fi

  report_p "关键目录占用（单文件系统，带超时保护；用于定位大头）："
  local paths=(
    "/var/log"
    "/var/cache"
    "/var/cache/apt"
    "/var/lib/apt/lists"
    "/var/lib/snapd"
    "/var/lib/docker"
    "/snap"
    "/tmp"
  )

  local out="" p b hb
  for p in "${paths[@]}"; do
    if b="$(du_bytes "$p")"; then hb="$(human_bytes "$b")"; else hb="(unknown/timeout)"; fi
    out+=$(printf "%-35s %16s\n" "$p" "$hb")$'\n'
  done
  report_code_block "text" "$out"

  if [[ "$DEEP_SCAN" -eq 1 ]]; then
    report_h2 "深度扫描（可能较慢）"
    if has_cmd du; then
      report_p "根目录一级目录占用（du -xhd1 /）："
      if has_cmd timeout; then
        report_code_block "text" "$(timeout 30s du -xhd1 / 2>/dev/null | sort -h || true)"
      else
        report_code_block "text" "$(du -xhd1 / 2>/dev/null | sort -h || true)"
      fi
    else
      report_p "未找到 du，跳过深度扫描。"
    fi
  fi
}

apt_health_check() {
  APT_HEALTH_OK=1
  APT_HEALTH_HELD_COUNT=0
  APT_HEALTH_PARTIAL_COUNT=0
  APT_HEALTH_AUDIT_COUNT=0
  APT_HEALTH_DETAILS_FILE="$STATE_DIR/apt.health.report"
  : >"$APT_HEALTH_DETAILS_FILE"

  local holds=""
  if has_cmd apt-mark; then
    holds="$(apt-mark showhold 2>/dev/null || true)"
  fi
  if [[ -n "$holds" ]]; then
    APT_HEALTH_HELD_COUNT="$(printf '%s\n' "$holds" | wc -l | tr -d ' ')"
    APT_HEALTH_OK=0
    printf 'Held packages (%s):\n%s\n\n' "$APT_HEALTH_HELD_COUNT" "$holds" >>"$APT_HEALTH_DETAILS_FILE"
  else
    printf 'Held packages: none\n\n' >>"$APT_HEALTH_DETAILS_FILE"
  fi

  local audit=""
  if has_cmd dpkg; then
    audit="$(dpkg --audit 2>/dev/null || true)"
  fi
  if [[ -n "$audit" ]]; then
    APT_HEALTH_AUDIT_COUNT="$(printf '%s\n' "$audit" | wc -l | tr -d ' ')"
    APT_HEALTH_OK=0
    printf 'DPKG audit (dpkg --audit):\n%s\n\n' "$audit" >>"$APT_HEALTH_DETAILS_FILE"
  else
    printf 'DPKG audit: clean\n\n' >>"$APT_HEALTH_DETAILS_FILE"
  fi

  local partial=""
  if has_cmd dpkg; then
    partial="$(dpkg -l 2>/dev/null | awk '$1 ~ /^(iU|iF|iH|iW|iT|iQ)$/ {print $1" "$2}' || true)"
  fi
  if [[ -n "$partial" ]]; then
    APT_HEALTH_PARTIAL_COUNT="$(printf '%s\n' "$partial" | wc -l | tr -d ' ')"
    APT_HEALTH_OK=0
    printf 'Partial installs:\n%s\n\n' "$partial" >>"$APT_HEALTH_DETAILS_FILE"
  else
    printf 'Partial installs: none\n\n' >>"$APT_HEALTH_DETAILS_FILE"
  fi
}

collect_pkg_summary() {
  report_h2 "包/软件状态"
  case "$PKG_MGR" in
    apt)
      if has_cmd dpkg-query; then
        local cnt
        cnt="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
        report_p "- 已安装包数量（dpkg）：\`$cnt\`"
      fi
      if has_cmd apt-get; then
        local up=""
        if up="$(LC_ALL=C LANG=C apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')"; then
          :
        else
          warn "apt-get -s upgrade failed; upgrade count unknown."
          up="unknown"
        fi
        [[ -n "$up" ]] || up="0"
        report_p "- 可升级包数量（模拟）：\`$up\`（仅提示，不会自动升级）"
      fi
      apt_health_check
      if [[ "$APT_HEALTH_OK" -eq 1 ]]; then
        report_p "- APT 健康检查：OK"
      else
        report_p "- APT 健康检查：发现问题（held=$APT_HEALTH_HELD_COUNT partial=$APT_HEALTH_PARTIAL_COUNT audit=$APT_HEALTH_AUDIT_COUNT）"
        report_code_block "text" "$(cat "$APT_HEALTH_DETAILS_FILE" 2>/dev/null || true)"
      fi
      ;;
    *)
      report_p "- 当前发行版包管理器：\`$PKG_MGR\`（本脚本对 apt/dpkg 支持最完整）"
      ;;
  esac
}

collect_service_summary() {
  report_h2 "服务/启动状态"
  if [[ "$SYSTEMD_AVAILABLE" -eq 1 ]]; then
    report_p "systemd 失败单元（如有）："
    report_code_block "text" "$(systemctl --failed --no-pager 2>/dev/null || true)"
  else
    report_p "非 systemd 环境，跳过 systemd 单元检查。"
  fi
}

risk_rank() {
  case "$1" in safe) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; all) echo 99 ;; *) echo 99 ;; esac
}
risk_allows() {
  local selected="$1" item="$2"
  [[ "$selected" == "all" ]] && return 0
  (( $(risk_rank "$item") <= $(risk_rank "$selected") ))
}

declare -a ACTION_IDS=()

register_action() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  local existing
  for existing in "${ACTION_IDS[@]}"; do
    [[ "$existing" == "$id" ]] && return 0
  done
  ACTION_IDS+=( "$id" )
}

load_action_modules() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local -a dirs=()
  dirs+=( "$script_dir/actions.d" )
  if [[ -n "${UBUNTU_TUNE_ACTIONS_DIR:-}" ]]; then
    local -a extra_dirs
    IFS=':' read -r -a extra_dirs <<<"$UBUNTU_TUNE_ACTIONS_DIR"
    dirs+=( "${extra_dirs[@]}" )
  fi
  dirs+=( "$BASE_DIR/actions.d" )

  local d f
  local nullglob_state=""
  nullglob_state="$(shopt -p nullglob 2>/dev/null || true)"
  shopt -s nullglob
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.sh; do
      [[ -n "$f" ]] || continue
      log "Loading action module: $f"
      # shellcheck disable=SC1090
      source "$f"
    done
  done
  if [[ -n "$nullglob_state" ]]; then
    eval "$nullglob_state"
  else
    shopt -u nullglob
  fi
}

init_actions() {
  ACTION_IDS=()
  register_action "apt_autoremove"
  register_action "dpkg_purge_rc_conffiles"
  register_action "apt_conf_tuning_dropin"
  register_action "apt_repair_broken"
  register_action "systemd_enable_fstrim_timer"
  register_action "systemd_journald_limits_dropin"
  register_action "sysctl_swappiness_dropin"
  load_action_modules
}

action_call() {
  local id="$1" fn="$2"; shift 2
  local f="action_${id}_${fn}"
  declare -F "$f" >/dev/null 2>&1 || die "Internal error: missing function $f"
  "$f" "$@"
}

ACTION_STATUS="" ACTION_SUMMARY="" ACTION_DETAILS="" ACTION_EST_BYTES=""
reset_action_result() { ACTION_STATUS=""; ACTION_SUMMARY=""; ACTION_DETAILS=""; ACTION_EST_BYTES=""; }

ROLLBACK_SEQ=0
add_rollback_block() {
  local id="$1" src="$2"
  ((++ROLLBACK_SEQ))
  local dst="$ROLLBACK_DIR/$(printf '%04d-%s.sh' "$ROLLBACK_SEQ" "$id")"
  cp -a "$src" "$dst"
  chmod 700 "$dst" || true
  log "Registered rollback block: $(basename "$dst")"
}

generate_rollback_sh() {
  local rb="$RUN_DIR/rollback.sh"
  cat >"$rb" <<'RBEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$RUN_DIR/rollback.log"
: >"$LOG_FILE"

ts() { date +'%Y-%m-%d %H:%M:%S%z'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

rb_run() {
  local -a cmd=( "$@" )
  log "RUN: ${cmd[*]}"
  local rc=0
  set +e
  "${cmd[@]}" >>"$LOG_FILE" 2>&1
  rc=$?
  set -e
  return "$rc"
}

rb_restore_from_backup() {
  local target="$1"
  local backup="$RUN_DIR/backup${target}"
  if [[ -e "$backup" || -L "$backup" ]]; then
    rb_run mkdir -p "$(dirname "$target")"
    if [[ -e "$target" || -L "$target" ]]; then
      rb_run rm -rf -- "$target"
    fi
    rb_run cp -a -- "$backup" "$target"
    log "Restored: $target"
  else
    log "No backup for $target (skip restore)"
  fi
}

rb_remove_if_exists() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    rb_run rm -rf -- "$target"
    log "Removed: $target"
  fi
}

main() {
  if ! is_root; then
    log "ERROR: rollback must be run as root."
    exit 1
  fi

  log "=== ubuntu-tune rollback ==="
  log "Run dir: $RUN_DIR"

  local dir="$RUN_DIR/rollback.d"
  if [[ ! -d "$dir" ]]; then
    log "No rollback.d directory found. Nothing to do."
    exit 0
  fi

  local failures=0
  while IFS= read -r f; do
    log ">>> rollback block: $(basename "$f")"
    if ! ( set -Eeuo pipefail; source "$f" ); then
      log "WARN: rollback block failed: $f"
      failures=1
    fi
  done < <(ls -1 "$dir"/*.sh 2>/dev/null | sort -r)

  if [[ "$failures" -eq 0 ]]; then
    log "Rollback completed successfully."
  else
    log "Rollback completed with failures. Inspect: $LOG_FILE"
  fi
  exit "$failures"
}
main "$@"
RBEOF
  chmod 700 "$rb" || true
  log "Generated rollback entrypoint: $rb"
}

apt_lock_check() {
  [[ "$PKG_MGR" == "apt" ]] || return 0
  if ! has_cmd flock; then
    if has_cmd pgrep && pgrep -x apt-get >/dev/null 2>&1; then return 1; fi
    if has_cmd pgrep && pgrep -x apt >/dev/null 2>&1; then return 1; fi
    if has_cmd pgrep && pgrep -x dpkg >/dev/null 2>&1; then return 1; fi
    return 0
  fi

  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock)
  local lf
  for lf in "${locks[@]}"; do
    if [[ -e "$lf" ]]; then
      exec {fd}>"$lf" || continue
      if ! flock -n "$fd"; then return 1; fi
      flock -u "$fd" || true
      eval "exec ${fd}>&-"
    fi
  done
  return 0
}

# -------- Action: apt_autoremove --------
action_apt_autoremove_title() { echo "APT 清理不再需要的依赖（autoremove --purge）"; }
action_apt_autoremove_risk() { echo "safe"; }
action_apt_autoremove_supports() { [[ "$PKG_MGR" == "apt" ]] && has_cmd apt-get && has_cmd dpkg; }

action_apt_autoremove_inspect() {
  reset_action_result
  if ! action_apt_autoremove_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="当前系统不是 apt/dpkg，跳过。"; return 0
  fi
  if [[ "${APT_HEALTH_OK:-1}" -ne 1 ]]; then
    ACTION_STATUS="blocked"; ACTION_SUMMARY="APT 健康检查发现问题（held/partial/audit）。请先修复。"; return 0
  fi

  local out pkgs_file
  pkgs_file="$STATE_DIR/apt_autoremove.packages"
  : >"$pkgs_file"

  out="$(LC_ALL=C LANG=C apt-get -s autoremove --purge 2>/dev/null || true)"
  awk '/^Remv /{print $2}' <<<"$out" | sort -u >"$pkgs_file" || true

  local count
  count="$(wc -l <"$pkgs_file" | tr -d ' ' || echo 0)"
  if (( count == 0 )); then
    ACTION_STATUS="noop"; ACTION_SUMMARY="没有可 autoremove 的包。"; return 0
  fi

  ACTION_STATUS="applicable"
  ACTION_SUMMARY="可移除 $count 个自动安装且不再需要的包（可回滚：重新安装）。"
}

action_apt_autoremove_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then log "Skip (status=$ACTION_STATUS): apt_autoremove"; return 0; fi
  if [[ "$DRY_RUN" -eq 0 ]] && ! apt_lock_check; then
    die "APT/Dpkg is locked (another package process is running). Please retry later."
  fi

  local rb_block="$STATE_DIR/rb_apt_autoremove.sh"
  cat >"$rb_block" <<'EOF'
# rollback: apt_autoremove
if command -v apt-get >/dev/null 2>&1; then
  pkgs_file="$RUN_DIR/state/apt_autoremove.packages"
  if [[ -s "$pkgs_file" ]]; then
    mapfile -t pkgs <"$pkgs_file" || true
    if ((${#pkgs[@]})); then
      rb_run env DEBIAN_FRONTEND=noninteractive apt-get -y install "${pkgs[@]}"
    fi
  fi
else
  log "apt-get not found; cannot rollback apt_autoremove."
fi
EOF
  add_rollback_block "apt_autoremove" "$rb_block"

  run_cmd_c env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
  append_file "$STATE_DIR/applied.actions" "apt_autoremove\n"
}

# -------- Action: dpkg_purge_rc_conffiles --------
action_dpkg_purge_rc_conffiles_title() { echo "清理 dpkg 残留配置（rc 状态包）并备份 conffiles 以便回滚"; }
action_dpkg_purge_rc_conffiles_risk() { echo "safe"; }
action_dpkg_purge_rc_conffiles_supports() { [[ "$PKG_MGR" == "apt" ]] && has_cmd dpkg && has_cmd apt-get; }

action_dpkg_purge_rc_conffiles_inspect() {
  reset_action_result
  if ! action_dpkg_purge_rc_conffiles_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="需要 dpkg/apt-get（Ubuntu/Debian 系）。"; return 0
  fi
  if [[ "${APT_HEALTH_OK:-1}" -ne 1 ]]; then
    ACTION_STATUS="blocked"; ACTION_SUMMARY="APT 健康检查发现问题（held/partial/audit）。请先修复。"; return 0
  fi

  local pkgs_file="$STATE_DIR/dpkg_rc.packages"
  : >"$pkgs_file"
  dpkg -l 2>/dev/null | awk '$1=="rc"{print $2}' | sort -u >"$pkgs_file" || true

  local count
  count="$(wc -l <"$pkgs_file" | tr -d ' ' || echo 0)"
  if (( count == 0 )); then
    ACTION_STATUS="noop"; ACTION_SUMMARY="没有 rc 状态包（无需 purge）。"; return 0
  fi

  ACTION_STATUS="applicable"
  ACTION_SUMMARY="发现 $count 个 rc 状态包。执行 purge 前会备份其 conffiles；回滚将尽量恢复 rc 语义并还原 conffiles。"
}

dpkg_conffiles_list_for_pkg() {
  local pkg="$1"
  local info="/var/lib/dpkg/info/${pkg}.conffiles"
  if [[ -r "$info" ]]; then
    sed '/^[[:space:]]*$/d' "$info" | awk '{print $1}' | sed -n 's#^\(/.*\)#\1#p'
    return 0
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Conffiles}\n' "$pkg" 2>/dev/null \
      | sed '/^ *$/d' | awk '{print $1}' | sed -n 's#^\(/.*\)#\1#p' || true
    return 0
  fi
  return 1
}

backup_dpkg_conffiles_for_pkg() {
  local pkg="$1"
  local list_dir="$STATE_DIR/dpkg_rc_conffiles"
  mkdir_p "$list_dir"
  local list_file="$list_dir/${pkg}.paths"
  : >"$list_file"

  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ -e "$path" || -L "$path" ]]; then
      backup_file "$path" || true
      printf '%s\n' "$path" >>"$list_file"
    fi
  done < <(dpkg_conffiles_list_for_pkg "$pkg" 2>/dev/null || true)
}

action_dpkg_purge_rc_conffiles_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then
    log "Skip (status=$ACTION_STATUS): dpkg_purge_rc_conffiles"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 0 ]] && ! apt_lock_check; then
    die "APT/Dpkg is locked (another package process is running). Please retry later."
  fi

  local pkgs_file="$STATE_DIR/dpkg_rc.packages"
  log "Applying: purge rc packages (with conffiles backup + rollback metadata)"

  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    backup_dpkg_conffiles_for_pkg "$pkg"
  done <"$pkgs_file"

  local rb_block="$STATE_DIR/rb_dpkg_purge_rc.sh"
  cat >"$rb_block" <<'EOF'
# rollback: dpkg_purge_rc_conffiles
pkgs_file="$RUN_DIR/state/dpkg_rc.packages"
list_dir="$RUN_DIR/state/dpkg_rc_conffiles"
if [[ -s "$pkgs_file" ]]; then
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if command -v apt-get >/dev/null 2>&1; then
      rb_run env DEBIAN_FRONTEND=noninteractive apt-get -y install "$pkg" || true
      rb_run env DEBIAN_FRONTEND=noninteractive apt-get -y remove "$pkg" || true
    else
      log "apt-get not found; cannot restore dpkg state for $pkg (will still restore conffiles)."
    fi
    lf="$list_dir/${pkg}.paths"
    if [[ -s "$lf" ]]; then
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rb_restore_from_backup "$path"
      done <"$lf"
    fi
  done <"$pkgs_file"
fi
EOF
  add_rollback_block "dpkg_purge_rc_conffiles" "$rb_block"

  local -a batch=()
  local max_batch=50
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    batch+=( "$pkg" )
    if (( ${#batch[@]} >= max_batch )); then
      run_cmd_c env DEBIAN_FRONTEND=noninteractive apt-get -y purge "${batch[@]}"
      batch=()
    fi
  done <"$pkgs_file"
  if (( ${#batch[@]} )); then
    run_cmd_c env DEBIAN_FRONTEND=noninteractive apt-get -y purge "${batch[@]}"
  fi

  append_file "$STATE_DIR/applied.actions" "dpkg_purge_rc_conffiles\n"
}

# -------- Action: apt_conf_tuning_dropin --------
action_apt_conf_tuning_dropin_title() { echo "APT 配置优化（重试/超时/锁等待）"; }
action_apt_conf_tuning_dropin_risk() { echo "medium"; }
action_apt_conf_tuning_dropin_supports() { [[ "$PKG_MGR" == "apt" ]] && has_cmd apt-get; }

action_apt_conf_tuning_dropin_inspect() {
  reset_action_result
  if ! action_apt_conf_tuning_dropin_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="需要 apt-get（Ubuntu/Debian 系）。"; return 0
  fi

  local dropin="/etc/apt/apt.conf.d/99-ubuntu-tune.conf"
  local desired
  desired=$'# Managed by ubuntu-tune\nAcquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nDPkg::Lock::Timeout "30";\n'
  write_file "$STATE_DIR/apt.conf.dropin.path" "$dropin\n"
  write_file "$STATE_DIR/apt.conf.dropin.desired" "$desired"

  if [[ -e "$dropin" || -L "$dropin" ]]; then
    backup_file "$dropin" || true
    if cmp -s <(printf '%b' "$desired") "$dropin" 2>/dev/null; then
      ACTION_STATUS="already"; ACTION_SUMMARY="APT drop-in 已是目标配置。"; return 0
    fi
  fi

  ACTION_STATUS="applicable"
  ACTION_SUMMARY="将写入 $dropin，设置重试/超时/锁等待参数（可回滚）。"
}

action_apt_conf_tuning_dropin_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then
    log "Skip (status=$ACTION_STATUS): apt_conf_tuning_dropin"
    return 0
  fi
  local dropin desired
  dropin="$(cat "$STATE_DIR/apt.conf.dropin.path" 2>/dev/null | tr -d '\n')"
  desired="$(cat "$STATE_DIR/apt.conf.dropin.desired" 2>/dev/null || true)"

  local rb_block="$STATE_DIR/rb_apt_conf_dropin.sh"
  cat >"$rb_block" <<'EOF'
# rollback: apt_conf_tuning_dropin
dropin="/etc/apt/apt.conf.d/99-ubuntu-tune.conf"
if [[ -e "$RUN_DIR/backup${dropin}" || -L "$RUN_DIR/backup${dropin}" ]]; then
  rb_restore_from_backup "$dropin"
else
  rb_remove_if_exists "$dropin"
fi
EOF
  add_rollback_block "apt_conf_tuning_dropin" "$rb_block"

  backup_file "$dropin" || true
  write_file_with_diff "$dropin" "$desired" "apt.conf.dropin"
  append_file "$STATE_DIR/applied.actions" "apt_conf_tuning_dropin\n"
}

# -------- Action: apt_repair_broken --------
action_apt_repair_broken_title() { echo "修复 APT/Dpkg 异常（configure -a + fix-broken）"; }
action_apt_repair_broken_risk() { echo "medium"; }
action_apt_repair_broken_supports() { [[ "$PKG_MGR" == "apt" ]] && has_cmd dpkg && has_cmd apt-get; }

action_apt_repair_broken_inspect() {
  reset_action_result
  if ! action_apt_repair_broken_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="需要 dpkg/apt-get（Ubuntu/Debian 系）。"; return 0
  fi

  if (( APT_HEALTH_AUDIT_COUNT > 0 || APT_HEALTH_PARTIAL_COUNT > 0 )); then
    ACTION_STATUS="applicable"
    ACTION_SUMMARY="发现 dpkg audit/partial，尝试修复（可能修改包集合）。"
    return 0
  fi

  if (( APT_HEALTH_HELD_COUNT > 0 )); then
    ACTION_STATUS="blocked"
    ACTION_SUMMARY="存在 held packages，修复动作不会自动执行。"
    return 0
  fi

  ACTION_STATUS="noop"
  ACTION_SUMMARY="APT 健康 OK，无需修复。"
}

action_apt_repair_broken_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then
    log "Skip (status=$ACTION_STATUS): apt_repair_broken"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 0 ]] && ! apt_lock_check; then
    die "APT/Dpkg is locked (another package process is running). Please retry later."
  fi

  local rb_block="$STATE_DIR/rb_apt_repair_broken.sh"
  cat >"$rb_block" <<'EOF'
# rollback: apt_repair_broken
log "No automated rollback for apt_repair_broken."
EOF
  add_rollback_block "apt_repair_broken" "$rb_block"

  if ! run_cmd_c dpkg --configure -a; then
    warn "dpkg --configure -a failed; continuing with apt-get -f install."
  fi
  run_cmd_c env DEBIAN_FRONTEND=noninteractive apt-get -y -f install
  append_file "$STATE_DIR/applied.actions" "apt_repair_broken\n"
}

# -------- Action: systemd_enable_fstrim_timer --------
action_systemd_enable_fstrim_timer_title() { echo "启用 systemd fstrim.timer（SSD/支持 TRIM 的文件系统更受益）"; }
action_systemd_enable_fstrim_timer_risk() { echo "safe"; }
action_systemd_enable_fstrim_timer_supports() { [[ "$SYSTEMD_AVAILABLE" -eq 1 ]] && has_cmd systemctl; }

action_systemd_enable_fstrim_timer_inspect() {
  reset_action_result
  if ! action_systemd_enable_fstrim_timer_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="当前不是可用的 systemd 环境，跳过。"; return 0
  fi
  local load_state
  load_state="$(systemctl show -p LoadState --value fstrim.timer 2>/dev/null || echo "unknown")"
  if [[ -z "$load_state" || "$load_state" == "not-found" || "$load_state" == "unknown" ]]; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="系统中没有 fstrim.timer 单元。"; return 0
  fi
  local enabled
  enabled="$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "unknown")"
  write_file "$STATE_DIR/fstrim.enabled.before" "$enabled\n"
  if [[ "$enabled" == "enabled" ]]; then
    ACTION_STATUS="already"; ACTION_SUMMARY="fstrim.timer 已启用。"; return 0
  fi
  ACTION_STATUS="applicable"; ACTION_SUMMARY="将启用并启动 fstrim.timer（可回滚：恢复之前 enable 状态）。"
}

action_systemd_enable_fstrim_timer_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then log "Skip (status=$ACTION_STATUS): systemd_enable_fstrim_timer"; return 0; fi
  local rb_block="$STATE_DIR/rb_fstrim_timer.sh"
  cat >"$rb_block" <<'EOF'
# rollback: systemd_enable_fstrim_timer
before="$(cat "$RUN_DIR/state/fstrim.enabled.before" 2>/dev/null | tr -d '\n' || echo unknown)"
if command -v systemctl >/dev/null 2>&1; then
  case "$before" in
    enabled) rb_run systemctl enable --now fstrim.timer ;;
    *) rb_run systemctl disable --now fstrim.timer || true ;;
  esac
fi
EOF
  add_rollback_block "systemd_enable_fstrim_timer" "$rb_block"
  run_cmd systemctl enable --now fstrim.timer
  append_file "$STATE_DIR/applied.actions" "systemd_enable_fstrim_timer\n"
}

# -------- Action: systemd_journald_limits_dropin --------
action_systemd_journald_limits_dropin_title() { echo "配置 journald 日志占用上限（drop-in，可回滚）"; }
action_systemd_journald_limits_dropin_risk() { echo "medium"; }
action_systemd_journald_limits_dropin_supports() { [[ "$SYSTEMD_AVAILABLE" -eq 1 ]] && has_cmd systemctl && has_cmd journalctl; }

action_systemd_journald_limits_dropin_inspect() {
  reset_action_result
  if ! action_systemd_journald_limits_dropin_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="需要 systemd + journalctl。"; return 0
  fi
  local dropin="/etc/systemd/journald.conf.d/ubuntu-tune.conf"
  local desired
  desired=$'# Managed by ubuntu-tune\n[Journal]\n# 限制 system journal 占用。按需调整：\nSystemMaxUse=500M\nSystemMaxFileSize=50M\nRuntimeMaxUse=200M\nRuntimeMaxFileSize=25M\n'
  write_file "$STATE_DIR/journald.dropin.path" "$dropin\n"

  if [[ -e "$dropin" || -L "$dropin" ]]; then
    backup_file "$dropin" || true
    if cmp -s <(printf '%b' "$desired") "$dropin" 2>/dev/null; then
      ACTION_STATUS="already"; ACTION_SUMMARY="journald drop-in 已是目标配置。"; return 0
    fi
  fi

  local usage
  usage="$(journalctl --disk-usage 2>/dev/null || true)"
  write_file "$STATE_DIR/journald.diskusage" "$usage\n"

  ACTION_STATUS="applicable"
  ACTION_SUMMARY="将写入 $dropin 并重启 systemd-journald（中风险：改变日志保留策略；可回滚）。"
  write_file "$STATE_DIR/journald.dropin.desired" "$desired"
}

action_systemd_journald_limits_dropin_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then log "Skip (status=$ACTION_STATUS): systemd_journald_limits_dropin"; return 0; fi
  local dropin desired
  dropin="$(cat "$STATE_DIR/journald.dropin.path" 2>/dev/null | tr -d '\n')"
  desired="$(cat "$STATE_DIR/journald.dropin.desired" 2>/dev/null || true)"

  local rb_block="$STATE_DIR/rb_journald_dropin.sh"
  cat >"$rb_block" <<'EOF'
# rollback: systemd_journald_limits_dropin
dropin="/etc/systemd/journald.conf.d/ubuntu-tune.conf"
if [[ -e "$RUN_DIR/backup${dropin}" || -L "$RUN_DIR/backup${dropin}" ]]; then
  rb_restore_from_backup "$dropin"
else
  rb_remove_if_exists "$dropin"
fi
if command -v systemctl >/dev/null 2>&1; then
  rb_run systemctl restart systemd-journald || true
fi
EOF
  add_rollback_block "systemd_journald_limits_dropin" "$rb_block"

  backup_file "$dropin" || true
  write_file_with_diff "$dropin" "$desired" "journald.dropin"
  run_cmd systemctl restart systemd-journald
  append_file "$STATE_DIR/applied.actions" "systemd_journald_limits_dropin\n"
}

# -------- Action: sysctl_swappiness_dropin --------
action_sysctl_swappiness_dropin_title() { echo "可选：写入 sysctl drop-in 调整 vm.swappiness（高风险项，默认仅建议）"; }
action_sysctl_swappiness_dropin_risk() { echo "high"; }
action_sysctl_swappiness_dropin_supports() { has_cmd sysctl; }

action_sysctl_swappiness_dropin_inspect() {
  reset_action_result
  if ! action_sysctl_swappiness_dropin_supports; then
    ACTION_STATUS="unsupported"; ACTION_SUMMARY="未找到 sysctl。"; return 0
  fi
  local cur
  cur="$(sysctl -n vm.swappiness 2>/dev/null || echo "unknown")"
  write_file "$STATE_DIR/swappiness.before" "$cur\n"
  local target="20"
  write_file "$STATE_DIR/swappiness.target" "$target\n"
  local dropin="/etc/sysctl.d/99-ubuntu-tune.conf"
  write_file "$STATE_DIR/sysctl.dropin.path" "$dropin\n"

  if [[ -e "$dropin" || -L "$dropin" ]]; then
    backup_file "$dropin" || true
    if grep -qE '^vm\.swappiness=20$' "$dropin" 2>/dev/null && grep -q 'Managed by ubuntu-tune' "$dropin" 2>/dev/null; then
      ACTION_STATUS="already"; ACTION_SUMMARY="sysctl drop-in 已设置 vm.swappiness=20。"; return 0
    fi
  fi

  ACTION_STATUS="applicable"
  ACTION_SUMMARY="建议项：当前 vm.swappiness=$cur。桌面/开发机可考虑设为 $target（可能影响内存/交换行为）。可回滚。"
  ACTION_DETAILS=$'风险说明：\n- 低内存压力下过低 swappiness 可能更早触发 OOM。\n- 服务器/数据库场景默认 60 可能更合适。\n适用：交互式桌面、内存较充足、希望减少 swap 的机器。\n'
}

action_sysctl_swappiness_dropin_apply() {
  if [[ "$ACTION_STATUS" != "applicable" ]]; then log "Skip (status=$ACTION_STATUS): sysctl_swappiness_dropin"; return 0; fi
  local dropin target
  dropin="$(cat "$STATE_DIR/sysctl.dropin.path" 2>/dev/null | tr -d '\n')"
  target="$(cat "$STATE_DIR/swappiness.target" 2>/dev/null | tr -d '\n')"

  local rb_block="$STATE_DIR/rb_sysctl_swappiness.sh"
  cat >"$rb_block" <<'EOF'
# rollback: sysctl_swappiness_dropin
dropin="/etc/sysctl.d/99-ubuntu-tune.conf"
before="$(cat "$RUN_DIR/state/swappiness.before" 2>/dev/null | tr -d '\n' || echo unknown)"
if [[ -e "$RUN_DIR/backup${dropin}" || -L "$RUN_DIR/backup${dropin}" ]]; then
  rb_restore_from_backup "$dropin"
else
  rb_remove_if_exists "$dropin"
fi
if command -v sysctl >/dev/null 2>&1; then
  if [[ "$before" != "unknown" ]]; then
    rb_run sysctl -w "vm.swappiness=$before" || true
  fi
  rb_run sysctl --system || true
fi
EOF
  add_rollback_block "sysctl_swappiness_dropin" "$rb_block"

  backup_file "$dropin" || true
  write_file_with_diff "$dropin" $'# Managed by ubuntu-tune\n# 高风险：请理解该参数含义后再启用\nvm.swappiness=20\n' "sysctl.swappiness.dropin"
  run_cmd sysctl -w "vm.swappiness=$target"
  run_cmd sysctl --system || true
  append_file "$STATE_DIR/applied.actions" "sysctl_swappiness_dropin\n"
}

write_plan_header() {
  write_file "$PLAN_FILE" ""
  append_file "$PLAN_FILE" "# 计划（Plan）\n\n"
  append_file "$PLAN_FILE" "- Run ID: \`$RUN_ID\`\n"
  append_file "$PLAN_FILE" "- 时间: \`$NOW_ISO\`\n"
  append_file "$PLAN_FILE" "- 系统: \`$OS_PRETTY\`\n"
  append_file "$PLAN_FILE" "- 风险选择: \`$RISK_LEVEL\`\n"
  append_file "$PLAN_FILE" "- 说明：默认只生成计划；apply 才会真正改动系统。\n\n"
  append_file "$PLAN_FILE" "## 动作列表\n\n"
  append_file "$PLAN_FILE" "|ID|风险|状态|标题|摘要|\n"
  append_file "$PLAN_FILE" "|---|---|---|---|---|\n"
}

plan_actions() {
  write_plan_header
  local inspect_file="$STATE_DIR/inspect.tsv"
  write_file "$inspect_file" "id\trisk\tstatus\tsummary\n"
  local id title risk status summary summary_tsv
  for id in "${ACTION_IDS[@]}"; do
    title="$(action_call "$id" title)"
    risk="$(action_call "$id" risk)"
    reset_action_result
    if ! action_call "$id" supports; then
      status="unsupported"; summary="不支持该环境"
    else
      action_call "$id" inspect || true
      status="$ACTION_STATUS"; summary="$ACTION_SUMMARY"
    fi
    summary_tsv="${summary//$'\t'/ }"
    summary_tsv="${summary_tsv//$'\n'/ }"
    append_file "$inspect_file" "$id\t$risk\t$status\t$summary_tsv\n"
    summary="${summary//|/\\|}"
    append_file "$PLAN_FILE" "|$id|$risk|$status|$title|$summary|\n"
  done

  append_file "$PLAN_FILE" "\n## 额外建议（默认不自动 apply）\n\n"
  append_file "$PLAN_FILE" $'- **系统升级/安全更新**：建议定期运行 `apt update && apt upgrade`（脚本默认不做升级，避免不可逆）。\n'
  append_file "$PLAN_FILE" $'- **清空 APT 缓存**：`apt-get clean` 可释放空间，但属于不可逆/低价值回滚项，脚本默认不执行。\n'
  append_file "$PLAN_FILE" $'- **systemd journal 立即清理**：`journalctl --vacuum-time=...` 会删除旧日志（不可逆），脚本默认仅给建议。\n'
  append_file "$PLAN_FILE" "- **Snap 旧版本清理**：可省空间但恢复复杂；脚本默认不执行。\n"
}

apply_actions() {
  generate_rollback_sh
  local id title risk applied_any=0

  for id in "${ACTION_IDS[@]}"; do
    title="$(action_call "$id" title)"
    risk="$(action_call "$id" risk)"

    reset_action_result
    if ! action_call "$id" supports; then
      log "Skip unsupported: $id"; continue
    fi

    action_call "$id" inspect || true
    if [[ "$ACTION_STATUS" != "applicable" ]]; then
      log "Skip $id (status=$ACTION_STATUS)"; continue
    fi

    if ! risk_allows "$RISK_LEVEL" "$risk"; then
      log "Skip $id due to risk-level filter (item=$risk, selected=$RISK_LEVEL)"; continue
    fi

    if [[ "$risk" == "high" ]] && [[ "$ASSUME_YES" -ne 1 ]] && [[ "$NON_INTERACTIVE" -ne 1 ]]; then
      printf '%s\n' "即将应用高风险项：$id - $title" >&2
      printf '%s\n' "摘要：$ACTION_SUMMARY" >&2
      if ! prompt_yn "确认继续？" "n"; then
        warn "User skipped high-risk action: $id"
        continue
      fi
    fi

    log "APPLY: $id - $title"
    action_call "$id" apply
    applied_any=1
  done

  if [[ "$applied_any" -eq 1 ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    write_file "$RUN_DIR/success" "ok\n"
    write_file "$BASE_DIR/last_successful_run" "$RUN_ID\n"
  fi
}

cmd_diagnose_or_plan() {
  collect_system_summary
  collect_storage_summary
  collect_pkg_summary
  collect_service_summary

  if [[ "$MODE" == "plan" || "$MODE" == "dry-run" || "$MODE" == "apply" ]]; then
    report_h2 "计划与建议"
    plan_actions
    report_p "已生成计划文件：\`$PLAN_FILE\`"
  fi
}

cmd_list_runs() {
  local runs_dir="$BASE_DIR/runs"
  [[ -d "$runs_dir" ]] || { echo "No runs found under: $runs_dir"; return 0; }
  printf '%-26s %-10s %s\n' "RUN_ID" "STATUS" "PATH"
  local d id status
  while IFS= read -r d; do
    id="$(basename "$d")"
    status="plan"
    [[ -f "$d/success" ]] && status="applied"
    printf '%-26s %-10s %s\n' "$id" "$status" "$d"
  done < <(ls -1dt "$runs_dir"/* 2>/dev/null || true)
}

find_run_dir_for_rollback() {
  local id="${1:-}"
  if [[ -n "$id" ]]; then
    [[ -d "$BASE_DIR/runs/$id" ]] && { echo "$BASE_DIR/runs/$id"; return 0; }
    die "Run ID not found: $id"
  fi
  if [[ -r "$BASE_DIR/last_successful_run" ]]; then
    local last
    last="$(cat "$BASE_DIR/last_successful_run" 2>/dev/null | tr -d '\n' || true)"
    [[ -n "$last" && -d "$BASE_DIR/runs/$last" ]] && { echo "$BASE_DIR/runs/$last"; return 0; }
  fi
  die "No last successful run found. Use: rollback --run-id <id> (see list-runs)."
}

post_rollback_inspect() {
  local baseline_dir="$1"
  local baseline_id
  baseline_id="$(basename "$baseline_dir")"

  report_h2 "回滚后检查"
  report_p "- 基线 run：\`$baseline_id\`"

  if [[ "$PKG_MGR" == "apt" ]]; then
    apt_health_check
  fi
  plan_actions
  report_p "- 回滚后计划文件：\`$PLAN_FILE\`"

  local baseline_inspect="$baseline_dir/state/inspect.tsv"
  local current_inspect="$STATE_DIR/inspect.tsv"
  local diff_file="$RUN_DIR/rollback-inspect.diff"

  if [[ -f "$baseline_inspect" && -f "$current_inspect" ]]; then
    if has_cmd diff; then
      diff -u "$baseline_inspect" "$current_inspect" >"$diff_file" || true
      report_p "- inspect diff：\`$diff_file\`"
      if [[ -s "$diff_file" ]]; then
        report_code_block "diff" "$(cat "$diff_file")"
      else
        report_p "- inspect diff：无差异"
      fi
    else
      report_p "- 未找到 diff，跳过对比。"
    fi
  else
    report_p "- 未找到基线 inspect，跳过对比。"
  fi
}

cmd_rollback() {
  is_root || die "rollback requires root"
  local target_run_dir
  target_run_dir="$(find_run_dir_for_rollback "$RUN_ID_OVERRIDE")"
  local rb="$target_run_dir/rollback.sh"
  [[ -x "$rb" ]] || die "rollback.sh not found or not executable: $rb"
  report_h1 "Rollback"
  report_p "- 目标 run：\`$(basename "$target_run_dir")\`"
  report_p "- 回滚脚本：\`$rb\`"
  log "Executing rollback: $rb"
  run_cmd bash "$rb"
  post_rollback_inspect "$target_run_dir"
}

interactive_menu() {
  local rc=0

  if [[ "$SIMPLE_MENU" -eq 1 || -n "${UBUNTU_TUNE_SIMPLE_MENU:-}" ]]; then
    menu_select_simple "ubuntu-tune 交互菜单（默认安全：只诊断+计划，不会改系统）" \
      "诊断 + 生成计划（推荐，默认）" \
      "Dry-run（演练 apply，不改系统）" \
      "Apply（仅 safe 风险项）" \
      "Apply（medium 风险项也执行）" \
      "Apply（包含 high 风险项：会二次确认）" \
      "Rollback（回滚最近一次成功 apply）" \
      "List runs" \
      "退出"
  else
    set +e
    menu_select "ubuntu-tune 交互菜单（默认安全：只诊断+计划，不会改系统）" \
      "诊断 + 生成计划（推荐，默认）" \
      "Dry-run（演练 apply，不改系统）" \
      "Apply（仅 safe 风险项）" \
      "Apply（medium 风险项也执行）" \
      "Apply（包含 high 风险项：会二次确认）" \
      "Rollback（回滚最近一次成功 apply）" \
      "List runs" \
      "退出"
    rc=$?
    set -e
    if (( rc != 0 )) || [[ -z "${MENU_RET:-}" ]]; then
      warn "菜单交互异常，切换为数字选择。"
      menu_select_simple "ubuntu-tune 交互菜单（默认安全：只诊断+计划，不会改系统）" \
        "诊断 + 生成计划（推荐，默认）" \
        "Dry-run（演练 apply，不改系统）" \
        "Apply（仅 safe 风险项）" \
        "Apply（medium 风险项也执行）" \
        "Apply（包含 high 风险项：会二次确认）" \
        "Rollback（回滚最近一次成功 apply）" \
        "List runs" \
        "退出"
    fi
  fi
  local choice="$MENU_RET"
  case "$choice" in
    0) MODE="plan" ;;
    1) MODE="dry-run" ;;
    2) MODE="apply"; RISK_LEVEL="safe" ;;
    3) MODE="apply"; RISK_LEVEL="medium" ;;
    4) MODE="apply"; RISK_LEVEL="high" ;;
    5) MODE="rollback" ;;
    6) MODE="list-runs" ;;
    7)
      if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        exit 0
      fi
      if prompt_yn "确认退出？" "n"; then
        exit 0
      fi
      menu_select_simple "ubuntu-tune 交互菜单（默认安全：只诊断+计划，不会改系统）" \
        "诊断 + 生成计划（推荐，默认）" \
        "Dry-run（演练 apply，不改系统）" \
        "Apply（仅 safe 风险项）" \
        "Apply（medium 风险项也执行）" \
        "Apply（包含 high 风险项：会二次确认）" \
        "Rollback（回滚最近一次成功 apply）" \
        "List runs" \
        "退出"
      choice="$MENU_RET"
      case "$choice" in
        0) MODE="plan" ;;
        1) MODE="dry-run" ;;
        2) MODE="apply"; RISK_LEVEL="safe" ;;
        3) MODE="apply"; RISK_LEVEL="medium" ;;
        4) MODE="apply"; RISK_LEVEL="high" ;;
        5) MODE="rollback" ;;
        6) MODE="list-runs" ;;
        7) exit 0 ;;
        *) warn "无效选择，回到默认 plan"; MODE="plan" ;;
      esac
      ;;
    *) warn "无效选择，回到默认 plan"; MODE="plan" ;;
  esac
}

goto_summary() {
  {
    echo "=== $PROG summary ==="
    echo "Run ID: $RUN_ID"
    echo "Mode: $MODE"
    echo "Run dir: $RUN_DIR"
    echo "Report: $REPORT_FILE"
    [[ -f "$PLAN_FILE" ]] && echo "Plan:   $PLAN_FILE"
    [[ -f "$RUN_DIR/rollback.sh" ]] && echo "Rollback: $RUN_DIR/rollback.sh"
    echo "Log:    $LOG_FILE"
  } | tee "$STDOUT_SUMMARY_FILE" >&2
}

main() {
  parse_args "$@"

  if [[ "$MODE" == "help" ]]; then
    usage
    exit 0
  fi

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    NON_INTERACTIVE=1
  fi

  if [[ "$MODE" == "apply" ]] && [[ "$NON_INTERACTIVE" -ne 1 ]] && [[ "$ASSUME_YES" -ne 1 ]] && ! is_tty; then
    err "No TTY detected for apply. Use -y or --non-interactive to proceed."
    exit 2
  fi

  if [[ "$NON_INTERACTIVE" -ne 1 ]] && is_tty && [[ "$MODE" == "plan" ]] && [[ $# -eq 0 ]]; then
    interactive_menu
  fi

  [[ "$MODE" == "dry-run" ]] && DRY_RUN=1

  if [[ "$QUIET" -eq 0 ]]; then
    printf '%s\n' "Starting $PROG (mode=$MODE risk=$RISK_LEVEL dry-run=$DRY_RUN)" >&2
  fi

  if [[ "$MODE" == "list-runs" ]]; then
    init_base_dir
    cmd_list_runs
    exit 0
  fi

  if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
    is_root || die "$MODE requires root. Use: sudo ./$SCRIPT_NAME $MODE ..."
  fi

  init_base_dir
  if [[ "$MODE" == "apply" || "$MODE" == "rollback" ]]; then
    acquire_lock "$MODE" "$BASE_DIR/${PROG}.lock"
  fi

  init_run

  case "$MODE" in
    rollback) cmd_rollback ;;
    diagnose|plan|dry-run|apply)
      cmd_diagnose_or_plan

      if [[ "$MODE" == "dry-run" ]]; then
        report_h2 "Dry-run（演练 apply，不改系统）"
        apply_actions
        if [[ -s "$STATE_DIR/applied.actions" ]]; then
          report_p "Dry-run 期间将会执行的动作（未实际改动系统）："
          report_code_block "text" "$(cat "$STATE_DIR/applied.actions")"
          report_p "（dry-run 仍会生成 rollback.sh 作为审计材料，但无需执行。）"
        else
          report_p "Dry-run：没有动作会被执行（可能全部已是目标状态，或被风险等级过滤）。"
        fi
      fi

      if [[ "$MODE" == "apply" ]]; then
        if [[ "$ASSUME_YES" -ne 1 ]] && [[ "$NON_INTERACTIVE" -ne 1 ]]; then
          printf '%s\n' "即将应用变更（risk-level=$RISK_LEVEL）。所有变更都将写入 rollback.sh 以便回滚。" >&2
          if ! prompt_yn "确认继续 apply？" "n"; then
            warn "User aborted apply."
            report_h2 "Apply"
            report_p "**用户取消 apply，未做任何变更。**"
            goto_summary
            exit 0
          fi
        fi
        apply_actions
        report_h2 "Apply 结果"
        if [[ -s "$STATE_DIR/applied.actions" ]]; then
          report_p "本次已应用动作："
          report_code_block "text" "$(cat "$STATE_DIR/applied.actions")"
          report_p "回滚入口：\`$RUN_DIR/rollback.sh\`（也可运行：\`sudo ./$SCRIPT_NAME rollback --run-id $RUN_ID\`）"
        else
          report_p "没有动作被应用（可能全部已是目标状态，或被风险等级过滤）。"
        fi
      fi
      ;;
    *) usage; die "Unknown mode: $MODE" ;;
  esac

  goto_summary
}

main "$@"
