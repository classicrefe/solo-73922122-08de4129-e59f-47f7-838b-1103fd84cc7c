#!/bin/bash
# =============================================================================
# WAL 段名工具（供 setup.sh 与本地测试 source 使用）
# PG16 段名形如 000000010000000000000003：时间线(8) + 日志号高32位(8) + 段号(8)，
# 全部为十六进制。单个日志号默认含 256 个段（wal_segment_size=16MB）。
# =============================================================================

# 将段名的“日志号/段号”部分 +1；同一时间线内线性推进
wal_next() {
  local f="$1"
  local tl log seg
  tl="${f:0:8}"
  log="${f:8:8}"
  seg="${f:16:8}"
  seg=$(printf '%08X' $(( 0x$seg + 1 )))
  if [ "$seg" == "00000100" ]; then
    seg="00000000"
    log=$(printf '%08X' $(( 0x$log + 1 )))
  fi
  echo "${tl}${log}${seg}"
}

# 枚举 [start, end] 闭区间内的全部段名（每行一个），只支持同一时间线线性区间
wal_range() {
  local cur="$1" end="$2"
  while :; do
    echo "$cur"
    [ "$cur" == "$end" ] && break
    cur=$(wal_next "$cur")
  done
}

# 段名校验：24 位十六进制纯文件名
wal_name_valid() {
  case "$1" in
    *[!0-9A-Fa-f]*|"") return 1 ;;
  esac
  [ "${#1}" -eq 24 ]
}
