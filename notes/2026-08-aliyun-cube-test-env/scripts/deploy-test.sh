#!/bin/bash
# TASK-0007 部署脚本(在 self-hosted runner 上执行;runner 容器已挂载 docker.sock 与 /opt/metrics-platform)
# 流程:备份 → 同步模型 → 重启 Cube → 冒烟(node 进容器,预聚合命中校验) → 失败自动回滚
# 注意:runner 在容器内,localhost 不通宿主机——一切对 Cube 的探测走 docker exec
set -u
SRC="${1:-$GITHUB_WORKSPACE}"
TARGET=/opt/metrics-platform
TS=$(date +%Y%m%d%H%M%S)
BACKUP=$TARGET/backup/model-$TS

smoke() {
  local R
  R=$(docker exec -e SEC="$CUBE_API_SECRET" mp-test-cube node -e '
    const http=require("http"),crypto=require("crypto");
    const b64=o=>Buffer.from(JSON.stringify(o)).toString("base64url");
    const h=b64({alg:"HS256",typ:"JWT"}),p=b64({exp:Math.floor(Date.now()/60000)+10});
    const sig=crypto.createHmac("sha256",process.env.SEC).update(h+"."+p).digest("base64url");
    const tok=h+"."+p+"."+sig;
    const req=(m,path,body)=>new Promise((res,rej)=>{const r=http.request({host:"localhost",port:4000,path:m==="GET"?path:"/cubejs-api/v1/load",method:m,headers:{Authorization:tok,"Content-Type":"application/json"}},x=>{let d="";x.on("data",c=>d+=c);x.on("end",()=>res({code:x.statusCode,body:d}))});r.on("error",rej);if(body)r.write(body);r.end()});
    (async()=>{
      const meta=await req("GET","/cubejs-api/v1/meta");
      if(meta.code!==200){console.log("META_FAIL:"+meta.code);process.exit(1)}
      const q=await req("POST","","{\"query\":{\"measures\":[\"DwdUserOrder.arpu\"],\"dimensions\":[\"DimProvince.prov_name\"],\"limit\":2}}");
      const j=JSON.parse(q.body);
      if(!j.data||!j.data.length){console.log("Q_FAIL:"+q.body.slice(0,150));process.exit(1)}
      const hit=Object.keys(j.usedPreAggregations||{}).map(k=>k.split(".").pop()).join(",");
      console.log("SMOKE_OK rows="+j.data.length+" hit="+(hit||"无(若改了预聚合定义属预期)")+" sample="+JSON.stringify(j.data[0]).slice(0,120));
    })().catch(e=>{console.log("ERR:"+e.message);process.exit(1)});
  ' 2>&1)
  echo "$R"
  echo "$R" | grep -q SMOKE_OK
}

echo "=== 1/5 备份当前模型 → $BACKUP ==="
mkdir -p "$TARGET/backup" && cp -r "$TARGET/model/model" "$BACKUP" || { echo 备份失败; exit 1; }

echo "=== 2/5 同步模型(只动 model/ 定义,不碰 .cubestore/pgdata/seaweed-data) ==="
rm -rf "$TARGET/model/model.new" && cp -r "$SRC/model" "$TARGET/model/model.new" && \
  rm -rf "$TARGET/model/model" && mv "$TARGET/model/model.new" "$TARGET/model/model" || { echo 同步失败; exit 1; }

echo "=== 3/5 重启 Cube ==="
docker restart mp-test-cube || { echo 重启失败; exit 1; }

echo "=== 4/5 等待就绪(容器内探测) ==="
for i in $(seq 1 20); do
  sleep 3
  if docker exec mp-test-cube node -e "require('http').get('http://localhost:4000/cubejs-api/v1/meta',r=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null; then break; fi
  [ $i = 20 ] && echo "Cube 60s 未就绪"
done

echo "=== 5/5 冒烟 ==="
. "$TARGET/.env"
if smoke; then
  echo "部署成功: $TS"
  echo "$TS" > "$TARGET/VERSION"
  exit 0
fi

echo "=== 冒烟失败 → 自动回滚 ==="
rm -rf "$TARGET/model/model" && cp -r "$BACKUP" "$TARGET/model/model"
docker restart mp-test-cube
echo "已回滚至 $BACKUP"
exit 1
