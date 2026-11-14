# 遥测恢复演练台（FastAPI + PostgreSQL 16）

数仓工程师误删遥测记录后的恢复演练环境：在**原库持续入仓不受影响**的前提下，
从**物理基线备份 + WAL 归档**真实重放，精确停在所选**命名恢复点**，拉起一份
**独立核查库**，用于核对误删前数据。

- 恢复 = 复制 `pg_basebackup` 物理基线 + `restore_command` 从 WAL 归档重放 +
  `recovery_target_name` 精确停止 + `recovery_target_action=promote`，**不是 SQL 重建样例**。
- 只有三重证据齐备才开放结果（仅凭数据库可连接不算成功）：
  1. 日志出现 `recovery stopping at restore point "<所选恢复点>"`
  2. 日志出现 `archive recovery complete`
  3. `pg_is_in_recovery() = false`（已 promote）
- 全站同时只允许一份恢复；归档缺段 / 未到达目标 → 失败，恢复进程被停止回收，
  失败残库不开放查询，必须“回收残库”后才允许重试。

## WAL 归档 ↔ 初始化交接（本次修复核心）

### 问题背景

WAL 复制中断会在归档目录留下**同名半截归档**：旧 `archive_command` 用
`test ! -f %f && cp %p %f`，半截文件已占用最终段名，后续归档因 `test ! -f`
持续失败；而初始化又以 `pg_stat_archiver.failed_count`（**累计、不归零**的计数）
为门槛，即使归档后来重试成功，也会因历史失败次数拒绝生成恢复清单。

### 修复后的交接契约

归档侧 `primary/archive_command.sh`（`archive_command=/opt/archive_command.sh %p %f`）：

1. **完整复制并核对后才发布**：先复制到同卷临时文件 `.<段名>.tmp.<pid>`，
   尺寸 + `cmp` 逐字节核对通过后，再同文件系统**原子 `rename`** 为最终段名。
   归档目录中任意时刻要么没有该段、要么是完整段——恢复实例不可能读到写入中的归档。
2. **失败可重试修复**：复制/核对失败即删临时文件并非零退出，PostgreSQL 归档器自动重试；
   重试开始时清理同段历史临时文件；对已存在的**尺寸不符**同名文件（半截/损坏残留）
   删除后重新归档修复。
3. **同名完整且内容一致 → 幂等成功**（可重复归档，归档器不再反复重试该段）。
4. **同名完整但内容不同 → 报错并保留原件**（疑似 WAL 分叉/串档，禁止覆盖，交人工排查）。
5. 段名白名单校验（拒绝路径穿越），同段归档用 `flock` 串行化。

恢复侧 `app/restore_command.sh` 对称加固：按精确段名从只读归档卷取段，
先写临时文件、尺寸与逐字节核对后原子改名为 `%p`，缺段/零尺寸/非法段名一律拒绝。

初始化侧 `setup/setup.sh` 的**清单门禁改为看“所需 WAL 是否真正归档”**，不再看失败计数：

- 从基线备份 `backup_label` 解析恢复所需起始段，从第二个命名恢复点 LSN 计算结束段，
  枚举恢复实例真正需要的 WAL 段闭区间（`wal_helpers.sh`，含跨日志号进位）；
- 轮询直到区间内每一段都以**最终段名**存在、尺寸等于 `wal_segment_size`、无写入中临时文件；
- `pg_waldump` 解析整个归档区间（半截/损坏文件会非零退出），并确认两个
  `RESTORE_POINT` 记录在归档区间内可见；
- 全部满足后才写 `/basebackup/manifest.json`，清单内含区间、段尺寸、校验方式、
  所需段清单与归档器统计（`failed_count` 仅记录展示，不参与决策）。

应用侧 `app/main.py` 发起恢复前还有一道**归档就绪预检**：按清单段区间逐段核对
最终段名与尺寸，未完整归档直接拒绝启动恢复实例，绝不带缺段重放。

## 架构

```
┌────────────┐  archive_command.sh        ┌──────────────┐
│  primary   │ 临时文件+核对+原子发布  ──▶ │  wal_archive │（命名卷）
│ 遥测源(原库)│                            └──────┬───────┘
│  :5432     │   pg_basebackup     restore_command│ 临时文件+核对+原子落位
└─────▲──────┘ ───────────▶ ┌─────┴──────────────┐
      │ 持续写入             │  basebackup/base   │
┌─────┴──────┐              └─────┬──────────────┘
│  writer    │                    │ 复制副本 + recovery.signal
│ 心跳遥测    │              ┌─────▼──────────────┐
└────────────┘              │  app (FastAPI)     │
                            │  · 恢复编排/状态机  │
                            │  · 内嵌 PG16 恢复实例│
                            │    127.0.0.1:5433  │
                            │  · 浏览器 :8080     │
                            └────────────────────┘
```

## 快速开始

```bash
docker compose up --build -d
docker compose logs -f setup     # 等待出现 “[setup] 完成。”
# 浏览器打开 http://localhost:8080
```

可选：直接核查原库 `psql postgresql://postgres:postgres@localhost:5432/telemetry`

## 测试

```bash
# 本地（无需 Docker）：归档/恢复交接语义 20 项断言
bash tests/test_archive_handoff.sh

# 有 Docker 时：完整端到端（启动编排、setup 清单门禁、两个恢复点、故障注入、查询门禁）
bash tests/e2e_compose.sh
```

## 演练流程

1. **恢复到误删前**：选择 `rp_before_delete` → 启动恢复 → 观察 WAL 逐段重放 →
   READY 后核对：总行数 168、误删集（WX-03/temperature）7 行、
   最新 recorded_at `2026-11-12 11:00:00+08`。可逐行查询恢复库记录。
2. **回收**当前恢复库 → 选择 `rp_after_delete` → 核对：总行数 185、
   误删集 0 行、含误删后批次2（最新 recorded_at `2026-11-13 09:00:00+08`）。
   两个恢复点的差异即“误删事件”的影响范围。
3. **故障演示**：勾选“注入归档缺段”→ 启动恢复 → 恢复在缺失段处停下，
   postgres 报 `recovery ended before configured recovery target was reached` →
   页面显示失败，进程已回收 → 点击“回收残库并重置”后才可重试，重试可成功。
4. 全程观察左上角原库面板：行数持续增长，证明原库入仓不受影响；
   恢复点之后产生的 `WX-LIVE` 心跳不会出现在恢复库。

## 虚构遥测数据与两个恢复点的差异

| 批次 | 内容 | 行数 |
|---|---|---|
| 基线（备份前） | 6 设备 × 4 指标 × 5 时点 | 120 |
| 批次1（备份后、rp1 前） | 6 设备 × 4 指标 × 2 时点 | +48 |
| **误删**（rp1 后） | `DELETE WHERE device_id='WX-03' AND metric='temperature'` | −7 |
| 批次2（误删后、rp2 前） | 6 设备 × 4 指标 × 1 时点 | +24 |
| 心跳（rp2 后持续） | writer 每 2 秒 1 行 `WX-LIVE/heartbeat` | 持续增长 |

| 核对项 | rp_before_delete | rp_after_delete |
|---|---|---|
| 遥测总行数 | 168 | 185 |
| 误删集行数（WX-03/temperature） | 7 | 0 |
| 最新 recorded_at | 2026-11-12 11:00:00+08 | 2026-11-13 09:00:00+08 |

清单 `/basebackup/manifest.json` 由 setup 以实际 SQL 计数与 WAL 归档实质校验生成，
页面“预期”列与“归档就绪”信息以此为准。

## 目录

```
docker-compose.yml             # 四服务编排：primary / setup / writer / app
primary/entrypoint-wrap.sh     # 归档卷权限准备后交回官方镜像入口
primary/archive_command.sh     # 归档交接：临时文件+核对+原子发布，重试修复/幂等/冲突保护
primary/initdb/00_init.sh      # 复制账号 + pg_hba
setup/setup.sh                 # 造数、pg_basebackup、两个命名恢复点、WAL 实质归档校验、清单
setup/wal_helpers.sh           # WAL 段名枚举/进位/校验
writer/writer.sh               # 持续入仓心跳
app/Dockerfile                 # postgres:16 + python3 + fastapi
app/main.py                    # 恢复编排状态机（归档预检、单恢复锁、目标确认、失败回收、查询门禁）
app/restore_command.sh         # restore_command（原子落位+核对，支持注入“归档缺段”故障）
app/static/index.html          # 演练台页面
tests/test_archive_handoff.sh  # 本地交接语义测试（无需 Docker）
tests/e2e_compose.sh           # 端到端冒烟测试（需要 Docker）
```

## 重置

```bash
docker compose down -v && docker compose up --build -d
```

## 说明

- 恢复实例只监听 app 容器内 `127.0.0.1:5433`，不对外暴露；结果查询一律经过
  应用层 READY 门禁（失败残库不可查，未到达目标恢复点禁止查询结果）。
- 演示环境使用弱口令（postgres/postgres、replicator/replicator），仅限本地演练。
- setup 幂等：已存在基线备份与清单时直接跳过；如需重新生成请先 `down -v`。
