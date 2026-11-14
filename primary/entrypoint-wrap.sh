#!/bin/bash
# primary 容器入口包装：
# 命名卷首次挂载到 /wal_archive 时可能是 root 所有，确保 postgres 用户对归档卷
# 可写，然后交回 postgres 官方镜像入口点（其内部会再降权到 postgres 用户）。
set -e
mkdir -p /wal_archive
chown postgres:postgres /wal_archive
chmod 750 /wal_archive
exec docker-entrypoint.sh "$@"
