#!/usr/bin/env python3
"""按连接流量日志分析（traffic.log）。

用于回答“哪些请求被运营商算作收费流量、哪些算专属/免流”。

日志格式（制表符分隔，见 Tweak/Sources/KPKIngCore.c）：
    # ts  host  port  proto  route  up  down  status  proxy  ms
    route = queen（走王卡上游，应免流）| direct（直连兜底，应计费）

用法：
    python3 Scripts/analyze_traffic_log.py traffic.log
    python3 Scripts/analyze_traffic_log.py traffic.log traffic.log.1
    python3 Scripts/analyze_traffic_log.py --route direct traffic.log
    python3 Scripts/analyze_traffic_log.py --since 1725000000 traffic.log
"""
import argparse
import collections
import sys

HEADER = "# ts\thost\tport\tproto\troute\tup\tdown\tstatus\tproxy\tms"


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024.0:
            return f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} PB"


def parse_line(line):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        return None
    parts = line.split("\t")
    if len(parts) < 10:
        return None
    try:
        return {
            "ts": int(parts[0]),
            "host": parts[1],
            "port": int(parts[2]),
            "proto": parts[3],
            "route": parts[4],
            "up": int(parts[5]),
            "down": int(parts[6]),
            "status": int(parts[7]),
            "proxy": parts[8],
            "ms": int(parts[9]),
        }
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser(description="分析王卡转发器按连接流量日志")
    ap.add_argument("files", nargs="+", help="traffic.log / traffic.log.1 ...")
    ap.add_argument("--route", choices=["queen", "direct"], help="只看某一类路由")
    ap.add_argument("--since", type=int, help="只看该 epoch 秒之后的记录")
    ap.add_argument("--top", type=int, default=30, help="每个列表显示前 N 行（默认 30）")
    args = ap.parse_args()

    rows = []
    for path in args.files:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    rec = parse_line(line)
                    if not rec:
                        continue
                    if args.route and rec["route"] != args.route:
                        continue
                    if args.since and rec["ts"] < args.since:
                        continue
                    rows.append(rec)
        except OSError as exc:
            print(f"跳过 {path}: {exc}", file=sys.stderr)

    if not rows:
        print("没有匹配的记录。")
        return 1

    routes = collections.defaultdict(lambda: {"n": 0, "up": 0, "down": 0})
    hosts = collections.defaultdict(lambda: {"n": 0, "up": 0, "down": 0, "routes": collections.Counter()})
    for r in rows:
        route = r["route"]
        routes[route]["n"] += 1
        routes[route]["up"] += r["up"]
        routes[route]["down"] += r["down"]
        h = hosts[(r["host"], r["port"], r["proto"])]
        h["n"] += 1
        h["up"] += r["up"]
        h["down"] += r["down"]
        h["routes"][route] += 1

    first = min(r["ts"] for r in rows)
    last = max(r["ts"] for r in rows)
    print(f"记录数: {len(rows)}  时间范围: {first}..{last}")
    print()
    print("== 按路由汇总（up=上行/发送，down=下行/接收） ==")
    total_up = total_down = 0
    for route in sorted(routes):
        d = routes[route]
        total = d["up"] + d["down"]
        total_up += d["up"]
        total_down += d["down"]
        print(f"  {route:<8} 连接 {d['n']:>6}  up {human(d['up']):>10}  down {human(d['down']):>10}  合计 {human(total):>10}")
    print(f"  {'TOTAL':<8} 连接 {len(rows):>6}  up {human(total_up):>10}  down {human(total_down):>10}  合计 {human(total_up + total_down):>10}")
    print()

    print(f"== 按目标域名（Top {args.top}，按合计字节） ==")
    ranked = sorted(hosts.items(), key=lambda kv: -(kv[1]["up"] + kv[1]["down"]))
    print(f"{'host':<44} {'port':>5} {'proto':<8} {'conn':>6} {'up':>10} {'down':>10} {'routes'}")
    for (host, port, proto), d in ranked[: args.top]:
        rlabel = ",".join(f"{k}:{v}" for k, v in d["routes"].most_common())
        print(f"{host[:44]:<44} {port:>5} {proto:<8} {d['n']:>6} {human(d['up']):>10} {human(d['down']):>10} {rlabel}")

    direct = routes.get("direct")
    if direct and direct["up"] + direct["down"] > 0:
        print()
        print("== 计费嫌疑（route=direct 直连兜底）Top ==")
        billed = [(k, v) for k, v in hosts.items() if v["routes"].get("direct")]
        for (host, port, proto), d in sorted(billed, key=lambda kv: -(kv[1]["up"] + kv[1]["down"]))[: args.top]:
            print(f"{host[:44]:<44} {port:>5} {proto:<8} {d['n']:>6} {human(d['up']):>10} {human(d['down']):>10}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
