# =============================================================================
# Makefile — monitoring-ansible shortcut commands
# =============================================================================
# Cách dùng:
#   make deploy      — Deploy toàn bộ hệ thống
#   make verify      — Kiểm tra sức khỏe hệ thống
#   make upgrade     — Nâng cấp version các thành phần
#   make backup      — Backup dữ liệu
#   make destroy     — Gỡ bỏ toàn bộ hệ thống
#   make help        — Hiển thị hướng dẫn này
# =============================================================================

SHELL           := /bin/bash
INVENTORY       := inventory/hosts.yml
PLAYBOOKS       := playbooks
VAULT_FILE      := inventory/group_vars/vault.yml
ANSIBLE_OPTS    ?=

.DEFAULT_GOAL := help

# ── Colors ─────────────────────────────────────────────────────────────────
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
BOLD   := \033[1m
NC     := \033[0m

# ── Vault guard ─────────────────────────────────────────────────────────────
.PHONY: vault-check
vault-check:
	@if [ ! -f "$(VAULT_FILE)" ]; then \
		echo -e "$(RED)[✘] vault.yml không tồn tại! Chạy: make vault-init$(NC)"; \
		exit 1; \
	fi
	@if ! head -1 "$(VAULT_FILE)" | grep -q '^\$$ANSIBLE_VAULT'; then \
		echo -e "$(RED)[✘] vault.yml chưa được mã hóa! Chạy: make vault-encrypt$(NC)"; \
		exit 1; \
	fi
	@echo -e "$(GREEN)[✔] vault.yml đã mã hóa$(NC)"

# ── Lint ─────────────────────────────────────────────────────────────────────
.PHONY: lint
lint:
	@echo -e "$(CYAN)▶ Ansible Lint$(NC)"
	@command -v ansible-lint >/dev/null 2>&1 || pip3 install ansible-lint
	ansible-lint $(PLAYBOOKS)/site.yml

# ── Syntax check ─────────────────────────────────────────────────────────────
.PHONY: syntax-check
syntax-check:
	@echo -e "$(CYAN)▶ Syntax Check$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/site.yml --syntax-check $(ANSIBLE_OPTS)

# ── Deploy ───────────────────────────────────────────────────────────────────
.PHONY: deploy
deploy: vault-check
	@echo -e "$(BOLD)$(GREEN)▶ Deploying monitoring stack...$(NC)"
	./run.sh deploy $(ANSIBLE_OPTS)

# ── Verify ───────────────────────────────────────────────────────────────────
.PHONY: verify
verify:
	@echo -e "$(BOLD)$(CYAN)▶ Verifying system health...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/verify.yml $(ANSIBLE_OPTS)

# ── Upgrade ──────────────────────────────────────────────────────────────────
.PHONY: upgrade
upgrade: vault-check
	@echo -e "$(BOLD)$(YELLOW)▶ Upgrading components...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/upgrade.yml \
		--ask-vault-pass \
		--extra-vars "confirm_upgrade=true" \
		$(ANSIBLE_OPTS)

# ── Backup ───────────────────────────────────────────────────────────────────
.PHONY: backup
backup: vault-check
	@echo -e "$(BOLD)$(CYAN)▶ Backing up data...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/backup.yml \
		--ask-vault-pass \
		$(ANSIBLE_OPTS)

# ── Destroy ──────────────────────────────────────────────────────────────────
.PHONY: destroy
destroy:
	@echo -e "$(BOLD)$(RED)▶ Destroying system...$(NC)"
	@read -p "Gõ 'DESTROY' để xác nhận: " confirm && \
	if [ "$$confirm" = "DESTROY" ]; then \
		ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/destroy.yml \
			--extra-vars "confirm_destroy=true" $(ANSIBLE_OPTS); \
	else \
		echo "Hủy bỏ."; \
	fi

# ── Reconfig ─────────────────────────────────────────────────────────────────
.PHONY: reconfig
reconfig: vault-check
	@echo -e "$(BOLD)$(CYAN)▶ Reconfiguring...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/reconfig.yml \
		--ask-vault-pass \
		$(ANSIBLE_OPTS)

# ── Vault management ─────────────────────────────────────────────────────────
.PHONY: vault-init
vault-init:
	@if [ -f "$(VAULT_FILE)" ]; then \
		echo -e "$(YELLOW)[!] vault.yml đã tồn tại$(NC)"; \
	else \
		cp inventory/group_vars/vault.yml.example $(VAULT_FILE); \
		echo -e "$(GREEN)[✔] vault.yml được tạo từ example. Hãy điền secrets rồi chạy: make vault-encrypt$(NC)"; \
	fi

.PHONY: vault-encrypt
vault-encrypt:
	@bash scripts/vault-encrypt.sh

.PHONY: vault-edit
vault-edit:
	ansible-vault edit $(VAULT_FILE)

.PHONY: vault-view
vault-view:
	ansible-vault view $(VAULT_FILE)

# ── Ping ─────────────────────────────────────────────────────────────────────
.PHONY: ping
ping:
	ansible all -i $(INVENTORY) -m ping --one-line

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo ""
	@echo -e "$(BOLD)  VNPT Cloud — HA Monitoring System$(NC)"
	@echo -e "  $(CYAN)make <target>$(NC)"
	@echo ""
	@echo -e "  $(BOLD)Deploy & Operate:$(NC)"
	@echo -e "  $(GREEN)deploy$(NC)          Deploy toàn bộ hệ thống"
	@echo -e "  $(GREEN)verify$(NC)          Kiểm tra sức khỏe hệ thống"
	@echo -e "  $(GREEN)upgrade$(NC)         Nâng cấp version các thành phần"
	@echo -e "  $(GREEN)backup$(NC)          Backup dữ liệu"
	@echo -e "  $(GREEN)reconfig$(NC)        Cập nhật cấu hình"
	@echo -e "  $(RED)destroy$(NC)         Gỡ bỏ toàn bộ hệ thống (nguy hiểm!)"
	@echo ""
	@echo -e "  $(BOLD)Vault Management:$(NC)"
	@echo -e "  $(CYAN)vault-init$(NC)      Tạo vault.yml từ example"
	@echo -e "  $(CYAN)vault-encrypt$(NC)   Mã hóa vault.yml"
	@echo -e "  $(CYAN)vault-edit$(NC)      Chỉnh sửa vault.yml (auto decrypt/encrypt)"
	@echo -e "  $(CYAN)vault-view$(NC)      Xem vault.yml"
	@echo ""
	@echo -e "  $(BOLD)CI / QA:$(NC)"
	@echo -e "  $(CYAN)lint$(NC)            Chạy ansible-lint"
	@echo -e "  $(CYAN)syntax-check$(NC)    Kiểm tra syntax playbooks"
	@echo -e "  $(CYAN)ping$(NC)            Ping tất cả nodes"
	@echo ""
	@echo -e "  $(BOLD)Options:$(NC)"
	@echo -e "  $(YELLOW)ANSIBLE_OPTS$(NC)    Truyền thêm args, vd: make deploy ANSIBLE_OPTS='--check -vv'"
	@echo ""

## Random Ping
.PHONY: random-ping
random-ping: vault-check
	./run.sh random-ping

.PHONY: random-ping-check
random-ping-check:
	ansible-playbook -i inventory/hosts.yml playbooks/random-ping.yml --check
