#!/usr/bin/env bash
# =============================================================================
# 演练数据与备份初始化（幂等）：
#   1) 重建遥测表并写入基线批次（120 行，备份前已入仓）
#   2) pg_basebackup 物理基线备份 -> /basebackup/base
#   3) 批次1（48 行）-> 命名恢复点 rp_before_delete
#   4) 模拟误删：DELETE WX-03 / temperature（7 行）
#   5) 批次2（24 行，误删后新入仓）-> 命名恢复点 rp_after_delete
#   6) 清单门禁（修复点）：不再用 pg_stat_archiver.failed_count 决定成败
#      （历史失败次数不等于当前不可用——重试成功后 failed_count 仍会保留），
#      而是枚举“恢复实例真正需要的 WAL 段闭区间”，逐段确认其在归档卷中
#      尺寸完整、无写入中临时文件、可被 pg_waldump 解析，且两个命名恢复点
#      记录在归档区间内可见，全部满足后才写出 /basebackup/manifest.json
# =============================================================================
set -euo pipefail

PGHOST=primary
PGUSER=postgres
PGDATABASE=telemetry
export PGPASSWORD=postgres
PSQL=(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -X -q -A -t)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wal_helpers.sh
source "$SCRIPT_DIR/wal_helpers.sh"

ARCHIVE_DIR="${ARCHIVE_DIR:-/wal_archive}"

if [[ -f /basebackup/manifest.json && -d /basebackup/base ]]; then
  echo "[setup] 已存在基线备份与清单，跳过（幂等）。如需重置演练：docker compose down -v && docker compose up --build"
  exit 0
fi

echo "[setup] 等待 primary 就绪 ..."
until pg_isready -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; do sleep 1; done

echo "[setup] 重建 telemetry_events 并写入基线遥测（6 设备 × 4 指标 × 5 时点 = 120 行）..."
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -X -q <<'SQL'
DROP TABLE IF EXISTS telemetry_events;
CREATE TABLE telemetry_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id   text NOT NULL,
  site        text NOT NULL,
  metric      text NOT NULL,
  value       double precision NOT NULL,
  recorded_at timestamptz NOT NULL,
  ingested_at timestamptz NOT NULL DEFAULT now()
);

-- 基线批次：备份前已入仓的历史遥测
INSERT INTO telemetry_events (device_id, site, metric, value, recorded_at)
SELECT d.device_id, d.site, m.metric,
       CASE m.metric
         WHEN 'temperature' THEN (12 + 8*sin(g*1.7 + ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'humidity'    THEN (55 + 20*cos(g*1.3 + ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'wind_speed'  THEN (3 + 2.5*sin(g*2.1 + ascii(right(d.device_id,1))))::numeric(10,2)
         ELSE                    (98 - g*1.5)::numeric(10,2)
       END::float8,
       timestamptz '2026-11-10 00:00:00+08' + make_interval(hours => g*6)
FROM (VALUES ('WX-01','青山站'),('WX-02','白鹭站'),('WX-03','临湖站'),
             ('WX-04','风口站'),('WX-05','城北站'),('WX-06','湿地站')) AS d(device_id, site)
CROSS JOIN (VALUES ('temperature'),('humidity'),('wind_speed'),('battery')) AS m(metric)
CROSS JOIN generate_series(0,4) AS g;
CHECKPOINT;
SQL

BASELINE=$("${PSQL[@]}" -c "SELECT count(*) FROM telemetry_events")
echo "[setup] 基线行数: $BASELINE"

echo "[setup] 执行物理基线备份 pg_basebackup -> /basebackup/base ..."
rm -rf /basebackup/base
PGPASSWORD=replicator pg_basebackup -h "$PGHOST" -U replicator -D /basebackup/base -Fp -Xs -c fast
FIRST_WAL=$("${PSQL[@]}" -c "SELECT pg_current_wal_file_name()")
echo "[setup] 基线备份完成；备份后首个 WAL 段: $FIRST_WAL（故障注入演示将“丢失”该段）"

echo "[setup] 写入批次1（48 行，备份后新入仓）..."
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -X -q <<'SQL'
INSERT INTO telemetry_events (device_id, site, metric, value, recorded_at)
SELECT d.device_id, d.site, m.metric,
       CASE m.metric
         WHEN 'temperature' THEN (14 + 7*sin(g*2.3 + ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'humidity'    THEN (58 + 18*cos(g*1.9 + ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'wind_speed'  THEN (4 + 2.0*sin(g*1.1 + ascii(right(d.device_id,1))))::numeric(10,2)
         ELSE                    (96 - g*1.2)::numeric(10,2)
       END::float8,
       timestamptz '2026-11-12 08:00:00+08' + make_interval(hours => g*3)
FROM (VALUES ('WX-01','青山站'),('WX-02','白鹭站'),('WX-03','临湖站'),
             ('WX-04','风口站'),('WX-05','城北站'),('WX-06','湿地站')) AS d(device_id, site)
CROSS JOIN (VALUES ('temperature'),('humidity'),('wind_speed'),('battery')) AS m(metric)
CROSS JOIN generate_series(0,1) AS g;
SQL

RP1_LSN=$("${PSQL[@]}" -c "SELECT pg_create_restore_point('rp_before_delete')")
RP1_TOTAL=$("${PSQL[@]}" -c "SELECT count(*) FROM telemetry_events")
RP1_DS=$("${PSQL[@]}" -c "SELECT count(*) FROM telemetry_events WHERE device_id='WX-03' AND metric='temperature'")
RP1_MAX=$("${PSQL[@]}" -c "SELECT max(recorded_at) FROM telemetry_events")
RP1_AT=$("${PSQL[@]}" -c "SELECT now()")
echo "[setup] 命名恢复点 rp_before_delete @ $RP1_LSN（总行数 $RP1_TOTAL，WX-03/temperature $RP1_DS 行）"

echo "[setup] 模拟误删：DELETE FROM telemetry_events WHERE device_id='WX-03' AND metric='temperature' ..."
DELETED=$("${PSQL[@]}" -c "WITH d AS (DELETE FROM telemetry_events WHERE device_id='WX-03' AND metric='temperature' RETURNING 1) SELECT count(*) FROM d")
echo "[setup] 误删 $DELETED 行（临湖站 WX-03 温度遥测）"

echo "[setup] 误删后原库继续入仓：批次2（24 行）..."
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -X -q <<'SQL'
INSERT INTO telemetry_events (device_id, site, metric, value, recorded_at)
SELECT d.device_id, d.site, m.metric,
       CASE m.metric
         WHEN 'temperature' THEN (15 + 6*sin(ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'humidity'    THEN (60 + 15*cos(ascii(right(d.device_id,1))))::numeric(10,2)
         WHEN 'wind_speed'  THEN (5 + 1.5*sin(ascii(right(d.device_id,1))))::numeric(10,2)
         ELSE                    (95)::numeric(10,2)
       END::float8,
       timestamptz '2026-11-13 09:00:00+08'
FROM (VALUES ('WX-01','青山站'),('WX-02','白鹭站'),('WX-03','临湖站'),
             ('WX-04','风口站'),('WX-05','城北站'),('WX-06','湿地站')) AS d(device_id, site)
CROSS JOIN (VALUES ('temperature'),('humidity'),('wind_speed'),('battery')) AS m(metric);
SQL

RP2_LSN=$("${PSQL[@]}" -c "SELECT pg_create_restore_point('rp_after_delete')")
RP2_TOTAL=$("${PSQL[@]}" -c "SELECT count(*) FROM telemetry_events")
RP2_DS=$("${PSQL[@]}" -c "SELECT count(*) FROM telemetry_events WHERE device_id='WX-03' AND metric='temperature'")
RP2_MAX=$("${PSQL[@]}" -c "SELECT max(recorded_at) FROM telemetry_events")
RP2_AT=$("${PSQL[@]}" -c "SELECT now()")
echo "[setup] 命名恢复点 rp_after_delete @ $RP2_LSN（总行数 $RP2_TOTAL，WX-03/temperature $RP2_DS 行）"

# -----------------------------------------------------------------------------
# 清单门禁：按“恢复实例真正需要哪些 WAL 段”验证归档，而非看历史失败计数
# -----------------------------------------------------------------------------
# 1) 恢复所需第一段：基线备份 backup_label 里 START WAL LOCATION 对应的段
START_WAL=$(sed -n 's/^START WAL LOCATION: [0-9A-Fa-f]*\/[0-9A-Fa-f]* (file \([0-9A-Fa-f]\{24\}\)).*$/\1/p' \
            /basebackup/base/backup_label | head -1)
if [[ -z "$START_WAL" ]]; then
  echo "[setup] 无法从 backup_label 解析 START WAL LOCATION" >&2
  exit 1
fi
# 2) 恢复所需最后一段：覆盖第二个命名恢复点记录的段（先取段名再 switch）
END_WAL=$("${PSQL[@]}" -c "SELECT pg_walfile_name('$RP2_LSN'::pg_lsn)")
SEG_BYTES=$("${PSQL[@]}" -t -c "SELECT setting::int * 8192 FROM pg_settings WHERE name='wal_segment_size'")
echo "[setup] 恢复所需 WAL 区间: $START_WAL .. $END_WAL（段尺寸 ${SEG_BYTES} 字节）"

mapfile -t REQUIRED < <(wal_range "$START_WAL" "$END_WAL")
echo "[setup] 恢复实例需要的 WAL 段共 ${#REQUIRED[@]} 个，等待其在归档卷中完整发布 ..."
"${PSQL[@]}" -c "SELECT pg_switch_wal()" >/dev/null

ok=0
for _ in $(seq 1 120); do
  missing=0; badsize=0; inflight=0
  for seg in "${REQUIRED[@]}"; do
    f="$ARCHIVE_DIR/$seg"
    if [[ ! -f "$f" ]]; then missing=1
    elif [[ "$(stat -c '%s' "$f")" -ne "$SEG_BYTES" ]]; then badsize=1
    fi
    # 写入中的段只以临时名存在，最终名一旦出现即原子完整；检查残留临时/锁文件
    if compgen -G "$ARCHIVE_DIR/.$seg.tmp.*" >/dev/null; then inflight=1; fi
  done
  if [[ $missing -eq 0 && $badsize -eq 0 && $inflight -eq 0 ]]; then ok=1; break; fi
  sleep 2
done
if [[ "$ok" != "1" ]]; then
  echo "[setup] 等待恢复所需 WAL 完整归档超时（missing=$missing badsize=$badsize inflight=$inflight）" >&2
  exit 1
fi
echo "[setup] 所需 ${#REQUIRED[@]} 个 WAL 段均已按最终段名完整归档"

# 3) pg_waldump 逐段解析归档区间：任一文件损坏/半截都会非零退出
WALDUMP_OUT=$(mktemp)
if ! pg_waldump --start="$START_WAL" --end="$(wal_next "$END_WAL")" -p "$ARCHIVE_DIR" >"$WALDUMP_OUT" 2>&1; then
  echo "[setup] pg_waldump 解析归档 WAL 区间失败，归档存在损坏/半截文件：" >&2
  cat "$WALDUMP_OUT" >&2
  exit 1
fi
# 4) 两个命名恢复点记录必须能在归档区间内被解析到（证明所需 WAL 真正覆盖目标）
for rp in rp_before_delete rp_after_delete; do
  if ! grep -q "RESTORE_POINT.*$rp" "$WALDUMP_OUT"; then
    echo "[setup] 归档 WAL 区间内未找到命名恢复点记录 $rp" >&2
    exit 1
  fi
done
RP_RECORDS=$(grep -c "RESTORE_POINT" "$WALDUMP_OUT" || true)
echo "[setup] pg_waldump 校验通过：归档区间可完整解析，含 $RP_RECORDS 条 RESTORE_POINT 记录"
rm -f "$WALDUMP_OUT"

# 归档器统计仅作信息展示（含历史 failed_count），不再作为清单生成门槛
read -r ARCHIVED_COUNT FAILED_COUNT LAST_ARCHIVED <<<"$("${PSQL[@]}" -A -F' ' -c \
  "SELECT archived_count, failed_count, COALESCE(last_archived_wal,'') FROM pg_stat_archiver")"
echo "[setup] 归档器统计（仅参考）：archived_count=$ARCHIVED_COUNT failed_count=$FAILED_COUNT last=$LAST_ARCHIVED"

# 纯 bash 构造 JSON 字符串数组（postgres:16 镜像不含 python3/jq，避免新增依赖）
REQUIRED_JSON="["
for i in "${!REQUIRED[@]}"; do
  [[ $i -gt 0 ]] && REQUIRED_JSON+=","
  REQUIRED_JSON+="\"${REQUIRED[$i]}\""
done
REQUIRED_JSON+="]"
NOW=$("${PSQL[@]}" -c "SELECT now()")
cat > /basebackup/manifest.json <<EOF
{
  "created_at": "$NOW",
  "db": "telemetry",
  "table": "public.telemetry_events",
  "baseline_rows": $BASELINE,
  "batch1_rows": 48,
  "deleted_rows": $DELETED,
  "batch2_rows": 24,
  "deleted_set": {
    "device_id": "WX-03",
    "metric": "temperature",
    "description": "被误删的临湖站（WX-03）温度遥测"
  },
  "first_wal_after_backup": "$FIRST_WAL",
  "wal_archive": {
    "archive_dir": "$ARCHIVE_DIR",
    "segment_size_bytes": $SEG_BYTES,
    "required_start_wal": "$START_WAL",
    "required_end_wal": "$END_WAL",
    "required_wal_files": $REQUIRED_JSON,
    "verified_with": "size check + pg_waldump + restore point records",
    "restore_point_records_seen": $RP_RECORDS,
    "archiver_archived_count": $ARCHIVED_COUNT,
    "archiver_failed_count_at_manifest": $FAILED_COUNT
  },
  "restore_points": [
    {
      "name": "rp_before_delete",
      "lsn": "$RP1_LSN",
      "created_at": "$RP1_AT",
      "expected_total": $RP1_TOTAL,
      "deleted_set_rows": $RP1_DS,
      "max_recorded_at": "$RP1_MAX",
      "note": "误删前：包含全部 WX-03 温度遥测，不含误删后入仓的批次2"
    },
    {
      "name": "rp_after_delete",
      "lsn": "$RP2_LSN",
      "created_at": "$RP2_AT",
      "expected_total": $RP2_TOTAL,
      "deleted_set_rows": $RP2_DS,
      "max_recorded_at": "$RP2_MAX",
      "note": "误删后：WX-03 温度遥测已缺失，包含误删后新入仓的批次2（24 行）"
    }
  ]
}
EOF
echo "[setup] 清单已写入 /basebackup/manifest.json（仅在恢复所需 WAL 全部完整归档后生成）"
echo "[setup] 完成。两个恢复点差异：rp_before_delete=$RP1_TOTAL 行(含误删集 $RP1_DS) / rp_after_delete=$RP2_TOTAL 行(误删集 $RP2_DS)"
