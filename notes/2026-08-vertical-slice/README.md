# devlog 002 · 垂直切片实录:一条查询从 AI 会话到浏览器图表

> 本文记录一个指标平台项目 M0.5 阶段(约四周)的垂直切片验证:用"ARPU 按省排名"这一条查询,把 AI 会话、Rust 网关、Cube 语义层、前端图表整条链路打通并实测。文中命令与数字均为实测记录。环境为阿里云单机(CentOS 7,Docker Compose),引擎版本 Cube v1.7.22。
> (发布前自查:无公司/内网信息,无凭据,数据为演示数据集。)

## 1. 目标与验收标准

切片的目的:在扩宽产品面之前,先验证最窄一条查询链路是否成立。三条可判定的验收:

1. 同一查询经三个入口(AI 会话、浏览器、直连 REST)返回**逐位一致**;
2. Rust 网关转发开销 **p95 < 10ms**;
3. 预聚合命中状态在 API 响应、前端、AI 工具输出三处均可见。

## 2. 拓扑与组件

```
AI 会话(ZCode)                浏览器(React 分析页)
      │ MCP(stdio)                  │ HTTPS /api
      ▼                             ▼
  MCP Server ──────────► Rust 网关 ──────┐
   (两工具:检索/取数)      (登录/JWT/转发) │
                                         ▼
                              Cube 语义层(YAML 模型)
                                         │ 预聚合
                                         ▼
                          PostgreSQL + 对象存储(SeaweedFS)
```

| 组件 | 技术 | 职责 |
|---|---|---|
| Cube | `cubejs/cube:v1.7.22` | 语义层:YAML 建模、SQL 生成、预聚合调度 |
| 网关 | Rust / axum + jsonwebtoken | 登录与 JWT 签发、`/cubejs-api/v1/*` 反代 |
| MCP Server | rmcp(stdio) | 两个工具:指标目录检索、取数 |
| 前端 | React + nginx | 分析页,读 API 响应中的命中字段做指示器 |
| 存储 | PostgreSQL + SeaweedFS(S3 协议) | 业务数据 / 预聚合物化对象 |

同一份数据三个入口走同一引擎、同一套预聚合,数值一致性由此保证,不依赖事后比对(比对仍在验收中执行,见 §8)。

## 3. 语义层模型(节选)

事实表 `dwd_user_order`(一行一订单)关联省份维表;指标含原子(total_fee、user_cnt)、衍生(5G 用户数 = user_cnt + 过滤修饰)、复合(ARPU = total_fee / user_cnt):

```yaml
measures:
  - name: total_fee
    type: sum
    sql: fee
  - name: user_cnt
    type: count_distinct
    sql: user_id
  - name: arpu
    type: number
    sql: "CAST({total_fee} AS DOUBLE PRECISION) / {user_cnt}"

pre_aggregations:
  - name: byProvName
    measures: [total_fee, user_cnt, user_5g_cnt]
    dimensions: [DimProvince.prov_name]
    scheduled_refresh: true
```

`dwd_user_order` 共定义 9 个 `scheduled_refresh` rollup(按省/按大区/按日/按月等维度粒度组合)+ 1 个 original_sql。查询不命中预聚合会回源 PostgreSQL,耗时差一个量级以上,所以命中判定贯穿整条验收链。

## 4. 查询接口契约备忘(实测)

以下均为 v1.7.22 实测,与官方文档有出入的以实测为准:

| 项 | 实测结论 |
|---|---|
| 请求体 | `/cubejs-api/v1/load` 必须包一层 `{"query": {...}}` |
| 排序 | `order` 用对象格式 `{"arpu": "desc"}` |
| 元数据路径 | 是 `/cubejs-api/v1/meta`,裸 `/meta` 返回 404 |
| 探活 | `/readyz`(dev 模式起容器后需等它返回 200 再发查询) |
| 命中判定(dev 模式) | 响应 `annotation.usedPreAggregations` 直接给出 |
| 命中判定(prod 模式) | `usedPreAggregations` **不出现**;判定信号为 `lastRefreshTime` 非空 + `external: true` + `extDbType: "cubestore"` |

prod 模式下命中信号的差异是切片后期才实测发现的——如果按 dev 模式的经验写判定逻辑,prod 环境会全部误判为未命中。此类契约统一记入带版本号的知识库条目,升级引擎时逐条重验。

## 5. Rust 网关

职责三项:`POST /api/v1/auth/login` 校验引导用户(`MP_BOOTSTRAP_USER/PASS`)并签发 HS256 JWT;`/cubejs-api/v1/*` 透传反代;鉴权关闭模式下保持裸通以便调试。Rust 侧 36 个测试,全部 mock,不连真实 Cube。

网关开销实测踩的坑在测法本身:首测用 `docker exec` 每请求起进程,测得 p95 差 29.7ms;该数字包含进程 spawn 抖动,不是网关开销。修正为**容器内单连接循环 + 3 轮预热**后:p50 差 1.5ms,p95 差 3.8ms,通过 <10ms 阈值。测法脚本随仓库交付(`scripts/demo/p95-check.sh`)。

## 6. MCP 工具契约

MCP Server 只暴露两个工具:

```
search_metrics(keyword) → 成员全名/标题/类型(含 cube 前缀)
run_query(measures, dimensions, ...)   → 查询结果行
```

设计约束是"禁猜":`run_query` 的成员名必须是 `search_metrics` 返回的精确全名,凭记忆猜测会被拒绝并返回纠错候选。自然语言到工具调用的翻译交给模型,参数合法性交给工具——工具面越小,幻觉面越小。

## 7. CI 与部署实录

CI 门禁在切片收官时接入(rust fmt/clippy/test + 前端 lint/build),容器化工具链,三个具体的坑:

1. 官方 rust 镜像不预装 rustfmt/clippy → `rustup component add`,组件走国内镜像源,rustup 目录挂持久卷;
2. `bash -lc` 登录 shell 会重置 PATH 丢掉镜像内工具链 → 改 `bash -c`;
3. reqwest 默认 native-tls 在 slim 镜像缺 libssl-dev 编不过 → 切 rustls(网关只连容器内 http,openssl 属连带依赖)。

部署为一条流水线 8 步:预检 `.env` → 备份 → 同步 → 构建 → 重启基础服务 → 起应用 → 双冒烟 → 失败回滚(应用镜像带时间戳 tag,可回退)。时长:首次约 25min(Rust 全量编译),之后 BuildKit 缓存命中约 5min。

"零手签 JWT"作为验收口径执行:演示链路中每个 token 都来自登录接口,联调期的手签脚本从链路中移除——早期手签图省事,代价是鉴权链路从未被真实走过。

## 8. 端到端验证

`scripts/demo/demo_e2e.py` 在部署机上执行,步骤:登录获取 token → 拉 meta → 发起 ARPU 按省排名查询(校验命中预聚合)→ 对同一查询直连 Cube 发起,逐位比对:

```text
$ python3 demo_e2e.py --gateway http://127.0.0.1:8081 --cube http://127.0.0.1:4000
login          ok
meta           ok  (cubes=2)
gateway query  ok  hit=true rows=31
cube direct    ok  hit=true rows=31
diff gateway vs direct: 0 rows differ
```

浏览器侧同一查询(河北 ARPU 110.1396…)与 AI 会话侧、直连侧数值一致,命中指示器三处均点亮。

## 9. 遗留与下一步

- 数值一致性目前靠逐位比对保证;M1 指标目录落地后,三入口收敛为单一定义源,比对降级为回归手段;
- 权限与多租户未做;
- M1 首项为指标目录(元数据即文件 + 网关目录检索端点),切片已验证的契约与测法直接复用。
