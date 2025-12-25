#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2.1.3"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAG=$'\033[0;35m'
NC=$'\033[0m'

if [[ ! -t 1 ]]; then
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BLUE=""; MAG=""; NC=""
fi

TEMP_DIR="${TMPDIR:-/tmp}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
UPDATE_MARKER="${CACHE_DIR}/xevo_update_done"

AUTO_YES=0
SKIP_UPDATE=0

DEFAULT_INSTALL_DIR="/data/data/com.termux/files/home/xevo"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
RELEASE_URL=""
GITHUB_REPO="soyorRin/X-EVO"

DB_USER=""
DB_PASS=""
DB_NAME="xevo"

APP_HOST="0.0.0.0"
APP_PORT="3001"

SPIN_PID=""

TTY_FD=0
HAS_TTY=0
bind_tty() {
  HAS_TTY=0
  TTY_FD=0
  if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; then
    if exec 3<>/dev/tty; then
      if [[ -n "${BASH_VERSION-}" ]]; then
        TTY_FD=3
        HAS_TTY=1
      fi
    fi
  fi
}
bind_tty

tprintf() {
  if [[ "$HAS_TTY" -eq 1 ]]; then
    if printf "$@" >&"$TTY_FD" 2>/dev/null; then
      return 0
    fi
    HAS_TTY=0
    TTY_FD=0
  fi
  printf "$@"
}

tprintln() {
  tprintf "%b\n" "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }
is_termux() { [[ -n "${TERMUX_VERSION-}" ]] || [[ -n "${PREFIX-}" && "${PREFIX}" == /data/data/com.termux/files/usr* ]]; }

github_api_get() {
  local path="$1"
  local url="https://api.github.com/repos/${GITHUB_REPO}${path}"
  if have curl; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: xevo-deploy" \
      "$url"
    return $?
  fi
  if have wget; then
    wget -q -O - \
      --header="Accept: application/vnd.github+json" \
      --header="User-Agent: xevo-deploy" \
      "$url"
    return $?
  fi
  return 1
}

parse_json_string_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | tr -d '\r' | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

extract_github_asset_urls() {
  local json="$1"
  printf '%s' "$json" | tr -d '\r' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

choose_release_asset_url() {
  local urls="$1"
  local selected=""

  selected="$(printf '%s\n' "$urls" | grep -Ei 'termux.*(\.tar\.gz|\.tgz)$' | head -n 1 || true)"
  [[ -n "$selected" ]] && { printf '%s' "$selected"; return 0; }

  selected="$(printf '%s\n' "$urls" | grep -Ei '(\.tar\.gz|\.tgz)$' | head -n 1 || true)"
  [[ -n "$selected" ]] && { printf '%s' "$selected"; return 0; }

  selected="$(printf '%s\n' "$urls" | grep -Ei '\.zip$' | head -n 1 || true)"
  [[ -n "$selected" ]] && { printf '%s' "$selected"; return 0; }

  selected="$(printf '%s\n' "$urls" | grep -Ei '\.cjs$' | head -n 1 || true)"
  [[ -n "$selected" ]] && { printf '%s' "$selected"; return 0; }

  return 1
}

get_github_latest_release() {
  local json tag urls asset_url
  json="$(github_api_get "/releases/latest")" || return 1
  tag="$(parse_json_string_field "$json" "tag_name")"
  urls="$(extract_github_asset_urls "$json")"
  asset_url="$(choose_release_asset_url "$urls")" || return 1
  printf '%s\n%s\n' "$tag" "$asset_url"
}

cleanup() {
  if [[ -n "${SPIN_PID:-}" ]]; then
    kill "$SPIN_PID" >/dev/null 2>&1 || true
    wait "$SPIN_PID" >/dev/null 2>&1 || true
    SPIN_PID=""
    [[ -t 1 ]] && printf "\r\033[K"
  fi
  if [[ "$TTY_FD" -eq 3 ]]; then
    exec 3>&- 3<&- || true
    TTY_FD=0
    HAS_TTY=0
  fi
}
trap cleanup EXIT INT TERM

mklog() {
  mkdir -p "$TEMP_DIR" >/dev/null 2>&1 || true
  if have mktemp; then
    mktemp "${TEMP_DIR%/}/xevo_deploy.XXXXXX.log"
  else
    printf "%s/xevo_deploy_%s_%s.log" "${TEMP_DIR%/}" "$$" "$RANDOM"
  fi
}

spinner_start() {
  local msg="$1"
  if [[ ! -t 1 ]]; then
    printf "%s▶%s %s...\n" "$CYAN" "$NC" "$msg"
    return 0
  fi
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while :; do
      printf "\r%s%s%s %s\033[K" "$CYAN" "${frames:i%10:1}" "$NC" "$msg"
      sleep 0.08
      i=$((i+1))
    done
  ) &
  SPIN_PID="$!"
}

spinner_stop() {
  local rc="${1:-0}"
  if [[ -n "${SPIN_PID:-}" ]]; then
    kill "$SPIN_PID" >/dev/null 2>&1 || true
    wait "$SPIN_PID" >/dev/null 2>&1 || true
    SPIN_PID=""
    [[ -t 1 ]] && printf "\r\033[K"
  fi
  if [[ "$rc" -eq 0 ]]; then
    printf "%s✔%s 完成\n" "$GREEN" "$NC"
  else
    printf "%s✘%s 失败\n" "$RED" "$NC"
  fi
}

run_task() {
  local desc="$1"; shift
  local log_file
  log_file="$(mklog)"
  spinner_start "$desc"
  set +e
  "$@" >"$log_file" 2>&1
  local rc=$?
  set -e
  spinner_stop "$rc"
  if [[ "$rc" -ne 0 ]]; then
    printf "%s┌───────────────────────────────%s\n" "$YELLOW" "$NC"
    printf "%s│ 错误日志 (最后 60 行)%s\n" "$YELLOW" "$NC"
    printf "%s└───────────────────────────────%s\n" "$YELLOW" "$NC"
    tail -n 60 "$log_file" 2>/dev/null || cat "$log_file" || true
  fi
  rm -f "$log_file" >/dev/null 2>&1 || true
  return "$rc"
}

run_task_stream() {
  local desc="$1"; shift
  printf "%s▶%s %s\n" "$CYAN" "$NC" "$desc"
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf "%s✔%s 完成\n" "$GREEN" "$NC"
  else
    printf "%s✘%s 失败\n" "$RED" "$NC"
  fi
  return "$rc"
}

hr() { tprintln "${MAG}────────────────────────────────────────${NC}"; }

title() {
  hr
  tprintln "${BLUE}$1${NC}"
  hr
}

banner() {
  if have clear && [[ -t 1 ]]; then clear || true; fi
  tprintln "${CYAN} __   __      ________      ______  ${NC}"
  tprintln "${CYAN} \\ \\ / /     |  ____\\ \\    / / __ \\ ${NC}"
  tprintln "${CYAN}  \\ V /______| |__   \\ \\  / / |  | |${NC}"
  tprintln "${CYAN}   > <_______|  __|   \\ \\/ /| |  | |${NC}"
  tprintln "${CYAN}  / . \\      | |____   \\  / | |__| |${NC}"
  tprintln "${CYAN} /_/ \\_\\     |______|   \\/   \\____/ ${NC}"
  tprintln "${BLUE}xevo启动脚本${NC}  v${SCRIPT_VERSION}"
  tprintln ""
}

print_system_check() {
  local node_v pg_v redis_v plugin_v
  
  if have node; then
    node_v="${GREEN}$(node -v 2>/dev/null | head -n1)${NC}"
  else
    node_v="${RED}未安装${NC}"
  fi

  if have postgres; then
    pg_v="${GREEN}$(postgres --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)${NC}"
  else
    pg_v="${RED}未安装${NC}"
  fi

  if have redis-server; then
    redis_v="${GREEN}$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | head -n1 | cut -d= -f2)${NC}"
  else
    redis_v="${RED}未安装${NC}"
  fi

  local super_user
  super_user="$(whoami)"
  # 尝试检测插件，如果DB连不上也不报错，直接显示未知
  if have pg_isready && pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then
    local vec_ver trgm_ver
    vec_ver="$(psql -U "$super_user" -d "$DB_NAME" -tAc "select installed_version from pg_available_extensions where name='vector'" 2>/dev/null || echo "")"
    trgm_ver="$(psql -U "$super_user" -d "$DB_NAME" -tAc "select installed_version from pg_available_extensions where name='pg_trgm'" 2>/dev/null || echo "")"
    
    local vec_status="${RED}vector:未安装${NC}"
    local trgm_status="${RED}pg_trgm:未安装${NC}"
    
    [[ -n "$vec_ver" ]] && vec_status="${GREEN}vector:${vec_ver}${NC}"
    [[ -n "$trgm_ver" ]] && trgm_status="${GREEN}pg_trgm:${trgm_ver}${NC}"
    
    plugin_v="${vec_status} / ${trgm_status}"
  else
    if [[ "$pg_v" == *"未安装"* ]]; then
        plugin_v="${RED}数据库未安装${NC}"
    else
        plugin_v="${YELLOW}数据库未启动(无法检测)${NC}"
    fi
  fi

  tprintln "${CYAN}--- 环境检测 ---${NC}"
  tprintln "Node.js:    $node_v"
  tprintln "PostgreSQL: $pg_v"
  tprintln "Redis:      $redis_v"
  tprintln "DB Plugins: $plugin_v"
  tprintln ""
  tprintln "${YELLOW}提示: 首次运行或环境缺失，请务必选择 [1] 全量部署${NC}"
}

read_line() {
  local __varname="$1"
  local __tmp=""
  if [[ "$HAS_TTY" -eq 1 ]]; then
    if ! IFS= read -r -u "$TTY_FD" __tmp; then
      HAS_TTY=0
      TTY_FD=0
      IFS= read -r __tmp || true
    fi
  else
    IFS= read -r __tmp || true
  fi
  printf -v "$__varname" "%s" "$__tmp"
}

read_secret() {
  local __varname="$1"
  local __tmp=""
  if [[ "$HAS_TTY" -eq 1 ]]; then
    if ! IFS= read -rs -u "$TTY_FD" __tmp; then
      HAS_TTY=0
      TTY_FD=0
      IFS= read -rs __tmp || true
    fi
  else
    IFS= read -rs __tmp || true
  fi
  printf -v "$__varname" "%s" "$__tmp"
}

prompt_text() {
  local label="$1"
  local def="${2:-}"
  local out=""
  if [[ -n "$def" ]]; then
    tprintf "${CYAN}%s${NC} [${YELLOW}%s${NC}]: " "$label" "$def"
  else
    tprintf "${CYAN}%s${NC}: " "$label"
  fi
  read_line out
  [[ -z "$out" ]] && out="$def"
  printf '%s' "$out"
}

prompt_secret() {
  local label="$1"
  local out=""
  if [[ "$AUTO_YES" -eq 1 ]]; then
    printf ""
    return 0
  fi
  tprintf "${CYAN}%s${NC}: " "$label"
  read_secret out
  tprintln ""
  printf '%s' "$out"
}

env_get_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^${key}=" "$file" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r'
}

pause_any() {
  if [[ "$AUTO_YES" -eq 1 ]]; then return 0; fi
  tprintf "\n${YELLOW}按回车返回...${NC}"
  local _
  read_line _
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) AUTO_YES=1; shift ;;
      --no-update) SKIP_UPDATE=1; shift ;;
      --release-url) RELEASE_URL="${2:-}"; shift 2 ;;
      --db-user) DB_USER="${2:-}"; shift 2 ;;
      --db-pass) DB_PASS="${2:-}"; shift 2 ;;
      --host) APP_HOST="${2:-}"; shift 2 ;;
      --port) APP_PORT="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
}

auto_fix_termux_mirrors() {
  tprintln "${YELLOW}镜像源可能异常，尝试自动修复...${NC}"
  local sources_file="$PREFIX/etc/apt/sources.list"
  if [[ -f "$sources_file" ]]; then
    cp "$sources_file" "${sources_file}.bak" >/dev/null 2>&1 || true
    printf "deb https://grimler.se/termux-packages-24 stable main\n" > "$sources_file"
    if run_task_stream "重试更新数据源" env DEBIAN_FRONTEND=noninteractive pkg update -y -o Dpkg::Options::="--force-confnew"; then
      return 0
    fi
    printf "deb https://packages.termux.dev/apt/termux-main stable main\n" > "$sources_file"
    if run_task_stream "再次重试更新" env DEBIAN_FRONTEND=noninteractive pkg update -y -o Dpkg::Options::="--force-confnew"; then
      return 0
    fi
  fi
  return 1
}

do_update_sources() {
  if [[ "$SKIP_UPDATE" -eq 1 ]]; then
    tprintln "${YELLOW}已跳过数据源更新。${NC}"
    return 0
  fi

  mkdir -p "$CACHE_DIR" >/dev/null 2>&1 || true

  local now ts ttl
  now="$(date +%s)"
  ttl=43200
  ts=0
  if [[ -f "$UPDATE_MARKER" ]]; then
    ts="$(cat "$UPDATE_MARKER" 2>/dev/null || echo 0)"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < ttl )); then
      tprintln "${GREEN}数据源近期已更新，自动跳过。${NC}"
      return 0
    fi
  fi

  if is_termux; then
    if run_task_stream "更新 Termux 数据源" env DEBIAN_FRONTEND=noninteractive pkg update -y -o Dpkg::Options::="--force-confnew"; then
      printf "%s\n" "$now" > "$UPDATE_MARKER"
      return 0
    fi
    if auto_fix_termux_mirrors; then
      printf "%s\n" "$now" > "$UPDATE_MARKER"
      return 0
    fi
    return 1
  fi

  tprintln "${RED}当前脚本仅支持 Termux。${NC}"
  return 1
}

termux_ensure_deps() {
  local pkgs=()
  if [[ -n "${PREFIX-}" ]]; then
    if [[ ! -f "$PREFIX/etc/tls/certs/ca-certificates.crt" && ! -f "$PREFIX/etc/tls/cert.pem" ]]; then
      pkgs+=(ca-certificates)
    fi
  else
    pkgs+=(ca-certificates)
  fi
  have node || pkgs+=(nodejs-lts)
  have openssl || pkgs+=(openssl)
  have curl || pkgs+=(curl)
  have wget || pkgs+=(wget)
  have git || pkgs+=(git)
  have clang || pkgs+=(clang)
  have make || pkgs+=(make)
  have ld || pkgs+=(binutils)
  have pkg-config || pkgs+=(pkg-config)
  have tar || pkgs+=(tar)
  have unzip || pkgs+=(unzip)
  have psql || pkgs+=(postgresql)
  have redis-server || pkgs+=(redis)
  have ip || pkgs+=(iproute2)

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    tprintln "${GREEN}依赖检查通过。${NC}"
    return 0
  fi

  tprintln "${YELLOW}缺失依赖${NC}: ${pkgs[*]}"
  run_task_stream "安装依赖" env DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::="--force-confnew" "${pkgs[@]}"
  tprintln ""
}

proc_running() {
  local name="$1"
  if have pgrep; then
    pgrep -x "$name" >/dev/null 2>&1
    return $?
  fi
  ps aux 2>/dev/null | grep -E "[[:space:]]${name}([[:space:]]|$)" >/dev/null 2>&1
}

termux_pgdata() { printf "%s" "$PREFIX/var/lib/postgresql"; }

termux_fix_pg_conf() {
  local pg_data="$1"
  local conf="$pg_data/postgresql.conf"
  local hba="$pg_data/pg_hba.conf"

  [[ -f "$conf" ]] || return 0
  [[ -f "$hba" ]] || return 0

  cp -n "$conf" "${conf}.bak" >/dev/null 2>&1 || true
  cp -n "$hba" "${hba}.bak" >/dev/null 2>&1 || true

  if grep -qE '^[[:space:]]*#?[[:space:]]*listen_addresses[[:space:]]*=' "$conf"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '127.0.0.1'|g" "$conf" || true
  else
    printf "\nlisten_addresses = '127.0.0.1'\n" >> "$conf"
  fi

  if grep -qE '^[[:space:]]*#?[[:space:]]*password_encryption[[:space:]]*=' "$conf"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = 'scram-sha-256'|g" "$conf" || true
  else
    printf "\npassword_encryption = 'scram-sha-256'\n" >> "$conf"
  fi

  if grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+' "$hba"; then
    sed -i -E "s|^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+.*|host all all 127.0.0.1/32 scram-sha-256|g" "$hba" || true
  else
    printf "\nhost all all 127.0.0.1/32 scram-sha-256\n" >> "$hba"
  fi

  if grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128[[:space:]]+' "$hba"; then
    sed -i -E "s|^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128[[:space:]]+.*|host all all ::1/128 scram-sha-256|g" "$hba" || true
  else
    printf "host all all ::1/128 scram-sha-256\n" >> "$hba"
  fi
}

termux_pg_start() {
  local pg_data="$1"
  local pg_log="${TEMP_DIR%/}/pg.log"
  local pid_file="$pg_data/postmaster.pid"

  if [[ ! -d "$pg_data" ]]; then
    run_task "初始化 PostgreSQL" initdb -D "$pg_data"
  fi

  if have pg_isready && pg_isready -q -h 127.0.0.1 -p 5432; then
    tprintln "${GREEN}PostgreSQL 已就绪。${NC}"
    return 0
  fi

  if [[ -f "$pid_file" ]]; then
    local pid=""
    pid="$(head -n 1 "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
      if [[ ! -d "/proc/$pid" ]]; then
        rm -f "$pid_file" >/dev/null 2>&1 || true
      else
        kill -9 "$pid" >/dev/null 2>&1 || true
        rm -f "$pid_file" >/dev/null 2>&1 || true
      fi
    else
      rm -f "$pid_file" >/dev/null 2>&1 || true
    fi
  fi

  : > "$pg_log" || true
  run_task "启动 PostgreSQL" pg_ctl -D "$pg_data" -l "$pg_log" start

  local i=0
  while (( i < 30 )); do
    if have pg_isready && pg_isready -q -h 127.0.0.1 -p 5432; then
      tprintln "${GREEN}PostgreSQL 启动成功。${NC}"
      return 0
    fi
    sleep 0.4
    i=$((i+1))
  done

  tprintln "${RED}PostgreSQL 未能就绪。日志: ${pg_log}${NC}"
  return 1
}

termux_pg_config_user_db() {
  local pg_data="$1"
  local super_user
  super_user="$(whoami)"

  title "配置数据库"

  # 智能检测跳过
  if psql -U "$super_user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
      local vec_chk trgm_chk
      vec_chk="$(psql -U "$super_user" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null || true)"
      trgm_chk="$(psql -U "$super_user" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_trgm'" 2>/dev/null || true)"
      
      if [[ "$vec_chk" == "1" && "$trgm_chk" == "1" ]]; then
          tprintln "${GREEN}检测到数据库及插件已部署，跳过初始化流程。${NC}"
          
          if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
             local env_f="$INSTALL_DIR/.env"
             if [[ -f "$env_f" ]]; then
                 DB_USER="$(env_get_value "$env_f" "DB_USER" || echo "$DB_USER")"
                 DB_PASS="$(env_get_value "$env_f" "DB_PASS" || echo "$DB_PASS")"
             fi
          fi
          if [[ -z "$DB_USER" ]]; then
             DB_USER="$(prompt_text "数据库用户名" "")"
          fi
          if [[ -z "$DB_PASS" ]]; then
             DB_PASS="$(prompt_secret "数据库密码")"
          fi
          return 0
      fi
  fi

  if [[ -z "$DB_USER" ]]; then
    while :; do
      DB_USER="$(prompt_text "数据库用户名" "")"
      [[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]{0,30}$ ]] && break
      tprintln "${YELLOW}用户名不合法，请重试。${NC}"
    done
  fi

  if [[ -z "$DB_PASS" && "$AUTO_YES" -eq 0 ]]; then
    while :; do
      local p1 p2
      p1="$(prompt_secret "数据库密码")"
      [[ -n "$p1" ]] || { tprintln "${YELLOW}密码不能为空。${NC}"; continue; }
      p2="$(prompt_secret "确认密码")"
      [[ "$p1" == "$p2" ]] || { tprintln "${YELLOW}两次密码不一致。${NC}"; continue; }
      DB_PASS="$p1"
      break
    done
  fi

  if [[ -z "$DB_PASS" ]]; then
    tprintln "${RED}未提供 DB_PASS（可用 --db-pass 传入）。${NC}"
    return 1
  fi

 run_task "创建/更新角色与密码" bash -lc "
psql -v ON_ERROR_STOP=1 -U \"$super_user\" -d postgres -v db_user=\"$DB_USER\" -v db_pass=\"$DB_PASS\" <<'SQL'
SELECT set_config('xphone.db_user', :'db_user', false);
SELECT set_config('xphone.db_pass', :'db_pass', false);

DO \$\$
DECLARE
  v_user text := current_setting('xphone.db_user');
  v_pass text := current_setting('xphone.db_pass');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_user) THEN
    EXECUTE format('CREATE ROLE %I LOGIN', v_user);
  END IF;
  EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', v_user, v_pass);
END
\$\$;
SQL
"

  run_task "创建数据库 ${DB_NAME}" bash -lc "createdb -U \"$super_user\" -O \"$DB_USER\" \"$DB_NAME\" >/dev/null 2>&1 || true"
  run_task "确保数据库归属" bash -lc "psql -U \"$super_user\" -d postgres -v ON_ERROR_STOP=1 -c \"ALTER DATABASE $DB_NAME OWNER TO $DB_USER;\" >/dev/null 2>&1 || true"

  local did_build_pgvector=0
  local vector_available=""
  vector_available="$(psql -U "$super_user" -d "$DB_NAME" -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector' LIMIT 1;" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$vector_available" != "1" ]]; then
    if run_task "编译/安装 pgvector（vector）" bash -lc "
set -euo pipefail
if ! command -v pg_config >/dev/null 2>&1; then
  echo \"[错误] 未找到 pg_config。Termux 中通常由 postgresql 包提供，请先安装/升级：pkg install -y postgresql\"
  exit 1
fi
BUILD_ROOT=\"${TEMP_DIR%/}/xevo_pgvector_build\"
rm -rf \"\$BUILD_ROOT\" || true
mkdir -p \"\$BUILD_ROOT\"
cd \"\$BUILD_ROOT\"
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make PG_CONFIG=\"\$(command -v pg_config)\" SHLIB_LINK=\"-lm\"
make install
cd /
rm -rf \"\$BUILD_ROOT\" || true
"; then
      did_build_pgvector=1
    else
      tprintln "${YELLOW}警告${NC}: pgvector 编译/安装失败（将继续流程）。如需向量检索功能，请检查网络/编译工具链，并确保已安装 postgresql。"
    fi
  else
    tprintln "${GREEN}pgvector 已可用${NC}: 跳过编译阶段"
  fi

  if ! run_task "安装数据库扩展（pg_trgm）" bash -lc "psql -U \"$super_user\" -d \"$DB_NAME\" -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\" >/dev/null"; then
    tprintln "${YELLOW}警告${NC}: pg_trgm 扩展安装失败（将继续流程）。"
  fi

  if ! run_task "安装数据库扩展（vector）" bash -lc "psql -U \"$super_user\" -d \"$DB_NAME\" -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS vector;\" >/dev/null"; then
    if [[ "$did_build_pgvector" -eq 0 ]]; then
      if run_task "重新编译/安装 pgvector（vector）" bash -lc "
set -euo pipefail
if ! command -v pg_config >/dev/null 2>&1; then
  echo \"[错误] 未找到 pg_config。Termux 中通常由 postgresql 包提供，请先安装/升级：pkg install -y postgresql\"
  exit 1
fi
BUILD_ROOT=\"${TEMP_DIR%/}/xevo_pgvector_build\"
rm -rf \"\$BUILD_ROOT\" || true
mkdir -p \"\$BUILD_ROOT\"
cd \"\$BUILD_ROOT\"
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make PG_CONFIG=\"\$(command -v pg_config)\" SHLIB_LINK=\"-lm\"
make install
cd /
rm -rf \"\$BUILD_ROOT\" || true
"; then
        if ! run_task "重试安装数据库扩展（vector）" bash -lc "psql -U \"$super_user\" -d \"$DB_NAME\" -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS vector;\" >/dev/null"; then
          tprintln "${YELLOW}警告${NC}: vector 扩展安装失败（将继续流程）。应用可能无法使用向量检索相关功能。"
        fi
      else
        tprintln "${YELLOW}警告${NC}: vector 扩展安装失败且 pgvector 重新编译失败（将继续流程）。应用可能无法使用向量检索相关功能。"
      fi
    else
      tprintln "${YELLOW}警告${NC}: vector 扩展安装失败（将继续流程）。应用可能无法使用向量检索相关功能。"
    fi
  fi

  termux_fix_pg_conf "$pg_data"
  run_task "重载 PostgreSQL 配置" pg_ctl -D "$pg_data" reload
  run_task "验证 TCP 登录" bash -lc "PGPASSWORD=\"$DB_PASS\" psql -h 127.0.0.1 -p 5432 -U \"$DB_USER\" -d \"$DB_NAME\" -v ON_ERROR_STOP=1 -c \"SELECT 1;\" >/dev/null"
}

termux_redis_start() {
  if proc_running "redis-server"; then
    tprintln "${GREEN}Redis 已在运行。${NC}"
    return 0
  fi
  run_task "启动 Redis" redis-server --daemonize yes --protected-mode no
}

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"

  if have curl; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    if run_task "下载应用包" bash -lc "curl --http1.1 -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o \"$tmp\" \"$url\""; then
      mv -f "$tmp" "$dest" >/dev/null 2>&1 || true
      return 0
    fi

    rm -f "$tmp" >/dev/null 2>&1 || true
    if run_task "下载应用包(IPv4重试)" bash -lc "curl -4 --http1.1 -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o \"$tmp\" \"$url\""; then
      mv -f "$tmp" "$dest" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  if have wget; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    if run_task "下载应用包(wget)" bash -lc "wget -q -O \"$tmp\" \"$url\""; then
      mv -f "$tmp" "$dest" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  tprintln "${RED}下载失败${NC}：请检查网络/代理，或尝试在 Termux 执行：pkg update && pkg install -y ca-certificates openssl curl${NC}"
  return 1
}

extract_package() {
  local src="$1"
  local dest="$2"
  mkdir -p "$dest" >/dev/null 2>&1 || true

  if tar -tzf "$src" >/dev/null 2>&1; then
    run_task "解压文件" tar -xzf "$src" -C "$dest"
    return 0
  fi

  if unzip -t "$src" >/dev/null 2>&1; then
    run_task "解压文件" unzip -o "$src" -d "$dest"
    return 0
  fi

  mkdir -p "$dest/server" >/dev/null 2>&1 || true
  run_task "部署单文件包" cp -f "$src" "$dest/server/index.bundle.cjs"
  return 0
}

ensure_termux_env_files() {
  local dir="$1"
  local env_file="$dir/.env"

  if [[ -z "${DB_USER:-}" && -f "$env_file" ]]; then
    DB_USER="$(env_get_value "$env_file" "DB_USER" || true)"
  fi
  if [[ -z "${DB_PASS:-}" && -f "$env_file" ]]; then
    DB_PASS="$(env_get_value "$env_file" "DB_PASS" || true)"
  fi
  if [[ -f "$env_file" ]]; then
    local h p
    h="$(env_get_value "$env_file" "HOST" || true)"
    p="$(env_get_value "$env_file" "PORT" || true)"
    if [[ "${APP_HOST:-}" == "0.0.0.0" && -n "$h" ]]; then APP_HOST="$h"; fi
    if [[ "${APP_PORT:-}" == "3001" && -n "$p" ]]; then APP_PORT="$p"; fi
  fi

  if [[ -z "${DB_USER:-}" ]]; then
    if [[ "$AUTO_YES" -eq 1 ]]; then
      tprintln "${RED}缺少 DB_USER（非交互模式）。请先用菜单“配置服务”创建账号，或用 --db-user/--db-pass 传入。${NC}"
      return 1
    fi
    while :; do
      DB_USER="$(prompt_text "数据库用户名" "")"
      [[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]{0,30}$ ]] && break
      tprintln "${YELLOW}用户名不合法，请重试。${NC}"
    done
  fi

  if [[ -z "${DB_PASS:-}" ]]; then
    if [[ "$AUTO_YES" -eq 1 ]]; then
      tprintln "${RED}缺少 DB_PASS（非交互模式）。请先用菜单“配置服务”创建账号，或用 --db-user/--db-pass 传入。${NC}"
      return 1
    fi
    while :; do
      local p1 p2
      p1="$(prompt_secret "数据库密码")"
      [[ -n "$p1" ]] || { tprintln "${YELLOW}密码不能为空。${NC}"; continue; }
      p2="$(prompt_secret "确认密码")"
      [[ "$p1" == "$p2" ]] || { tprintln "${YELLOW}两次密码不一致。${NC}"; continue; }
      DB_PASS="$p1"
      break
    done
  fi

  mkdir -p "$dir/server" "$dir/storage" "$dir/data" >/dev/null 2>&1 || true
  cat >"$dir/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
export NODE_ENV="${NODE_ENV:-production}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-3001}"
if [[ -x ./xevo-server ]]; then exec ./xevo-server "$@"; fi
exec node server/index.bundle.cjs "$@"
EOF
  chmod +x "$dir/start.sh"

  cat >"$dir/.env" <<ENV
NODE_ENV=production
HOST=${APP_HOST}
PORT=${APP_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASS}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}
REDIS_URL=redis://127.0.0.1:6379
ENV
}

detect_ips() {
  local ip1
  ip1=""
  if have ip; then
    ip1="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$ip1" ]] && have hostname; then
    ip1="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -n "$ip1" ]] && printf "%s" "$ip1"
}

wait_port() {
  local host="$1"
  local port="$2"
  local tries="${3:-40}"
  local i=0
  while (( i < tries )); do
    if (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      exec 3<&- 3>&- || true
      return 0
    fi
    sleep 0.25
    i=$((i+1))
  done
  return 1
}

show_urls() {
  local port="$1"
  local lan
  lan="$(detect_ips || true)"
  tprintln "${GREEN}可访问地址${NC}:"
  tprintln "  ${CYAN}http://127.0.0.1:${port}${NC}"
  if [[ -n "$lan" ]]; then
    tprintln "  ${CYAN}http://${lan}:${port}${NC}"
  fi
}

ask_port() {
  local def="$1"
  local p=""
  while :; do
    p="$(prompt_text "应用端口" "$def")"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      printf "%s" "$p"
      return 0
    fi
    tprintln "${RED}端口不合法，请输入 1-65535。${NC}"
  done
}

termux_install_app() {
  title "安装/更新应用"

  local dir url latest
  dir="$INSTALL_DIR"

  url="${RELEASE_URL:-}"
  if [[ -z "$url" ]]; then
    local latest_tag latest_url
    if latest="$(get_github_latest_release)"; then
      latest_tag="$(printf '%s\n' "$latest" | sed -n '1p')"
      latest_url="$(printf '%s\n' "$latest" | sed -n '2p')"

      local marker="$dir/.xevo_release_tag"
      local installed=""
      if [[ -f "$marker" ]]; then
        installed="$(cat "$marker" 2>/dev/null | tr -d '\r' | head -n 1 || true)"
      fi

      if [[ -n "$installed" && -n "$latest_tag" && "$installed" == "$latest_tag" ]]; then
        tprintln "${GREEN}已是最新版本${NC}: ${latest_tag} (无需下载)"
        ensure_termux_env_files "$dir"
        return 0
      fi

      url="$latest_url"
      tprintln "${CYAN}检测到最新版本${NC}: ${GREEN}${latest_tag}${NC}"
    else
      url="$(prompt_text "下载链接" "")"
    fi
  fi
  [[ -n "$url" ]] || { tprintln "${RED}链接为空，已取消。${NC}"; return 1; }
  RELEASE_URL="$url"

  mkdir -p "$dir/server" "$dir/storage" "$dir/data" >/dev/null 2>&1 || true

  local tmp_file
  tmp_file="$(mklog)"
  download_file "$url" "$tmp_file"
  extract_package "$tmp_file" "$dir"
  rm -f "$tmp_file" >/dev/null 2>&1 || true

  ensure_termux_env_files "$dir"

  if [[ -n "${latest_tag:-}" ]]; then
    printf "%s\n" "$latest_tag" >"$dir/.xevo_release_tag" 2>/dev/null || true
  fi

  tprintln "${GREEN}应用已部署到${NC}: $dir"
  return 0
}

termux_config_services() {
  title "配置服务"

  local pg_data
  pg_data="$(termux_pgdata)"
  termux_pg_start "$pg_data"
  termux_pg_config_user_db "$pg_data"
  termux_redis_start
  
  tprintln "${GREEN}数据库配置完成${NC}:"
  tprintln "  DB_NAME: ${DB_NAME}"
  tprintln "  DB_USER: ${DB_USER}"
  tprintln "  Redis:   127.0.0.1:6379"
}

termux_start_app_foreground() {
  title "启动程序 (前台运行)"

  # 1. 启动服务 (确保后台进程运行)
  local pg_data="$(termux_pgdata)"
  termux_pg_start "$pg_data"
  termux_redis_start

  # 2. 检查入口文件
  local dir="$INSTALL_DIR"
  local entry="$dir/server/index.bundle.cjs"

  if [[ ! -f "$entry" ]]; then
    tprintln "${RED}未找到入口文件: $entry${NC}"
    tprintln "${YELLOW}请先执行 [1] 全量部署${NC}"
    return 1
  fi

  # 3. 配置运行环境
  tprintln "${GREEN}正在启动应用... (按 Ctrl+C 停止)${NC}"
  tprintln "${YELLOW}日志将直接输出到屏幕${NC}"
  
  # 加载 .env
  set -a
  if [[ -f "$dir/.env" ]]; then source "$dir/.env"; fi
  set +a

  # 兜底变量
  export NODE_ENV="${NODE_ENV:-production}"
  export HOST="${HOST:-0.0.0.0}"
  export PORT="${PORT:-3001}"

  # 4. 显示访问地址
  show_urls "$PORT"
  tprintln ""

  # 5. 前台启动 (exec 替换当前 shell 进程)
  cd "$dir"
  exec node server/index.bundle.cjs
}

termux_full_deploy() {
  title "全量部署向导"

  do_update_sources
  termux_ensure_deps

  title "网络监听配置"
  tprintln "${YELLOW}说明${NC}: 0.0.0.0 可供局域网访问，127.0.0.1仅本机设备访问"
  tprintln ""

  APP_HOST="$(prompt_text "监听地址" "$APP_HOST")"
  APP_PORT="$(ask_port "$APP_PORT")"

  termux_config_services
  termux_install_app

  tprintln ""
  tprintln "${GREEN}部署已完成。${NC}"
  tprintln "请在菜单中选择 ${CYAN}[2] 启动程序${NC} 运行应用。"
  tprintln ""
}

menu_termux() {
  while :; do
    banner
    print_system_check
    title "菜单"
    tprintln "${GREEN}1${NC}) 开始部署/更新"
    tprintln "${GREEN}2${NC}) 启动程序"
    tprintln "${GREEN}0${NC}) 退出"
    tprintln ""
    tprintf "${YELLOW}请选择${NC}: "
    local choice=""
    read_line choice
    case "$choice" in
      1) termux_full_deploy; pause_any ;;
      2) termux_start_app_foreground ;;
      0) tprintln "已退出。"; exit 0 ;;
      *) tprintln "${YELLOW}无效选项。${NC}"; sleep 0.4 ;;
    esac
  done
}

main() {
  parse_args "$@"

  if ! is_termux; then
    banner
    title "提示"
    tprintln "${RED}当前脚本仅支持 Termux。${NC}"
    exit 1
  fi

  menu_termux
}

main "$@"
