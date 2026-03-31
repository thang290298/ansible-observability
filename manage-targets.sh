#!/usr/bin/env bash
# manage-targets.sh — Quản lý scrape targets
# Wrapper gọi scripts/targets_manager.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

# Kiểm tra python3 có sẵn không
if ! command -v "$PYTHON" &>/dev/null; then
    echo "❌ python3 không tìm thấy. Cài đặt: apt install python3 python3-pip"
    exit 1
fi

# Kiểm tra PyYAML
if ! "$PYTHON" -c "import yaml" &>/dev/null; then
    echo "⚠️  Cài PyYAML: pip3 install pyyaml"
    pip3 install pyyaml --quiet
fi

ACTION="${1:-help}"

case "$ACTION" in
    list|count|add|remove)
        "$PYTHON" "$SCRIPT_DIR/scripts/targets_manager.py" "$@"
        ;;
    apply)
        echo "🔄 Applying targets → reload vmagent..."
        ansible monitoring_vmagent \
            -i "$SCRIPT_DIR/inventory/hosts.yml" \
            -m uri \
            -a "url=http://localhost:8429/-/reload method=GET"
        echo "✅ vmagent reloaded"
        ;;
    help|--help|-h|*)
        echo ""
        echo "  manage-targets.sh — Quản lý scrape targets"
        echo ""
        echo "  USAGE:"
        echo "    manage-targets.sh list [job]               List tất cả targets"
        echo "    manage-targets.sh count                    Đếm targets theo job"
        echo "    manage-targets.sh add <job> <ip>           Thêm target"
        echo "      [--port 9100] [--group <name>] [--labels k=v,k=v]"
        echo "    manage-targets.sh remove <job> <ip>        Xóa target"
        echo "    manage-targets.sh apply                    Reload vmagent ngay"
        echo ""
        echo "  VÍ DỤ:"
        echo "    manage-targets.sh add node_exporter 10.1.2.100 --group compute-hn4 --labels site=HN4,cluster=sc2022"
        echo "    manage-targets.sh remove node_exporter 10.1.2.100"
        echo "    manage-targets.sh list node_exporter"
        echo "    manage-targets.sh count"
        echo "    manage-targets.sh apply"
        echo ""
        ;;
esac
