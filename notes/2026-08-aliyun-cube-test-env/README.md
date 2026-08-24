# 从零在阿里云 CentOS 7 上搭建 Cube 语义层测试环境(含 CI/CD 与对象存储)

> 2026-08 实操复盘。两天内在一台阿里云 ECS 上从裸机到全自动 GitOps 部署闭环:Cube v1.7.22 + PostgreSQL + SeaweedFS + GitHub Actions self-hosted runner。
> 全部命令经过实测,关键坑均附排障过程。目标读者:想低成本搭一套"改模型 push 即生效"的语义层测试环境的工程师。

## 0. 最终架构与成果

```
开发者本机 ──git push──▶ GitHub(metrics-platform 私有仓)
                            │ ①push main 触发 workflow
                            ▼
              GitHub Actions(deploy-test.yml)
                            │ ②runner 主动轮询领任务(纯出站)
                            ▼
        阿里云 ECS(CentOS 7) 上的 runner 容器
                            │ ③docker.sock 操作宿主机
        ┌───────────────────┼──────────────────┐
        ▼                   ▼                  ▼
   mp-test-pg          mp-test-cube       mp-test-seaweed
   PG16 数据源      语义层 v1.7.22        S3 兼容对象存储
   (200万行)        预聚合→S3 远端        (cube-store 桶)
                            ▲
        开发者 ──ssh -L 4000 隧道──▶ Playground http://localhost:4000
```

**实测成果数据**:

| 指标 | 数值 |
|---|---|
| 五种查询形态延迟(预聚合命中) | 30~310ms |
| 模型变更 push → 线上生效 | **约 40 秒**(全自动,含门禁/备份/冒烟) |
| 200 万行数据迁移+对账 | COPY 导入 2.8s,三项校验和逐位一致 |
| 每日 PG 备份 | 62MB gz,完整性自校验 |
| 环境重建(重开机器目标) | ≤30 分钟(自定义镜像+一键脚本) |

## 1. 采购与初始化

### 1.1 规格选择

| 项 | 建议 | 理由 |
|---|---|---|
| 机型 | 2核8G 起步(本文实测机 4c15G) | Cube+PG+SeaweedFS+runner 同机 |
| 系统盘 | 100G ESSD | 数据集+预聚合+镜像缓存 |
| 系统 | **CentOS 7 或 Ubuntu 22.04** | 见下方"OS 选择" |
| 带宽 | 按流量计费 3~5M | 部署流量小 |
| 安全组 | **只开 22**(建议限源 IP) | 所有服务走 SSH 隧道,不公网暴露 |

**OS 选择(重要决策)**:CentOS 7 内核 3.10 会遇到两类坑——①最新基础镜像(如 nginx:alpine)运行崩溃;②原生跑新 glibc 程序(如 GitHub runner)是死路。**但如果你要交付的环境也是老 Linux,测试机与交付环境同源反而能提前踩出这些坑**(本文就是实例)。选 CentOS 7 的代价是:**所有镜像锁版本、拒绝 latest、新用户态程序一律容器化**。求稳选 Ubuntu 22.04。

### 1.2 首次连接

```bash
ssh root@<服务器IP>
# 探测现状(本文实测机:Docker 26.1.4 已预装,CentOS 7.9,内核 3.10)
cat /etc/os-release | head -2 && uname -r && nproc && free -h | head -2 && df -h / | tail -1
```

## 2. 系统底座:Docker 与镜像加速

```bash
# 若无 docker: yum install -y yum-utils && yum-config-manager --add-repo \
#   https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo \
#   && yum install -y docker-ce docker-ce-cli container.io docker-compose-plugin
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "3"}
}
EOF
systemctl restart docker && systemctl enable docker
```

> **坑①(必踩)**:Docker Hub 直连从国内是**间歇性阻断**——本文实测 busybox/postgres 秒拉成功,几分钟后 registry-1.docker.io 全超时。配加速源后 1GB 镜像数分钟拉完;加速源偶发握手失败,**重试即好**,别急着换源。

## 3. 目录规划与凭据

```bash
mkdir -p /opt/metrics-platform/{model/model,pgdata,seaweed-data,seaweed-conf,backup}
cd /opt/metrics-platform
```

`.env`(只放服务器,**永不进 Git**):

```bash
PG_USER=metrics
PG_PASSWORD=<强密码>
PG_DB=metrics
CUBE_API_SECRET=<长随机串>        # openssl rand -hex 24
SW_SECRET=<长随机串>              # SeaweedFS S3 密钥,稍后与 s3.json 保持一致
```

## 4. docker-compose:四服务一页纸

`/opt/metrics-platform/docker-compose.yml`(完整可用版,逐段带注释):

```yaml
services:
  seaweedfs:
    image: chrislusf/seaweedfs:3.80          # 版本锁定
    container_name: mp-test-seaweed
    restart: unless-stopped
    command: 'server -dir=/data -master.volumeSizeLimitMB=2048 -s3 -s3.port=8333 -s3.config=/etc/sw/s3.json'
    volumes:
      - ./seaweed-data:/data
      - ./seaweed-conf:/etc/sw
    ports: ["127.0.0.1:8333:8333", "127.0.0.1:9333:9333"]

  postgres:
    image: postgres:16
    container_name: mp-test-pg
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${PG_USER}
      - POSTGRES_PASSWORD=${PG_PASSWORD}
      - POSTGRES_DB=${PG_DB}
    volumes: [ "./pgdata:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:5432:5432" ]         # 仅本机监听
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PG_USER} -d ${PG_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  cube:
    image: cubejs/cube:v1.7.22              # 版本锁定!
    container_name: mp-test-cube
    restart: unless-stopped
    depends_on:
      postgres: { condition: service_healthy }
    ports: [ "127.0.0.1:4000:4000", "127.0.0.1:15432:15432" ]
    environment:
      - CUBEJS_DB_TYPE=postgres
      - CUBEJS_DB_HOST=postgres
      - CUBEJS_DB_PORT=5432
      - CUBEJS_DB_NAME=${PG_DB}
      - CUBEJS_DB_USER=${PG_USER}
      - CUBEJS_DB_PASS=${PG_PASSWORD}
      - CUBEJS_API_SECRET=${CUBE_API_SECRET}
      # 注意:不要设置 CUBEJS_SCHEMA_PATH(见坑⑨)
      - CUBEJS_DEV_MODE=true
      - CUBEJS_SCHEDULED_REFRESH=true
      - CUBEJS_TELEMETRY=false
      # 预聚合远端 → SeaweedFS(见 §7 的坑史)
      - CUBESTORE_MINIO_SERVER_ENDPOINT=http://seaweedfs:8333
      - CUBESTORE_MINIO_BUCKET=cube-store
      - CUBESTORE_MINIO_REGION=us-east-1
      - CUBESTORE_MINIO_ACCESS_KEY_ID=cubetest
      - CUBESTORE_MINIO_SECRET_ACCESS_KEY=${SW_SECRET}
    volumes: [ "./model:/cube/conf" ]

  # runner 用 docker run 单独管理(见 §8),不在 compose 里
```

模型文件放 `model/model/telecom.yaml`(Cube 约定模型在 /cube/conf 的 **model/ 子目录**)。

```bash
docker compose up -d postgres   # 先起 PG,等 healthy
docker compose up -d cube       # 再起 Cube(镜像约 1GB,耐心)
docker logs mp-test-cube 2>&1 | grep -E 'listening|error' | tail -5
```

看到三行 `Cube SQL listening :15432 / Cube API server (1.7.22) :4000 / Http Server :3030` 即成功。

> **坑⑨(反直觉)**:显式设置 `CUBEJS_SCHEMA_PATH=/cube/conf/model` 会导致模型**空加载**(/meta 返回空 cubes)。不设变量、靠默认约定才生效。
> **坑(安全)**:dev 模式下 /meta **无 token 也返回 200**。靠 127.0.0.1 绑定+安全组只开 22 兜底;生产模式行为待另行验证。

## 5. 数据迁移(任意源 PG → 云端)

三段式:源库 COPY 导出 → scp/sftp 上传 → 容器内 COPY 导入,**全程带对账**。

```bash
# ① 源库导出(在能连源库的机器上,python+psycopg2)
python - << 'EOF'
import psycopg2
conn = psycopg2.connect(host='<源库IP>', port=5432, user='<u>', password='<p>', dbname='<db>')
cur = conn.cursor()
for t in ['dim_province', 'dwd_user_order']:
    with open(f'mig_{t}.csv', 'w', newline='') as f:
        cur.copy_expert(f'COPY {t} TO STDOUT WITH (FORMAT csv, HEADER true)', f)
EOF
# 实测:200 万行/81MB 导出 8.2s

# ② 上传
scp mig_*.csv root@<服务器IP>:/tmp/

# ③ 云端建表+导入+对账
docker cp /tmp/mig_dwd_user_order.csv mp-test-pg:/tmp/
docker exec mp-test-pg psql -U metrics -d metrics -c "
CREATE TABLE dwd_user_order (user_id varchar, prov_id text, user_type text, fee numeric, create_time timestamp);
CREATE TABLE dim_province (prov_id text PRIMARY KEY, prov_name text, region text);"
docker exec mp-test-pg psql -U metrics -d metrics -c \
  "\copy dwd_user_order FROM '/tmp/mig_dwd_user_order.csv' WITH (FORMAT csv, HEADER true)"
docker exec mp-test-pg psql -U metrics -d metrics -c "ANALYZE"
# 实测:200 万行 COPY 2.8s

# ④ 对账(源库与目标库各跑一遍,必须逐位一致)
SELECT count(*), round(sum(fee),2), count(DISTINCT user_id) FROM dwd_user_order;
```

> **坑(Cube 侧)**:换了数据源后必须清空整个 `.cubestore/` 再重启,否则旧预聚合继续服务旧数据(秒回但数值错)。

## 6. 冒烟验证:JWT 签发与预聚合命中

```bash
# 本机签 JWT(HS256,密钥=CUBE_API_SECRET)
python - << 'EOF'
import hmac, hashlib, base64, json, time
secret = '<CUBE_API_SECRET>'
b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b'=')
h = b64(json.dumps({'alg':'HS256','typ':'JWT'}).encode())
p = b64(json.dumps({'exp': int(time.time())+3600}).encode())
sig = b64(hmac.new(secret.encode(), h+b'.'+p, hashlib.sha256).digest())
print((h+b'.'+p+b'.'+sig).decode())
EOF

# 服务器上验证(或 ssh 隧道后本机访问 localhost:4000)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: <JWT>" \
  http://localhost:4000/cubejs-api/v1/meta          # → 200

curl -s -X POST -H "Authorization: <JWT>" -H 'Content-Type: application/json' \
  -d '{"query":{"measures":["DwdUserOrder.arpu"],"dimensions":["DimProvince.prov_name"],"limit":3}}' \
  http://localhost:4000/cubejs-api/v1/load
```

看响应里的 **`usedPreAggregations` 字段——这是命中预聚合的权威证明**(注意:重复查询 20ms 级是内存缓存,不算命中证据)。首查可能返回 "Continue wait"(预聚合构建中),属正常,等几十秒重试。

**SSH 隧道访问 Playground**(推荐日常用法):
```bash
ssh -L 4000:localhost:4000 -L 15432:localhost:15432 root@<服务器IP>
# 本机浏览器 http://localhost:4000
```

## 7. SeaweedFS 对接:一段三次 panic 的排障史

### 7.1 S3 网关配置

`/opt/metrics-platform/seaweed-conf/s3.json`:
```json
{"identities":[{"name":"cube","credentials":[{"accessKey":"cubetest","secretKey":"<SW_SECRET>"}],
"actions":["Admin","Read","Write","List","Tagging"]}]}
```

```bash
docker compose up -d seaweedfs
# 建桶(注意 shell 必须显式指 master,默认值不工作)
echo 's3.bucket.create -name cube-store' | docker exec -i mp-test-seaweed sh -c 'weed shell -master=localhost:9333'
# 自检:8333 返回 403 = 正常(匿名拒绝)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8333/
```

### 7.2 三次 panic 的定位过程(本文最有价值的部分)

给 Cube 配 S3 远端,连续三次崩溃,错误信息层层递进:

| 次 | panic 信息 | 根因 |
|---|---|---|
| 1 | `CUBESTORE_S3_REGION required when CUBESTORE_S3_BUCKET is set` | REGION 与 BUCKET 成对必填(值任意) |
| 2 | `Could not get valid credentials from STS, ENV, Profile` | `CUBESTORE_S3_*` **不携带凭证**,凭证走 AWS SDK 链 |
| 3 | `ssl3_get_record:wrong version number` | 端点缺省按 **https** 握手,S3 兼容后端是 http |

正解不是继续猜,而是**对 cubestore 二进制做字符串分析**(路径在容器内 `/cube/node_modules/@cubejs-backend/cubestore/downloaded/latest/bin/cubestored`):

```bash
docker exec mp-test-cube sh -c 'grep -aoE "CUBESTORE_MINIO_[A-Z_]*" /cube/node_modules/@cubejs-backend/cubestore/downloaded/latest/bin/cubestored | sort -u'
```

输出证实 v1.7.22 的变量集:**`CUBESTORE_S3_*` 只有 BUCKET/REGION/SSE/SUB_PATH(AWS 原生专用);带 SERVER_ENDPOINT/ACCESS_KEY_ID/SECRET_ACCESS_KEY 的是 `CUBESTORE_MINIO_*` 系**——名字叫 MINIO,实际是"任意 S3 兼容后端"的通用配置。最终配置(端点必须带 `http://` 前缀):

```yaml
- CUBESTORE_MINIO_SERVER_ENDPOINT=http://seaweedfs:8333
- CUBESTORE_MINIO_BUCKET=cube-store
- CUBESTORE_MINIO_REGION=us-east-1
- CUBESTORE_MINIO_ACCESS_KEY_ID=cubetest
- CUBESTORE_MINIO_SECRET_ACCESS_KEY=${SW_SECRET}
```

改配置后:**清空 `.cubestore/` + 重建 cube 容器**(KX 铁律),panic 归零。验证数据真落 S3:

```bash
echo 's3.bucket.list' | docker exec -i mp-test-seaweed sh -c 'weed shell -master=localhost:9333'
# → cube-store size:106352 chunk:10
```

架构确认(与官方设计一致):**parquet part 文件上 S3,RocksDB metastore 留本地 `.cubestore/`**。查询验证:三形态命中 S3 后端预聚合,数值与本地盘逐位一致;冷查 0.25~0.31s vs 本地盘 0.03~0.10s(小数据量时 S3 往返占比高,数据量大摊薄)。

## 8. self-hosted runner:为什么容器化

**原生安装的死路**(CentOS 7 实测):①config.sh 拒绝 root → 建 runneruser;②缺 libicu → installdependencies.sh 可解;③**GLIBCXX_3.4.20+ 缺失** → devtoolset 源已 EOL,从 ubuntu 容器抽的 libstdc++ 反而要求 glibc 2.32(CentOS 7 是 2.17)——死锁,无解。

**结论:CentOS 7 上凡新 glibc 程序,一律容器化。**

```bash
# 本机取注册 token(一次性,凭据不落服务器)
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token

# 服务器上起 runner 容器
docker run -d --name mp-runner --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /opt/metrics-platform:/opt/metrics-platform \
  -e REPO_URL=https://github.com/<owner>/<repo> \
  -e RUNNER_TOKEN=<注册token> \
  -e RUNNER_NAME=mp-test-runner \
  -e RUNNER_LABELS=test \
  myoung34/github-runner:latest

docker logs mp-runner 2>&1 | grep -E 'Listening|Connected'   # → Listening for Jobs
```

三个挂载/参数的意义:docker.sock 让流水线能操作宿主机容器;`/opt/metrics-platform` 挂载让部署脚本可见目标目录;labels 供 workflow 的 `runs-on: [self-hosted, test]` 匹配。

> **坑⑩**:runner 在**容器内**,`localhost:4000` 不通宿主机(Cube 端口还只绑了 127.0.0.1)——流水线里对 Cube 的一切探测改用 `docker exec mp-test-cube node -e '...'`。
> **下载经验**:runner 包 216MB,服务器直连 GitHub 44KB/s,`ghfast.top` 前缀镜像 2MB/s(8 倍):`curl -L https://ghfast.top/https://github.com/actions/runner/releases/download/...`。

## 9. 部署流水线:改模型 push 即生效

四个文件(全部进 Git,服务器零手工):

**① `scripts/gate.py`**——模型门禁,把踩过的坑变成机器检查:YAML 语法、cube/measure/dimension 结构、join 目标存在且有 primary_key、**被预聚合引用的维表必须显式 refresh_key**(否则默认 10s 失效拖死预聚合)。本地跑法:`python scripts/gate.py`。

**② `scripts/deploy-test.sh`**——部署动作:备份→同步模型→重启→冒烟→**失败自动回滚**。冒烟在 Cube 容器内用 node 签 JWT+查询+检查 `usedPreAggregations`(docker exec 方案,绕开坑⑩)。

**③ `.github/workflows/deploy-test.yml`**:

```yaml
name: deploy-test
on:
  push:
    branches: [main]
    paths: ['model/**', 'deploy/test/**']   # 只有模型/环境变更才触发
  workflow_dispatch:
jobs:
  deploy:
    runs-on: [self-hosted, test]
    steps:
      - uses: actions/checkout@v4
      - run: pip3 install -q pyyaml -i https://pypi.tuna.tsinghua.edu.cn/simple  # runner 容器无 pyyaml(坑⑪)
      - run: python3 scripts/gate.py
      - run: bash scripts/deploy-test.sh "$GITHUB_WORKSPACE"
      - if: success()
        run: echo "$(date +%Y%m%d%H%M%S) $GITHUB_SHA deploy" >> /opt/metrics-platform/DEPLOY_LOG
```

**④ `scripts/setup.sh`**——一键重建(见 §11)。

**金丝雀验证法**(强烈推荐交付前做一次):给任一度量加个 `title: 金丝雀<日期>` → push main → 流水线自动跑 → `curl /meta` 确认新 title 出现。本文实测:**push 到线上生效约 40 秒,全程零人工服务器操作**。部署痕迹三件套:VERSION(时间戳)、DEPLOY_LOG(commit SHA)、backup/model-<ts>。

## 10. 备份与恢复

`/opt/metrics-platform/backup.sh`(唯一不可重建的数据只有 PG:模型在 Git,预聚合可重建):

```bash
#!/bin/bash
BASE=/opt/metrics-platform
TS=$(date +%Y%m%d_%H%M%S)
OUT=$BASE/backup/pg-$TS.sql.gz
docker exec mp-test-pg pg_dump -U metrics -d metrics | gzip > "$OUT"
zcat "$OUT" | grep -q "CREATE TABLE" || { echo "备份损坏 $TS" >> $BASE/backup/BACKUP_LOG; exit 1; }
ls -1t $BASE/backup/pg-*.sql.gz | tail -n +8 | xargs -r rm -f     # 保留 7 份
echo "$(date '+%F %T') OK pg-$TS $(du -h "$OUT" | cut -f1)" >> $BASE/backup/BACKUP_LOG
```

```bash
chmod +x backup.sh && bash backup.sh       # 立即试跑(实测 62MB)
(crontab -l 2>/dev/null | grep -v backup.sh; echo "10 4 * * * /bin/bash /opt/metrics-platform/backup.sh") | crontab -

# 恢复(重开机器时)
zcat backup/pg-<ts>.sql.gz | docker exec -i mp-test-pg psql -U metrics -d metrics
```

## 11. 机器回收与重建:自定义镜像策略

云服务器随时可能回收,设计原则:**镜像只固化无状态底座,一切"活的"东西从 Git 和备份恢复**。

| 进自定义镜像 | 不进(重开时恢复) |
|---|---|
| Docker + daemon.json 加速源 | `.env` 凭据(手工重建) |
| 四个业务镜像预拉好(pg/cube/seaweed/runner) | pgdata(从备份恢复) |
| `/opt/metrics-platform` 目录骨架 | model/compose(git clone) |
| — | runner 注册(重取 token) |
| — | seaweed-data、.cubestore(清空自动重建) |

**重开 runbook(目标 ≤30 分钟)**:
```bash
# ① 控制台:从自定义镜像开新机
# ② 本机取 runner token,传给服务器跑一键脚本
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
ssh root@<新IP> 'bash setup.sh <token>'   # clone+起栈+注册runner+备份cron+冒烟
# ③ 恢复数据
zcat backup/pg-*.sql.gz | docker exec -i mp-test-pg psql -U metrics -d metrics
```

## 12. 踩坑速查表(全文坑汇总)

| # | 坑 | 对策 |
|---|---|---|
| 1 | Docker Hub 间歇阻断 | daemon.json 加速源;偶发失败重试即好 |
| 2 | CentOS7 内核 3.10 跑不动新基础镜像 | 全镜像锁版本;busybox 替代 nginx:alpine 做静态页 |
| 3 | CentOS7 glibc 2.17 锁死原生 runner | 容器化 runner |
| 4 | 服务器直连 GitHub 下载慢 | ghfast.top 前缀镜像(8 倍速) |
| 5 | CUBEJS_SCHEMA_PATH 显式设置反致空加载 | 不设,靠默认约定 |
| 6 | dev 模式 /meta 无鉴权 | 127.0.0.1 绑定+安全组只开 22 |
| 7 | CUBESTORE_S3_* 不带凭证/不支持自定义端点 | 用 CUBESTORE_MINIO_* 系+http:// 前缀 |
| 8 | weed shell 默认 master 地址不工作 | 显式 `-master=localhost:9333` |
| 9 | runner 容器内 localhost 不通宿主机 | docker exec 进目标容器操作 |
| 10 | runner 容器无 pyyaml | workflow 里 pip 装(清华源) |
| 11 | 换数据源旧预聚合继续服务旧数据 | 清空整个 .cubestore 再重启 |

## 附:环境信息

- Cube v1.7.22 / PostgreSQL 16 / SeaweedFS 3.80 / Docker 26.1.4 / CentOS 7.9(内核 3.10)
- 数据集:dwd_user_order 200 万行 + dim_province 维表
- 本文所有脚本可在本目录 `scripts/` 找到(gate.py / deploy-test.sh / setup.sh / backup.sh / docker-compose.yml)

*遵循 CC BY-NC-SA 4.0,转载注明出处。*
