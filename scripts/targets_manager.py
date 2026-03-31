#!/usr/bin/env python3
"""
targets_manager.py — Quản lý scrape targets cho monitoring-ansible
Dùng bởi manage-targets.sh
"""
import sys
import yaml
import argparse
from pathlib import Path

TARGETS_DIR = Path(__file__).parent.parent / "targets"


def load(job: str) -> dict:
    f = TARGETS_DIR / f"{job}.yml"
    if not f.exists():
        print(f"❌ File không tồn tại: {f}", file=sys.stderr)
        sys.exit(1)
    with open(f) as fp:
        return yaml.safe_load(fp) or {"groups": []}


def save(job: str, data: dict):
    f = TARGETS_DIR / f"{job}.yml"
    with open(f, "w") as fp:
        yaml.dump(data, fp, default_flow_style=False, allow_unicode=True, sort_keys=False)


def cmd_list(args):
    jobs = [args.job] if args.job else [f.stem for f in TARGETS_DIR.glob("*.yml")]
    total = 0
    for job in jobs:
        data = load(job)
        print(f"\n\033[36m► {job}\033[0m")
        for group in (data.get("groups") or []):
            hosts = group.get("hosts") or []
            if not hosts:
                continue
            labels = group.get("labels", {})
            print(f"  [{group['name']}]  ({len(hosts)} hosts)")
            for h in hosts:
                ip = h["host"]
                port = h.get("port", 9100)
                extra = {**labels, **h.get("labels", {})}
                label_str = ", ".join(f"{k}={v}" for k, v in extra.items())
                print(f"    {ip}:{port}  {label_str}")
                total += 1
    print(f"\n\033[1mTổng: {total} targets\033[0m")


def cmd_count(args):
    total = 0
    print("\033[1mTargets theo job:\033[0m")
    for f in sorted(TARGETS_DIR.glob("*.yml")):
        data = load(f.stem)
        count = sum(len(g.get("hosts") or []) for g in (data.get("groups") or []))
        print(f"  {f.stem:<25} {count}")
        total += count
    print(f"  {'─' * 35}")
    print(f"  {'Tổng cộng':<25} {total}")


def cmd_add(args):
    data = load(args.job)
    groups = data.get("groups") or []

    # Parse labels
    extra_labels = {}
    if args.labels:
        for pair in args.labels.split(","):
            k, v = pair.strip().split("=", 1)
            extra_labels[k.strip()] = v.strip()

    # Build host entry
    host_entry = {"host": args.ip}
    if args.port != 9100:
        host_entry["port"] = args.port
    if extra_labels and args.group:
        host_entry["labels"] = extra_labels

    # Find or create group
    target_group = None
    if args.group:
        for g in groups:
            if g["name"] == args.group:
                target_group = g
                break
        if not target_group:
            target_group = {"name": args.group, "labels": extra_labels, "hosts": []}
            groups.append(target_group)
            host_entry = {"host": args.ip}
            if args.port != 9100:
                host_entry["port"] = args.port
    elif groups:
        target_group = groups[-1]

    if not target_group:
        print("❌ Không có group nào. Dùng --group <tên>.", file=sys.stderr)
        sys.exit(1)

    # Check duplicate
    existing = [h["host"] for h in (target_group.get("hosts") or [])]
    if args.ip in existing:
        print(f"⚠️  {args.ip} đã tồn tại trong group [{target_group['name']}]")
        return

    if target_group.get("hosts") is None:
        target_group["hosts"] = []
    target_group["hosts"].append(host_entry)
    data["groups"] = groups
    save(args.job, data)
    print(f"✅ Đã thêm {args.ip}:{args.port} vào group [{target_group['name']}] trong {args.job}.yml")


def cmd_remove(args):
    data = load(args.job)
    found = False
    for group in (data.get("groups") or []):
        before = len(group.get("hosts") or [])
        group["hosts"] = [h for h in (group.get("hosts") or []) if h["host"] != args.ip]
        if len(group.get("hosts", [])) < before:
            found = True
            print(f"✅ Đã xóa {args.ip} khỏi group [{group['name']}]")
    if not found:
        print(f"⚠️  Không tìm thấy {args.ip} trong {args.job}.yml")
    save(args.job, data)


def main():
    parser = argparse.ArgumentParser(description="Manage Ansible scrape targets")
    sub = parser.add_subparsers(dest="cmd")

    # list
    p = sub.add_parser("list", help="List targets")
    p.add_argument("job", nargs="?", help="Filter by job name")

    # count
    sub.add_parser("count", help="Count targets by job")

    # add
    p = sub.add_parser("add", help="Add a target")
    p.add_argument("job", help="Job name (e.g. node_exporter)")
    p.add_argument("ip", help="IP address")
    p.add_argument("--port", type=int, default=9100)
    p.add_argument("--group", help="Group name")
    p.add_argument("--labels", help="Extra labels: key=val,key=val")

    # remove
    p = sub.add_parser("remove", help="Remove a target")
    p.add_argument("job", help="Job name")
    p.add_argument("ip", help="IP address to remove")

    args = parser.parse_args()
    dispatch = {"list": cmd_list, "count": cmd_count, "add": cmd_add, "remove": cmd_remove}

    if args.cmd not in dispatch:
        parser.print_help()
        sys.exit(1)

    dispatch[args.cmd](args)


if __name__ == "__main__":
    main()
