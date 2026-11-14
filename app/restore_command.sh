#!/bin/bash
# =============================================================================
# restore_command：由恢复实例的 postmaster 调用
#   $1 = %f（WAL 段文件名）  $2 = %p（目标路径）  $3 = 可选：模拟缺失的段名（故障注入）
#
# 与归档侧对称的交接语义，保证恢复实例永远读不到“写入中/半截”的归档：
#   - 归档卷按只读挂载，且归档侧只在完整复制+核对后原子发布最终段名，因此这里
#     按精确段名打开 /wal_archive/<段名> 时，看到的只能是完整文件
#   - 复制到 %p 时先写同目录临时文件，尺寸核对通过后再原子改名为 %p，postmaster
#     不会读到半个目标文件
#   - 拒绝任何非纯段名（含路径分隔符）的请求，杜绝路径穿越
# =============================================================================
set -u

f="$1"
dest="$2"
missing="${3:-}"
archive="${ARCHIVE_DIR:-/wal_archive}"

case "$f" in
  ""|.|..|*/*) echo "restore_command: 非法段名 '$f'" >&2; exit 1 ;;
esac

if [ -n "$missing" ] && [ "$f" = "$missing" ]; then
  echo "restore_command: 段 $f 在归档中缺失（模拟归档缺段）" >&2
  exit 1
fi

src="$archive/$f"
if [ ! -f "$src" ]; then
  echo "restore_command: 段 $f 不存在于 $archive" >&2
  exit 1
fi

src_size=$(stat -c '%s' "$src")
# 完整 WAL 段必须非空；异常尺寸直接拒绝，绝不把半截文件交给 postmaster
if [ "$src_size" -le 0 ]; then
  echo "restore_command: 段 $f 尺寸异常（${src_size} 字节），拒绝使用" >&2
  exit 1
fi

dest_dir=$(dirname -- "$dest")
tmp="$dest_dir/.restore.$f.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT

if ! cp -- "$src" "$tmp"; then
  echo "restore_command: 复制失败 $src -> $tmp" >&2
  exit 1
fi
tmp_size=$(stat -c '%s' "$tmp")
if [ "$tmp_size" -ne "$src_size" ]; then
  echo "restore_command: 临时文件尺寸不符（${tmp_size} != ${src_size}），拒绝落位" >&2
  exit 1
fi
if ! cmp -s "$src" "$tmp"; then
  echo "restore_command: 临时文件内容核对不一致，拒绝落位" >&2
  exit 1
fi
if ! mv -f -- "$tmp" "$dest"; then
  echo "restore_command: 原子落位失败 $tmp -> $dest" >&2
  exit 1
fi
trap - EXIT
exit 0
