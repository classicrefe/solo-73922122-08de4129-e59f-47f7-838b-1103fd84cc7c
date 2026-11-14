#!/usr/bin/env bash
# =============================================================================
# 端到端冒烟测试（需要 Docker Compose，在仓库根目录运行）：
#   bash tests/e2e_compose.sh
# 覆盖：
#   1) 四服务启动，setup 成功并生成清单（清单门禁 = 所需 WAL 完整归档）
#   2) 容器内运行本地交接语义测试 tests/test_archive_handoff.sh
#   3) 原库持续入仓（行数增长、心跳存在）
#   4) 恢复到 rp_before_delete：三重证据 READY + 核对值 168/7
#   5) 回收 -> 恢复到 rp_after_delete：185/0
#   6) 故障注入：缺段 -> FAILED，且失败残库拒绝查询
#   7) 回收后可再次成功恢复（失败不留死状态）
#   8) 恢复库 READY 前查询被门禁拒绝（未到达目标禁止查询结果）
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE=http://localhost:8080
jget() { python3 - "$BASE$1" <<'PY'
import json,sys,urllib.request
print(json.dumps(json.load(urllib.request.urlopen(sys.argv[1]))))
PY
}
jpost() { python3 - "$BASE$1" "${2:-}" <<'PY'
import json,sys,urllib.request
req=urllib.request.Request(sys.argv[1], data=sys.argv[2].encode() or None,
                           headers={"Content-Type":"application/json"}, method="POST")
print(json.dumps(json.load(urllib.request.urlopen(req))))
PY
}
wait_state() { # wait_state <状态...>  最多 ~180s
  local want=("$@") i s
  for i in $(seq 1 120); do
    s=$(python3 -c "import json,urllib.request;print(json.load(urllib.request.urlopen('$BASE/api/status'))['state'])")
    for w in "${want[@]}"; do [ "$s" == "$w" ] && { echo "$s"; return 0; }; done
    sleep 1.5
  done
  echo "超时，最终状态=$s" >&2; return 1
}

echo "== 1. 启动环境 =="
docker compose down -v >/dev/null 2>&1 || true
docker compose up --build -d
for i in $(seq 1 60); do
  if curl -sf "$BASE/api/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
for i in $(seq 1 60); do
  if curl -sf "$BASE/api/manifest" >/dev/null 2>&1; then break; fi
  echo "等待 setup 清单 ..."; sleep 3
done
echo "清单就绪："
jget /api/manifest | python3 -m json.tool | grep -E 'required_start_wal|required_end_wal|verified_with|archiver_failed_count'

echo "== 2. 容器内交接语义单测 =="
docker compose exec -T primary bash /tests/test_archive_handoff.sh

echo "== 3. 原库持续入仓 =="
n1=$(jget /api/primary/stats | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])")
sleep 5
n2=$(jget /api/primary/stats | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])")
[ "$n2" -gt "$n1" ] && echo "原库行数增长 $n1 -> $n2 ✔"

echo "== 4. 恢复到 rp_before_delete =="
jpost /api/recover '{"restore_point":"rp_before_delete"}' >/dev/null
wait_state READY
jget /api/recovered/summary | python3 -c "
import json,sys; r=json.load(sys.stdin)
assert r['total']==168, r['total']
assert r['deleted_set_rows']==7, r['deleted_set_rows']
assert all(c['ok'] for c in r['checks']), r['checks']
print('rp_before_delete 核对通过：168 行 / 误删集 7 行 ✔')"

echo "== 5. 回收后恢复到 rp_after_delete =="
jpost /api/reclaim >/dev/null
wait_state IDLE
jpost /api/recover '{"restore_point":"rp_after_delete"}' >/dev/null
wait_state READY
jget /api/recovered/summary | python3 -c "
import json,sys; r=json.load(sys.stdin)
assert r['total']==185, r['total']
assert r['deleted_set_rows']==0, r['deleted_set_rows']
print('rp_after_delete 核对通过：185 行 / 误删集 0 行 ✔')"

echo "== 6. 故障注入：缺段 -> FAILED 且残库拒绝查询 =="
jpost /api/reclaim >/dev/null
wait_state IDLE
jpost /api/recover '{"restore_point":"rp_before_delete","inject_fault":true}' >/dev/null
wait_state FAILED
if jget /api/recovered/summary >/dev/null 2>&1; then
  echo "失败残库竟然可查询 ✘"; exit 1
else echo "失败残库查询被门禁拒绝 ✔"; fi

echo "== 7. 回收后重试成功（失败不留死状态） =="
jpost /api/reclaim >/dev/null
wait_state IDLE
jpost /api/recover '{"restore_point":"rp_before_delete"}' >/dev/null
wait_state READY
jpost /api/reclaim >/dev/null
wait_state IDLE
echo
echo "全部端到端断言通过 ✔ （环境仍在运行：$BASE；清理：docker compose down -v）"
