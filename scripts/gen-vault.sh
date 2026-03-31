#!/usr/bin/env bash
# =============================================================================
#  scripts/gen-vault.sh
#  Tự động generate tất cả passwords và tạo vault.yml encrypted
#
#  Usage:
#    bash scripts/gen-vault.sh
#    bash scripts/gen-vault.sh --vault-pass-file .vault_pass
# =============================================================================

set -euo pipefail

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VAULT_FILE="$PROJECT_DIR/inventory/group_vars/vault.yml"
VAULT_PASS_FILE=""

log_info()    { echo -e "  ${GREEN}[✔]${NC} $*"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "  ${RED}[✘]${NC} $*"; }
log_section() { echo -e "\n  ${BOLD}${CYAN}▶ $*${NC}"; printf '  %s\n' "$(printf '─%.0s' {1..55})"; }

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-pass-file) VAULT_PASS_FILE="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Banner ──
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║     gen-vault.sh — Auto-generate Vault Passwords        ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Check vault.yml exists ──
log_section "Kiểm tra vault.yml"
if [ -f "$VAULT_FILE" ]; then
    if head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
        log_warn "vault.yml đã tồn tại và ĐÃ ĐƯỢC MÃ HÓA."
        echo -e "  ${RED}Overwrite sẽ xóa toàn bộ passwords hiện tại!${NC}"
        read -rp "  Tiếp tục overwrite? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }
    else
        log_warn "vault.yml đã tồn tại (chưa mã hóa)."
        read -rp "  Overwrite vault.yml với passwords mới? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }
    fi
else
    log_info "vault.yml chưa tồn tại — sẽ tạo mới."
fi

# ── Password generator ──
gen_password() {
    local length="${1:-20}"
    # Thử dùng openssl trước, fallback sang python3
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -d '=+/\n' | cut -c1-"$length"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits
print(''.join(secrets.choice(chars) for _ in range($length)))
"
    else
        log_error "Cần openssl hoặc python3 để generate password"
        exit 1
    fi
}

# ── Prompt required values ──
log_section "Nhập thông tin Telegram (bắt buộc)"
echo -e "  ${YELLOW}Các giá trị này không thể tự động gen — cần nhập tay.${NC}"
echo ""

read -rp "  vault_telegram_bot_token      : " TELEGRAM_BOT_TOKEN
while [ -z "$TELEGRAM_BOT_TOKEN" ]; do
    log_warn "Không được để trống!"
    read -rp "  vault_telegram_bot_token      : " TELEGRAM_BOT_TOKEN
done

read -rp "  vault_telegram_chat_id        : " TELEGRAM_CHAT_ID
while [ -z "$TELEGRAM_CHAT_ID" ]; do
    log_warn "Không được để trống!"
    read -rp "  vault_telegram_chat_id        : " TELEGRAM_CHAT_ID
done

read -rp "  vault_telegram_critical_chat_id [Enter = same as chat_id]: " TELEGRAM_CRITICAL_CHAT_ID
TELEGRAM_CRITICAL_CHAT_ID="${TELEGRAM_CRITICAL_CHAT_ID:-$TELEGRAM_CHAT_ID}"

read -rp "  vault_minio_root_user         [Enter = minioadmin]: " MINIO_ROOT_USER
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"

# ── Generate all passwords ──
log_section "Generate passwords tự động"

GRAFANA_ADMIN_PASS="$(gen_password 20)"
GRAFANA_DB_PASS="$(gen_password 20)"
POSTGRES_PASS="$(gen_password 20)"
VRRP_AUTH_PASS="$(gen_password 16)"
HAPROXY_STATS_PASS="$(gen_password 20)"
GITEA_DB_PASS="$(gen_password 20)"
GITEA_SECRET_KEY="$(gen_password 32)"
ANSIBLE_WEBHOOK_SECRET="$(gen_password 32)"
MINIO_ROOT_PASS="$(gen_password 24)"

log_info "Đã generate 9 passwords"

# ── Write vault.yml ──
log_section "Ghi vault.yml"

cat > "$VAULT_FILE" << EOF
---
# inventory/group_vars/vault.yml
# AUTO-GENERATED bởi scripts/gen-vault.sh — $(date '+%Y-%m-%d %H:%M:%S')
# QUAN TRỌNG: File này phải được mã hóa trước khi commit!
#   ansible-vault encrypt inventory/group_vars/vault.yml

# ── Telegram Notifications ──────────────────────────────────────────────────
vault_telegram_bot_token: "${TELEGRAM_BOT_TOKEN}"
vault_telegram_chat_id: "${TELEGRAM_CHAT_ID}"
vault_telegram_critical_chat_id: "${TELEGRAM_CRITICAL_CHAT_ID}"

# ── Grafana ─────────────────────────────────────────────────────────────────
vault_grafana_admin_password: "${GRAFANA_ADMIN_PASS}"
vault_grafana_db_password: "${GRAFANA_DB_PASS}"

# ── PostgreSQL ───────────────────────────────────────────────────────────────
vault_postgres_password: "${POSTGRES_PASS}"

# ── Network / HA ─────────────────────────────────────────────────────────────
vault_vrrp_auth_pass: "${VRRP_AUTH_PASS}"
vault_haproxy_stats_password: "${HAPROXY_STATS_PASS}"

# ── Gitea / CI ───────────────────────────────────────────────────────────────
vault_gitea_db_password: "${GITEA_DB_PASS}"
vault_gitea_secret_key: "${GITEA_SECRET_KEY}"
vault_ansible_webhook_secret: "${ANSIBLE_WEBHOOK_SECRET}"

# ── MinIO / Loki storage ─────────────────────────────────────────────────────
vault_minio_root_user: "${MINIO_ROOT_USER}"
vault_minio_root_password: "${MINIO_ROOT_PASS}"
EOF

log_info "vault.yml đã được ghi tại: $VAULT_FILE"

# ── Print summary table ──
log_section "Passwords đã gen — LƯU LẠI NGAY!"
echo ""
echo -e "  ${BOLD}${YELLOW}⚠  SAO LƯU BẢNG NÀY TRƯỚC KHI MÃ HÓA!${NC}"
echo ""
printf "  %-35s %s\n" "Biến" "Giá trị"
printf "  %s\n" "$(printf '─%.0s' {1..70})"
printf "  %-35s %s\n" "vault_grafana_admin_password"  "$GRAFANA_ADMIN_PASS"
printf "  %-35s %s\n" "vault_grafana_db_password"     "$GRAFANA_DB_PASS"
printf "  %-35s %s\n" "vault_postgres_password"       "$POSTGRES_PASS"
printf "  %-35s %s\n" "vault_vrrp_auth_pass"          "$VRRP_AUTH_PASS"
printf "  %-35s %s\n" "vault_haproxy_stats_password"  "$HAPROXY_STATS_PASS"
printf "  %-35s %s\n" "vault_gitea_db_password"       "$GITEA_DB_PASS"
printf "  %-35s %s\n" "vault_gitea_secret_key"        "$GITEA_SECRET_KEY"
printf "  %-35s %s\n" "vault_ansible_webhook_secret"  "$ANSIBLE_WEBHOOK_SECRET"
printf "  %-35s %s\n" "vault_minio_root_user"         "$MINIO_ROOT_USER"
printf "  %-35s %s\n" "vault_minio_root_password"     "$MINIO_ROOT_PASS"
printf "  %s\n" "$(printf '─%.0s' {1..70})"
echo ""
echo -e "  ${YELLOW}Telegram bot token và chat IDs đã được lưu vào vault.yml${NC}"
echo ""

# ── Prompt encrypt ──
log_section "Mã hóa vault.yml"
read -rp "  Mã hóa vault.yml ngay bây giờ? [Y/n] " do_encrypt
do_encrypt="${do_encrypt:-Y}"

if [[ "$do_encrypt" =~ ^[Yy]$ ]]; then
    if ! command -v ansible-vault >/dev/null 2>&1; then
        log_error "ansible-vault không tìm thấy — cài Ansible trước."
        log_warn "Chạy thủ công sau: ansible-vault encrypt $VAULT_FILE"
        exit 0
    fi

    if [ -n "$VAULT_PASS_FILE" ]; then
        if [ ! -f "$VAULT_PASS_FILE" ]; then
            log_error "Vault pass file không tồn tại: $VAULT_PASS_FILE"
            exit 1
        fi
        ansible-vault encrypt "$VAULT_FILE" --vault-password-file "$VAULT_PASS_FILE"
        log_info "vault.yml đã được mã hóa (dùng pass file: $VAULT_PASS_FILE)"
    else
        echo -e "  ${YELLOW}Nhập vault password (sẽ dùng khi deploy):${NC}"
        ansible-vault encrypt "$VAULT_FILE"
        log_info "vault.yml đã được mã hóa!"
    fi

    echo ""
    log_info "Hoàn thành! Bước tiếp theo:"
    echo -e "  ${CYAN}1.${NC} Điền IP vào inventory/ (monitoring.yml, site-*.yml)"
    echo -e "  ${CYAN}2.${NC} Điền VIP vào inventory/group_vars/all.yml  (vip_address)"
    echo -e "  ${CYAN}3.${NC} make deploy"
else
    log_warn "vault.yml CHƯA được mã hóa."
    log_warn "Chạy thủ công: ansible-vault encrypt $VAULT_FILE"
    log_warn "Hoặc: make vault-encrypt"
fi

echo ""
echo -e "  ${BOLD}${GREEN}✅ gen-vault.sh hoàn thành!${NC}"
echo ""
