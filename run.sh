#!/usr/bin/env bash
# =============================================================================
#  run.sh — Entrypoint duy nhất để triển khai / vận hành hệ thống monitoring
#  v6.1 — Bug fixes + structure cleanup
# =============================================================================
#
#  Cách dùng:
#    ./run.sh site        — Deploy toàn bộ hệ thống (full)
#    ./run.sh reconfig    — Cập nhật cấu hình (targets, alert rules, config...)
#    ./run.sh upgrade     — Nâng cấp version các thành phần
#    ./run.sh add-node    — Thêm node mới vào hệ thống
#    ./run.sh destroy     — Gỡ bỏ toàn bộ hệ thống
#    ./run.sh verify      — Kiểm tra sức khỏe hệ thống
#    ./run.sh help        — Hiển thị hướng dẫn này
#
#  Stack commands:
#    ./run.sh infra       — Deploy infra stack (common+docker+keepalived+haproxy)
#    ./run.sh monitoring  — Deploy monitoring stack (VictoriaMetrics+vmagent+alertmanager)
#    ./run.sh grafana     — Deploy visualization (Grafana+PostgreSQL)
#    ./run.sh logging     — Deploy logging stack (Loki+Promtail+MinIO)
#    ./run.sh gitops      — Deploy GitOps (Gitea)
#
#  Exporter commands:
#    ./run.sh exporters          — Deploy tất cả exporters
#    ./run.sh node-exporter      — Deploy node_exporter only
#    ./run.sh blackbox           — Deploy blackbox/random-ping
#    ./run.sh ceph-exporter      — Deploy Ceph exporter
#    ./run.sh openstack-exporter — Deploy OpenStack exporter
#
#  Reconfig commands (không downtime):
#    ./run.sh reconfig                 — Reconfig toàn bộ
#    ./run.sh reconfig-monitoring      — Reload vmagent + alert rules
#    ./run.sh reconfig-grafana         — Reload Grafana datasources
#    ./run.sh reconfig-logging         — Reload Loki + Promtail
#    ./run.sh reconfig-alertmanager    — Reload Alertmanager
#    ./run.sh reconfig-haproxy         — Reload HAProxy backends
#    ./run.sh reconfig-exporters       — Reload scrape targets
#
#  Operations:
#    ./run.sh scale       — Mở rộng hệ thống (thêm monitoring node)
#    ./run.sh backup      — Backup dữ liệu
#    ./run.sh promote-pg <node> — PostgreSQL failover
#
#  Tùy chọn thêm:
#    --limit <node>       — Chỉ chạy trên node chỉ định (vd: --limit node01)
#    --check              — Dry-run, không thay đổi thực tế
#    --tags <tag>         — Chỉ chạy task có tag nhất định
#    --verbose            — Hiển thị log chi tiết (-vvv)
#
#  Ví dụ:
#    ./run.sh site --check
#    ./run.sh reconfig-monitoring --limit node01
#    ./run.sh upgrade --tags victoriametrics
#    ./run.sh promote-pg node02
# =============================================================================

set -euo pipefail

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory"
PLAYBOOKS_DIR="$SCRIPT_DIR/playbooks"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ansible-$(date +%Y%m%d-%H%M%S).log"

ACTION="${1:-help}"
shift || true

# [FIX] Dùng array thay vì string để tránh word-splitting với args phức tạp
# Ví dụ: ./run.sh monitoring -e "node_groups=['compute_hn4']" --check
EXTRA_ARGS=("$@")

# ── Banner ──
banner() {
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║     VNPT Cloud — HA Monitoring System                   ║"
    echo "  ║     VictoriaMetrics + Grafana + HAProxy + Keepalived     ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Log helpers ──
log_info()    { echo -e "  ${GREEN}[✔]${NC} $*"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "  ${RED}[✘]${NC} $*"; }
log_section() { echo -e "\n  ${BOLD}${CYAN}▶ $*${NC}"; echo "  $(printf '─%.0s' {1..55})"; }

# ── Pre-flight checks ──
preflight() {
    log_section "Kiểm tra môi trường"
    local ok=true

    command -v ansible-playbook >/dev/null 2>&1 \
        && log_info "Ansible: $(ansible --version | head -1)" \
        || { log_error "Ansible chưa được cài đặt!"; ok=false; }

    [ -d "$INVENTORY" ] \
        && log_info "Inventory: $INVENTORY" \
        || { log_error "Không tìm thấy inventory directory: $INVENTORY"; ok=false; }

    [ -f "$HOME/.ssh/id_rsa" ] \
        && log_info "SSH key: ~/.ssh/id_rsa" \
        || log_warn "Không tìm thấy ~/.ssh/id_rsa — đảm bảo SSH key đã được cấu hình"

    $ok || exit 1

    log_section "Kiểm tra kết nối nodes"
    ansible all -i "$INVENTORY" -m ping --one-line 2>/dev/null \
        && log_info "Tất cả nodes phản hồi OK" \
        || log_warn "Một số node không phản hồi — vẫn tiếp tục..."
}

# ── Vault pre-deploy check ──
vault_check() {
    local vault_file="$SCRIPT_DIR/inventory/group_vars/all/vault.yml"
    log_section "Kiểm tra vault.yml"

    if [ ! -f "$vault_file" ]; then
        log_error "Không tìm thấy vault.yml! Chạy: make init"
        log_error "  cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml"
        log_error "  ansible-vault encrypt inventory/group_vars/all/vault.yml"
        exit 1
    fi

    if head -1 "$vault_file" | grep -q '^\$ANSIBLE_VAULT'; then
        log_info "vault.yml đã được mã hóa ✅"
    else
        log_error "vault.yml CHƯA được mã hóa!"
        log_error "Chạy: make vault-encrypt"
        exit 1
    fi
}

# ── Run playbook ──
# Usage: run_playbook <playbook_path> <description> [extra ansible args...]
run_playbook() {
    local playbook="$1"
    local desc="$2"
    shift 2

    log_section "$desc"
    echo -e "  ${YELLOW}Playbook:${NC} $playbook"
    echo -e "  ${YELLOW}Log file:${NC} $LOG_FILE"
    echo ""

    ansible-playbook \
        -i "$INVENTORY" \
        "$PLAYBOOKS_DIR/$playbook" \
        "${EXTRA_ARGS[@]}" \
        "$@" \
        2>&1 | tee -a "$LOG_FILE"

    local rc=${PIPESTATUS[0]}
    if [ $rc -eq 0 ]; then
        log_info "Hoàn thành: $desc"
    else
        log_error "Thất bại: $desc (exit code $rc)"
        log_error "Xem log: $LOG_FILE"
        exit $rc
    fi
}

# ── ACTIONS ──

do_deploy() {
    banner
    echo -e "  ${BOLD}Action: DEPLOY${NC} — Triển khai toàn bộ hệ thống lần đầu"
    echo ""
    log_warn "Quá trình này sẽ cài đặt và cấu hình toàn bộ stack monitoring."
    log_warn "Đảm bảo vault.yml đã được cấu hình (xem vault.yml.example)"
    echo ""
    read -rp "  Xác nhận tiếp tục? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }

    vault_check
    preflight

    run_playbook "site.yml" "Deploy toàn bộ hệ thống" --ask-vault-pass

    echo ""
    echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${BOLD}${GREEN}║  🎉 TRIỂN KHAI HOÀN THÀNH!                      ║${NC}"
    echo -e "  ${BOLD}${GREEN}║                                                  ║${NC}"
    echo -e "  ${BOLD}${GREEN}║  Grafana:       http://VIP:80                    ║${NC}"
    echo -e "  ${BOLD}${GREEN}║  HAProxy Stats: http://VIP:8404/stats            ║${NC}"
    echo -e "  ${BOLD}${GREEN}║  Gitea:         http://node01:3001               ║${NC}"
    echo -e "  ${BOLD}${GREEN}║  Alertmanager:  http://VIP:9093                  ║${NC}"
    echo -e "  ${BOLD}${GREEN}║  Loki:          http://VIP:3100                  ║${NC}"
    echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
}

do_reconfig() {
    banner
    echo -e "  ${BOLD}Action: RECONFIG${NC} — Cập nhật cấu hình hệ thống"
    echo ""
    echo -e "  Chọn loại reconfig:"
    echo -e "  ${CYAN}[1]${NC} Cập nhật scrape targets (thêm/xóa server monitored)"
    echo -e "  ${CYAN}[2]${NC} Cập nhật alert rules"
    echo -e "  ${CYAN}[3]${NC} Cập nhật HAProxy config"
    echo -e "  ${CYAN}[4]${NC} Cập nhật Grafana datasource/provisioning"
    echo -e "  ${CYAN}[5]${NC} Cập nhật Alertmanager routing (Telegram, email...)"
    echo -e "  ${CYAN}[6]${NC} Cập nhật Loki + Promtail"
    echo -e "  ${CYAN}[7]${NC} Reconfig toàn bộ"
    echo ""
    read -rp "  Lựa chọn [1-7]: " choice

    case "$choice" in
        1) run_playbook "reconfig/exporters.yml"     "Cập nhật scrape targets" ;;
        2) run_playbook "reconfig/monitoring.yml"    "Cập nhật alert rules + vmagent" ;;
        3) run_playbook "reconfig/haproxy.yml"       "Cập nhật HAProxy config" ;;
        4) run_playbook "reconfig/grafana.yml"       "Cập nhật Grafana config" ;;
        5) run_playbook "reconfig/alertmanager.yml"  "Cập nhật Alertmanager routing" ;;
        6) run_playbook "reconfig/logging.yml"       "Cập nhật Loki + Promtail" ;;
        7) run_playbook "reconfig/all.yml"           "Reconfig toàn bộ hệ thống" ;;
        *) log_error "Lựa chọn không hợp lệ"; exit 1 ;;
    esac
}

do_upgrade() {
    banner
    echo -e "  ${BOLD}Action: UPGRADE${NC} — Nâng cấp version các thành phần"
    echo ""
    echo -e "  ${YELLOW}Version hiện tại (trong group_vars/all.yml):${NC}"
    grep -E "_version:" "$SCRIPT_DIR/inventory/group_vars/all/main.yml" | \
        sed 's/^/    /' || true
    echo ""
    log_warn "Upgrade sẽ rolling update từng node, không downtime."
    read -rp "  Xác nhận upgrade? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }

    run_playbook "ops/upgrade.yml" "Upgrade tất cả components" \
        --extra-vars "confirm_upgrade=true"
}

do_add_node() {
    banner
    echo -e "  ${BOLD}Action: ADD-NODE${NC} — Thêm server mới vào hệ thống monitoring"
    echo ""
    echo -e "  ${YELLOW}Lưu ý:${NC} Trước tiên hãy thêm server vào inventory/"
    echo ""
    read -rp "  Nhập hostname của node mới: " new_node
    [ -z "$new_node" ] && { log_error "Hostname không được để trống"; exit 1; }

    run_playbook "ops/add-node.yml" "Thêm node mới: $new_node" \
        --limit "$new_node" \
        --extra-vars "new_node=$new_node"
}

do_destroy() {
    banner
    echo -e "  ${BOLD}${RED}Action: DESTROY${NC} — Gỡ bỏ toàn bộ hệ thống monitoring"
    echo ""
    log_error "CẢNH BÁO: Hành động này sẽ XÓA TOÀN BỘ containers, volumes, config!"
    log_error "Dữ liệu metrics sẽ MẤT VĨNH VIỄN nếu không backup trước!"
    echo ""
    read -rp "  Gõ 'DESTROY' để xác nhận: " confirm
    [ "$confirm" != "DESTROY" ] && { echo "  Hủy bỏ."; exit 0; }

    run_playbook "ops/destroy.yml" "Gỡ bỏ toàn bộ hệ thống" \
        --extra-vars "confirm_destroy=true"
}

do_verify() {
    banner
    echo -e "  ${BOLD}Action: VERIFY${NC} — Kiểm tra sức khỏe hệ thống"
    echo ""
    run_playbook "ops/verify.yml" "Health check toàn bộ hệ thống"
}

do_scale() {
    banner
    echo -e "  ${BOLD}Action: SCALE${NC} — Scale từng service cụ thể"
    echo ""
    echo -e "  ${BOLD}Trạng thái hiện tại:${NC}"
    ansible-inventory -i "$INVENTORY" --list 2>/dev/null | python3 -c "
import sys, json
inv = json.load(sys.stdin)
groups = [
    ('monitoring_lb',           'Keepalived + HAProxy (LB)'),
    ('monitoring_storage',      'vmstorage             '),
    ('monitoring_query',        'vminsert + vmselect   '),
    ('monitoring_grafana',      'Grafana               '),
    ('monitoring_vmagent',      'vmagent               '),
    ('monitoring_alertmanager', 'Alertmanager          '),
    ('monitoring_db',           'PostgreSQL            '),
    ('monitoring_gitea',        'Gitea + Runner        '),
]
for g, label in groups:
    hosts = inv.get(g, {}).get('hosts', [])
    print(f'  {label}: {len(hosts)} nodes')
" 2>/dev/null || true
    echo ""
    echo -e "  Chọn service muốn scale:"
    echo -e "  ${CYAN}[1]${NC} vmstorage       — storage đầy / I/O cao"
    echo -e "  ${CYAN}[2]${NC} vminsert/select — ingestion cao / query chậm"
    echo -e "  ${CYAN}[3]${NC} Grafana         — nhiều user / dashboard nặng"
    echo -e "  ${CYAN}[4]${NC} vmagent         — nhiều targets / scrape miss"
    echo -e "  ${CYAN}[5]${NC} Alertmanager    — thêm redundancy"
    echo -e "  ${CYAN}[6]${NC} Tất cả services"
    echo ""
    echo -e "  ${YELLOW}Lưu ý:${NC} Thêm node vào đúng group trong inventory/ trước!"
    echo ""
    read -rp "  Lựa chọn [1-6]: " choice

    case "$choice" in
        1) run_playbook "ops/scale.yml" "Scale vmstorage"         --tags scale-storage ;;
        2) run_playbook "ops/scale.yml" "Scale vminsert/vmselect" --tags scale-query ;;
        3) run_playbook "ops/scale.yml" "Scale Grafana"           --tags scale-grafana ;;
        4) run_playbook "ops/scale.yml" "Scale vmagent"           --tags scale-vmagent ;;
        5) run_playbook "ops/scale.yml" "Scale Alertmanager"      --tags scale-alertmanager ;;
        6) run_playbook "ops/scale.yml" "Scale tất cả services" ;;
        *) log_error "Lựa chọn không hợp lệ"; exit 1 ;;
    esac
}

do_promote_pg() {
    # [FIX] Lấy tham số từ EXTRA_ARGS[0] thay vì biến positional $2 (đã bị shift)
    local target_node="${EXTRA_ARGS[0]:-}"

    if [[ -z "$target_node" ]]; then
        log_error "Thiếu tham số: ./run.sh promote-pg <node>"
        echo "  Ví dụ: ./run.sh promote-pg node02"
        exit 1
    fi

    # Xóa node khỏi EXTRA_ARGS để không truyền lại vào ansible-playbook
    EXTRA_ARGS=("${EXTRA_ARGS[@]:1}")

    banner
    echo -e "  ${BOLD}Action: PROMOTE-PG${NC} — PostgreSQL failover"
    echo ""
    log_warn "Promote '$target_node' lên PostgreSQL primary."
    log_warn "Đảm bảo primary hiện tại đã DOWN trước khi thực hiện!"
    echo ""
    read -rp "  Xác nhận promote $target_node? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }

    run_playbook "ops/promote-replica.yml" \
        "PostgreSQL failover — promote $target_node lên primary" \
        -e "target_node=$target_node" --ask-vault-pass
}

do_help() {
    banner
    echo -e "  ${BOLD}Cách dùng:${NC}  ./run.sh <action> [options]"
    echo ""
    echo -e "  ${BOLD}Full Deploy:${NC}"
    echo -e "  ${GREEN}site${NC}        Deploy toàn bộ hệ thống"
    echo -e "  ${GREEN}deploy${NC}      Alias cho site (legacy)"
    echo ""
    echo -e "  ${BOLD}Stack Deploy:${NC}"
    echo -e "  ${GREEN}infra${NC}       Deploy infra stack (common+docker+keepalived+haproxy)"
    echo -e "  ${GREEN}monitoring${NC}  Deploy monitoring stack (VictoriaMetrics+vmagent+alertmanager)"
    echo -e "  ${GREEN}grafana${NC}     Deploy visualization (Grafana+PostgreSQL)"
    echo -e "  ${GREEN}logging${NC}     Deploy logging stack (Loki+Promtail+MinIO)"
    echo -e "  ${GREEN}gitops${NC}      Deploy GitOps (Gitea)"
    echo ""
    echo -e "  ${BOLD}Exporter Deploy:${NC}"
    echo -e "  ${GREEN}exporters${NC}          Deploy tất cả exporters"
    echo -e "  ${GREEN}node-exporter${NC}      Deploy node_exporter only"
    echo -e "  ${GREEN}blackbox${NC}           Deploy blackbox/random-ping"
    echo -e "  ${GREEN}ceph-exporter${NC}      Deploy Ceph exporter"
    echo -e "  ${GREEN}openstack-exporter${NC} Deploy OpenStack exporter"
    echo -e "  ${GREEN}gen-config${NC}         Generate vmagent scrape configs từ inventory"
    echo ""
    echo -e "  ${BOLD}Reconfig (no downtime):${NC}"
    echo -e "  ${CYAN}reconfig${NC}               Reconfig toàn bộ (interactive)"
    echo -e "  ${CYAN}reconfig-monitoring${NC}    Reload vmagent + alert rules"
    echo -e "  ${CYAN}reconfig-grafana${NC}       Reload Grafana datasources"
    echo -e "  ${CYAN}reconfig-logging${NC}       Reload Loki + Promtail"
    echo -e "  ${CYAN}reconfig-alertmanager${NC}  Reload Alertmanager"
    echo -e "  ${CYAN}reconfig-haproxy${NC}       Reload HAProxy backends"
    echo -e "  ${CYAN}reconfig-exporters${NC}     Reload scrape targets"
    echo ""
    echo -e "  ${BOLD}Operations:${NC}"
    echo -e "  ${GREEN}init${NC}              Khởi tạo vault passwords lần đầu"
    echo -e "  ${GREEN}upgrade${NC}           Nâng cấp version các thành phần"
    echo -e "  ${GREEN}scale${NC}             Mở rộng hệ thống (thêm monitoring node)"
    echo -e "  ${GREEN}add-node${NC}          Thêm server monitored mới (cài node_exporter)"
    echo -e "  ${GREEN}backup${NC}            Backup dữ liệu"
    echo -e "  ${GREEN}verify${NC}            Kiểm tra sức khỏe hệ thống"
    echo -e "  ${GREEN}promote-pg <node>${NC} PostgreSQL failover — promote node lên primary"
    echo -e "  ${RED}destroy${NC}           Gỡ bỏ toàn bộ hệ thống"
    echo ""
    echo -e "  ${BOLD}Options:${NC}"
    echo -e "  ${CYAN}--limit <node>${NC}    Chỉ chạy trên node chỉ định"
    echo -e "  ${CYAN}--check${NC}           Dry-run, không thay đổi thực tế"
    echo -e "  ${CYAN}--tags <tag>${NC}      Chỉ chạy task có tag nhất định"
    echo -e "  ${CYAN}--verbose${NC}         Hiển thị log chi tiết (-vvv)"
    echo ""
    echo -e "  ${BOLD}Ví dụ:${NC}"
    echo -e "  ${YELLOW}./run.sh site${NC}                         # Deploy toàn bộ"
    echo -e "  ${YELLOW}./run.sh infra${NC}                        # Chỉ deploy infra"
    echo -e "  ${YELLOW}./run.sh monitoring${NC}                   # Chỉ deploy monitoring stack"
    echo -e "  ${YELLOW}./run.sh reconfig-monitoring${NC}          # Reload alert rules"
    echo -e "  ${YELLOW}./run.sh node-exporter --limit node01${NC} # Thêm node_exporter"
    echo -e "  ${YELLOW}./run.sh promote-pg node02${NC}            # Promote node02 lên PG primary"
    echo -e "  ${YELLOW}./run.sh site --check${NC}                 # Dry-run deploy"
    echo ""
}

do_init() {
    banner
    echo -e "  ${BOLD}Action: INIT${NC} — Khởi tạo vault passwords lần đầu"
    echo ""
    bash "$SCRIPT_DIR/scripts/gen-vault.sh"
}

# ── Dispatch ──
case "$ACTION" in
    # ── Full deploy ──────────────────────────────────────────────────────────
    site)
        vault_check
        preflight
        run_playbook "site.yml" "Deploy toàn bộ hệ thống" --ask-vault-pass
        ;;
    deploy)
        # Legacy alias for 'site'
        do_deploy
        ;;

    # ── Stack deploy ─────────────────────────────────────────────────────────
    infra)
        vault_check
        run_playbook "stacks/infra.yml" \
            "Deploy Infrastructure (common+docker+keepalived+haproxy)" --ask-vault-pass
        ;;
    monitoring)
        vault_check
        run_playbook "stacks/monitoring.yml" \
            "Deploy Monitoring Stack (VictoriaMetrics+vmagent+alertmanager)" --ask-vault-pass
        ;;
    grafana)
        vault_check
        run_playbook "stacks/grafana.yml" \
            "Deploy Grafana Stack (PostgreSQL+Grafana)" --ask-vault-pass
        ;;
    logging)
        vault_check
        run_playbook "stacks/logging.yml" \
            "Deploy Logging Stack (MinIO+Loki+Promtail)" --ask-vault-pass
        ;;
    gitops)
        vault_check
        run_playbook "stacks/gitops.yml" \
            "Deploy GitOps Stack (Gitea)" --ask-vault-pass
        ;;

    # ── Exporter deploy ──────────────────────────────────────────────────────
    exporters)
        run_playbook "exporters/all.yml" "Deploy tất cả exporters"
        ;;
    node-exporter)
        run_playbook "exporters/node-exporter.yml" "Deploy node_exporter"
        ;;
    blackbox)
        run_playbook "exporters/blackbox.yml" "Deploy Blackbox + Random Ping"
        ;;
    ceph-exporter)
        run_playbook "exporters/ceph-exporter.yml" "Deploy Ceph Exporter"
        ;;
    openstack-exporter)
        run_playbook "exporters/openstack-exporter.yml" "Deploy OpenStack Exporter"
        ;;
    telegraf)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf (multi-config per group)"
        ;;
    telegraf-compute)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf — compute nodes" "--limit compute"
        ;;
    telegraf-gpu)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf — compute GPU nodes" "--limit compute_gpu"
        ;;
    telegraf-controller)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf — controller nodes" "--limit controller"
        ;;
    telegraf-network)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf — network nodes" "--limit network"
        ;;
    telegraf-ceph)
        run_playbook "exporters/telegraf.yml" "Deploy Telegraf — ceph nodes" "--limit ceph"
        ;;
    gen-config)
        run_playbook "exporters/gen-config.yml" \
            "Generate vmagent scrape configs từ inventory"
        ;;

    # ── Reconfig (no downtime) ───────────────────────────────────────────────
    reconfig)
        do_reconfig
        ;;
    reconfig-monitoring)
        run_playbook "reconfig/monitoring.yml" "Reconfig vmagent + alert rules"
        ;;
    reconfig-grafana)
        run_playbook "reconfig/grafana.yml" "Reconfig Grafana datasources"
        ;;
    reconfig-logging)
        run_playbook "reconfig/logging.yml" "Reconfig Loki + Promtail"
        ;;
    reconfig-alertmanager)
        run_playbook "reconfig/alertmanager.yml" "Reconfig Alertmanager"
        ;;
    reconfig-haproxy)
        run_playbook "reconfig/haproxy.yml" "Reconfig HAProxy backends"
        ;;
    reconfig-exporters)
        run_playbook "reconfig/exporters.yml" "Reload scrape targets"
        ;;

    # ── Operations ───────────────────────────────────────────────────────────
    upgrade)   do_upgrade ;;
    scale)     do_scale ;;
    add-node)  do_add_node ;;
    init|setup) do_init ;;
    destroy)   do_destroy ;;
    verify)    do_verify ;;
    promote-pg) do_promote_pg ;;
    backup)
        vault_check
        run_playbook "ops/backup.yml" \
            "Backup VictoriaMetrics + PostgreSQL + Grafana dashboards" --ask-vault-pass
        ;;

    # ── Help ─────────────────────────────────────────────────────────────────
    help|--help|-h)
        do_help
        ;;
    *)
        log_error "Action không hợp lệ: '$ACTION'"
        echo ""
        do_help
        exit 1
        ;;
esac
