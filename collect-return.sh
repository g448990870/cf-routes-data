#!/usr/bin/env bash
# collect-return.sh —— 在 VPS 上采集「回程」线路（VPS → 国内三网）
#
# 用法（在每台 Debian VPS 上，root 身份粘贴即用）：
#   curl -fsSL -o /usr/local/bin/collect-return.sh <脚本地址> && chmod +x /usr/local/bin/collect-return.sh
#   SERVER_NAME="诺连-LAX" /usr/local/bin/collect-return.sh
#
# 环境变量（可选）：
#   SERVER_NAME  面板上显示的服务器名字，默认取 hostname（务必改成面板上的名字，
#                否则主题按名字匹配不到这台机器）
#   SERVER_IP    本机公网 IPv4，默认自动探测（api.ipify.org）
#   OUT_DIR      结果输出目录，默认 /var/lib/cf-routes
#
# 流程：对电信 / 联通 / 移动各一个代表性目标跑 mtr（10 轮），解析每跳的 AS，
# 按优先级定出骨干标签，输出一份 JSON 片段到 $OUT_DIR/return.json。
# 汇总进 routes.json 的办法见 README（merge-routes.py）。
#
# 定时任务（每 6 小时跑一次，整点后 10 分，错开整点）：
#   10 */6 * * * /usr/local/bin/collect-return.sh >> /var/log/cf-routes.log 2>&1
#
# TODO（推到 GitHub 的办法，先留空位）：把 $OUT_DIR/return.json 推到放 routes.json
# 的仓库，例如：
#   cd <你的 routes 仓库> && cp "$OUT_DIR/return.json" "fragments/return-$(hostname).json" \
#     && git add . && git commit -m "update return routes $(date -u +%FT%TZ)" && git push
# 需要用户提供：仓库地址 + 推送凭证（deploy key 或 PAT）。凭证不要写进脚本。
#
set -euo pipefail

SERVER_NAME="${SERVER_NAME:-$(hostname)}"
SERVER_IP="${SERVER_IP:-$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true)}"
OUT_DIR="${OUT_DIR:-/var/lib/cf-routes}"
CACHE_FILE="${CACHE_FILE:-$OUT_DIR/asn-cache.json}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 探测目标（三网各一个）。选取理由见 README「mtr 目标 IP 的选取理由」。
# 格式：运营商:目标 IP
TARGETS=(
  "telecom:202.97.12.29"
  "unicom:218.105.2.5"
  "mobile:211.136.17.107"
)

log() { echo "[$(date -u +%FT%TZ)] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    log "当前不是 root，尝试用 sudo 提权"
    exec sudo "$0" "$@"
  else
    log "错误：请用 root 身份运行（mtr 需要 raw socket，装包也需要 root）" >&2
    exit 1
  fi
fi

# 装依赖：mtr（采集）、python3（解析 ASN、拼 JSON）、curl（探测本机 IP）
for cmd in mtr python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "正在安装 $cmd ..."
    apt-get update -qq && apt-get install -y -qq mtr python3 curl
  fi
done

mkdir -p "$OUT_DIR"

if [ -z "$SERVER_IP" ]; then
  log "警告：探测不到本机公网 IP，routes.json 里将没有 ip 字段（只按名字匹配）"
fi
log "服务器：$SERVER_NAME（$SERVER_IP），结果写到 $OUT_DIR/return.json"

for spec in "${TARGETS[@]}"; do
  carrier="${spec%%:*}"
  target="${spec##*:}"
  log "mtr $carrier -> $target ..."
  # -n 不反解域名，-j 输出 JSON，-c 10 跑 10 轮；120 秒超时兜底。
  if ! timeout 120 mtr -n -j -c 10 "$target" > "$WORK_DIR/$carrier.json" 2>"$WORK_DIR/$carrier.err"; then
    log "警告：mtr $carrier 失败（$(head -c 200 "$WORK_DIR/$carrier.err" | tr '\n' ' ')），该运营商记为未测"
    echo '{"report":{"hubs":[]}}' > "$WORK_DIR/$carrier.json"
  fi
done

# 解析：把三份 mtr JSON 拼成 routes.json 片段。
# ASN 查询用 ip-api.com 的 batch 接口（一次 POST 最多 100 个 IP，免费），
# 结果缓存在 $CACHE_FILE，下次只查新出现的 IP。
python3 - "$WORK_DIR" "$OUT_DIR/return.json" "$CACHE_FILE" "$SERVER_NAME" "$SERVER_IP" <<'PYEOF'
import json
import os
import re
import sys
import urllib.request

work_dir, out_path, cache_path, server_name, server_ip = sys.argv[1:6]

# 骨干优先级：一条路径里同时出现多个同运营商 AS 时，取排在最前面的那个。
# （例如诺连回程是 AS979 → AS10099 → AS9929，要认 9929 而不是 10099。）
PRIORITY = {
    "telecom": [("AS4809", "CN2GIA"), ("AS4134", "163"), ("AS23764", "CTGNet")],
    "unicom": [("AS9929", "9929"), ("AS4837", "4837"), ("AS10099", "10099")],
    "mobile": [("AS58807", "CMIN2"), ("AS58453", "CMI"), ("AS9808", "CMNET")],
}

# 不参与 AS 判断的地址：私网、链路本地、CGNAT、未响应（*）。
PRIVATE_RE = re.compile(
    r"^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)"
)

def load_cache(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

def save_cache(path, cache):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, sort_keys=True)

def batch_lookup_ips(ips):
    """用 ip-api.com batch 接口一次查多个 IP 的 ASN，返回 {ip: 'ASxxxx' | None}。"""
    out = {}
    for i in range(0, len(ips), 100):
        chunk = ips[i : i + 100]
        body = json.dumps([{"query": ip} for ip in chunk]).encode("utf-8")
        req = urllib.request.Request(
            "http://ip-api.com/batch",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                rows = json.load(resp)
        except Exception as exc:  # noqa: BLE001 - 网络失败时留空，不中断采集
            print(f"ASN 查询失败（batch）：{exc}", file=sys.stderr)
            return out
        for row in rows:
            ip = row.get("query")
            m = re.search(r"AS(\d+)", row.get("as") or "")
            out[ip] = f"AS{m.group(1)}" if m else None
    return out

def parse_mtr(path):
    """读一份 mtr JSON，返回 (as_path, latency_ms, loss_pct)。"""
    try:
        with open(path, encoding="utf-8") as f:
            hubs = json.load(f)["report"]["hubs"]
    except (OSError, ValueError, KeyError):
        return [], None, None
    hop_ips = []
    last = None
    for hub in hubs:
        host = hub.get("host") or ""
        if host in ("???", "") or PRIVATE_RE.match(host):
            continue
        hop_ips.append(host)
        last = hub
    latency = None
    loss = None
    if last is not None:
        avg = last.get("Avg")
        if isinstance(avg, (int, float)) and avg > 0 and (last.get("Loss%") or 0) < 100:
            latency = round(float(avg), 1)
        if isinstance(last.get("Loss%"), (int, float)):
            loss = round(float(last["Loss%"]), 1)
    return hop_ips, latency, loss

# 1. 先读三份 mtr，收集所有要查的 hop IP。
per_carrier = {}
all_ips = set()
for carrier in ("telecom", "unicom", "mobile"):
    hop_ips, latency, loss = parse_mtr(os.path.join(work_dir, f"{carrier}.json"))
    per_carrier[carrier] = (hop_ips, latency, loss)
    all_ips.update(hop_ips)

# 2. 查 ASN（先读缓存，只查新 IP）。
cache = load_cache(cache_path)
todo = sorted(ip for ip in all_ips if ip not in cache)
if todo:
    cache.update(batch_lookup_ips(todo))
    save_cache(cache_path, cache)

# 3. 按优先级定标签，拼片段。
fragment = {
    "name": server_name,
    "ip": server_ip or None,
    "carriers": {},
    "measured_at": __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
for carrier, (hop_ips, latency, loss) in per_carrier.items():
    asns = [cache.get(ip) for ip in hop_ips]
    # as_path：按跳数顺序，去掉连续重复和查不到 ASN 的跳。
    as_path = []
    for asn in asns:
        if asn and (not as_path or as_path[-1] != asn):
            as_path.append(asn)
    label = None
    if hop_ips:
        label = "unknown"
        for asn, name in PRIORITY[carrier]:
            if asn in as_path:
                label = name
                break
    fragment["carriers"][carrier] = {
        "return": {
            "label": label,
            "as_path": as_path,
            "latency_ms": latency,
            "loss_pct": loss,
            "measured_at": fragment["measured_at"],
        }
    }

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(fragment, f, ensure_ascii=False, indent=2)
print(f"WROTE {out_path}")
print(json.dumps(fragment, ensure_ascii=False, indent=2))
PYEOF

log "完成。片段已写到 $OUT_DIR/return.json（只含回程；去程由 Windows 脚本采）"
