#!/usr/bin/env bash
# =============================================================================
# scripts/vault-encrypt.sh — Tiện ích quản lý Ansible Vault
# =============================================================================
#
# Cách dùng:
#   ./scripts/vault-encrypt.sh           — Encrypt vault.yml (tạo mới nếu chưa có)
#   ./scripts/vault-encrypt.sh decrypt   — Decrypt vault.yml (cẩn thận!)
#   ./scripts/vault-encrypt.sh rekey     — Đổi vault password
#   ./scripts/vault-encrypt.sh status    — Kiểm tra trạng thái vault.yml
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$PROJECT_DIR/inventory/group_vars/vault.yml"
VAULT_EXAMPLE="$PROJECT_DIR/inventory/group_vars/vault.yml.example"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "  ${GREEN}[✔]${NC} $*"; }
log_warn()  { echo -e "  ${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "  ${RED}[✘]${NC} $*"; }

# ── Check ansible-vault ──────────────────────────────────────────────────────
check_ansible() {
    command -v ansible-vault >/dev/null 2>&1 || {
        log_error "ansible-vault không tìm thấy! Hãy cài Ansible trước."
        exit 1
    }
}

# ── Status ───────────────────────────────────────────────────────────────────
vault_status() {
    echo -e "\n  ${BOLD}${CYAN}Vault Status${NC}"
    echo "  ──────────────────────────────────────"

    if [ ! -f "$VAULT_FILE" ]; then
        log_warn "vault.yml KHÔNG tồn tại"
        echo -e "  Chạy: cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml"
        echo -e "  Rồi:  $0 encrypt"
        return
    fi

    if head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
        log_info "vault.yml ĐÃ ĐƯỢC MÃ HÓA ✅"
        local vault_id
        vault_id=$(head -1 "$VAULT_FILE" | awk -F';' '{print $2}')
        echo -e "  Vault format: $vault_id"
    else
        log_error "vault.yml CHƯA MÃ HÓA ⚠️  — Không được commit!"
        echo ""
        echo -e "  ${YELLOW}Danh sách keys trong file:${NC}"
        grep "^[a-z]" "$VAULT_FILE" | awk -F: '{print "    -", $1}' || true
    fi
    echo ""
}

# ── Encrypt ──────────────────────────────────────────────────────────────────
vault_encrypt() {
    check_ansible

    if [ ! -f "$VAULT_FILE" ]; then
        log_warn "vault.yml chưa tồn tại. Tạo từ example..."
        cp "$VAULT_EXAMPLE" "$VAULT_FILE"
        log_info "Đã tạo vault.yml từ example"
        echo ""
        echo -e "  ${YELLOW}Hãy điền đầy đủ thông tin vào vault.yml trước khi encrypt:${NC}"
        echo -e "  ${CYAN}  vim $VAULT_FILE${NC}"
        echo ""
        read -rp "  Tiếp tục encrypt luôn? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }
    fi

    if head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
        log_warn "vault.yml đã được mã hóa rồi. Dùng --rekey để đổi password."
        exit 0
    fi

    echo -e "\n  ${BOLD}Encrypt vault.yml${NC}"
    echo "  ──────────────────────────────────────"
    log_warn "Nhớ lưu vault password ở nơi an toàn!"
    echo ""

    ansible-vault encrypt "$VAULT_FILE"

    log_info "vault.yml đã được mã hóa thành công!"
    echo ""
    echo -e "  ${GREEN}Bây giờ bạn có thể commit vault.yml một cách an toàn.${NC}"
    echo -e "  Khi chạy playbook, dùng: --ask-vault-pass hoặc --vault-password-file"
}

# ── Decrypt ──────────────────────────────────────────────────────────────────
vault_decrypt() {
    check_ansible

    if [ ! -f "$VAULT_FILE" ]; then
        log_error "vault.yml không tồn tại!"
        exit 1
    fi

    if ! head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
        log_warn "vault.yml chưa được mã hóa"
        exit 0
    fi

    echo -e "\n  ${RED}${BOLD}⚠️  CẢNH BÁO${NC}"
    echo "  ──────────────────────────────────────"
    log_warn "Decrypt sẽ tạo file plaintext. KHÔNG được commit khi đã decrypt!"
    echo ""
    read -rp "  Xác nhận decrypt? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Hủy bỏ."; exit 0; }

    ansible-vault decrypt "$VAULT_FILE"
    log_info "vault.yml đã được decrypt. Nhớ encrypt lại sau khi chỉnh sửa!"
}

# ── Rekey ─────────────────────────────────────────────────────────────────────
vault_rekey() {
    check_ansible

    if [ ! -f "$VAULT_FILE" ]; then
        log_error "vault.yml không tồn tại!"
        exit 1
    fi

    if ! head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
        log_error "vault.yml chưa được mã hóa! Encrypt trước."
        exit 1
    fi

    echo -e "\n  ${BOLD}Đổi Vault Password${NC}"
    echo "  ──────────────────────────────────────"

    ansible-vault rekey "$VAULT_FILE"
    log_info "Đã đổi vault password thành công!"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ACTION="${1:-encrypt}"

case "$ACTION" in
    encrypt|enc)    vault_encrypt ;;
    decrypt|dec)    vault_decrypt ;;
    rekey)          vault_rekey ;;
    status|check)   vault_status ;;
    *)
        echo "Cách dùng: $0 [encrypt|decrypt|rekey|status]"
        echo "  encrypt  — Mã hóa vault.yml (mặc định)"
        echo "  decrypt  — Giải mã vault.yml (cẩn thận!)"
        echo "  rekey    — Đổi vault password"
        echo "  status   — Kiểm tra trạng thái"
        exit 1
        ;;
esac
