#!/bin/sh
# 达梦 DM8 容器入口脚本（POSIX sh）
set -e

DEFAULT_DB_NAME=${DATABASE_NAME:-DAMENG}
INSTANCE_NAME=${INSTANCE_NAME:-DMSERVER}
CASE_SENSITIVE=${CASE_SENSITIVE:-Y}
SYSDBA_PWD=${SYSDBA_PWD:-DMdba_123}
SYSAUDITOR_PWD=${SYSAUDITOR_PWD:-DMauditor_123}
PORT_NUM=${PORT_NUM:-5236}
PAGE_SIZE=${PAGE_SIZE:-16}
CHARSET=${CHARSET:-1}
TIME_ZONE=${TIME_ZONE:-+08:00}

log() {
  echo "[dm8-entrypoint] $*"
}

DM_INITIALIZED=''

# 数据目录里已有 dm.ini 就认为实例已初始化，跳过 dminit
check_init_status() {
  if [ -d "${DM_DATA_DIR}/${DEFAULT_DB_NAME}" ] \
     && [ -f "${DM_DATA_DIR}/${DEFAULT_DB_NAME}/dm.ini" ]; then
    DM_INITIALIZED='true'
  fi
}

generate_init_ini() {
  cat > "${DM_INSTALL_DIR}/default_db_init.ini" <<EOF
[${DEFAULT_DB_NAME}]
system_path=${DM_DATA_DIR}
instance_name=${INSTANCE_NAME}
port_num=${PORT_NUM}
page_size=${PAGE_SIZE}
time_zone=${TIME_ZONE}
charset=${CHARSET}
case_sensitive=${CASE_SENSITIVE}
sysdba_pwd=${SYSDBA_PWD}
sysauditor_pwd=${SYSAUDITOR_PWD}
EOF
}

default_db_init() {
  log "未检测到已初始化的实例，开始初始化: db=${DEFAULT_DB_NAME} instance=${INSTANCE_NAME} port=${PORT_NUM}"
  mkdir -p "${DM_DATA_DIR}"
  generate_init_ini
  chmod +x "${DM_INSTALL_DIR}/bin/dminit" "${DM_INSTALL_DIR}/bin/dmserver" 2>/dev/null || true
  "${DM_INSTALL_DIR}/bin/dminit" CONTROL="${DM_INSTALL_DIR}/default_db_init.ini"
  log "实例初始化完成"
}

check_init_status
if [ -z "${DM_INITIALIZED}" ]; then
  default_db_init
fi

# 无参数 -> 启动数据库服务；有参数 -> 执行用户指定命令
if [ $# -eq 0 ]; then
  chmod +x "${DM_INSTALL_DIR}/bin/dmserver" 2>/dev/null || true
  log "启动 dmserver: ${DM_DATA_DIR}/${DEFAULT_DB_NAME}/dm.ini"
  exec "${DM_INSTALL_DIR}/bin/dmserver" "${DM_DATA_DIR}/${DEFAULT_DB_NAME}/dm.ini"
else
  exec "$@"
fi
