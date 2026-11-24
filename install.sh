#!/usr/bin/env bash
# install.sh —— 在一台 Debian VPS 上一键装好回程采集（采集 + 每 6 小时自动推送）
#
# 用法（root 身份，每台粘贴一行，三个参数按这台改）：
#   curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/g448990870/cf-routes-data/main/install.sh && bash /tmp/install.sh <PAT> "诺连-LAX" return-nuolian.json
#
# 参数：$1 = GitHub PAT（classic，勾 repo 权限）；$2 = 面板上显示的服务器名字；
#       $3 = 片段文件名（英文短名，如 return-nuolian.json）。
# 装完以后：每 6 小时自动采集回程并推送，仓库自动汇总进 routes.json，面板线路表自动更新。
# 注意：PAT 只用来克隆仓库（存在这台机器 .git/config 里），不会写进脚本；
#       命令会留在 shell 历史里，别把这行命令发给别人。
#
set -euo pipefail

PAT="${1:-}"; SERVER_NAME="${2:-}"; FRAG="${3:-}"
if [ -z "$PAT" ] || [ -z "$SERVER_NAME" ] || [ -z "$FRAG" ]; then
  echo "用法：bash install.sh <PAT> \"服务器名字\" <片段文件名>" >&2
  echo "例如：bash install.sh ghp_xxxx \"诺连-LAX\" return-nuolian.json" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    echo "请用 root 身份运行" >&2
    exit 1
  fi
fi

REPO_DIR="/root/cf-routes-data"

MISSING=""
for cmd in git mtr python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
  echo "正在安装：$MISSING"
  apt-get update -qq && apt-get install -y -qq $MISSING
fi

# 克隆仓库（已有则更新远程地址并拉取）
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" remote set-url origin "https://$PAT@github.com/g448990870/cf-routes-data.git"
  git -C "$REPO_DIR" pull --ff-only || true
else
  git clone "https://$PAT@github.com/g448990870/cf-routes-data.git" "$REPO_DIR"
fi
git -C "$REPO_DIR" config user.name "cf-routes-bot"
git -C "$REPO_DIR" config user.email "cf-routes-bot@users.noreply.github.com"

# 拉采集脚本并跑一次
curl -fsSL -o /usr/local/bin/collect-return.sh https://raw.githubusercontent.com/g448990870/cf-routes-data/main/collect-return.sh
chmod +x /usr/local/bin/collect-return.sh
SERVER_NAME="$SERVER_NAME" /usr/local/bin/collect-return.sh

# 推第一个片段（触发仓库自动汇总）
cp /var/lib/cf-routes/return.json "$REPO_DIR/fragments/$FRAG"
cd "$REPO_DIR" && git add fragments/ && (git diff --cached --quiet || git commit -m "update return $SERVER_NAME") && git push || { echo "推送失败：检查 PAT 是否勾了 repo 权限" >&2; exit 1; }

# 定时任务：每 6 小时采集并推送（先清掉旧的同类行，再加新的）
CRON_LINE="10 */6 * * * SERVER_NAME=\"$SERVER_NAME\" /usr/local/bin/collect-return.sh >> /var/log/cf-routes.log 2>&1 && cp /var/lib/cf-routes/return.json $REPO_DIR/fragments/$FRAG && cd $REPO_DIR && git add fragments/ && (git diff --cached --quiet || git commit -m \"update return $SERVER_NAME\") && git push >> /var/log/cf-routes.log 2>&1"
( crontab -l 2>/dev/null | grep -v "collect-return.sh" || true; echo "$CRON_LINE" ) | crontab -

echo "完成：$SERVER_NAME 已接好，每 6 小时自动采集并推送，面板线路表会自动更新。"
