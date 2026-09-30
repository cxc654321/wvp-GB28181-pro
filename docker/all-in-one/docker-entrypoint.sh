#!/usr/bin/env bash
# 一体化镜像入口脚本：
#   1. 渲染 nginx 配置
#   2. 首次启动时初始化 MySQL（建库/建用户/导入表结构与初始数据）
#   3. 交给 supervisord 拉起 mysql/redis/zlm/nginx/wvp
set -euo pipefail

DATABASE_USER="${DATABASE_USER:-wvp_user}"
DATABASE_PASSWORD="${DATABASE_PASSWORD:-wvp_password}"
DATABASE_NAME="${DATABASE_NAME:-wvp}"
MYSQL_DATA_DIR="/var/lib/mysql"
MYSQL_RUN_DIR="/var/run/mysqld"
MYSQL_SOCK="${MYSQL_RUN_DIR}/mysqld.sock"
INIT_MARKER="${MYSQL_DATA_DIR}/.wvp_initialized"
INIT_SQL="/docker-entrypoint-initdb.d/init.sql"

log() { echo "[all-in-one] $*"; }

# ------------------------------------------------------------------
# 1. 渲染 nginx 站点配置（替换 ${Stream_IP}）
# ------------------------------------------------------------------
export Stream_IP="${Stream_IP:-127.0.0.1}"
if [ -f /etc/nginx/templates/all-in-one.conf.template ]; then
    envsubst '${Stream_IP}' \
        < /etc/nginx/templates/all-in-one.conf.template \
        > /etc/nginx/conf.d/all-in-one.conf
    log "nginx 配置已渲染 (Stream_IP=${Stream_IP})"
fi

# ------------------------------------------------------------------
# 2. 初始化 MySQL
# ------------------------------------------------------------------
mkdir -p "$MYSQL_RUN_DIR" /var/log/mysql
chown -R mysql:mysql "$MYSQL_DATA_DIR" "$MYSQL_RUN_DIR" /var/log/mysql 2>/dev/null || true

if [ ! -f "$INIT_MARKER" ]; then
    if [ ! -d "$MYSQL_DATA_DIR/mysql" ]; then
        log "初始化 MySQL 数据目录..."
        rm -rf "${MYSQL_DATA_DIR:?}"/*
        mysqld --initialize-insecure --user=mysql --datadir="$MYSQL_DATA_DIR"
    fi

    log "启动临时 MySQL 以导入初始化数据..."
    # --skip-networking：仅通过 socket 使用，避免占用 3306
    mysqld --user=mysql --datadir="$MYSQL_DATA_DIR" \
           --socket="$MYSQL_SOCK" --skip-networking &
    MYSQL_PID=$!

    for _ in $(seq 1 60); do
        if mysqladmin --socket="$MYSQL_SOCK" -uroot ping >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if ! mysqladmin --socket="$MYSQL_SOCK" -uroot ping >/dev/null 2>&1; then
        log "MySQL 启动超时，退出"
        exit 1
    fi

    log "创建数据库/用户并导入表结构..."
    mysql --socket="$MYSQL_SOCK" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DATABASE_NAME}\`
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DATABASE_USER}'@'%'         IDENTIFIED BY '${DATABASE_PASSWORD}';
CREATE USER IF NOT EXISTS '${DATABASE_USER}'@'localhost' IDENTIFIED BY '${DATABASE_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DATABASE_NAME}\`.* TO '${DATABASE_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DATABASE_NAME}\`.* TO '${DATABASE_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    if [ -f "$INIT_SQL" ]; then
        mysql --socket="$MYSQL_SOCK" -uroot "$DATABASE_NAME" < "$INIT_SQL"
    else
        log "未找到初始化 SQL: $INIT_SQL"
    fi

    mysqladmin --socket="$MYSQL_SOCK" -uroot shutdown || kill "$MYSQL_PID" || true
    wait "$MYSQL_PID" 2>/dev/null || true

    touch "$INIT_MARKER"
    log "MySQL 初始化完成"
else
    log "检测到已完成初始化，跳过 MySQL 初始化"
fi

# ------------------------------------------------------------------
# 3. 启动 supervisord
# ------------------------------------------------------------------
log "启动 supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
