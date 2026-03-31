# =============================================================================
# Makefile — monitoring-ansible v6.1
# =============================================================================
# Cách dùng:
#   make help              — Xem tất cả lệnh
#   make init              — Khởi tạo lần đầu (gen passwords + deps)
#   make deploy            — Deploy toàn bộ hệ thống
#   make verify            — Kiểm tra sức khỏe
# =============================================================================

SHELL           := /bin/bash
INVENTORY       := inventory/
PLAYBOOKS       := playbooks
VAULT_FILE      := inventory/group_vars/vault.yml
ANSIBLE_OPTS    ?=

.DEFAULT_GOAL := help

# ── Colors ──────────────────────────────────────────────────────────────────
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
BOLD   := \033[1m
NC     := \033[0m

# ── Vault guard ──────────────────────────────────────────────────────────────
.PHONY: vault-check
vault-check:
	@if [ ! -f "$(VAULT_FILE)" ]; then \
		echo -e "$(RED)[✘] vault.yml không tồn tại! Chạy: make init$(NC)"; \
		exit 1; \
	fi
	@if ! head -1 "$(VAULT_FILE)" | grep -q '^\$$ANSIBLE_VAULT'; then \
		echo -e "$(RED)[✘] vault.yml chưa được mã hóa! Chạy: make vault-encrypt$(NC)"; \
		exit 1; \
	fi
	@echo -e "$(GREEN)[✔] vault.yml đã mã hóa$(NC)"

# ── Dependencies ─────────────────────────────────────────────────────────────
.PHONY: deps
deps:  ## Cài Ansible Galaxy collections (community.docker, community.general)
	@echo -e "$(CYAN)▶ Cài đặt Ansible collections...$(NC)"
	ansible-galaxy collection install -r requirements.yml
	@echo -e "$(GREEN)[✔] Collections đã cài xong$(NC)"

# ── Init ─────────────────────────────────────────────────────────────────────
.PHONY: init
init: deps  ## Khởi tạo lần đầu: gen passwords + cài collections
	@echo -e "$(BOLD)$(CYAN)▶ Khởi tạo vault passwords...$(NC)"
	bash scripts/gen-vault.sh

# ── Lint & QA ────────────────────────────────────────────────────────────────
.PHONY: lint
lint:  ## Chạy ansible-lint trên site.yml
	@echo -e "$(CYAN)▶ Ansible Lint$(NC)"
	@command -v ansible-lint >/dev/null 2>&1 || pip3 install ansible-lint
	ansible-lint $(PLAYBOOKS)/site.yml

.PHONY: syntax-check
syntax-check:  ## Kiểm tra syntax tất cả playbooks
	@echo -e "$(CYAN)▶ Syntax Check — site.yml$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/site.yml --syntax-check $(ANSIBLE_OPTS)
	@echo -e "$(CYAN)▶ Syntax Check — stacks/$(NC)"
	@for f in $(PLAYBOOKS)/stacks/*.yml; do \
		echo "  Checking: $$f"; \
		ansible-playbook -i $(INVENTORY) "$$f" --syntax-check $(ANSIBLE_OPTS); \
	done
	@echo -e "$(GREEN)[✔] Tất cả playbooks syntax OK$(NC)"

.PHONY: ping
ping:  ## Ping tất cả nodes
	ansible all -i $(INVENTORY) -m ping --one-line

# ── Full Deploy ───────────────────────────────────────────────────────────────
.PHONY: deploy
deploy: vault-check  ## Deploy toàn bộ hệ thống
	@echo -e "$(BOLD)$(GREEN)▶ Deploying monitoring stack...$(NC)"
	./run.sh deploy $(ANSIBLE_OPTS)

# ── Stack Deploy ──────────────────────────────────────────────────────────────
.PHONY: deploy-infra
deploy-infra: vault-check  ## Deploy infrastructure (common+docker+keepalived+haproxy)
	@echo -e "$(BOLD)$(GREEN)▶ Deploying Infrastructure stack...$(NC)"
	./run.sh infra $(ANSIBLE_OPTS)

.PHONY: deploy-monitoring
deploy-monitoring: vault-check  ## Deploy monitoring stack (VictoriaMetrics+vmagent+alertmanager)
	@echo -e "$(BOLD)$(GREEN)▶ Deploying Monitoring stack...$(NC)"
	./run.sh monitoring $(ANSIBLE_OPTS)

.PHONY: deploy-grafana
deploy-grafana: vault-check  ## Deploy visualization (Grafana+PostgreSQL)
	@echo -e "$(BOLD)$(GREEN)▶ Deploying Grafana stack...$(NC)"
	./run.sh grafana $(ANSIBLE_OPTS)

.PHONY: deploy-logging
deploy-logging: vault-check  ## Deploy logging stack (Loki+Promtail+MinIO)
	@echo -e "$(BOLD)$(GREEN)▶ Deploying Logging stack...$(NC)"
	./run.sh logging $(ANSIBLE_OPTS)

.PHONY: deploy-gitops
deploy-gitops: vault-check  ## Deploy GitOps (Gitea)
	@echo -e "$(BOLD)$(GREEN)▶ Deploying GitOps stack...$(NC)"
	./run.sh gitops $(ANSIBLE_OPTS)

# ── Exporter Deploy ───────────────────────────────────────────────────────────
.PHONY: deploy-exporters
deploy-exporters:  ## Deploy tất cả exporters
	./run.sh exporters $(ANSIBLE_OPTS)

.PHONY: deploy-node-exporter
deploy-node-exporter:  ## Deploy node_exporter only
	./run.sh node-exporter $(ANSIBLE_OPTS)

.PHONY: deploy-blackbox
deploy-blackbox:  ## Deploy blackbox/random-ping
	./run.sh blackbox $(ANSIBLE_OPTS)

.PHONY: deploy-ceph-exporter
deploy-ceph-exporter:  ## Deploy Ceph exporter
	./run.sh ceph-exporter $(ANSIBLE_OPTS)

.PHONY: deploy-openstack-exporter
deploy-openstack-exporter:  ## Deploy OpenStack exporter
	./run.sh openstack-exporter $(ANSIBLE_OPTS)

.PHONY: gen-config
gen-config:  ## Generate vmagent scrape configs từ inventory
	@echo -e "$(YELLOW)Tip: ANSIBLE_OPTS='-e \"node_groups=[...] ceph_groups=[...]\"' make gen-config$(NC)"
	./run.sh gen-config $(ANSIBLE_OPTS)

# ── Reconfig ──────────────────────────────────────────────────────────────────
.PHONY: reconfig
reconfig:  ## Reconfig toàn bộ (interactive)
	./run.sh reconfig $(ANSIBLE_OPTS)

.PHONY: reconfig-monitoring
reconfig-monitoring:  ## Reload vmagent + alert rules
	./run.sh reconfig-monitoring $(ANSIBLE_OPTS)

.PHONY: reconfig-grafana
reconfig-grafana:  ## Reload Grafana datasources
	./run.sh reconfig-grafana $(ANSIBLE_OPTS)

.PHONY: reconfig-logging
reconfig-logging:  ## Reload Loki + Promtail
	./run.sh reconfig-logging $(ANSIBLE_OPTS)

.PHONY: reconfig-alertmanager
reconfig-alertmanager:  ## Reload Alertmanager
	./run.sh reconfig-alertmanager $(ANSIBLE_OPTS)

.PHONY: reconfig-haproxy
reconfig-haproxy:  ## Reload HAProxy backends
	./run.sh reconfig-haproxy $(ANSIBLE_OPTS)

.PHONY: reconfig-exporters
reconfig-exporters:  ## Reload scrape targets
	./run.sh reconfig-exporters $(ANSIBLE_OPTS)

# ── Operations ────────────────────────────────────────────────────────────────
.PHONY: verify
verify:  ## Kiểm tra sức khỏe hệ thống
	@echo -e "$(BOLD)$(CYAN)▶ Verifying system health...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/ops/verify.yml $(ANSIBLE_OPTS)

.PHONY: upgrade
upgrade: vault-check  ## Nâng cấp version các thành phần (rolling, no downtime)
	@echo -e "$(BOLD)$(YELLOW)▶ Upgrading components...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/ops/upgrade.yml \
		--ask-vault-pass \
		--extra-vars "confirm_upgrade=true" \
		$(ANSIBLE_OPTS)

.PHONY: backup
backup: vault-check  ## Backup VictoriaMetrics + PostgreSQL + Grafana
	@echo -e "$(BOLD)$(CYAN)▶ Backing up data...$(NC)"
	ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/ops/backup.yml \
		--ask-vault-pass \
		$(ANSIBLE_OPTS)

.PHONY: scale
scale:  ## Scale từng service (interactive)
	./run.sh scale $(ANSIBLE_OPTS)

.PHONY: destroy
destroy:  ## Gỡ bỏ toàn bộ hệ thống (nguy hiểm!)
	@echo -e "$(BOLD)$(RED)▶ Destroying system...$(NC)"
	@read -p "Gõ 'DESTROY' để xác nhận: " confirm && \
	if [ "$$confirm" = "DESTROY" ]; then \
		ansible-playbook -i $(INVENTORY) $(PLAYBOOKS)/ops/destroy.yml \
			--extra-vars "confirm_destroy=true" $(ANSIBLE_OPTS); \
	else \
		echo "Hủy bỏ."; \
	fi

# ── Vault Management ──────────────────────────────────────────────────────────
.PHONY: vault-init
vault-init:  ## Tạo vault.yml từ example
	@if [ -f "$(VAULT_FILE)" ]; then \
		echo -e "$(YELLOW)[!] vault.yml đã tồn tại$(NC)"; \
	else \
		cp inventory/group_vars/vault.yml.example $(VAULT_FILE); \
		echo -e "$(GREEN)[✔] vault.yml được tạo. Hãy điền secrets rồi chạy: make vault-encrypt$(NC)"; \
	fi

.PHONY: vault-encrypt
vault-encrypt:  ## Mã hóa vault.yml
	bash scripts/vault-encrypt.sh

.PHONY: vault-edit
vault-edit:  ## Chỉnh sửa vault.yml (auto decrypt/encrypt)
	ansible-vault edit $(VAULT_FILE)

.PHONY: vault-view
vault-view:  ## Xem nội dung vault.yml
	ansible-vault view $(VAULT_FILE)

# ── Help ──────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo ""
	@echo -e "$(BOLD)  VNPT Cloud — HA Monitoring System v6.1$(NC)"
	@echo -e "  $(CYAN)make <target>$(NC)  |  $(CYAN)./run.sh <action>$(NC)"
	@echo ""
	@echo -e "  $(BOLD)── Setup ─────────────────────────────────────────$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		grep -E "^(init|deps|vault-)" | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── Full Deploy ───────────────────────────────────$(NC)"
	@grep -E '^deploy:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── Stack Deploy ──────────────────────────────────$(NC)"
	@grep -E '^deploy-[a-z]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── Exporter Deploy ───────────────────────────────$(NC)"
	@grep -E '^(deploy-exporters|deploy-node|deploy-blackbox|deploy-ceph|deploy-openstack|gen-config):.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── Reconfig (no downtime) ────────────────────────$(NC)"
	@grep -E '^reconfig[a-z-]*:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── Operations ────────────────────────────────────$(NC)"
	@grep -E '^(verify|upgrade|backup|scale|destroy|ping):.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)── QA / CI ───────────────────────────────────────$(NC)"
	@grep -E '^(lint|syntax-check):.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(BOLD)Options:$(NC)"
	@echo -e "  $(YELLOW)ANSIBLE_OPTS$(NC)  Truyền thêm args, vd: make deploy ANSIBLE_OPTS='--check -vv'"
	@echo ""

## ─── Security Checks ───────────────────────────────────────────────
check-vault:
	@echo "🔐 Checking vault security..."
	@if grep -q "CHANGE_ME" .vault_pass 2>/dev/null; then \
		echo "❌ .vault_pass chưa được cập nhật! Thay CHANGE_ME bằng password thật"; exit 1; \
	fi
	@if git ls-files --error-unmatch inventory/group_vars/all/vault.yml 2>/dev/null; then \
		echo "❌ vault.yml đang bị track bởi git! Chạy: git rm --cached inventory/group_vars/all/vault.yml"; exit 1; \
	fi
	@echo "✅ Vault security OK"

pre-deploy: check-vault deps
	@echo "✅ Pre-deploy checks passed — ready to deploy"
