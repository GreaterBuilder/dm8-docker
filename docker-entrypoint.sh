#!/bin/bash
###############################################################################
# 达梦 DM8 容器启动脚本（ARM64 通用，对应官方镜像的 /opt/startup.sh）
#
# 首次启动：dminit 初始化实例 -> 启动 dmserver
# 再次启动：检测到完整实例（dm.ini + dm.ctl）直接启动 dmserver
# 带参数启动：执行用户命令（docker run ... bash）
#
# 兼容性处理：
#   1) DM 8.4 起 dminit 移除了 LENGTH_IN_CHAR 等参数，直接传会报
#      "Invalid parameter" 并初始化失败。这里启动时先 `dminit help`
#      探测一次，只传当前版本认识的参数。
#   2) 初始化被中断会留下只有 dm.ini 没有 dm.ctl 的残库，脚本会明确报错，
#      而不是带着残库反复重启。
#   3) 日志里不打印明文密码。
###############################################################################
set -e

DM_INSTALL_DIR=${DM_INSTALL_DIR:-/opt/dmdbms}
DM_DATA_DIR=${DM_DATA_DIR:-${DM_INSTALL_DIR}/data}
DMINIT="${DM_INSTALL_DIR}/bin/dminit"

MODE=${MODE:-dmsingle}
DB_NAME=${DB_NAME:-DAMENG}
INSTANCE_NAME=${INSTANCE_NAME:-DMSERVER}
PORT_NUM=${PORT_NUM:-5236}
PAGE_SIZE=${PAGE_SIZE:-8}
EXTENT_SIZE=${EXTENT_SIZE:-16}
CASE_SENSITIVE=${CASE_SENSITIVE:-1}
UNICODE_FLAG=${UNICODE_FLAG:-0}
LENGTH_IN_CHAR=${LENGTH_IN_CHAR:-0}
BLANK_PAD_MODE=${BLANK_PAD_MODE:-0}
BUFFER=${BUFFER:-1000}
LOG_SIZE=${LOG_SIZE:-256}
SYSDBA_PWD=${SYSDBA_PWD:-Dmdba_123}
SYSAUDITOR_PWD=${SYSAUDITOR_PWD:-${SYSDBA_PWD}}
TIME_ZONE=${TIME_ZONE:-+08:00}

log() { echo "[dm8] $*"; }
die() { echo "[dm8] ERROR: $*" >&2; exit 1; }

# DM 8.4 起密码规则：8~48 位，必须同时含大写、小写、数字
check_password() {  # $1=变量名 $2=值
  local name="$1" pwd="$2"
  [ ${#pwd} -ge 8 ] && [ ${#pwd} -le 48 ] || die "${name} 长度必须 8~48 位，当前 ${#pwd} 位"
  case "$pwd" in *[A-Z]*) ;; *) die "${name} 必须包含大写字母" ;; esac
  case "$pwd" in *[a-z]*) ;; *) die "${name} 必须包含小写字母" ;; esac
  case "$pwd" in *[0-9]*) ;; *) die "${name} 必须包含数字" ;; esac
}

# ------------------------------------------------------------------ 前置检查
[ -x "${DM_INSTALL_DIR}/bin/dmserver" ] || die "找不到 ${DM_INSTALL_DIR}/bin/dmserver，镜像构建是否失败？"

case "${MODE}" in
  dmsingle) ;;
  *) log "WARN: 本镜像只实现 dmsingle（单机），MODE=${MODE} 将按单机启动" ;;
esac

if [ ! -w "${DM_DATA_DIR}" ]; then
  die "${DM_DATA_DIR} 不可写。宿主机挂载目录请先执行: chown -R $(id -u):$(id -g) <宿主机目录>"
fi

# ------------------------------------------------------------------ 参数探测
DMINIT_HELP=$("${DMINIT}" help 2>&1 || true)

dminit_supports() {
  printf '%s\n' "${DMINIT_HELP}" | grep -q -- "$1"
}

# ------------------------------------------------------------------ 初始化
is_initialized() {
  [ -f "${DM_DATA_DIR}/${DB_NAME}/dm.ini" ] && [ -f "${DM_DATA_DIR}/${DB_NAME}/dm.ctl" ]
}

is_partial() {
  [ -f "${DM_DATA_DIR}/${DB_NAME}/dm.ini" ] && [ ! -f "${DM_DATA_DIR}/${DB_NAME}/dm.ctl" ]
}

init_db() {
  local args=() kv key skipped=()

  args+=("PATH=${DM_DATA_DIR}")
  args+=("DB_NAME=${DB_NAME}")
  args+=("INSTANCE_NAME=${INSTANCE_NAME}")
  args+=("PORT_NUM=${PORT_NUM}")

  # 字符集：新版本用 UNICODE_FLAG(0/1)，老版本也可能只认 CHARSET(0/1/2)
  if dminit_supports UNICODE_FLAG; then
    args+=("UNICODE_FLAG=${UNICODE_FLAG}")
  elif dminit_supports CHARSET; then
    args+=("CHARSET=${UNICODE_FLAG}")
  fi

  for kv in \
      "PAGE_SIZE=${PAGE_SIZE}" \
      "EXTENT_SIZE=${EXTENT_SIZE}" \
      "CASE_SENSITIVE=${CASE_SENSITIVE}" \
      "LENGTH_IN_CHAR=${LENGTH_IN_CHAR}" \
      "BLANK_PAD_MODE=${BLANK_PAD_MODE}" \
      "BUFFER=${BUFFER}" \
      "LOG_SIZE=${LOG_SIZE}" \
      "SYSDBA_PWD=${SYSDBA_PWD}" \
      "SYSAUDITOR_PWD=${SYSAUDITOR_PWD}" \
      "TIME_ZONE=${TIME_ZONE}" ; do
    key=${kv%%=*}
    if dminit_supports "${key}"; then
      args+=("${kv}")
    else
      skipped+=("${key}")
    fi
  done

  [ ${#skipped[@]} -gt 0 ] && log "WARN: 当前 dminit 不支持 ${skipped[*]}，已跳过（DM 8.4 起移除了 LENGTH_IN_CHAR 等参数）"

  check_password SYSDBA_PWD "${SYSDBA_PWD}"
  check_password SYSAUDITOR_PWD "${SYSAUDITOR_PWD}"

  local shown=() a
  for a in "${args[@]}"; do
    case "$a" in
      SYSDBA_PWD=*|SYSAUDITOR_PWD=*) shown+=("${a%%=*}=******") ;;
      *) shown+=("$a") ;;
    esac
  done

  log "初始化实例: DB_NAME=${DB_NAME} INSTANCE_NAME=${INSTANCE_NAME} PORT=${PORT_NUM}"
  log "  ${shown[*]}"

  "${DMINIT}" "${args[@]}"

  log "实例初始化完成：${DM_DATA_DIR}/${DB_NAME}"
}

if is_partial; then
  die "检测到未完成的初始化（只有 dm.ini，没有 dm.ctl）：请清空 ${DM_DATA_DIR} 后重启容器"
elif is_initialized; then
  log "检测到已有实例：${DM_DATA_DIR}/${DB_NAME}/dm.ini"
else
  init_db
fi

# ------------------------------------------------------------------ 启动
if [ $# -eq 0 ]; then
  log "启动 dmserver: ${DM_DATA_DIR}/${DB_NAME}/dm.ini"
  exec "${DM_INSTALL_DIR}/bin/dmserver" "${DM_DATA_DIR}/${DB_NAME}/dm.ini"
else
  exec "$@"
fi
