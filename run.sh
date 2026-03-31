#!/usr/bin/env bash
# =============================================================================
#  run.sh — Entrypoint duy nhất để triển khai / vận hành hệ thống monitoring
# =============================================================================
#
#  Cách dùng:
#    ./run.sh deploy      — Triển khai toàn bộ hệ thống lần đầu
#    ./run.sh reconfig    — Cập nhật cấu hình (targets, alert rules, config...)
#    ./run.sh upgrade     — Nâng cấp version các thành phần
#    ./run.sh add-node    — Thêm node mới vào hệ thống
#    ./run.sh destroy     — Gỡ bỏ toàn bộ hệ thống
#    ./run.sh verify      — Kiểm tra sức khỏe hệ thống
#    ./run.sh help        — Hiển thị hướng dẫn này
#
#  Tùy chọn thêm:
#    --limit <node>       — Chỉ chạy trên node chỉ định (vd: --limit node01)
#    --check              — Dry-run, không thay đổi thực tế
#    --tags <tag>         — Chỉ chạy task có tag nhất định
#    --verbose            — Hiển thị log chi tiết
#
#  Ví dụ:
#    ./run.sh deploy --check
#    ./run.sh reconfig --limit node01
#    ./run.sh upgrade --tags victoriametrics
# =============================================================================

set -euo pipefail

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory/hosts.yml"
PLAYBOOKS_DIR="$SCRIPT_DIR/playbooks"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ansible-$(date +%Y%m%d-%H%M%S).log"

ACTION="${1:-help}"
shift || true
EXTRA_ARGS="$*"

# ── Banner ──
banner() {
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║     VNPT Cloud — HA Monitoring System                   ║"
    echo "  ║     VictoriaMetrics + Grafana + HAProxy + Keepalived     ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Log helper ──
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

    [ -f "$INVENTORY" ] \
        && log_info "Inventory: $INVENTORY" \
        || { log_error "Không tìm thấy inventory: $INVENTORY"; ok=false; }

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
    local vault_file="$SCRIPT_DIR/inventory/group_vars/vault.yml"
    log_section "Kiểm tra vault.yml"

    if [ ! -f "$vault_file" ]; then
        log_error "Không tìm thấy vault.yml! Hãy copy từ vault.yml.example và điền secrets."
        log_error "  cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml"
        log_error "  ansible-vault encrypt inventory/group_vars/vault.yml"
        exit 1
    fi

    # Kiểm tra file đã được ansible-vault encrypt chưa
    if head -1 "$vault_file" | grep -q '^\$ANSIBLE_VAULT'; then
        log_info "vault.yml đã được mã hóa ✅"
    else
        log_error "vault.yml CHƯA được mã hóa!"
        log_error "Chạy lệnh sau trước khi deploy:"
        log_error "  ansible-vault encrypt inventory/group_vars/vault.yml"
        log_error "Hoặc dùng script tiện ích:"
        log_error "  ./scripts/vault-encrypt.sh"
        exit 1
    fi
}

# ── Run playbook ──
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
        $EXTRA_ARGS \
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

    # Tất cả deploy đi qua site.yml duy nhất — không dùng nhiều playbook riêng lẻ
    run_playbook "site.yml" "Deploy toàn bộ hệ thống" \
        --ask-vault-pass

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
    echo -e "  ${CYAN}[6]${NC} Reconfig toàn bộ"
    echo ""
    read -rp "  Lựa chọn [1-6]: " choice

    case "$choice" in
        1) run_playbook "reconfig-targets.yml"      "Cập nhật scrape targets" ;;
        2) run_playbook "reconfig-alerts.yml"       "Cập nhật alert rules" ;;
        3) run_playbook "reconfig-haproxy.yml"      "Cập nhật HAProxy config" ;;
        4) run_playbook "reconfig-grafana.yml"      "Cập nhật Grafana config" ;;
        5) run_playbook "reconfig-alertmanager.yml" "Cập nhật Alertmanager routing" ;;
        6) run_playbook "reconfig-all.yml"          "Reconfig toàn bộ hệ thống" ;;
        *) log_error "Lựa chọn không hợp lệ"; exit 1 ;;
    esac
}

do_upgrade() {
    banner
    echo -e "  ${BOLD}Action: UPGRADE${NC} — Nâng cấp version các thành phần"
    echo ""
    echo -e "  ${YELLOW}Version hiện tại (trong group_vars/all.yml):${NC}"
    grep -E "version:|_version:" "$SCRIPT_DIR/inventory/group_vars/all.yml" | \
        sed 's/^/    /' || true
    echo ""
    log_warn "Upgrade sẽ rolling update từng node, không downtime."
    read -rp "  Xác nhận upgrade? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }

    run_playbook "upgrade.yml" "Upgrade tất cả components" --extra-vars "confirm_upgrade=true"
}

do_add_node() {
    banner
    echo -e "  ${BOLD}Action: ADD-NODE${NC} — Thêm server mới vào hệ thống monitoring"
    echo ""
    echo -e "  ${YELLOW}Lưu ý:${NC} Trước tiên hãy thêm server vào inventory/hosts.yml"
    echo ""
    read -rp "  Nhập hostname của node mới: " new_node
    [ -z "$new_node" ] && { log_error "Hostname không được để trống"; exit 1; }

    run_playbook "add-node.yml" "Thêm node mới: $new_node" \
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

    run_playbook "destroy.yml" "Gỡ bỏ toàn bộ hệ thống" --extra-vars "confirm_destroy=true"
}

do_verify() {
    banner
    echo -e "  ${BOLD}Action: VERIFY${NC} — Kiểm tra sức khỏe hệ thống"
    echo ""
    run_playbook "verify.yml" "Health check toàn bộ hệ thống"
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
    echo -e "  ${YELLOW}Lưu ý:${NC} Thêm node vào đúng group trong inventory/hosts.yml trước!"
    echo ""
    read -rp "  Lựa chọn [1-6]: " choice

    case "$choice" in
        1) run_playbook "scale.yml" "Scale vmstorage"          --tags scale-storage ;;
        2) run_playbook "scale.yml" "Scale vminsert/vmselect"  --tags scale-query ;;
        3) run_playbook "scale.yml" "Scale Grafana"            --tags scale-grafana ;;
        4) run_playbook "scale.yml" "Scale vmagent"            --tags scale-vmagent ;;
        5) run_playbook "scale.yml" "Scale Alertmanager"       --tags scale-alertmanager ;;
        6) run_playbook "scale.yml" "Scale tất cả services" ;;
        *) log_error "Lựa chọn không hợp lệ"; exit 1 ;;
    esac
}

do_help() {
    banner
    echo -e "  ${BOLD}Cách dùng:${NC}  ./run.sh <action> [options]"
    echo ""
    echo -e "  ${BOLD}Actions:${NC}"
    echo -e "  ${GREEN}deploy${NC}      Triển khai toàn bộ hệ thống lần đầu"
    echo -e "  ${GREEN}reconfig${NC}    Cập nhật cấu hình (targets, alerts, LB...)"
    echo -e "  ${GREEN}upgrade${NC}     Nâng cấp version các thành phần"
    echo -e "  ${GREEN}scale${NC}       Mở rộng hệ thống (thêm monitoring node)"
    echo -e "  ${GREEN}add-node${NC}    Thêm server monitored mới (cài node_exporter)"
    echo -e "  ${GREEN}destroy${NC}     Gỡ bỏ toàn bộ hệ thống"
    echo -e "  ${GREEN}verify${NC}      Kiểm tra sức khỏe hệ thống"
    echo -e "  ${GREEN}help${NC}        Hiển thị trợ giúp này"
    echo ""
    echo -e "  ${BOLD}Options:${NC}"
    echo -e "  ${CYAN}--limit <node>${NC}    Chỉ chạy trên node chỉ định"
    echo -e "  ${CYAN}--check${NC}           Dry-run, không thay đổi thực tế"
    echo -e "  ${CYAN}--tags <tag>${NC}      Chỉ chạy task có tag nhất định"
    echo -e "  ${CYAN}--verbose${NC}         Hiển thị log chi tiết (-vvv)"
    echo ""
    echo -e "  ${BOLD}Ví dụ:${NC}"
    echo -e "  ${YELLOW}./run.sh deploy${NC}                    # Deploy toàn bộ"
    echo -e "  ${YELLOW}./run.sh reconfig${NC}                  # Cập nhật config"
    echo -e "  ${YELLOW}./run.sh upgrade${NC}                   # Upgrade version"
    echo -e "  ${YELLOW}./run.sh scale${NC}                     # Thêm monitoring node"
    echo -e "  ${YELLOW}./run.sh add-node${NC}                  # Thêm server monitored"
    echo -e "  ${YELLOW}./run.sh deploy --check${NC}            # Dry-run deploy"
    echo -e "  ${YELLOW}./run.sh reconfig --limit node01${NC}   # Reconfig 1 node"
    echo ""
}

# ── Dispatch ──
do_random_ping() {
    banner
    echo -e "  ${BOLD}Action: RANDOM-PING${NC} — Deploy Random Ping Monitoring"
    echo ""
    vault_check
    run_playbook "random-ping.yml" "Deploy Random Ping Monitoring" \
        --ask-vault-pass
}
case "$ACTION" in
    deploy)    do_deploy ;;
    reconfig)  do_reconfig ;;
    upgrade)   do_upgrade ;;
    scale)     do_scale ;;
    add-node)  do_add_node ;;
    random-ping) do_random_ping ;;
    destroy)   do_destroy ;;
    backup)
    run_playbook "backup.yml" "Backup VictoriaMetrics + PostgreSQL + Grafana dashboards" \
        --ask-vault-pass
    ;;
  promote-pg)
    if [[ -z "${2:-}" ]]; then
      log_error "Thiếu tham số: ./run.sh promote-pg <node>"
      echo "  Ví dụ: ./run.sh promote-pg node02"
      exit 1
    fi
    run_playbook "promote-replica.yml" "PostgreSQL failover — promote $2 lên primary" \
        -e "target_node=$2" --ask-vault-pass
    ;;
  verify)    do_verify ;;
    help|--help|-h) do_help ;;
    *) log_error "Action không hợp lệ: $ACTION"; do_help; exit 1 ;;
esac
