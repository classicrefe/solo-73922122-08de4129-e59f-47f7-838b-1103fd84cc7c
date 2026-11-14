#!/usr/bin/env bash
# =============================================================================
# 本地交接语义测试（无需 Docker / PostgreSQL）：
# 验证 archive_command.sh 与 restore_command.sh 的修复承诺：
#   T1 完整复制并核对后才发布最终段名（过程中最终名不可见）
#   T2 同名完整且内容一致 -> 幂等成功，可重复归档
#   T3 同名半截（尺寸不符）-> 重试自动修复
#   T4 同名完整但内容不同 -> 报错且保留原件
#   T5 复制中断残留临时文件 -> 重试清理并成功
#   T6 restore_command 原子落位 + 尺寸/内容核对，缺段/非法段名拒绝
# 用法: bash tests/test_archive_handoff.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ARCHIVE_SCRIPT="$ROOT/primary/archive_command.sh"
RESTORE_SCRIPT="$ROOT/app/restore_command.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCH="$WORK/archive"
PGWAL="$WORK/pgwal"
RESTORE_DEST="$WORK/restore_dest"
mkdir -p "$ARCH" "$PGWAL" "$RESTORE_DEST"

PASS=0; FAIL=0
check() { # check <描述> <条件命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ✔ $desc"; PASS=$((PASS+1));
  else echo "  ✘ $desc"; FAIL=$((FAIL+1)); fi
}
fsize() { stat -c '%s' "$1"; }
SEG="000000010000000000000003"

echo "T1 完整复制+核对后才原子发布最终段名"
# 用一个会“中途暂停”的 cp 包装，验证发布前最终段名不可见
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cp" <<'STUB'
#!/bin/bash
# 参数形如: cp -- src tmp；复制一半后先停留，让测试观察目录
args=("$@")
src=""; dst=""
for a in "${args[@]}"; do [ "$a" != "--" ] && { if [ -z "$src" ]; then src="$a"; else dst="$a"; fi; }; done
# 先写一半制造“半截临时文件”，停留后再补齐为完整内容（不重复追加）
total=$(stat -c '%s' "$src")
half=$(( total / 2 ))
head -c "$half" "$src" > "$dst"
sleep 1
tail -c "+$(( half + 1 ))" "$src" >> "$dst"
STUB
chmod +x "$WORK/bin/cp"
# 造一个 16MB 的“WAL 段”
dd if=/dev/urandom of="$PGWAL/$SEG" bs=1M count=16 status=none
( PATH="$WORK/bin:$PATH" ARCHIVE_DIR="$ARCH" bash "$ARCHIVE_SCRIPT" "$PGWAL/$SEG" "$SEG" ) &
APID=$!
sleep 0.4
check "T1a 复制过程中最终段名不可见（只有临时文件）" test ! -e "$ARCH/$SEG"
check "T1b 复制过程中仅存在临时文件" bash -c "ls -a '$ARCH' | grep -q '^\.$SEG\.tmp\.'"
wait "$APID"
check "T1c 归档成功后最终段名出现" test -f "$ARCH/$SEG"
check "T1d 发布后无临时文件残留（flock 锁文件可保留）" bash -c "! ls -a '$ARCH' | grep -q 'tmp'"
check "T1e 归档内容与源逐字节一致" cmp -s "$PGWAL/$SEG" "$ARCH/$SEG"
rm -f "$WORK/bin/cp"

echo "T2 同名完整且内容一致 -> 幂等成功（可重复归档）"
ARCHIVE_DIR="$ARCH" bash "$ARCHIVE_SCRIPT" "$PGWAL/$SEG" "$SEG" >/dev/null
check "T2a 重复归档退出码为 0" bash -c "ARCHIVE_DIR='$ARCH' bash '$ARCHIVE_SCRIPT' '$PGWAL/$SEG' '$SEG'"
check "T2b 段内容保持不变" cmp -s "$PGWAL/$SEG" "$ARCH/$SEG"

echo "T3 同名半截/损坏文件 -> 重试修复"
head -c 12345 "$PGWAL/$SEG" > "$ARCH/$SEG"   # 模拟旧逻辑中断留下的同名半截
check "T3a 半截文件尺寸确实不符" bash -c "[ '$(fsize "$ARCH/$SEG")' -ne '$(fsize "$PGWAL/$SEG")' ]"
ARCHIVE_DIR="$ARCH" bash "$ARCHIVE_SCRIPT" "$PGWAL/$SEG" "$SEG" >/dev/null
check "T3b 重试后修复为完整文件" cmp -s "$PGWAL/$SEG" "$ARCH/$SEG"

echo "T4 同名完整但内容不同 -> 报错且保留原件"
cp "$PGWAL/$SEG" "$WORK/original_seg"
dd if=/dev/urandom of="$ARCH/$SEG" bs=1M count=16 status=none  # 同尺寸、不同内容
if ARCHIVE_DIR="$ARCH" bash "$ARCHIVE_SCRIPT" "$PGWAL/$SEG" "$SEG" >/dev/null 2>"$WORK/err"; then
  echo "  ✘ T4a 内容冲突时应非零退出"; FAIL=$((FAIL+1))
else
  echo "  ✔ T4a 内容冲突时非零退出"; PASS=$((PASS+1))
fi
check "T4c 错误信息提示拒绝覆盖" grep -q "拒绝覆盖" "$WORK/err"
# 精确校验：冲突原件必须保留，不能被源文件覆盖
if ! cmp -s "$ARCH/$SEG" "$PGWAL/$SEG"; then
  echo "  ✔ T4b 原件被保留（与源不同，未被覆盖）"; PASS=$((PASS+1));
else echo "  ✘ T4b 原件被覆盖"; FAIL=$((FAIL+1)); fi

echo "T5 复制中断残留临时文件 -> 重试清理并成功"
cp "$WORK/original_seg" "$PGWAL/$SEG"
rm -f "$ARCH/$SEG"
head -c 999 "$PGWAL/$SEG" > "$ARCH/.$SEG.tmp.777"   # 上次中断的临时文件
ARCHIVE_DIR="$ARCH" bash "$ARCHIVE_SCRIPT" "$PGWAL/$SEG" "$SEG" >/dev/null
check "T5a 重试后归档成功且内容正确" cmp -s "$PGWAL/$SEG" "$ARCH/$SEG"
check "T5b 旧临时文件已清理" bash -c "! ls -a '$ARCH' | grep -q 'tmp'"

echo "T6 restore_command：原子落位 + 核对 + 拒绝异常输入"
# 独立归档目录，避免与前面 T4 的冲突文件互相干扰
RARCH="$WORK/restore_archive"
mkdir -p "$RARCH"
cp "$PGWAL/$SEG" "$RARCH/$SEG"
out="$RESTORE_DEST/$SEG"
check "T6a 正常段恢复成功" env ARCHIVE_DIR="$RARCH" bash "$RESTORE_SCRIPT" "$SEG" "$out"
check "T6b 恢复出的文件与归档逐字节一致" cmp -s "$RARCH/$SEG" "$out"
check "T6c 缺段退出非零" bash -c "! ARCHIVE_DIR='$RARCH' bash '$RESTORE_SCRIPT' '0000000100000000000000FF' '$RESTORE_DEST/x'"
check "T6d 路径穿越段名被拒" bash -c "! ARCHIVE_DIR='$RARCH' bash '$RESTORE_SCRIPT' '../../etc/passwd' '$RESTORE_DEST/y'"
check "T6e 故障注入缺段退出非零" bash -c "! ARCHIVE_DIR='$RARCH' bash '$RESTORE_SCRIPT' '$SEG' '$RESTORE_DEST/z' '$SEG'"
# 零尺寸归档拒绝
ZERO="0000000100000000000000EE"
: > "$RARCH/$ZERO"
check "T6f 零尺寸归档被拒绝" bash -c "! ARCHIVE_DIR='$RARCH' bash '$RESTORE_SCRIPT' '$ZERO' '$RESTORE_DEST/zz'"

echo
echo "结果: $PASS 通过 / $FAIL 失败"
[ "$FAIL" -eq 0 ]
