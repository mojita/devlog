#!/bin/bash
# TASK-0007 PG 每日备份:dump → backup/,保留最近 7 份
# 唯一不可重建的数据只有 PG(模型在 Git,预聚合可重建,SeaweedFS 数据随预聚合重建)
BASE=/opt/metrics-platform
TS=$(date +%Y%m%d_%H%M%S)
OUT=$BASE/backup/pg-$TS.sql.gz

docker exec mp-test-pg pg_dump -U metrics -d metrics | gzip > "$OUT" || { echo "备份失败 $TS" >> $BASE/backup/BACKUP_LOG; exit 1; }

# 完整性校验:gzip 可解且包含建表语句
zcat "$OUT" | grep -q "CREATE TABLE" || { echo "备份损坏 $TS" >> $BASE/backup/BACKUP_LOG; exit 1; }

# 保留策略:最近 7 份
ls -1t $BASE/backup/pg-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -f

echo "$(date '+%F %T') OK pg-$TS $(du -h "$OUT" | cut -f1)" >> $BASE/backup/BACKUP_LOG
