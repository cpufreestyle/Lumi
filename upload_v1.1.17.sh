#!/bin/bash
# 上传 v1.1.17 zip 到 GitHub Release（Release 已创建,补传资产）
set -e
cd "$(dirname "$0")"
TOKEN=$(gh auth token 2>/dev/null)
RELEASE_ID=368337319
echo "== 上传 Lumi-v1.1.17.zip =="
curl -s --max-time 180 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @Lumi-v1.1.17.zip \
  "https://uploads.github.com/repos/cpufreestyle/Lumi/releases/$RELEASE_ID/assets?name=Lumi-v1.1.17.zip" \
  -o /tmp/lumi_up117.json
grep -E '"state"|"size"|"name"' /tmp/lumi_up117.json | head -5
echo "DONE"
