#!/bin/bash
# TASK-0007 setup.sh —— 云 test 环境一键重建(配合系统自定义镜像使用)
# 用法: ./setup.sh <RUNNER_TOKEN>
# 前提: 系统镜像已固化 docker+加速源+/opt/<app> 目录;本脚本补齐"活的"部分
set -e
RUNNER_TOKEN=$1
BASE=/opt/<app>
REPO=https://github.com/<owner>/<repo>

echo "=== 1/6 环境定义(git clone 或 pull) ==="
if [ -d "$BASE/.git" ]; then cd "$BASE" && git pull; else git clone "$REPO" "$BASE/src" && mkdir -p "$BASE"; fi
# 首次: 从 src 复制定义
[ -f "$BASE/docker-compose.yml" ] || cp "$BASE/src/deploy/test/docker-compose.yml" "$BASE/"
[ -d "$BASE/model/model" ] || { mkdir -p "$BASE/model"; cp -r "$BASE/src/model" "$BASE/model/model"; }

echo "=== 2/6 凭据 ==="
if [ ! -f "$BASE/.env" ]; then
  echo "缺少 $BASE/.env —— 从 .env.example 复制并填写后重跑"; exit 1
fi

echo "=== 3/6 起栈 ==="
cd "$BASE" && docker compose up -d

echo "=== 4/6 runner 容器(注册 token 由本机 gh 现取现传,不落盘) ==="
if [ -z "$RUNNER_TOKEN" ]; then
  echo "未提供 RUNNER_TOKEN,跳过 runner(取回方式: gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token)"
else
  docker rm -f mp-runner 2>/dev/null || true
  docker run -d --name mp-runner --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$BASE":"$BASE" \
    -e REPO_URL=$REPO -e RUNNER_TOKEN=$RUNNER_TOKEN \
    -e RUNNER_NAME=mp-test-runner -e RUNNER_LABELS=test \
    myoung34/github-runner:latest
fi

echo "=== 5/6 备份 cron ==="
cp "$BASE/src/deploy/test/backup.sh" "$BASE/backup.sh" && chmod +x "$BASE/backup.sh"
bash "$BASE/backup.sh"   # 立即执行一次验证
(crontab -l 2>/dev/null | grep -v backup.sh; echo "10 4 * * * /bin/bash $BASE/backup.sh") | crontab -

echo "=== 6/6 冒烟 ==="
sleep 15 && bash "$BASE/src/scripts/deploy-test.sh" "$BASE/src" || echo "冒烟未过: 检查 docker logs mp-test-cube"

echo "=== 完成 ==="
docker ps --format '{{.Names}}\t{{.Status}}'
