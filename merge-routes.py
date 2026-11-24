#!/usr/bin/env python3
"""merge-routes.py —— 把采集片段汇总成 routes.json。

两种片段都能吃：
  形状 A（collect-return.sh，单台 VPS 的回程）：
      {"name": "诺连-LAX", "ip": "64.81.27.128",
       "carriers": {"telecom": {"return": {...}}, ...}, "measured_at": "..."}
  形状 B（collect-outbound.ps1，多台 VPS 的去程）：
      {"version": 1, "updated_at": "...",
       "servers": {"诺连-LAX": {"ip": "...", "carriers": {...}}, ...}}

合并规则：只用片段里“有实测数据”的方向覆盖旧数据
（label 不是 null，或 as_path 非空）；没测到的方向不覆盖、不清空。

用法：
  # 在放 routes.json 的仓库里：
  python3 merge-routes.py --out routes.json fragments/*.json
  # 想保留旧文件里已有的数据，先把它也当作输入：
  python3 merge-routes.py --out routes.json routes.json fragments/*.json

依赖：只有 Python 3 标准库。
"""

import argparse
import copy
import json
import sys
from datetime import datetime, timezone


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def has_data(direction):
    """一个方向算不算有实测数据。"""
    if not isinstance(direction, dict):
        return False
    return bool(direction.get("label")) or bool(direction.get("as_path"))


def empty_direction():
    return {
        "label": None,
        "as_path": [],
        "latency_ms": None,
        "loss_pct": None,
        "measured_at": None,
    }


def merge_direction(dst, src):
    """用 src 覆盖 dst（只有 src 有实测数据时才覆盖），返回是否改动。"""
    if not has_data(src):
        return False
    changed = False
    for key in ("label", "as_path", "latency_ms", "loss_pct", "measured_at"):
        if src.get(key) != dst.get(key):
            dst[key] = copy.deepcopy(src.get(key))
            changed = True
    return changed


def merge_server(dst_servers, name, entry):
    """把一台服务器的片段并进 dst_servers，返回改动的说明列表。"""
    notes = []
    ip = entry.get("ip")
    carriers = entry.get("carriers") or {}
    if not isinstance(carriers, dict):
        return notes
    server = dst_servers.setdefault(name, {"ip": ip, "carriers": {}})
    if ip and not server.get("ip"):
        server["ip"] = ip
    for carrier_name, carrier in carriers.items():
        if not isinstance(carrier, dict):
            continue
        dst_carrier = server["carriers"].setdefault(carrier_name, {})
        for direction in ("return", "outbound"):
            src_dir = carrier.get(direction)
            if not isinstance(src_dir, dict):
                continue
            dst_dir = dst_carrier.setdefault(direction, empty_direction())
            if merge_direction(dst_dir, src_dir):
                notes.append(f"{name}/{carrier_name}/{direction} -> {src_dir.get('label')}")
    return notes


def normalize_fragment(data):
    """把形状 A / B 统一成 {name: entry}，并返回文件的 updated_at。"""
    if not isinstance(data, dict):
        return {}, None
    if isinstance(data.get("servers"), dict):
        return data["servers"], data.get("updated_at")
    if isinstance(data.get("name"), str) and isinstance(data.get("carriers"), dict):
        return {data["name"]: data}, data.get("measured_at")
    return {}, None


def main(argv=None):
    parser = argparse.ArgumentParser(description="把线路采集片段汇总成 routes.json")
    parser.add_argument("inputs", nargs="+", help="片段文件（可多个），也可以把旧的 routes.json 放进来")
    parser.add_argument("--out", required=True, help="输出的 routes.json 路径")
    args = parser.parse_args(argv)

    merged = {"version": 1, "updated_at": utcnow(), "servers": {}}
    changed_notes = []
    for path in args.inputs:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as exc:
            print(f"跳过 {path}：读不到或不是合法 JSON（{exc}）", file=sys.stderr)
            continue
        # 顺序即优先级：旧的 routes.json 放最前面当底子，后面的片段覆盖它。
        # （方向级合并：片段里没测到的方向不会覆盖已有数据。）
        servers, _stamp = normalize_fragment(data)
        for name, entry in servers.items():
            changed_notes.extend(merge_server(merged["servers"], name, entry))

    merged["updated_at"] = utcnow()
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"写出 {args.out}，共 {len(merged['servers'])} 台服务器")
    for note in changed_notes:
        print(f"  更新：{note}")
    if not changed_notes:
        print("  （没有任何方向被更新：片段里可能全是未测数据）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
