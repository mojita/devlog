#!/usr/bin/env python3
# TASK-0007 门禁脚本:模型结构与合规校验(在 PR/部署前拦截低级错误)
# 规则来源:lab 六坑 + KX-004/005 + TP-001 投保铁律的机器可判部分
import sys, glob, yaml

errors, warnings = [], []
def err(m): errors.append(m)
def warn(m): warnings.append(m)

files = sorted(glob.glob("model/**/*.yaml", recursive=True) + glob.glob("model/**/*.yml", recursive=True))
if not files:
    err("model/ 下没有任何 yaml 文件")

# 第一遍:收集所有 cube 定义(跨文件/同文件后定义的都要先注册完)
cubes = {}
for f in files:
    try:
        docs = list(yaml.safe_load_all(open(f, encoding="utf-8")))
    except yaml.YAMLError as e:
        err(f"{f}: YAML 语法错误 {e}"); continue
    for doc in docs:
        if not isinstance(doc, dict) or "cubes" not in doc: continue
        for c in doc["cubes"]:
            name = c.get("name")
            if not name: err(f"{f}: cube 缺 name"); continue
            if name in cubes: err(f"cube 重复定义: {name}({f} 与之前文件)")
            cubes[name] = c

def dim_names(c):  return {d.get("name") for d in c.get("dimensions", []) or [] if d.get("name")}
def meas_names(c): return {m.get("name") for m in c.get("measures", []) or [] if m.get("name")}

# 第二遍:结构校验
for cname, c in cubes.items():
    if not c.get("sql_table"): err(f"{cname}: 缺 sql_table")
    for d in c.get("dimensions", []) or []:
        if not d.get("name"): err(f"{cname}: dimension 缺 name")
        elif not d.get("type"): err(f"{cname}.{d['name']}: dimension 缺 type")
    for m in c.get("measures", []) or []:
        mn = m.get("name")
        if not mn: err(f"{cname}: measure 缺 name"); continue
        t = m.get("type")
        if not t: err(f"{cname}.{mn}: measure 缺 type")
        elif t not in ("count","count_distinct","sum","avg","min","max","number","string","boolean","time","approximate_count_distinct"):
            warn(f"{cname}.{mn}: 非常规 measure type={t}(确认是否有意)")
        if t != "count" and not m.get("sql"): err(f"{cname}.{mn}: type={t} 的 measure 缺 sql")
    # KX-004:被 join 的 cube 必须有 primaryKey(编译期强制)
    for j in c.get("joins", []) or []:
        tgt = j.get("name")
        if tgt not in cubes: err(f"{cname}: join 目标 {tgt} 未定义(注意大小写)")
        elif not any(d.get("primary_key") for d in cubes[tgt].get("dimensions", []) or []):
            err(f"被 join 的 cube {tgt} 缺 primary_key 维度(KX-004)")
    # 预聚合引用校验
    own_dims, own_meas = dim_names(c), meas_names(c)
    for p in c.get("pre_aggregations", []) or []:
        pn = p.get("name", "?")
        for ref in (p.get("measures") or []):
            if ref not in own_meas: err(f"{cname}.{pn}: 预聚合引用了不存在的 measure {ref}")
        for ref in (p.get("dimensions") or []):
            base = ref.split(".")[-1]
            owner = ref.split(".")[0] if "." in ref else None
            if owner and owner in cubes:
                if base not in dim_names(cubes[owner]):
                    err(f"{cname}.{pn}: 预聚合引用了 {owner} 不存在的维度 {base}")
                # KX-005:被预聚合引用的维表必须显式 refresh_key
                elif not cubes[owner].get("refresh_key"):
                    err(f"{cname}.{pn}: 引用的维表 {owner} 未显式声明 refresh_key(KX-005:默认10s失效拖死预聚合)")
            elif base not in own_dims:
                err(f"{cname}.{pn}: 预聚合引用了不存在的维度 {ref}")
        td = p.get("time_dimension")
        if td and td not in own_dims: err(f"{cname}.{pn}: time_dimension {td} 不存在")

for w in warnings: print("[warn]", w)
if errors:
    for e in errors: print("[FAIL]", e)
    print(f"门禁未过: {len(errors)} 错误"); sys.exit(1)
print(f"门禁通过: {len(cubes)} cubes, {len(files)} 文件, {len(warnings)} 警告")
