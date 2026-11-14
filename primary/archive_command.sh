#!/bin/bash
# =============================================================================
# WAL 归档交接脚本（由 primary 的 archive_command 调用）
#
# 用法: archive_command.sh <源 WAL 路径 %p> <归档段名 %f>
#
# 交接语义（修复“复制中断留下同名半截归档、后续持续失败”）：
#   1. 先完整复制到同卷临时文件，尺寸 + 逐字节(cmp)核对通过后，才用同文件系统
#      原子 rename 发布为最终段名 —— 归档目录里永远不会出现“同名半截文件”，
#      恢复实例要么看不到该段，要么只能看到完整的该段，不可能读到写入中的归档。
#   2. 复制/核对任一环节失败都删除临时文件并以非零退出；PostgreSQL 归档器会自行
#      重试，上一次中断残留的临时文件在重试开始时自动清理，即“失败可通过重试修复”。
#   3. 同名目标已存在时：
#        与源文件逐字节一致  -> 幂等成功（同名完整且内容一致，可重复归档）
#        同尺寸但内容不同    -> 报错并保留原件（疑似分叉/串档，禁止覆盖）
#        尺寸不同（半截/损坏）-> 判定为历史失败残留，删除后重新复制修复
# =============================================================================
set -eu

ARCHIVE_DIR="${ARCHIVE_DIR:-/wal_archive}"

if [ "$#" -ne 2 ]; then
  echo "archive_command: 参数错误，用法: $0 <源路径 %p> <段名 %f>" >&2
  exit 1
fi

src="$1"
name="$2"

# 只接受纯文件名，杜绝路径穿越
case "$name" in
  ""|.|..|*/*) echo "archive_command: 非法归档段名 '$name'" >&2; exit 1 ;;
esac

if [ ! -f "$src" ]; then
  echo "archive_command: 源 WAL 文件不存在: $src" >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"
target="$ARCHIVE_DIR/$name"
lock="$ARCHIVE_DIR/.$name.lock"
tmp="$ARCHIVE_DIR/.$name.tmp.$$"

cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

# 同一段的归档尝试串行化（归档器本身单线程，这里再兜底防并发踩踏）
exec 9>"$lock"
flock -x 9

src_size=$(stat -c '%s' "$src")

if [ -e "$target" ]; then
  tgt_size=$(stat -c '%s' "$target")
  if [ "$tgt_size" -eq "$src_size" ] && cmp -s "$src" "$target"; then
    # 同名完整且内容一致：幂等成功，PostgreSQL 不会再反复重试该段
    echo "archive_command: $name 已存在且与源文件逐字节一致，幂等成功"
    exit 0
  fi
  if [ "$tgt_size" -ne "$src_size" ]; then
    # 半截/损坏残留（典型来源：旧逻辑复制中断后留下的同名文件）：删除并重新归档修复
    echo "archive_command: 已存在的 $name 尺寸不符（${tgt_size} != ${src_size} 字节），判定为半截/损坏残留，删除后重新归档" >&2
    rm -f -- "$target"
  else
    # 完整但内容不同：保留原件，拒绝覆盖，交人工排查
    echo "archive_command: $name 已存在且尺寸相同但内容不一致，拒绝覆盖并保留原件（疑似 WAL 分叉/串档）" >&2
    exit 1
  fi
fi

# 清理历史中断尝试留下的同段临时文件（重试修复的关键）
rm -f -- "$ARCHIVE_DIR/.$name.tmp".*

# ---- 1. 完整复制到临时名（最终段名在此期间不可见） ----
if ! cp -- "$src" "$tmp"; then
  echo "archive_command: 复制失败 $src -> $tmp" >&2
  exit 1
fi

# ---- 2. 发布前核对：尺寸一致 + 逐字节一致，缺一不可 ----
tmp_size=$(stat -c '%s' "$tmp")
if [ "$tmp_size" -ne "$src_size" ]; then
  echo "archive_command: 临时文件尺寸不符（${tmp_size} != ${src_size}），放弃发布" >&2
  exit 1
fi
if ! cmp -s "$src" "$tmp"; then
  echo "archive_command: 临时文件内容核对不一致，放弃发布" >&2
  exit 1
fi

# ---- 3. 同文件系统原子发布：rename 之后该段才对恢复实例可见 ----
if ! mv -f -- "$tmp" "$target"; then
  echo "archive_command: 原子发布失败 $tmp -> $target" >&2
  exit 1
fi
trap - EXIT
echo "archive_command: $name 归档发布成功（${src_size} 字节，已逐字节核对）"
exit 0
